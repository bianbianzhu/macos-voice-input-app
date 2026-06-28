import Foundation
import VoiceInputCore

// Plain (non-XCTest) test runner so the suite builds with only the Command Line Tools.
// `swift run TranscriptComposerTests` — exits non-zero if any check fails.
//
// The headline cases (rewindReset_*) reproduce the duplicated-chunk bug observed in UAT
// and proven with a real SFSpeechRecognizer capture: Apple's silent endpoint reset
// sometimes REWINDS and re-transcribes already-committed audio (often re-capitalized),
// which the old `committed + " " + segment` join duplicated.

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ message: @autoclosure () -> String,
            _ function: String = #function, _ line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        FileHandle.standardError.write("FAIL [\(function):\(line)] \(message())\n".data(using: .utf8)!)
    }
}

func expectEqual(_ a: String, _ b: String, _ label: String,
                 _ function: String = #function, _ line: Int = #line) {
    expect(a == b, "\(label): expected \"\(b)\" got \"\(a)\"", function, line)
}

func occurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var idx = haystack.startIndex
    while let r = haystack.range(of: needle, range: idx..<haystack.endIndex) {
        count += 1
        idx = r.upperBound
    }
    return count
}

func test(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    let status = failures == before ? "ok  " : "FAIL"
    print("[\(status)] \(name)")
}

// MARK: - Normal streaming (no reset)

test("monotonic growth returns latest hypothesis") {
    var c = TranscriptComposer()
    c.apply("hello", isFinal: false)
    c.apply("hello world", isFinal: false)
    c.apply("hello world this is a test", isFinal: false)
    expectEqual(c.composed, "hello world this is a test", "composed")
    expectEqual(c.committedText, "", "committed stays empty")
}

test("in-place revision is not a reset") {
    expect(!TranscriptComposer.isBackwardReset(from: "I scream you scream", to: "I scream"),
           "retraction sharing a long prefix is not a reset")
    var c = TranscriptComposer()
    c.apply("I scream you scream for", isFinal: false)
    c.apply("I scream you scream", isFinal: false)
    expectEqual(c.committedText, "", "a retraction must not commit")
    expectEqual(c.composed, "I scream you scream", "composed")
}

// MARK: - Clean reset (common case — must still concatenate)

test("clean backward reset concatenates both segments") {
    var c = TranscriptComposer()
    c.apply("the data pipeline and the integration layer", isFinal: false)
    c.apply("That", isFinal: false)
    c.apply("That connects all the different modules together", isFinal: false)
    expectEqual(c.composed,
        "the data pipeline and the integration layer That connects all the different modules together",
        "composed")
    expect(occurrences(of: "the integration layer", in: c.composed) == 1, "no spurious dup")
}

// MARK: - Rewind reset (THE bug) — must de-duplicate

test("rewind reset (user case) deduplicates re-transcribed tail") {
    let full = "so you only need to interact with one single point It saves a lot of time and money for the end user as a lead engineer in my responsibility is a development we have our flagship product called a role like which is a conversational"
    let regrown = "It saves a lot of time and money for the end user as a lead engineer my responsibility is a development we have our flagship product called real like which is a conversational and operation"

    // Sanity: the OLD naive concatenation duplicates the chunk (reproduces the bug).
    let naive = full + " " + regrown
    expect(occurrences(of: "is a conversational", in: naive) == 2,
           "sanity: naive concat duplicates (the original bug)")

    var c = TranscriptComposer()
    c.apply(full, isFinal: false)
    c.apply("It saves a lot of time and money", isFinal: false) // backward reset (rewind)
    expectEqual(c.committedText, full, "pre-reset segment committed")
    c.apply(regrown, isFinal: false)                            // regrows the overlap

    let fixed = c.composed
    expect(occurrences(of: "is a conversational", in: fixed) == 1, "chunk appears exactly once")
    expect(occurrences(of: "It saves a lot of time", in: fixed) == 1, "head appears exactly once")
    expect(fixed.hasSuffix("and operation"), "fresher, more-complete re-transcription wins")
    expect(fixed.hasPrefix("so you only need to interact with one single point"),
           "text before the overlap is preserved")
}

test("rewind reset uses a case-insensitive anchor") {
    let full = "we have a very good employee discount for this kind of activity and we really love that"
    var c = TranscriptComposer()
    c.apply(full, isFinal: false)
    c.apply("This kind of activity and we really", isFinal: false) // rewind, re-capitalized
    c.apply("This kind of activity and we really love that it is great", isFinal: false)
    expect(occurrences(of: "kind of activity", in: c.composed.lowercased()) == 1,
           "re-capitalized repeat collapses")
    expect(c.composed.hasSuffix("it is great"), "suffix preserved")
}

