# Bubble

A free, open-source screen recorder for macOS, in the spirit of Loom. Record a tab, a window, an area or your whole screen with your camera in a floating bubble and your voice, straight to an MP4 on your Mac.

No account, no uploads, no subscription.

## Features

- **Hover to pick what to record.** Start, hover a window, a Chrome tab or the desktop, and click *Record this*. Chrome tabs record just the page, without the tab bar or address bar. Drag to record a custom area instead.
- **Camera bubble.** Round and draggable, three sizes. Backgrounds: none, blur, dark grey, or cut-out (just you, no circle). Person segmentation runs on your Mac with Apple's Vision framework.
- **Clean audio.** A built-in noise reducer removes steady background noise (fans, hum, hiss) and keeps voices. Choose any microphone. Optionally include sound playing on your Mac.
- **Recording pill.** Timer, live mic level (warns you if the mic hears nothing), pause/resume, restart, discard and done. It never appears in the video.
- **Countdown** that tints exactly what will be recorded, with start and stop sounds.
- **Your style.** Six colour themes and a customisable global shortcut.
- **Done means done.** The video lands in `~/Desktop/Bubble Recordings`, opens in Finder and is copied to your clipboard, ready to paste into email or chat.

## Privacy

Bubble has no network code. It doesn't upload, sync, phone home or collect analytics. Recordings, settings and the log file (`~/Library/Logs/Bubble.log`) stay on your Mac.

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

Open Bubble from `~/Applications`. The first time, macOS asks for Screen Recording, camera and microphone access. After allowing Screen Recording, quit and reopen Bubble.

**Why the certificate?** macOS ties privacy permissions to an app's signature. Without a stable signature every rebuild looks like a new app and you'd have to allow Screen Recording again. `make-signing-cert.sh` creates a self-signed certificate in your login keychain, used only for signing your own build. If you skip it, `build.sh` still works but signs ad hoc.

## Shortcuts

| Keys | Action |
| --- | --- |
| Option-Shift-R (changeable) | Open the picker, or finish while recording |
| Option-Shift-A | Draw an area, then record it |

If the menu bar icon is hidden behind the notch, hold Command and drag it towards the clock.

## How it works

| File | What it does |
| --- | --- |
| `Sources/Recorder.swift` | ScreenCaptureKit capture written to MP4 with AVAssetWriter; pause, crop, audio mixdown |
| `Sources/Picker.swift` | The hover-to-pick overlay |
| `Sources/Camera.swift` | Camera bubble and background effects (Vision + Core Image) |
| `Sources/Mic.swift`, `Sources/Denoiser.swift` | Microphone capture and the spectral noise reducer |
| `Sources/UI.swift`, `Sources/Overlays.swift` | SwiftUI window, recording pill, countdown, toast |

For testing: `Bubble --selftest 6 [screen|area|window|chrome] [pause|restart]` records without the countdown; `--pickertest` and `--countdowntest` show those overlays.

## Contributing

Issues and pull requests are welcome. Please keep Bubble local-first: no network calls, accounts or analytics.

## Licence

MIT. Fork it, change it, ship it.
