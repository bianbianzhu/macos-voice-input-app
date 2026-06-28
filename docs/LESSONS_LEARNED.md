# Lessons Learned — "the app runs but Fn does nothing" (UAT)

## Symptom

After `make run`, VoiceInput launched successfully (process alive, no crash), but:

1. **No icon** appeared in the menu bar, and
2. **Holding Fn did nothing** — no floating capsule, no transcription, no paste. Not even
   the system emoji picker appeared.

## What it actually was — two *separate* problems

### Problem A — the menu-bar icon was invisible (not a bug)

- **Root cause:** this is a 14" MacBook Pro (`Mac14,9`) with a **notch**, and the menu bar
  was crowded. macOS lays status items out from the right; when they collide with the notch
  the leftover (newest) items are **hidden behind the notch** rather than wrapping to its
  left. The VoiceInput item existed the whole time.
- **Proof:** `osascript … get count of menu bar items` returned **1** — the item was created
  and present; it just had nowhere visible to render.
- **Takeaway:** on notched Macs, a "missing" menu-bar icon is usually overflow, not a failure.
  Free up space (quit/⌘-drag other items) to reveal it. Don't chase it as a code bug.

### Problem B — Fn never triggered (the real blocker)

- **Root cause:** the global Fn detection uses a `CGEvent` tap, which requires **Accessibility
  (TCC) permission**. We build with **ad-hoc signing** (`codesign -s -`), and **every rebuild
  produces a new code hash (cdhash)**. macOS keys the Accessibility grant to the app's code
  identity, so after each `make run` the previous grant became **stale/orphaned**:
  - System Settings *still showed VoiceInput "checked"*, but
  - at runtime `AXIsProcessTrusted()` returned **false**, so
  - `CGEvent.tapCreate(...)` returned **nil**, so
  - `FnKeyMonitor.start()` returned **false** → the tap was never installed → no Fn events.
- The app only checked permission **once at launch** and then gave up, so even after the user
  re-granted, nothing started until a full quit + relaunch.

## How it was diagnosed (systematically, not by guessing)

1. **Confirmed the process was alive** and the **status item existed** (`osascript` count = 1)
   → ruled out a crash and pointed Problem A at the notch.
2. **Verified the SF Symbol loaded** (`NSImage(systemSymbolName: "waveform")` → ok) → ruled out
   an icon-load failure.
3. **Built a minimal standalone CGEvent probe** and ran it **from iTerm** (which *does* hold
   Accessibility, so the child process inherits trust). It reported `TAP_CREATED_OK` and
   captured **`Fn=true` ×4** when the key was pressed — proving the Fn key and event taps work
   fine system-wide. That **isolated** the failure to the *app's own* trust, not the keyboard
   or the environment.
4. Added a **Shift control** to the probe so "0 Fn events" couldn't be misread as a key problem
   when it actually just meant "nothing was pressed yet."

## The fix

- **Code (this branch):**
  - `AppDelegate` now **polls `AXIsProcessTrusted()` on a 1.5s timer** and starts the Fn monitor
    the instant access is granted — **no relaunch required**.
  - A disabled **menu status line** shows readiness: `✓ Fn dictation ready` /
    `⚠︎ Waiting for Accessibility permission…`.
  - `FnKeyMonitor.isActive` exposes whether the tap is installed.
- **Process (to unblock UAT):** `tccutil reset Accessibility com.voiceinput.app`, grant access
  to the **final** build, then **stop rebuilding** (a rebuild re-signs and re-breaks the grant).

## Durable takeaways

1. **Ad-hoc signing + TCC don't mix well across rebuilds.** For iterating on a permission-gated
   app, either (a) grant once to a build and don't rebuild, or (b) sign with a **stable
   self-signed identity** so the cdhash/identity is constant and the grant survives rebuilds.
2. **"Enabled in System Settings" ≠ "effective at runtime"** for a re-signed app. Trust the
   runtime check (`AXIsProcessTrusted()`), not the UI checkbox.
3. **Don't do one-shot permission checks at launch.** Poll/retry so the app self-heals the
   moment the user grants — far better UX than "grant, then quit and relaunch."