test("rewind reset collapses a short repeated head") {
    var c = TranscriptComposer()
    c.apply("OK what testing things", isFinal: false)
    c.apply("OK", isFinal: false)                                 // reset
    c.apply("OK what testing things so my name is Jason", isFinal: false)
    expect(occurrences(of: "OK what testing things", in: c.composed) == 1, "head once")
    expectEqual(c.composed, "OK what testing things so my name is Jason", "composed")
}

// MARK: - False-positive safety

test("genuine far-back repeat is not merged") {
    let filler = " and then a lot of other unrelated words go here filling space for quite a while indeed"
    let committed = "the cat sat on the mat" + filler + filler
    let segment = "the cat sat on the mat again it was nice"
    let result = TranscriptComposer.compose(committed: committed, segment: segment)
    expect(occurrences(of: "the cat sat on the mat", in: result) == 2,
           "a far-back repeat is preserved, not destructively merged")
}

test("short new utterance starting with a common word is not merged") {
    let result = TranscriptComposer.compose(committed: "I like the red car", segment: "the bus")
    expectEqual(result, "I like the red car the bus", "plain join")
}

test("a short segment matching committed's HEAD must not drop the trailing clause") {
    // Data-loss guard (found in review/UAT): the new utterance's prefix recurs earlier
    // in committed ("please remember to …"), so the .backwards anchor matches the HEAD,
    // not a tail rewind. The segment is shorter than that committed tail, so suppressing
    // would destroy "and please remember to send the report". Must keep everything.
    var c = TranscriptComposer()
    c.apply("please remember to call the client and please remember to send the report", isFinal: false)
    c.apply("Please", isFinal: false)                                  // backward reset
    c.apply("please remember to call the client tomorrow morning", isFinal: false)
    expect(c.composed.contains("send the report"),
           "trailing committed clause must survive; got: \(c.composed)")
    expect(c.composed.hasSuffix("tomorrow morning"), "new utterance preserved")
}

// MARK: - Real UAT rewind cases (word-level divergence in the overlap)

test("UAT English rewind with changed leading word dedups (tape/tapes)") {
    let committed = "Double-sided tape along the edge or a sheet of aluminum foil laid on the desk when you are away discourages landing there keep the surface clean a clutter free task has nothing to investigate or knock off which removes a lot of of the fun"
    let segment = "Double-sided tapes along the hatch or a sheet of aluminum foil laid on the desk when you are away discourages landing there keep the surface clean a clutter free desk has nothing to investigate or knock off which removes a lot of the fun"
    let r = TranscriptComposer.compose(committed: committed, segment: segment)
    expect(occurrences(of: "aluminum foil laid on the desk", in: r) == 1, "big chunk once; got: \(r)")
    expect(occurrences(of: "has nothing to investigate", in: r) == 1, "second run once")
    expect(!r.contains("  "), "no double spaces at splice")
    expect(r.hasSuffix("a lot of the fun"), "fresher tail kept")
}

test("UAT English rewind with mid-phrase divergence dedups (Cozy/task-test)") {
    let committed = "Cause Cozy cozy bed in your old office somewhere where they can see you helps if the task is really about being near you and also consider be consistent calmly remove the cat every single time without making it again or giving attention"
    let segment = "Cozy cozy bed in your office somewhere they can see you helps if the test is really about being near you and also consider be consistent calmly remove the cat every single time without making it again or giving attention"
    let r = TranscriptComposer.compose(committed: committed, segment: segment)
    expect(occurrences(of: "remove the cat every single time", in: r) == 1, "tail once; got: \(r)")
    expect(occurrences(of: "bed in your", in: r) == 1, "head once")
}

test("UAT Chinese rewind with changed character dedups (其/族)") {
    let committed = "那么土耳其土耳其足球球呢土耳其足球球可以算作欧洲的二线经理不算顶级豪强但实力是在世界范围内属于中上的水平我来帮你梳理几个维度首先是国家队层面土耳其国家队历史上的最辉煌的时刻是2002年韩日世界杯一路杀进了四强最终获得了季军在欧洲杯赛场上六次入围决赛"
    let segment = "那么土耳族土耳其足球球呢土耳其足球可以算作欧洲的二线经理不算顶级豪强但实力是在世界范围内属于中上的水平我来帮你梳理几个维度首先是国家队层面土耳其国家队历史上的最辉煌的时刻是200二年韩日世界杯一路杀进了四强最终获得的季军在欧洲杯赛场上六次入围决赛其中2008年首次晋级四强"
    let r = TranscriptComposer.compose(committed: committed, segment: segment)
    expect(occurrences(of: "土耳其国家队历史上的最辉煌的时刻", in: r) == 1, "chunk once; got: \(r)")
    expect(occurrences(of: "属于中上的水平我来帮你梳理几个维度", in: r) == 1, "chunk once")
    expect(r.contains("其中2008年首次晋级四强"), "continuation kept")
}

