# Voice Input

A macOS menu-bar voice input app. **Hold the `Fn` key to dictate, release to inject** the
transcribed text into whatever field is focused. Streaming on-device speech recognition,
Simplified-Chinese-first, with an optional, very conservative LLM cleanup pass for mixed
Chinese/English technical speech.

> Requires macOS 14 (Sonoma) or later. Personal-use, privacy-first design — no telemetry,
> no analytics, nothing written to disk except your settings (the API key lives only in the
> Keychain).

## Features

- **Push-to-talk dictation** — hold `Fn`, speak, release. A global `CGEvent` tap watches the
  `Fn` key and *suppresses* it so it never triggers the emoji/dictation picker.
- **Streaming transcription** via Apple's Speech framework (`SFSpeechRecognizer`), with a
  real-time partial transcript shown as you talk.
- **Simplified Chinese by default**, plus Traditional Chinese, English, Japanese, and Korean —
  switchable from the menu bar (stored in `UserDefaults`).
- **Elegant floating capsule** — a frameless, nonactivating HUD panel centered at the bottom of
  the screen with a live, RMS-driven 5-bar waveform (it actually reacts to your voice) and an
  elastically-widening transcript label. Spring entry / smooth width / scale-out exit animations.
- **Reliable text injection** — clipboard + `Cmd+V`. If a CJK input method is active it briefly
  switches to an ASCII keyboard so the paste isn't swallowed, then restores your input source and
  your original clipboard (all types).
- **Optional LLM refinement** — point it at any OpenAI-compatible endpoint (cloud or a local model
  like Ollama / LM Studio). The system prompt is deliberately conservative: it only fixes obvious
  recognition slips (Chinese homophones, English tech terms mis-transcribed into Chinese such as
  `配森 → Python`, `杰森 → JSON`). It never rewrites or "polishes" correct text.

## Privacy & security

- **API key** is stored only in the macOS **Keychain** (`kSecClassGenericPassword`) — never in
  UserDefaults, a plist, or a log. The Settings field can be fully cleared (which deletes it).
- **On-device recognition** toggle (`requiresOnDeviceRecognition`) — both modes stream partials.
- **LLM endpoint** must use `https` for any remote host; plain `http` is allowed only for loopback
  (`localhost` / `127.0.0.1` / `::1`) so you can run a local model.
- **LLM output is treated as untrusted** — only a length sanity check is applied (overly long
  output is discarded and the raw transcription is used). No charset filtering, so CJK text is
  never stripped.
- **Clipboard** items are tagged `org.nspasteboard.TransientType` + `ConcealedType` so clipboard
  managers skip them, and your original clipboard is restored afterward.
- **Event tap** only ever inspects the `Fn` modifier flag. No other keycodes are read, logged,
  or persisted.
- **Injection safety** — before pasting it confirms the focused app is the same one you started
  dictating into, and aborts into secure (password) fields.
- **No telemetry.** The only outbound network request is to *your* configured LLM endpoint.

## Build & run

```sh
make build     # compile the release binary (SwiftPM)
make app       # assemble + ad-hoc sign VoiceInput.app (hardened runtime)
make run       # build the bundle and launch it
make install   # build and copy to /Applications
make clean
```

`make app` produces `VoiceInput.app`, ad-hoc signed (`codesign -s -`) with the hardened runtime
enabled — sufficient for personal use; no notarization required. To sign with a real Developer ID
instead, pass `SIGN_IDENTITY="Developer ID Application: …"` to `make`.

## First-run permissions

Launch the app, then grant these in **System Settings → Privacy & Security**:

1. **Microphone** — to hear you.
2. **Speech Recognition** — to transcribe.
3. **Accessibility** — required for the global `Fn` tap and for sending the paste keystroke.

The app prompts for Accessibility on first launch; if the `Fn` key isn't responding, confirm
`VoiceInput.app` is enabled under Accessibility and relaunch.

## Usage

1. Click the waveform icon in the menu bar to pick a language or configure LLM refinement.
2. Focus any text field, **hold `Fn`**, speak, and **release**. The capsule shows your words live;
   if LLM refinement is on it briefly shows *Refining…* before the cleaned text is pasted.

## Project layout

```
Package.swift                     SwiftPM manifest (executable target)
Makefile                          build / app / run / install / clean
Resources/Info.plist              LSUIElement, usage strings
Resources/VoiceInput.entitlements hardened-runtime mic entitlement
Sources/VoiceInput/
  main.swift                      entry point (.accessory policy)
  AppDelegate.swift               menu bar, wiring, permissions
  Core/Settings.swift             UserDefaults settings + L10n
  Core/KeychainStore.swift        API key in the Keychain
  Core/AppCoordinator.swift       record → refine → inject lifecycle
  Input/FnKeyMonitor.swift        Fn CGEvent tap (suppressed)
  Input/TextInjector.swift        clipboard + Cmd+V, input-source handling
  Speech/SpeechTranscriber.swift  streaming recognition + RMS levels
  LLM/LLMRefiner.swift            OpenAI-compatible refinement
  UI/FloatingCapsuleWindow.swift  the HUD capsule panel
  UI/WaveformView.swift           5-bar RMS waveform
  UI/LLMSettingsWindow.swift      LLM settings window
```
