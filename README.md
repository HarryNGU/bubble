# Bubble

A free, open-source personal assistant that lives on your Mac. Ask it about what's on your screen, have it write, reply and get tasks done with your approval, talk instead of typing, and record and edit videos. In the spirit of Cluely, Wispr Flow and Loom, but local-first and open.

No account, no analytics, no subscription.

## Features

### Record
- **Hover to pick what to record**: a window, a Chrome tab (just the page), an app, an area or the whole screen. A 3-2-1 countdown tints exactly what will be recorded.
- **Camera bubble**: round and draggable, with optional blur, dark or cut-out background (Apple's Vision framework, on your Mac).
- **Clean audio**: a built-in noise reducer for your mic, and optionally the sound playing on your Mac.
- **Recording pill**: pause, restart, discard and done. When you record the whole screen it follows you across desktops, full-screen apps and displays.
- **Smart names** from the page or window you recorded, refined with what you talked about.
- Videos are saved in `~/Desktop/Bubble Recordings` and shown in Bubble's library.

### Make reels
- One click on any recording turns it into **Original, 1:1, 9:16 and 16:9** videos, the shapes Instagram offers.
- **Pauses are cut automatically**, with **big captions** timed to your speech.
- Change pauses, speed, zoom and captions with simple controls, or ask Claude in the editor ("make it under 60 seconds", "cut the part where I restart").
- For accurate captions, Bubble uses [Whisper](https://github.com/ggml-org/whisper.cpp) on your Mac if it's installed (`brew install whisper-cpp`, then download the model from the editor). Otherwise it uses Apple's speech recognition.

### Dictate
- **Double-tap ⌥ Option anywhere** and talk. When you pause, Bubble types a tidy version where your cursor is (or tap ⌥ once to finish straight away).
- Removes fillers and stutters, applies self-corrections ("at 5, no wait, 6"), and handles "new line" and "new paragraph".
- **Snippets**: say a phrase and Bubble types the text you saved for it.
- Uses Whisper when it's set up (much more accurate), otherwise Apple's on-device recognition.

### Ask Bubble
- A see-through chat that floats over your screen (⌥\ to show or hide, ⌥ + arrows to move). It looks like texting a friend: your messages on the right, its replies as short texts on the left. Give it a face (dinosaur, panda, fox and more) and a nickname by clicking its picture, restyle it from the palette button, and react to each other's messages.
- **Sees your screen** when you ask (one screenshot, without its own window). **Hears your Mac's sound** (the other people on a call, or a video) when you turn on Listen, transcribed on your Mac. Listen never uses your microphone; to talk to it yourself, use Talk. **Talk** (⌥⇧\) lets you just say what you want.
- **Shows, not just tells**: code blocks, links, YouTube videos that play in the chat, pictures from Wikimedia Commons, and 2D/3D molecule structures from PubChem.
- **Two brains**:
  - **Claude Code (recommended)**: uses the Claude Code installed on your Mac, signed in with your Claude account. It brings your memory notes, `CLAUDE.md` files and connected apps (Gmail, Calendar, Notion and more), and can take actions for you.
  - **API key only**: uses Claude directly with your own Anthropic API key. Simpler, but it has none of that context.
- **Not a stranger**: use ChatGPT? In Settings → Assistant, copy a short prompt into ChatGPT and paste its answer back. Bubble keeps it on your Mac (`about-me.md`, readable only by you) and uses it so it already knows you. Delete it any time.
- **Messages**: it can draft emails, and prepare messages in Messenger, Instagram, WhatsApp or Messages by opening the chat and typing the message. It never presses send for you.

## Safety

Ask Bubble is built so it can't do anything behind your back:

- **Nothing is sent to anyone without you.** Email sending needs your Approve (or a spoken "yes"). Messenger, Instagram, WhatsApp and Messages messages are only typed in; you press Enter.
- **Changes need approval.** Reading and searching run freely. Anything that writes files, runs commands, or creates, sends, edits or deletes in your apps shows an Approve / Deny card first.
- **Protected from prompt injection.** A web page, email or file could contain text meant to trick an assistant. So Bubble always asks before Claude reads key, password or history files (`~/.ssh`, keychains, browser data, shell history, `.env` files and similar), searches your whole home folder, or opens a web address that carries data in it. This applies even to tools you've set to "Always allow".
- **Bubble keeps no passwords.** It uses the apps and browser you're already signed into. Claude Code keeps its own sign-in in your Keychain; Bubble never sees it.
- **Its local tool server is private.** It listens only on `127.0.0.1` and needs a random secret that changes every launch.
- **Visible on purpose.** The chat window shows up in screen shares and recordings like any other window, and a red dot shows whenever it's listening.

## Privacy

Everything stays on your Mac unless you use a feature that needs the internet:

| When | What is sent | To |
| --- | --- | --- |
| You ask Ask Bubble something | Your question, one screenshot (if the eye is on) and the recent transcript (if Listen is on) | Anthropic, through Claude Code or your API key |
| You use AI polish or the reel editor chat | The text of your dictation, or the video's transcript and edit settings (never audio or video) | Anthropic, with your API key |
| An answer shows a picture, molecule or video | The search words or compound name | Wikimedia Commons, PubChem or YouTube |
| You download the Whisper model | Nothing about you (a plain download) | Hugging Face |

Audio is never uploaded: speech recognition, Whisper and captions all run on your Mac. Your API key lives in the macOS Keychain. Snippets (`~/Library/Application Support/Bubble/snippets.json`) and the latest Ask Bubble screenshot are readable only by your user account. Recordings, transcripts, settings and the log (`~/Library/Logs/Bubble.log`) stay on your Mac.

When you use Listen on a call, other people's voices are transcribed too. Tell them, as you would if you were recording.

## Requirements

- macOS 15 (Sequoia) or later, Apple silicon or Intel
- Xcode Command Line Tools (`xcode-select --install`); the full Xcode isn't needed
- Optional: [Claude Code](https://claude.com/claude-code) (signed in) for Ask Bubble with your context; `brew install whisper-cpp` for accurate captions and dictation

## Build and install

```bash
git clone https://github.com/HarryNGU/bubble.git
cd bubble
./tools/make-signing-cert.sh   # once: a local signing certificate (see below)
./build.sh                     # builds and installs ~/Applications/Bubble.app
```

Open Bubble from `~/Applications`. A short welcome chat introduces Bubble and walks you through setup. macOS asks for Screen Recording, camera and microphone access; after allowing Screen Recording, quit and reopen Bubble. For dictation, allow **Speech Recognition** and **Accessibility** (to notice ⌥⌥ in other apps and type into them). If on-device dictation isn't available, turn on Dictation once in System Settings → Keyboard so macOS downloads the speech model.

**Why the certificate?** macOS ties privacy permissions to an app's signature. Without a stable signature, every rebuild looks like a new app and you'd have to allow Screen Recording again. `make-signing-cert.sh` creates a self-signed certificate in your login keychain, used only to sign your own build. If you skip it, `build.sh` signs ad hoc.

## Shortcuts

Every shortcut can be changed by clicking it in Bubble.

| Keys | Action |
| --- | --- |
| ⌥⇧R | Open the picker, or finish while recording |
| ⌥⇧A | Draw an area, then record it |
| Double-tap ⌥ | Start dictation; it finishes when you pause (tap ⌥ to finish early, Esc cancels) |
| ⌥\ | Show / hide Ask Bubble |
| ⌥⇧\ | Talk to Ask Bubble |
| ⌘↩ (while Ask Bubble is open) | Ask about the screen |
| ⌥ + arrow keys (while open) | Move Ask Bubble |

## How it works

| File | What it does |
| --- | --- |
| `Sources/Recorder.swift` | ScreenCaptureKit capture written to MP4 with AVAssetWriter; pause, crop, audio mixdown |
| `Sources/Picker.swift`, `Sources/Overlays.swift` | Hover-to-pick overlay, recording pill, countdown, toast |
| `Sources/Camera.swift`, `Sources/Mic.swift`, `Sources/Denoiser.swift` | Camera bubble, microphone capture and noise reducer |
| `Sources/Library.swift`, `Sources/Glyphs.swift` | The main window (library, settings) and Bubble's symbols |
| `Sources/Reels.swift`, `Sources/Editor.swift` | Pause cutting, captions, reel layouts and export; the reel editor and its Claude chat |
| `Sources/Whisper.swift` | Whisper for captions and voice, run on your Mac |
| `Sources/Dictation.swift`, `Sources/Cleaner.swift`, `Sources/Snippets.swift` | Dictation, clean-up rules, AI polish, snippets |
| `Sources/Assistant.swift`, `Sources/ClaudeCode.swift`, `Sources/BubbleTools.swift` | Ask Bubble: the panel, live listening, the Claude Code session and its safety rules, and Bubble's local tools |
| `Sources/Shortcuts.swift` | Global shortcuts you can change by clicking them |
| `Sources/Namer.swift` | Automatic titles |

For testing: `Bubble --selftest 6 [screen|area|window|chrome] [pause|restart]` records without the countdown and then quits. `--pickertest`, `--countdowntest`, `--edit <file>`, `--assisttest [question]` and `--dicttest` open those parts directly.

## Contributing

Issues and pull requests are welcome. Please keep Bubble local-first: no accounts or analytics, nothing leaves the Mac unless the user turns it on, and nothing is sent to other people without the user's say-so.

## Licence

MIT. Fork it, change it, ship it.