// MARK: - Genuine intentional repeats (must NOT merge)

test("intentional repeated English phrases are preserved") {
    var c = TranscriptComposer()
    c.apply("Please remember to send an email", isFinal: false)
    c.apply("please", isFinal: false)                                  // reset
    c.apply("please remember to call", isFinal: false)
    expect(c.composed.contains("send an email"), "first kept; got: \(c.composed)")
    expect(c.composed.contains("call"), "second kept")
}

test("intentional repeated CJK phrases are preserved") {
    let r = TranscriptComposer.compose(committed: "请记得写自己", segment: "请记得写报告")
    expect(r.contains("自己") && r.contains("报告"), "both short repeats kept; got: \(r)")
}

test("compose never merges consecutive same-prefixed reminders (UAT list)") {
    // UAT: "remember to send… remember to make call… … drive your care" — all survived.
    // The relevant guard is that `compose` does not collapse two distinct items that
    // share a sub-threshold prefix ("remember to …", 12 chars < the 24-char run gate).
    let pairs = [
        ("Remember to send an email", "remember to make call"),
        ("remember to make call", "remember to make a lock"),
        ("remember to make a lock", "remember to open the door"),
        ("remember to open the door", "remember to play with the cat"),
        ("remember to play with the cat", "remember to drive your car"),
    ]
    for (a, b) in pairs {
        let r = TranscriptComposer.compose(committed: a, segment: b)
        // Both items' distinctive tails must remain.
        let tailA = String(a.split(separator: " ").suffix(2).joined(separator: " "))
        let tailB = String(b.split(separator: " ").suffix(2).joined(separator: " "))
        expect(r.contains(tailA) && r.contains(tailB), "kept both; got: \(r)")
    }
}

test("an identical short phrase that does not shrink is treated as a no-op revision") {
    // Documents the pause-repeat edge: Apple replaces its hypothesis with an identical
    // string. It is indistinguishable from a no-op revision (not strictly shorter), so it
    // is NOT committed — yielding a single copy. Committing it would duplicate every
    // repeated identical partial the recognizer emits, so single-copy is the safe choice.
    var c = TranscriptComposer()
    c.apply("记得打开开关", isFinal: false)
    c.apply("记得打开开关", isFinal: false)
    expectEqual(c.composed, "记得打开开关", "no-op identical revision stays single")
}

// MARK: - Long-dictation preservation (the "现象2" guarantee)

test("multiple clean resets preserve all segments") {
    var c = TranscriptComposer()
    c.apply("first sentence about apples", isFinal: false)
    c.apply("Second", isFinal: false)
    c.apply("Second sentence about oranges", isFinal: false)
    c.apply("Third", isFinal: false)
    c.apply("Third sentence about pears", isFinal: false)
    expectEqual(c.composed,
        "first sentence about apples Second sentence about oranges Third sentence about pears",
        "all three preserved")
}

// MARK: - Final / error commits

test("final commits and clears the segment") {
    var c = TranscriptComposer()
    c.apply("hello world", isFinal: true)
    expectEqual(c.committedText, "hello world", "committed")
    expectEqual(c.currentSegment, "", "segment cleared")
    expectEqual(c.composed, "hello world", "composed")
}

test("commitOnError keeps the transcript") {
    var c = TranscriptComposer()
    c.apply("partial before the error", isFinal: false)
    c.commitOnError()
    expectEqual(c.committedText, "partial before the error", "committed")
    expectEqual(c.currentSegment, "", "segment cleared")
}

// MARK: - CJK joining

test("CJK segments join without a space") {
    var c = TranscriptComposer()
    c.apply("你好世界", isFinal: false)
    c.apply("再", isFinal: false)
    c.apply("再见朋友", isFinal: false)
    expectEqual(c.composed, "你好世界再见朋友", "no ASCII separator between CJK")
}

test("reset clears state") {
    var c = TranscriptComposer()
    c.apply("something", isFinal: true)
    c.reset()
    expectEqual(c.committedText, "", "committed")
    expectEqual(c.currentSegment, "", "segment")
    expectEqual(c.composed, "", "composed")
}

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    FileHandle.standardError.write("\(failures) check(s) FAILED\n".data(using: .utf8)!)
    exit(1)
}
print("ALL TESTS PASSED")
