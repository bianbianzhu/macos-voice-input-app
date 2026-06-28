import Foundation

/// Pure, thread-agnostic logic for composing a streaming dictation transcript from
/// `SFSpeechRecognizer`'s partial hypotheses across Apple's silent endpoint resets.
///
/// This type has NO dependency on Speech / AVFoundation / AppKit, so it can be unit
/// tested deterministically. `SpeechTranscriber` owns one instance behind its lock and
/// feeds it the recognizer's `bestTranscription.formattedString` on each callback.
///
/// Background:
/// - Apple's streaming recognizer occasionally REPLACES `bestTranscription` with a
///   fresh, much shorter string after a pause (no `isFinal`). We DETECT that backward
///   jump (`isBackwardReset`) and COMMIT the prior segment so long dictation is not
///   lost.
/// - BUT that reset is sometimes a *rewind*: the fresh string RE-TRANSCRIBES audio that
///   is already in the committed text (slightly differently — different word choices,
///   even different capitalization). Naively appending it duplicates the overlapping
///   chunk. `compose` suppresses that overlap so the re-transcribed tail appears once.
public struct TranscriptComposer {

    /// Segments finalized across silent resets and request restarts.
    public private(set) var committedText: String = ""
    /// The recognizer's current in-flight hypothesis (not yet committed).
    public private(set) var currentSegment: String = ""

    public init() {}

    /// The full live transcript: committed segments + the in-flight one, with any
    /// re-transcription overlap removed. This is what `stop()` ultimately returns.
    public var composed: String {
        TranscriptComposer.compose(committed: committedText, segment: currentSegment)
    }

    /// Apply one recognizer hypothesis `p` (the full `bestTranscription` string for the
    /// CURRENT request). Pass `isFinal` from the result; a final commits the segment.
    public mutating func apply(_ p: String, isFinal: Bool) {
        // Apple's silent endpoint reset: the live hypothesis jumps backward to a fresh,
        // much shorter string that does not extend the current one. Commit the prior
        // segment so it is not overwritten. A normal in-place revision ("I scream" ->
        // "ice cream") keeps a long shared prefix and does NOT count as a reset.
        if !currentSegment.isEmpty,
           TranscriptComposer.isBackwardReset(from: currentSegment, to: p) {
            committedText = TranscriptComposer.compose(committed: committedText, segment: currentSegment)
        }
        currentSegment = p

        // `isFinal` does not fire per-utterance for a streaming request, so when it DOES
        // arrive mid-session the recognizer hit its cap. Commit so the caller can restart
        // without losing what was captured.
        if isFinal {
            committedText = TranscriptComposer.compose(committed: committedText, segment: currentSegment)
            currentSegment = ""
        }
    }

    /// Commit the in-flight segment after a mid-session recognizer error (the request is
    /// about to be replaced). Leaves `committedText` as the full transcript so far.
    public mutating func commitOnError() {
        committedText = TranscriptComposer.compose(committed: committedText, segment: currentSegment)
        currentSegment = ""
    }

    /// Reset to empty for a new session.
    public mutating func reset() {
        committedText = ""
        currentSegment = ""
    }

    // MARK: - Overlap-suppression tuning

    /// Minimum length (characters) of the identical run shared by the committed tail and
    /// the new segment for us to treat them as the SAME span (a rewind) and splice. Real
    /// duplicated chunks share very long identical runs (80+ chars); genuine repeated
    /// short phrases ("please remember to ", "请记得写") share far less, so this threshold
    /// separates a rewind from an intentional repeat.
    private static let overlapMinRun = 24
    /// Slack (characters) for bounding the comparison windows and the data-loss length
    /// check — absorbs the small word-length differences between two re-transcriptions.
    private static let overlapSlack = 16
    /// Hard cap on the comparison window so the O(window²) run scan stays cheap even on a
    /// pathologically long single hypothesis. A rewind overlap sits at the committed/segment
    /// boundary, well within this, so capping never hides a real overlap.
    private static let overlapMaxWindow = 4096

    // MARK: - Pure helpers