4. **Isolate environment-vs-app failures with a minimal probe** that inherits a known-good
   parent's permission. It turns "something's broken" into "the app specifically isn't trusted."
5. **Guard diagnostics against false negatives** — a control signal (the Shift press) prevents
   reading "no events" as "the key is broken."
6. **Notch Macs hide overflow menu-bar items.** Awareness, not a code fix.

## Resolution (implemented)

Takeaway 1(b) is now the shipped default: `scripts/make-signing-cert.sh` creates a local
self-signed **"VoiceInput Local"** Code Signing identity, and the Makefile auto-detects and
signs with it. The resulting designated requirement keys on the certificate leaf, not the
cdhash — verified end-to-end: a full `make clean && make app` changes the executable's cdhash
yet the Accessibility grant stays (`codesign --verify -R` against the granted requirement still
passes, TCC `auth_value` stays `2`). So a one-time grant now survives every rebuild; ad-hoc
remains the automatic fallback when the cert is absent.

---

# Lessons Learned — duplicated chunks in long dictation (UAT)

## Symptom

On long dictation (≈1 min+, both English and 中文), the injected text contained **duplicated
chunks** the user never repeated — e.g. `…which is a conversational It saves a lot of time…which
is a conversational and operation`. The two copies were *slightly different* (`in my`→`my`,
`a role`→`real`, `其`→`族`), which was the key tell: two recognition passes over the same audio,
not the user repeating themselves.

## Root cause

`SFSpeechRecognizer`'s streaming hypothesis is *replaced* with a fresh, shorter string after a
short pause (a silent endpoint reset; no `isFinal`). We commit the prior segment across that reset
so long dictation isn't lost. But the reset is sometimes a **rewind**: the fresh string
RE-TRANSCRIBES audio already in the committed text (re-worded, even re-capitalized). Committing the
prior segment and then appending the re-transcription duplicated the overlapping chunk.

## How it was diagnosed (a reproduction harness, not guessing)

- Built a standalone harness that feeds `say`-synthesized audio (≈100 s, looped to force long
  sessions) through a **real** `SFSpeechRecognizer` running the exact commit/restart logic, logging
  every callback plus an `OVERLAP=true/false` probe at each reset. It captured a live rewind
  (`OVERLAP=true`), reproducing the bug deterministically — and showed the on-device recognizer runs
  **one continuous task for 200 s+** on macOS 15.6 (no ~1-min cap), so the request-restart path was
  *not* the cause; the silent rewind reset was.
- Confirmed the dup is created entirely in the transcript state machine (the injector pastes
  `stop()`'s value verbatim).

## The fix

- Extracted the string logic into a pure, framework-free `VoiceInputCore.TranscriptComposer` so it
  is unit-testable without a microphone; `SpeechTranscriber` delegates to it under its existing lock.
- Overlap suppression: a first attempt anchored on the segment's exact 24-char prefix — but real
  rewinds change words *throughout*, including the leading word, so it kept missing. The robust
  version finds the **longest identical run** shared by the committed tail and the segment and
  splices there (run is identical on both sides → no dup, no broken word).
- Two guards prevent data loss / false merges: the shared run must be long enough (≥24 chars, so
  intentional short repeats like `please remember to …` / `请记得写` are kept), and the segment from
  the run onward must be long enough to re-cover the committed tail it replaces.

## Durable takeaways

1. **Reproduce recognizer bugs with synthesized audio + a harness.** `say` + buffer-feeding a real
   recognizer turned an intermittent field bug into a deterministic, loggable repro — and disproved
   a wrong assumption (the ~1-min cap) with evidence.
2. **Exact-prefix matching is too brittle for re-transcriptions.** They diverge at the word level
   everywhere; anchor on the longest identical *run*, not the prefix.
3. **Prefer leaving a rare duplicate over silent data loss.** Every heuristic here fails safe to a
   plain join; the length guard exists specifically to never drop trailing committed text.
4. **Put pure logic in its own testable module.** The real UAT failures (EN/ZH/repeat lists) are now
   permanent fixtures in `swift run TranscriptComposerTests`.
