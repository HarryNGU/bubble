# Testing Bubble (private beta)

Thanks for trying Bubble before anyone else. It's the ultimate personal assistant, floating over your Mac: ask about your screen, dictate anywhere, have it draft things for you (it never sends without your OK), listen along to calls and videos, and record your screen.

This is an early build. Things will break, and that's what you're here to find.

## What you need

- A Mac on macOS 15 (Sequoia) or later. Apple silicon and Intel both work.
- About 15 minutes for setup and a first look.
- Optional, for the assistant: [Claude Code](https://claude.com/claude-code) signed in (`claude`, then `/login` in Terminal), or an Anthropic API key.
- Optional, for much better speech: [Homebrew](https://brew.sh), then `brew install whisper-cpp`. Bubble offers to download the speech model itself (574 MB).

## Install

1. Open `Bubble-1.3.1.dmg` and drag Bubble into Applications.
2. Optional: check the file is the one that was sent. In Terminal run `shasum -a 256 Bubble-1.3.1.dmg`; it should print
   `589c5f1e3bed6f473e9d18bd5466abbd99f3efa4e638f12c61714acd24b0e26a`.
3. Open Bubble. Because this beta isn't notarised by Apple yet, macOS will refuse the first time. Open **System Settings → Privacy & Security**, scroll down to the message about Bubble, click **Open Anyway** and confirm. You only do this once per version.
4. Bubble introduces itself in a short chat and asks for each permission as it goes. After you allow Screen Recording, macOS may ask you to quit and reopen it; it picks up where you left off.

Each new beta build may ask for the permissions again. That's expected for builds that aren't signed by Apple.

## What to try

Tick these off and note anything odd, slow, confusing or ugly.

**First run**
- [ ] The welcome chat. Was every step clear? Did any permission request surprise you?
- [ ] If you can, also try it on a brand-new user account (System Settings → Users & Groups), so nothing is pre-allowed.

**Ask Bubble** (⌥\ to show or hide)
- [ ] Ask about something on screen: a web page, a PDF, a spreadsheet.
- [ ] Ask for a picture, a molecule ("show me caffeine's structure") or a YouTube video.
- [ ] Ask it to make a chart or diagram for you. The picture should appear right in the chat, not in a browser tab; click it to open it in Preview.
- [ ] Ask it to draft an email or a message. Check that it shows an Allow / Deny card before sending anything, and that Deny really stops it.
- [ ] Talk to it with ⌥⇧\ and stop speaking. Does it finish on its own?
- [ ] Turn on **Listen** while a YouTube video plays. Does the transcript follow the video, and ignore your own voice?
- [ ] Click Bubble's picture to change its face and nickname; react to a message (hover it, or right-click).
- [ ] Move the panel with ⌥ + arrow keys. Try it over a full-screen app.
- [ ] Settings → Assistant → "What Bubble knows about you": paste what ChatGPT knows about you, then ask Bubble something personal.

**Chats remember**
- [ ] Ask Bubble something, quit Bubble (⌘Q), open it again and show the panel. Your chat should still be there.
- [ ] Start a new chat (⌘N in the panel, or the pencil button), then reopen the old one from the clock button.
- [ ] Settings → Assistant → Chat history: try "Don't keep" and "Delete all chats".

**Feels like a Mac app**
- [ ] Go through the menu bar: Bubble, File, Edit, View, Window and Help. Does everything do what it says?
- [ ] ⌘, opens Settings; ⌘1 to ⌘6 switch pages; About Bubble shows the version.
- [ ] Settings → General: turn on "Open Bubble when you log in", restart your Mac, and check it starts quietly in the menu bar.
- [ ] The Dock icon should appear only while Bubble's window is open.

**Dictation**
- [ ] Double-tap ⌥ in Notes, Messages, a browser text box and Slack. Talk, then pause. Did it type the right thing, in the right place?
- [ ] Try correcting yourself mid-sentence ("at 5, no wait, 6").

**Recording**
- [ ] Record a window, a Chrome tab, an area and the whole screen. Try pause, restart and discard.
- [ ] On a recording in the library, click **Make reels**. Are the captions accurate and in time?

**Things that should never happen** (tell me straight away if they do)
- Bubble sends, deletes or changes anything without you allowing it.
- Bubble listens, looks at your screen or records when you didn't ask.
- Bubble freezes your Mac or won't quit.

## Reporting a problem

Open an issue at [github.com/HarryNGU/bubble/issues](https://github.com/HarryNGU/bubble/issues) (or message me) with:

- what you did, what you expected, and what happened instead;
- a screenshot or short screen recording if you can;
- your Mac model and macOS version (Apple menu → About This Mac).

Bubble keeps a log at `~/Library/Logs/Bubble.log`. It can help a lot, but **read it before sharing**: it can contain app and window names you've used. Only send the lines around the problem.

If you find a security problem, please report it privately (GitHub → Security → Report a vulnerability) rather than in a public issue.

## Be kind to others

If you turn on Listen during a call, the other people's voices are transcribed (on your Mac). Tell them first, as you would before recording.

## Removing Bubble

Quit it, drag it from Applications to the Bin, and optionally delete `~/Library/Application Support/Bubble` and `~/Library/Logs/Bubble.log`. Your recordings in `~/Desktop/Bubble Recordings` stay until you delete them. Remove its permissions in System Settings → Privacy & Security if you like.