    /// Joins committed text and the in-flight segment, suppressing the case where the
    /// segment RE-TRANSCRIBES the tail of the committed text (Apple's silent "rewind"
    /// reset). The recognizer re-transcribes that span with scattered word-level edits —
    /// even a changed LEADING word or capitalization ("…土耳`其`…" → "…土耳`族`…",
    /// "Double-sided `tape`…" → "Double-sided `tapes`…") — so an exact-prefix anchor is
    /// too fragile. Instead we find the longest identical RUN shared by committed's tail
    /// and the segment's head and splice there: keep committed up to the run, then the
    /// (fresher, longer) segment from the run onward. The run is identical in both, so the
    /// splice neither duplicates nor drops it.
    ///
    /// Fails safe to a plain join unless (a) the shared run is long enough to be a real
    /// rewind rather than a coincidental short repeat, and (b) the segment from the run
    /// onward is long enough to re-cover the committed tail it replaces — otherwise
    /// splicing would silently drop trailing committed content (data loss / 现象2).
    public static func compose(committed: String, segment: String) -> String {
        if committed.isEmpty { return segment }
        if segment.isEmpty { return committed }

        let c = Array(committed)
        let s = Array(segment)

        // A rewind re-covers only a bounded tail of committed, so restrict the search to
        // committed's tail window and the segment's head — keeps this O(window²), and the
        // hard cap bounds the worst case regardless of input length.
        let cWindowLen = min(c.count, s.count + overlapSlack, overlapMaxWindow)
        let cStart = c.count - cWindowLen
        let sWindowLen = min(s.count, cWindowLen + overlapSlack, overlapMaxWindow)

        // Case-insensitive matching (the recognizer re-capitalizes), but slice the
        // ORIGINALS. Lowercasing is 1:1 for ASCII/CJK; if it ever changes the character
        // count we fall back to case-sensitive so indices stay aligned.
        let cLower = Array(committed.lowercased())
        let sLower = Array(segment.lowercased())
        let aligned = (cLower.count == c.count && sLower.count == s.count)
        let cMatch = Array((aligned ? cLower : c)[cStart..<c.count])
        let sMatch = Array((aligned ? sLower : s)[0..<sWindowLen])

        let (runLen, cEndInWindow, sEnd) = longestCommonRun(cMatch, sMatch)
        guard runLen >= overlapMinRun else { return join(committed, segment) }

        let cAnchor = cStart + (cEndInWindow - runLen + 1)   // run start in committed
        let sAnchor = sEnd - runLen + 1                       // run start in segment
        let committedTail = c.count - cAnchor
        let segmentTail = s.count - sAnchor
        guard segmentTail >= committedTail - overlapSlack else { return join(committed, segment) }

        return join(String(c[0..<cAnchor]), String(s[sAnchor..<s.count]))
    }

    /// Longest common substring (the matchers are already case-folded) between two
    /// Character arrays, returned as (length, endIndexInA, endIndexInB). O(a·b) time,
    /// O(b) space via a rolling row.
    private static func longestCommonRun(_ a: [Character], _ b: [Character]) -> (Int, Int, Int) {
        if a.isEmpty || b.isEmpty { return (0, 0, 0) }
        var prev = [Int](repeating: 0, count: b.count + 1)
        var curr = [Int](repeating: 0, count: b.count + 1)
        var best = 0, aEnd = 0, bEnd = 0
        for i in 1...a.count {
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    curr[j] = prev[j - 1] + 1
                    if curr[j] > best { best = curr[j]; aEnd = i - 1; bEnd = j - 1 }
                } else {
                    curr[j] = 0
                }
            }
            swap(&prev, &curr)
            for j in 0...b.count { curr[j] = 0 }
        }
        return (best, aEnd, bEnd)
    }

    /// True for Apple's silent endpoint reset: `p` is shorter than `current` and does
    /// not share a long common prefix with it (a normal revision keeps most of its
    /// prefix). Requiring shared < half of `p` rejects ordinary retractions. (An empty
    /// `p` shares a 0-length prefix with a 0 threshold and is therefore NOT a reset.)
    public static func isBackwardReset(from current: String, to p: String) -> Bool {
        guard p.count < current.count else { return false }
        let shared = current.commonPrefix(with: p).count
        return Double(shared) < 0.5 * Double(p.count)
    }

    /// Boundary-aware concatenation: a single space ONLY between two ASCII word
    /// characters (so CJK and punctuation boundaries get no space, and an empty side
    /// yields no separator).
    private static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        if let last = a.last, let first = b.first,
           isASCIIWordChar(last), isASCIIWordChar(first) {
            return a + " " + b
        }
        return a + b
    }

    /// ASCII letters, digits, and underscore — the boundary characters that need a
    /// separating space between two committed English segments.
    private static func isASCIIWordChar(_ c: Character) -> Bool {
        return c.isASCII && (c.isLetter || c.isNumber || c == "_")
    }
}
