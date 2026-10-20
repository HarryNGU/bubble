# Bubble

A free, open-source screen recorder and voice-typing app for macOS, in the spirit of Loom and Wispr Flow. Record a tab, a window, an area or your whole screen with your camera in a floating bubble. Or double-tap Option and talk: Bubble types a tidy version of what you said wherever your cursor is.

No account, no uploads, no subscription.

## Features

Bubble has two modes, switched at the top of its window: **Record** and **Dictate**. Colour theme and sound effects are shared.

### Dictate

- **Double-tap ⌥ Option anywhere** to start talking, double-tap again to finish (Esc cancels). A small pill shows your words live.
- **Typed where your cursor is.** If no text box is focused, the text goes to *Last dictation* in Bubble's window and onto your clipboard.
- **Tidied automatically:** filler words (um, uh), stutters, self-corrections ("at 5, no wait, 6" → "at 6", "scratch that"), punctuation, capitals, and "new line" / "new paragraph".
- **Snippets:** say a phrase ("email 2") and Bubble types the saved text. "Two" and "2" both work.
- **Optional AI polish** with your own Anthropic API key for smarter rewrites of very messy speech (off by default).

### Record

- **Hover to pick what to record.** Start, hover a window, a Chrome tab or the desktop, and click *Record this*. Chrome tabs record just the page, without the tab bar or address bar. Drag to record a custom area instead.
- **Camera bubble.** Round and draggable, three sizes. Backgrounds: none, blur, dark grey, or cut-out (just you, no circle). Person segmentation runs on your Mac with Apple's Vision framework.
- **Clean audio.** A built-in noise reducer removes steady background noise (fans, hum, hiss) and keeps voices. Choose any microphone. Optionally include sound playing on your Mac.
- **Recording pill.** Timer, live mic level (warns you if the mic hears nothing), pause/resume, restart, discard and done. It never appears in the video.
- **Countdown** that tints exactly what will be recorded, with start and stop sounds.
- **Your style.** Six colour themes and a customisable global shortcut.
- **Smart names.** Each video is named straight away after the page or window you recorded ("Quarterly Report · 20 Oct 18.14.mp4"), then refined with the topics you talked about, using Apple's on-device speech recognition.
- **Done means done.** The video lands in `~/Desktop/Bubble Recordings`, opens in Finder and is copied to your clipboard, ready to paste into email or chat.

## Privacy

Bubble doesn't upload, sync, phone home or collect analytics. Speech is recognised on your Mac (`requiresOnDeviceRecognition`), so audio never leaves it. The only network request Bubble can make is the optional AI polish: when you turn it on and add your own API key (kept in your macOS Keychain), the dictated *text* is sent to Anthropic's API to be tidied. Audio and snippet values are never sent. Snippets live in `~/Library/Application Support/Bubble/snippets.json`, readable only by your user account. Speech recognition for naming runs on-device only (if your Mac can't do it on-device, that step is skipped). Recordings, settings and the log file (`~/Library/Logs/Bubble.log`) stay on your Mac.

## Requirements

- macOS 15 (Sequoia) or later, Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`); the full Xcode isn't needed

## Build and install

```bash
git clone https://github.com/HarryNGU/bubble.git
cd bubble
./tools/make-signing-cert.sh   # once: a local signing certificate (see below)
./build.sh                     # builds and installs ~/Applications/Bubble.app
```

Open Bubble from `~/Applications`. The first time, macOS asks for Screen Recording, camera and microphone access. After allowing Screen Recording, quit and reopen Bubble. For dictation, allow **Speech Recognition** and **Accessibility** (Accessibility lets Bubble notice the ⌥⌥ double-tap in other apps and type into them). If macOS says on-device dictation isn't available, turn on Dictation once in System Settings → Keyboard so it downloads the speech model.

**Why the certificate?** macOS ties privacy permissions to an app's signature. Without a stable signature every rebuild looks like a new app and you'd have to allow Screen Recording again. `make-signing-cert.sh` creates a self-signed certificate in your login keychain, used only for signing your own build. If you skip it, `build.sh` still works but signs ad hoc.

## Shortcuts

| Keys | Action |
| --- | --- |
| Option-Shift-R (changeable) | Open the picker, or finish while recording |
| Option-Shift-A | Draw an area, then record it |
| Double-tap ⌥ Option | Start / finish dictation (Esc cancels) |

If the menu bar icon is hidden behind the notch, hold Command and drag it towards the clock.

## How it works

| File | What it does |
| --- | --- |
| `Sources/Recorder.swift` | ScreenCaptureKit capture written to MP4 with AVAssetWriter; pause, crop, audio mixdown |
| `Sources/Picker.swift` | The hover-to-pick overlay |
| `Sources/Camera.swift` | Camera bubble and background effects (Vision + Core Image) |
| `Sources/Mic.swift`, `Sources/Denoiser.swift` | Microphone capture and the spectral noise reducer |
| `Sources/Dictation.swift` | ⌥⌥ detection, live on-device speech, typing into the focused app, the dictation pill |
| `Sources/Cleaner.swift`, `Sources/Snippets.swift` | Transcript clean-up rules, optional AI polish, snippet library |
| `Sources/Namer.swift` | Automatic titles from the page/window and on-device speech recognition |
| `Sources/UI.swift`, `Sources/Overlays.swift` | SwiftUI window, recording pill, countdown, toast |

For testing: `Bubble --selftest 6 [screen|area|window|chrome] [pause|restart]` records without the countdown; `--pickertest` and `--countdowntest` show those overlays.

## Contributing

Issues and pull requests are welcome. Please keep Bubble local-first: no accounts or analytics, and nothing leaves the Mac unless the user turns it on.

## Licence

MIT. Fork it, change it, ship it.
