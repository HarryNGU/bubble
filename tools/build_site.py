#!/usr/bin/env python3
"""Builds Bubble's website into docs/ (served by GitHub Pages). Run: python3 tools/build_site.py

Plain HTML and CSS, system fonts, no cookies, no analytics and no outside requests, so visiting
the site shares nothing about the visitor.
"""
from pathlib import Path

DOCS = Path(__file__).resolve().parent.parent / "docs"
REPO = "https://github.com/HarryNGU/bubble"
SITE = "https://harryngu.github.io/bubble/"
UPDATED = "22 October 2026"

GLYPH = {
    "record": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><rect x="3" y="3.5" width="18" height="13.5" rx="3.5" stroke="var(--accent)"/><circle cx="7" cy="16.5" r="5.8" fill="var(--bg)" stroke="none"/><circle cx="7" cy="16.5" r="4.5" fill="var(--accent)" stroke="none"/><circle cx="7" cy="16.5" r="1.4" fill="#fff" stroke="none"/><circle cx="17" cy="8.2" r="1.6" fill="var(--accent)" stroke="none"/></svg>',
    "reels": '<svg viewBox="0 0 24 24" fill="none" stroke="var(--accent)" stroke-width="1.9" stroke-linejoin="round"><rect x="6" y="2.5" width="12" height="19" rx="3"/><path d="M10.5 9.2v5.6l4.6-2.8z" fill="var(--accent)" stroke="none"/></svg>',
    "dictate": '<svg viewBox="0 0 24 24" fill="none" stroke="var(--accent)" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M7.5 3h9a5 5 0 0 1 5 5v4a5 5 0 0 1-5 5H11l-5.5 4 1.5-4h.5a5 5 0 0 1-5-5V8a5 5 0 0 1 5-5z"/><path d="M7.5 8.5v3M10.5 6.5v7M13.5 7.5v5M16.5 8.8v2.4" stroke-width="2.1"/></svg>',
    "assist": '<svg viewBox="0 0 24 24" fill="none" stroke="var(--accent)" stroke-width="1.9"><circle cx="11" cy="13" r="8"/><circle cx="11" cy="13" r="3.4" fill="var(--accent)" stroke="none"/><circle cx="18.5" cy="5.5" r="4.2" fill="var(--bg)" stroke="none"/><circle cx="18.5" cy="5.5" r="2.9" fill="var(--accent)" stroke="none"/></svg>',
}

NAV = [("index.html#features", "Features"), ("get-started.html", "Get started"), ("security.html", "Safety"), ("faq.html", "FAQ")]
V = "6"  # bump to refresh cached CSS and JS

ICON = {
    "lock": '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><rect x="4.5" y="10.5" width="15" height="10" rx="3"/><path d="M8 10.5V7.5a4 4 0 0 1 8 0v3"/></svg>',
    "hand": '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M8 13V5.5a1.5 1.5 0 0 1 3 0V12M11 11V4.5a1.5 1.5 0 0 1 3 0V12M14 11.5V6a1.5 1.5 0 0 1 3 0v8.5a6.5 6.5 0 0 1-6.5 6.5c-2.4 0-3.9-1-5.1-2.9L3.6 15a1.5 1.5 0 0 1 2.4-1.8L8 15.5"/></svg>',
    "send": '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M21 3 10 14M21 3l-7 18-4-7-7-4z"/></svg>',
    "code": '<svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="m8 7-5 5 5 5M16 7l5 5-5 5M13.5 4l-3 16"/></svg>',
    "apple": '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M16.4 12.6c0-2.6 2.1-3.8 2.2-3.9-1.2-1.8-3.1-2-3.7-2-1.6-.2-3.1.9-3.9.9-.8 0-2-.9-3.4-.9-1.7 0-3.3 1-4.2 2.6-1.8 3.1-.5 7.7 1.3 10.2.9 1.2 1.9 2.6 3.2 2.6 1.3-.1 1.8-.8 3.3-.8 1.6 0 2 .8 3.4.8 1.4 0 2.3-1.3 3.1-2.5 1-1.4 1.4-2.8 1.4-2.9-.1 0-2.7-1-2.7-4.1zM13.9 5c.7-.9 1.2-2 1-3.2-1 0-2.3.7-3 1.6-.7.8-1.3 2-1.1 3.1 1.1.1 2.3-.6 3.1-1.5z"/></svg>',
    "play": '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M8 5.5v13l11-6.5z"/></svg>',
    "speaker": '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M11 5 6 9H3v6h3l5 4z"/><path d="M15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13"/></svg>',
}


def page(name, title, desc, body, dark_top=False):
    def link(href, label):
        here = href == name
        cur = ' aria-current="page"' if here else ""
        return f'<a href="{href}"{cur}>{label}</a>'
    nav = "".join(link(h, l) for h, l in NAV)
    html = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{desc}">
<meta name="referrer" content="no-referrer">
<meta name="theme-color" content="#f7f5f0">
<link rel="canonical" href="{SITE}{'' if name == 'index.html' else name}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Bubble">
<meta property="og:title" content="{title}">
<meta property="og:description" content="{desc}">
<meta property="og:url" content="{SITE}{'' if name == 'index.html' else name}">
<meta property="og:image" content="{SITE}assets/og.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="Bubble, your personal assistant living on your Mac, answering a question in a floating chat">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{title}">
<meta name="twitter:description" content="{desc}">
<meta name="twitter:image" content="{SITE}assets/og.png">
<meta http-equiv="Content-Security-Policy" content="default-src 'self'; img-src 'self' data:; media-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'; base-uri 'self'; form-action 'none'">
<link rel="icon" href="assets/favicon.png">
<link rel="stylesheet" href="assets/style.css?v={V}">
</head>
<body>
<div class="nav-shell{' on-dark' if dark_top else ''}">
<nav class="bar" aria-label="Main">
<a class="brand" href="index.html"><span class="logo"></span>Bubble</a>
<div class="links"><span class="glide"></span>{nav}</div>
<a href="index.html#download" class="btn primary small nav-cta">Download</a>
<button class="menu-btn" aria-label="Menu" aria-expanded="false"><span></span><span></span></button>
</nav>
</div>
<div class="drawer">{nav}<a href="index.html#download" class="btn primary">Download for Mac</a></div>
<main>
{body}
</main>
<footer class="site"><div class="wrap"><div class="cols">
<div><a class="brand" href="index.html"><span class="logo"></span>Bubble</a><p style="max-width:300px">Your personal assistant, living on your Mac. Free and open source. No account, no tracking, no ads.</p></div>
<div><h4>Product</h4><ul><li><a href="index.html#download">Download</a></li><li><a href="index.html#features">Features</a></li><li><a href="get-started.html">Get started</a></li><li><a href="faq.html">FAQ</a></li><li><a href="{REPO}">Source code</a></li></ul></div>
<div><h4>Trust</h4><ul><li><a href="security.html">Safety and security</a></li><li><a href="privacy.html">Privacy policy</a></li><li><a href="terms.html">Terms of use</a></li><li><a href="notices.html">Open-source notices</a></li></ul></div>
<div><h4>Help</h4><ul><li><a href="{REPO}/issues">Report a problem</a></li><li><a href="{REPO}/security/advisories/new">Report a security issue</a></li><li><a href="get-started.html#uninstall">Uninstall</a></li></ul></div>
</div><p style="margin-top:34px;font-size:14px">This site sets no cookies and uses no analytics. Hosted by GitHub Pages.</p></div></footer>
<script src="assets/site.js?v={V}"></script>
</body>
</html>
"""
    (DOCS / name).write_text(html)


def head(kicker, title, lede):
    return f'<section class="page-head"><div class="wrap narrow"><span class="kicker rise">{kicker}</span><h1 class="rise" style="--d:.05s">{title}</h1><p class="rise" style="--d:.1s">{lede}</p></div></section>'


def doc(name, title, desc, inner, kicker="Trust"):
    page(name, f"{title} · Bubble", desc, head(kicker, title, desc) + f'<div class="wrap narrow doc"><p class="updated">Last updated {UPDATED}</p>{inner}</div>')


def story(n, kicker, title, text, ticks, img, alt, keys="", flip=False):
    t = "".join(f"<li>{x}</li>" for x in ticks)
    k = f'<div class="keys">{keys}</div>' if keys else ""
    return f"""<div class="story{' flip' if flip else ''}">
<div class="copy reveal"><div class="num">{n:02d} · {kicker}</div><h3>{title}</h3><p>{text}</p><ul class="ticks">{t}</ul>{k}</div>
<div class="shot reveal" style="--d:.12s"><img src="assets/{img}" alt="{alt}" width="1600" height="900" loading="lazy"></div>
</div>"""


# ─────────────────────────────── Home ───────────────────────────────
STORIES = "".join([
    story(1, "Ask", "Ask about anything on your screen", "Stuck on a question in your Notion notes, a chart in Excel or a paragraph in a PDF? Press ⌥\\ and ask. Bubble looks at your screen and answers like a friend texting back, with pictures, videos and links when they help.",
          ["Looks at your screen only when you ask", "Diagrams, molecules and YouTube videos right in the chat", "Works over every app, nothing to copy and paste"],
          "feat-ask.jpg", "Bubble's chat over a Notion page of chemistry notes, showing caffeine's structure", "<kbd>⌥</kbd><kbd>\\</kbd> to open"),
    story(2, "Knows you", "Not a stranger", "Bubble picks up where your AI already is. Connect Claude and it knows your notes, your calendar and your inbox. Use ChatGPT? Bring over what it remembers about you in one paste.",
          ["Uses your Claude memory and connected apps", "Imports what ChatGPT knows about you", "Kept on your Mac, and you can delete it any time"],
          "feat-knows.jpg", "Bubble planning a revision week around the user's exam and shifts", flip=True),
    story(3, "Do", "Done in Gmail, sent by you", "“Reply to Sam and say I'll be there at 6.” Bubble writes the reply in Gmail or Outlook, shows it to you, and waits. It only sends when you tap Allow, or say “yes”.",
          ["Drafts in Gmail, Outlook, Messages, Instagram and Messenger", "An Allow or Deny card before anything is sent", "Messages are typed in for you to send yourself"],
          "feat-do.jpg", "Bubble writing a reply in Gmail and waiting for approval to send"),
    story(4, "Dictate", "Talk instead of typing", "Double-tap Option in iMessage, Slack, Word or anywhere else, and just speak. Bubble types a tidy version where your cursor is, and finishes on its own when you pause.",
          ["Works in every text box on your Mac", "No ums, and your corrections applied", "Speech is turned into text on your Mac"],
          "feat-dictate.jpg", "Bubble typing a dictated message into iMessage", "<kbd>⌥</kbd><kbd>⌥</kbd> double-tap", flip=True),
    story(5, "Listen", "A second brain on Zoom", "Turn on Listen in a Zoom or Google Meet call, a lecture or a YouTube video. Bubble hears your Mac's sound (never your microphone) and tells you what to say, or sums up what you missed.",
          ["“What should I say?” in one tap", "Summaries and to-dos from long calls", "A red dot shows whenever it's listening"],
          "feat-listen.jpg", "Bubble listening to a Zoom call and suggesting a reply"),
    story(6, "Record", "Record once, post everywhere", "Hover any window and click. Your face sits in a round bubble, and the noise is gone. One more click makes captioned versions for Reels, TikTok, Shorts and YouTube.",
          ["Pauses cut out automatically", "Big captions timed to your words", "9:16, 1:1 and 16:9, ready to post"],
          "feat-record.jpg", "Three captioned videos made from one recording", "<kbd>⌘</kbd><kbd>\\</kbd> to record", flip=True),
])

DAY = [
    ("8:30", "Gmail", "#ea4335", "Replying before class", "Reply to Ms Lee: I'll hand the lab report in on Friday.", "Written in Gmail. You read it and press Send."),
    ("10:00", "Zoom", "#2d8cff", "Lost in a lecture", "What did she mean by activation energy?", "A plain answer with a diagram, while the lecture keeps going."),
    ("13:15", "Notion", "#111214", "Writing up notes", "Double-tap ⌥ and talk through what you learned.", "Tidy notes, typed where your cursor is."),
    ("17:40", "Instagram", "#d62976", "Running late", "Tell Mia I'm 10 minutes away.", "Typed into her chat. You press send."),
    ("21:00", "GoodNotes", "#4e8cf6", "Checking homework", "Is my working for question 4 right?", "Spots the slip in step 2 and explains why."),
]
DAY_HTML = "".join(
    f'''<div class="moment reveal" style="--d:{i * 0.07:.2f}s"><div class="when">{t}<span class="app"><i style="background:{c}"></i>{app}</span></div>
<h3>{title}</h3><div class="said">{said}</div><div class="then">{then}</div></div>'''
    for i, (t, app, c, title, said, then) in enumerate(DAY)
)

CONTROL = [
    ("Looks at your screen", "Only when you ask a question, one screenshot each time.", '<span class="tag">👁 You can turn it off</span>'),
    ("Hears your Mac's sound", "Only while you've turned Listen on.", '<span class="tag"><span class="dot"></span>Red dot while on</span>'),
    ("Hears your voice", "Only while you're dictating or talking to it.", '<span class="tag">You start it</span>'),
    ("Sends an email or message", "Only after you tap Allow or say “yes”. Chat messages are typed in for you to send.", '<span class="tag">Your OK first</span>'),
    ("Changes files or apps", "Only after you see exactly what it will do, and allow it.", '<span class="tag">Your OK first</span>'),
    ("Works in the background", "Never. Nothing happens unless you asked for it.", '<span class="tag never">Never</span>'),
    ("Collects or sells your data", "Never. No account, no tracking, no analytics.", '<span class="tag never">Never</span>'),
]
CONTROL_HTML = "".join(f'<div class="row"><b>{a}</b><span>{b}</span>{c}</div>' for a, b, c in CONTROL)

HOME = f"""
<section class="hero">
<div class="wrap">
<h1 class="rise">Your personal assistant,<br><span class="quiet">living on your Mac.</span></h1>
<p class="lede rise" style="--d:.08s">Bubble floats over whatever you're doing, in Gmail, Notion, Zoom or anywhere else, and helps right there. It already knows you, and it only acts when you say so.</p>
<div class="actions rise" style="--d:.14s">
<a class="btn primary" href="#download">{ICON['apple']}Download for Mac</a>
<a class="btn ghost" href="#demo">{ICON['play']}Watch the demo</a>
</div>
<p class="meta rise" style="--d:.18s">Free · macOS 15 or later · Apple silicon and Intel</p>
<div class="stage rise" id="demo" style="--d:.24s">
<div class="frame"><video src="assets/bubble-demo.mp4" poster="assets/demo-poster.jpg" autoplay muted loop playsinline preload="metadata" width="1280" height="720" aria-label="A short demo of Bubble"></video></div>
<button class="sound" type="button">{ICON['speaker']}<span>Sound on</span></button>
</div>
</div>
</section>

<section class="block"><div class="wrap">
<div class="head reveal"><span class="kicker">A day with Bubble</span><h2>Same apps. Less effort.</h2><p>Nothing new to learn. Bubble shows up inside the apps you already use, whenever you need a hand.</p></div>
<div class="day">{DAY_HTML}</div>
</div></section>

<section class="block" id="features"><div class="wrap">
<div class="head reveal"><span class="kicker">What it does</span><h2>One assistant for everything on your Mac.</h2></div>
{STORIES}
</div></section>

<section class="block" id="control" style="padding-top:10px"><div class="wrap">
<div class="head reveal"><span class="kicker">You're in control</span><h2>Nothing happens without you.</h2><p>Bubble can see, hear and act on your Mac, so here is exactly when it does, in plain words.</p></div>
<div class="control">
<div class="reveal"><div class="ledger">{CONTROL_HTML}</div>
<p class="ledger-foot">Bubble is open source, so anyone can check that it does what this page says. <a href="security.html">Read the full safety details →</a></p></div>
<div class="approval reveal" style="--d:.12s">
<div class="who"><span class="logo"></span>Bubble</div>
<div class="msg"><small>To: Sam Lee · Re: Study group</small>Hi Sam, I'll be there at 6. See you then!</div>
<div class="ask"><p>✋ Send this email?</p><div class="btns"><span>Deny</span><span class="yes">Allow once</span></div></div>
<p class="cap">This is what you see before anything leaves your Mac.</p>
</div>
</div>
</div></section>

<section class="block"><div class="wrap">
<div class="head reveal"><span class="kicker">Getting started</span><h2>Up and running in two minutes.</h2><p>Bubble introduces itself and asks before every step. You can skip anything.</p></div>
<div class="steps3">
<div class="step reveal"><b class="n">01</b><h3>Download</h3><p>One small download for any Mac on macOS 15 or later. Drag it into Applications.</p><div class="big-keys"><div class="logo" style="width:64px;height:64px"></div></div></div>
<div class="step reveal" style="--d:.1s"><b class="n">02</b><h3>Say hello</h3><p>A short, friendly chat sets things up and explains each permission before macOS asks.</p><div class="pic"><img src="assets/onboard-hello.jpg" alt="Bubble's welcome chat" width="1200" height="776" loading="lazy"></div></div>
<div class="step reveal" style="--d:.2s"><b class="n">03</b><h3>Press and ask</h3><p>From any app, press the shortcut and ask your first question.</p><div class="big-keys"><kbd>⌥</kbd><kbd>\\</kbd></div></div>
</div>
</div></section>

<section class="block"><div class="wrap narrow">
<div class="head reveal"><span class="kicker">Questions</span><h2>Good to know.</h2></div>
<div class="faq reveal">
<details><summary>Is Bubble really free?</summary><p>Yes. It's open source with no paid tier and no ads. The assistant uses an AI you bring yourself (your Claude plan or your own API key).</p></details>
<details><summary>Can Bubble do anything without me knowing?</summary><p>No. It only looks, listens or acts when you ask, shows a red dot while it's listening, and anything that sends or changes something waits for your Allow.</p></details>
<details><summary>I use ChatGPT. Does Bubble know what it knows about me?</summary><p>You can bring it over: Bubble gives you a short prompt to paste into ChatGPT, and you paste the answer back. It's saved on your Mac and you can delete it any time. The answers themselves come from Claude.</p></details>
<details><summary>Which Macs does it work on?</summary><p>Any Mac on macOS 15 Sequoia or later, with Apple silicon or Intel. There's no Windows or phone version yet.</p></details>
</div>
<p class="center" style="margin-top:30px"><a href="faq.html">All questions →</a></p>
</div></section>

<section id="download"><div class="wrap">
<div class="cta reveal">
<div class="logo"></div>
<h2>Meet Bubble.</h2>
<div data-available="false"><p>Bubble is in a small private beta right now. The public download is coming soon.</p>
<a class="btn primary" href="{REPO}">Follow on GitHub</a>
<p class="fine">On GitHub, choose Watch → Custom → Releases to hear the moment it's out.</p></div>
<div data-os="mac" data-available="true" hidden>
<p>Free, for any Mac on macOS 15 or later.</p>
<a class="btn primary" data-release="url" href="{REPO}/releases/latest">{ICON['apple']}Download for Mac</a>
<p class="fine">Version <span data-release="version">1.1.0</span> · <span data-release="size">3.3 MB</span> · Apple silicon and Intel · <a href="get-started.html">Install guide</a></p>
</div>
<div data-os="ios android" class="elsewhere" hidden><p>Bubble is a Mac app. Open this page on your Mac to download it.</p></div>
<div data-os="windows linux chromeos other" class="elsewhere" hidden><p>Bubble is made for Mac and relies on macOS features that Windows, Linux and ChromeOS don't have. Follow it on <a href="{REPO}" style="color:#fff;text-decoration:underline">GitHub</a> to hear if that changes.</p></div>
</div>
</div></section>
"""

# ─────────────────────────────── Get started ───────────────────────────────
STARTED = f"""
<div class="wrap narrow doc">

<h2 id="install">1. Install</h2>
<ol class="steps">
<li><strong>Download Bubble</strong><p>From the <a href="index.html#download">download button</a>. Your browser saves a file called <code>Bubble-<span data-release="version">1.1.0</span>.dmg</code>.</p></li>
<li><strong>Drag Bubble into Applications</strong><p>Open the downloaded file and drag the Bubble icon onto the Applications folder.</p></li>
<li><strong>Open it</strong><p>Open Bubble from Applications.</p>
<div data-notarized="true" hidden><p>Bubble is signed and notarised by Apple, so it opens like any other app.</p></div>
<div data-notarized="false"><p>The first time, macOS asks you to confirm: open System Settings → Privacy &amp; Security and click <strong>Open Anyway</strong> next to Bubble. You only do this once.</p></div>
</li>
</ol>
<details class="note" style="margin-top:16px"><summary style="cursor:pointer;font-weight:600;color:var(--ink)">Want to check your download is genuine?</summary>
<p>Open Terminal and run <code>shasum -a 256 ~/Downloads/Bubble-*.dmg</code>. It should match this fingerprint exactly:</p>
<div class="checksum" id="sha" data-release="sha256">Loading…</div>
<p style="margin-top:8px"><button class="btn ghost small" data-copy="#sha">Copy fingerprint</button></p></details>

<h2 id="welcome">2. The welcome tour</h2>
<p>The first time Bubble opens, it introduces itself in a short chat. It asks what to call you (optional, and kept on your Mac), lets you pick what you'd like help with, then asks for each permission one at a time, saying why before macOS shows its own prompt. Skip any you like; Bubble asks again only when you use that feature.</p>
<table>
<tr><th>Permission</th><th>Why Bubble asks</th><th>Needed for</th></tr>
<tr><td>Screen Recording</td><td>To record your screen, to take a screenshot when you ask Bubble about it, and to hear your Mac's sound when you turn on Listen.</td><td>Record, Ask, Listen</td></tr>
<tr><td>Camera</td><td>For the round camera bubble in recordings. Never used otherwise.</td><td>Record (optional)</td></tr>
<tr><td>Microphone</td><td>Your voice in recordings, dictation and when you talk to Bubble.</td><td>Record, Dictate, Talk</td></tr>
<tr><td>Speech Recognition</td><td>Turning speech into text on your Mac.</td><td>Dictate, Ask Bubble, captions</td></tr>
<tr><td>Accessibility</td><td>To notice the ⌥⌥ double-tap in other apps and type text where your cursor is.</td><td>Dictate, Ask Bubble messages</td></tr>
<tr><td>Automation</td><td>Asked only if you have Ask Bubble use an app such as Mail or Messages for you.</td><td>Ask Bubble actions</td></tr>
</table>
<p class="note">After allowing Screen Recording, macOS may ask you to quit and reopen Bubble. Your choices are saved. You can review or remove any permission later in System Settings → Privacy &amp; Security.</p>

<h2 id="connect">3. Connect your AI (optional)</h2>
<p>Ask Bubble needs an AI to answer. The tour asks which you'd like, or you can skip it:</p>
<ul>
<li><strong>Claude Code on your Mac (recommended).</strong> If you already use <a href="https://claude.com/claude-code">Claude Code</a>, Ask Bubble uses it with your own Claude plan. It brings your memory notes and your connected apps (like Gmail and Calendar). Sign in once by opening Terminal, running <code>claude</code> and typing <code>/login</code>.</li>
<li><strong>An Anthropic API key.</strong> Create one at console.anthropic.com and paste it into Bubble. It's stored in your Mac's Keychain and billed to your Anthropic account.</li>
<li><strong>Not now.</strong> Recording and dictation work without any AI.</li>
</ul>
<p>Other assistants such as ChatGPT or Gemini can't be connected yet.</p>
<p>Before Ask Bubble can see or hear anything, it shows you its ground rules and asks you to agree. You can read them on the <a href="security.html#rules">safety page</a>.</p>

<h2 id="whisper">4. Sharper voice and captions (optional)</h2>
<p>Whisper is a free speech model that runs on your Mac and is much more accurate than the built-in one. To use it, install <a href="https://brew.sh">Homebrew</a>, run <code>brew install whisper-cpp</code> in Terminal, then download the model from Bubble's welcome tour or reel editor (574 MB, once). Nothing is uploaded.</p>

<h2 id="shortcuts">5. Shortcuts</h2>
<table>
<tr><th>Keys</th><th>What it does</th></tr>
<tr><td><kbd>⌥</kbd><kbd>⇧</kbd><kbd>R</kbd></td><td>Start a recording (pick what to record), or finish one</td></tr>
<tr><td><kbd>⌥</kbd><kbd>⇧</kbd><kbd>A</kbd></td><td>Draw an area, then record it</td></tr>
<tr><td><kbd>⌥</kbd> <kbd>⌥</kbd></td><td>Double-tap to dictate; it finishes when you pause (or tap ⌥ once)</td></tr>
<tr><td><kbd>⌥</kbd><kbd>\\</kbd></td><td>Show or hide Ask Bubble</td></tr>
<tr><td><kbd>⌥</kbd><kbd>⇧</kbd><kbd>\\</kbd></td><td>Talk to Ask Bubble</td></tr>
<tr><td><kbd>Esc</kbd></td><td>Cancel picking, the countdown, dictation, or hide Ask Bubble</td></tr>
</table>
<p>Click any shortcut inside Bubble to change it.</p>

<h2 id="uninstall">Uninstall</h2>
<p>Bubble keeps nothing outside your Mac, so removing it is complete:</p>
<ol>
<li>Quit Bubble and drag it from Applications to the Bin.</li>
<li>Optional: delete its data folder, <code>~/Library/Application Support/Bubble</code>, and its log, <code>~/Library/Logs/Bubble.log</code>. Your recordings in <code>~/Desktop/Bubble Recordings</code> are yours to keep or delete.</li>
<li>Optional: if you saved an API key, open the Keychain Access app, search for "Bubble AI polish" and delete it.</li>
<li>Optional: remove Bubble from System Settings → Privacy &amp; Security lists (Screen Recording, Microphone and so on).</li>
</ol>
</div>
"""

# ─────────────────────────────── FAQ ───────────────────────────────
def q(question, answer):
    return f"<details><summary>{question}</summary>{answer}</details>"

FAQ = head("FAQ", "Questions people ask", "Can't find yours? Ask on GitHub and we'll help.") + '<div class="wrap narrow doc faq">' + "".join([
    q("Is Bubble really free?", "<p>Yes. It's open source under the MIT licence. There's no paid tier and no ads. Ask Bubble uses an AI you bring yourself (your Claude plan or your own API key), and that provider may charge you for it.</p>"),
    q("Which devices does it work on?", "<p>Macs running macOS 15 Sequoia or later, with Apple silicon or Intel. There's no Windows, Linux, iPhone or Android version.</p>"),
    q("Is it safe to download?", "<p>Bubble is open source, so anyone can read exactly what it does, and every release lists a SHA-256 fingerprint so you can confirm the file hasn't been changed (see the <a href=\"get-started.html#install\">install guide</a>). Only download Bubble from this site or its GitHub page.</p>"),
    q("What does Bubble collect about me?", "<p>Nothing. There's no account, no analytics and no tracking. The only time anything leaves your Mac is when you use a feature that needs the internet, like asking Ask Bubble a question, and the <a href=\"privacy.html\">privacy policy</a> lists exactly what is sent and to whom.</p>"),
    q("Does Bubble record me all the time?", "<p>No. It records only when you start a recording, hears your voice only while you dictate or talk to it, hears your Mac's sound only while Listen is on (a red dot shows), and takes a screenshot only when you ask it something.</p>"),
    q("What does Listen hear?", "<p>Only the sound playing on your Mac: the other people on a call or meeting, or a video you're watching. It doesn't use your microphone. To talk to Bubble yourself, use Talk (⌥⇧\\) or dictation.</p>"),
    q("Can Ask Bubble send messages or emails for me?", "<p>It can prepare them, but it never sends on its own. Emails need you to approve them. For Messenger, Instagram, WhatsApp and Messages it opens the chat and types the message, and you press Enter.</p>"),
    q("Can I use it with ChatGPT or another AI?", "<p>Not yet. Ask Bubble works with Claude, either through Claude Code on your Mac or with an Anthropic API key. Recording and dictation don't need any AI.</p>"),
    q("Does it know my previous Claude chats?", "<p>Through Claude Code it knows your Claude Code memory notes and connected apps. It can't read your chat history from the Claude app or website, because Claude doesn't let other apps do that.</p>"),
    q("Can people tell I'm using Ask Bubble on a call?", "<p>Yes, if you share your screen: Bubble's chat window shows up in screen shares and recordings like any other window. Bubble isn't designed to be hidden, and you shouldn't use it to cheat in exams or interviews or to record people without telling them.</p>"),
    q("Where are my recordings?", "<p>In <code>Bubble Recordings</code> on your Desktop, and in Bubble's library. Reels are saved in its <code>Reels</code> folder. Nothing is uploaded.</p>"),
    q("Dictation didn't type into my app. Why?", "<p>Bubble needs Accessibility permission to type into other apps (System Settings → Privacy &amp; Security → Accessibility). Without it, your words are copied so you can paste them. Some secure fields, like password boxes, block typing on purpose.</p>"),
    q("How do I remove Bubble completely?", "<p>See <a href=\"get-started.html#uninstall\">Uninstall</a>. Because Bubble has no servers, deleting it from your Mac removes it completely.</p>"),
    q("How do I report a bug or a security problem?", f"<p>Bugs: <a href=\"{REPO}/issues\">open an issue on GitHub</a>. Security problems: please report them privately through <a href=\"{REPO}/security/advisories/new\">GitHub's private security reporting</a>, not in a public issue.</p>"),
]) + "</div>"

# ─────────────────────────────── Privacy ───────────────────────────────
PRIVACY = f"""
<p>Bubble is a free, open-source Mac app. This policy explains what happens to your information when you use the app and this website. The short version: we don't collect anything, and Bubble only sends information to other services when you use a feature that needs them.</p>

<h2>Who we are</h2>
<p>Bubble is an independent open-source project published at <a href="{REPO}">github.com/HarryNGU/bubble</a>. There's no company account system and no servers run by Bubble. Contact us through <a href="{REPO}/issues">GitHub issues</a>.</p>

<h2>What we collect</h2>
<p>Nothing. Bubble has no accounts, no analytics, no crash reporting, no advertising and no tracking. We don't receive your recordings, voice, screenshots, messages, contacts or settings, and we couldn't see them if we wanted to.</p>

<h2>What stays on your Mac</h2>
<ul>
<li>Recordings and reels (<code>~/Desktop/Bubble Recordings</code>).</li>
<li>Voice: dictation, captions and Ask Bubble's listening are transcribed on your Mac. Audio is never uploaded.</li>
<li>The name you asked Bubble to call you, if you gave one. It is only shown to you.</li>
<li>Your chats with Bubble (in <code>~/Library/Application Support/Bubble/Chats</code>, readable only by your user account), so it picks up where you left off. Screenshots are never saved. They're kept for 30 days unless you choose otherwise in Settings, and you can delete any chat, or all of them, at any time.</li>
<li>What you brought over from another assistant about yourself, if you did (in <code>~/Library/Application Support/Bubble/about-me.md</code>, readable only by your user account). You can delete it in Bubble's settings.</li>
<li>Settings, snippets, transcripts of your recordings, and Ask Bubble's latest screenshot (in <code>~/Library/Application Support/Bubble</code>, readable only by your user account).</li>
<li>Your Anthropic API key, if you add one, in the macOS Keychain.</li>
<li>A log file for troubleshooting (<code>~/Library/Logs/Bubble.log</code>). It stays on your Mac unless you choose to share it.</li>
</ul>

<h2>When information leaves your Mac</h2>
<p>Only when you use these features, and only to these services:</p>
<table>
<tr><th>When you…</th><th>What is sent</th><th>To</th></tr>
<tr><td>Ask Bubble something</td><td>Your question, a screenshot of your screen (unless you turn the eye off), the recent transcript (only if Listen is on), and what you brought over about yourself (if you did)</td><td>Anthropic, through Claude Code on your Mac or your API key</td></tr>
<tr><td>Ask Ask Bubble to use a connected app (for example Gmail)</td><td>What's needed for that task</td><td>That app, through the connection you set up with your Claude account</td></tr>
<tr><td>Use AI polish for dictation, or the reel editor chat</td><td>The text of your dictation, or the video's transcript and edit settings. Never audio or video.</td><td>Anthropic, with your API key</td></tr>
<tr><td>See a picture, molecule or video in an answer</td><td>The search words or compound name</td><td>Wikimedia Commons, PubChem or YouTube (the video player)</td></tr>
<tr><td>Download the Whisper speech model</td><td>A normal download request</td><td>Hugging Face</td></tr>
<tr><td>Bubble checks for updates (once a day, if that's on)</td><td>A normal request for one small public file. Nothing about you is included.</td><td>GitHub Pages (this website)</td></tr>
</table>
<p>Those services handle the information under their own privacy policies, including <a href="https://www.anthropic.com/legal/privacy">Anthropic's</a>. Bubble doesn't sell or share your information with anyone else, ever.</p>

<h2>Other people's information</h2>
<p>If you turn on Listen during a call, what other people say is transcribed on your Mac and may be included when you ask a question. Tell people before you do this. In some places the law requires their consent.</p>

<h2>This website</h2>
<p>This site sets no cookies and runs no analytics or third-party scripts. It's hosted by GitHub Pages, which, like any web host, may log your IP address for security; see <a href="https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement">GitHub's privacy statement</a>. Downloads come from GitHub.</p>

<h2>Children</h2>
<p>Bubble isn't meant for children under 13. Features that use Anthropic require you to meet Anthropic's age requirements, which are 18 or older.</p>

<h2>Your choices and rights</h2>
<p>Because we don't hold any of your information, there's nothing for us to access, correct or delete. You control everything on your Mac: you can delete recordings, clear Bubble's data folder, remove your API key and revoke permissions in System Settings at any time (see <a href="get-started.html#uninstall">Uninstall</a>). For information you sent to Anthropic or another service, use that service's privacy tools.</p>

<h2>Changes</h2>
<p>If this policy changes, we'll update this page and the date above, and note the change in the release notes. Bubble's code is public, so any change in what it does is visible.</p>
"""

# ─────────────────────────────── Terms ───────────────────────────────
TERMS = f"""
<p>These terms apply when you download or use Bubble or this website. By using Bubble you agree to them. If you don't agree, please don't use it.</p>

<h2>The licence</h2>
<p>Bubble is open-source software under the <a href="{REPO}/blob/main/LICENSE">MIT licence</a>. You can use, copy, change and share it, including commercially, as long as you keep the licence notice. These terms add rules about how you use it; they don't take away rights the licence gives you.</p>

<h2>Who can use Bubble</h2>
<p>You must be at least 13, or older if the law where you live requires it. Ask Bubble's AI features use Anthropic's services, and you must meet <a href="https://www.anthropic.com/legal">Anthropic's terms</a> (including their age requirement) to use them.</p>

<h2 id="acceptable-use">Acceptable use</h2>
<p>You're responsible for how you use Bubble. Don't use it to:</p>
<ul>
<li>record, transcribe or listen to people without the consent the law where you are requires;</li>
<li>cheat in exams, assessments or job interviews, or get around rules you've agreed to;</li>
<li>harass, impersonate, threaten or spam anyone, including through messages it helps you prepare;</li>
<li>break the law, infringe others' rights, or capture content you're not allowed to copy;</li>
<li>break the terms of services you connect, such as Anthropic, Google or Meta.</li>
</ul>

<h2>Things it does for you</h2>
<p>Ask Bubble can prepare emails and messages and take actions in apps when you ask and approve it. AI can make mistakes: check what it prepares before you send or approve anything. You're responsible for messages you send and actions you approve.</p>

<h2>Third-party services</h2>
<p>Some features connect to services Bubble doesn't control: Anthropic (Claude), Claude Code, apps you connect through your Claude account, Wikimedia Commons, PubChem, YouTube and Hugging Face. Your use of them is governed by their own terms and policies, and you're responsible for any costs they charge, such as API usage.</p>

<h2>No warranty</h2>
<p>Bubble is provided "as is", without warranties of any kind, as the MIT licence says. We don't promise it will be error-free, always available, or right for your purpose. Keep backups of recordings that matter.</p>

<h2>Limits of liability</h2>
<p>To the extent the law allows, the people who make Bubble aren't liable for any loss or damage from using or not being able to use it, including lost recordings, messages sent or actions approved, or costs from third-party services. Nothing in these terms limits rights you have under consumer law that can't be excluded, including the Australian Consumer Law.</p>

<h2>Changes</h2>
<p>We may update these terms. Changes take effect when they're posted here, and the date above will change. If you keep using Bubble after that, you accept the new terms.</p>

<h2>Law</h2>
<p>These terms are governed by the laws of Victoria, Australia.</p>

<h2>Contact</h2>
<p>Questions: <a href="{REPO}/issues">GitHub issues</a>.</p>
"""

# ─────────────────────────────── Security ───────────────────────────────
SECURITY = f"""
<p>Bubble can see your screen, hear your voice and act in your apps, so it's built to be careful by default. Here's exactly how.</p>

<h2 id="rules">The ground rules</h2>
<p>Before Ask Bubble can see or hear anything, Bubble shows you these rules and asks you to agree:</p>
<ul>
<li><strong>It sees your screen only when you ask.</strong> Each question sends one screenshot to your AI. Turn the eye off for private screens, like banking.</li>
<li><strong>Listening is off until you turn it on,</strong> and a red dot shows while it's on.</li>
<li><strong>Nothing is sent without you.</strong> Emails need your Approve. Messages are typed in for you to send.</li>
<li><strong>Private files stay private.</strong> It asks before reading key, password or history files, and before opening links that carry data.</li>
<li><strong>It's visible.</strong> The chat shows up in screen shares, and it isn't for cheating or secret recording.</li>
</ul>

<h2>Actions need your approval</h2>
<p>Looking things up runs freely. Anything that writes files, runs commands, or sends, creates, edits or deletes in your apps shows an Approve or Deny card first. You can say "yes" or "no" out loud. "Always allow" applies to one tool only, and never overrides the protections below.</p>

<h2>Protection from tricks</h2>
<p>A web page, email or document could contain hidden text meant to trick an AI into doing something you didn't ask for (called prompt injection). Bubble always asks you before:</p>
<ul>
<li>reading files that hold keys, passwords or private history (for example <code>~/.ssh</code>, keychains, browser data, shell history, <code>.env</code> files);</li>
<li>searching your whole home folder;</li>
<li>opening a web address that carries data in it, which is a common way to leak information.</li>
</ul>

<h2>Your accounts and keys</h2>
<ul>
<li>Bubble never asks for or stores your passwords. It works with the apps and browser you're already signed into.</li>
<li>Claude Code keeps its own sign-in in your Keychain; Bubble never sees it.</li>
<li>An API key you add is stored in the macOS Keychain, never in a file.</li>
</ul>

<h2>Inside the app</h2>
<ul>
<li>Bubble's helper for Ask Bubble listens only on your own Mac (127.0.0.1) and needs a random secret that changes every launch, so other devices and websites can't use it.</li>
<li>The app uses Apple's hardened runtime and asks only for the system permissions it needs: camera, microphone and automation.</li>
<li>Speech recognition and Whisper run on your Mac; audio is never uploaded.</li>
</ul>

<h2 id="verify">Check your download</h2>
<p>Every release publishes a SHA-256 fingerprint on the <a href="index.html#download">download page</a> and on GitHub. In Terminal, run <code>shasum -a 256 ~/Downloads/Bubble-*.dmg</code> and compare. If they don't match, don't open the file. Only download Bubble from this site or <a href="{REPO}/releases">its GitHub releases</a>.</p>
<p class="note" data-notarized="false">Early versions are signed but not yet notarised by Apple, so macOS warns the first time you open them. Notarisation (Apple's malware check) is planned. Until then, the fingerprint and the public source code are how you can check the download.</p>

<h2 id="report">Report a security problem</h2>
<p>Please report it privately through <a href="{REPO}/security/advisories/new">GitHub's private vulnerability reporting</a>, not in a public issue. Include what you found and how to reproduce it. We'll reply as soon as we can and credit you if you'd like.</p>
"""

# ─────────────────────────────── Notices ───────────────────────────────
NOTICES = f"""
<p>Bubble is MIT-licensed. It works with these projects and services, which keep their own licences and terms:</p>
<table>
<tr><th>Project or service</th><th>Used for</th><th>Licence or terms</th></tr>
<tr><td><a href="https://github.com/ggml-org/whisper.cpp">whisper.cpp</a></td><td>On-device transcription (installed separately)</td><td>MIT</td></tr>
<tr><td><a href="https://github.com/openai/whisper">Whisper models</a> (large-v3-turbo)</td><td>Speech model (downloaded separately)</td><td>MIT</td></tr>
<tr><td><a href="https://claude.com/claude-code">Claude Code</a> and the <a href="https://www.anthropic.com/api">Anthropic API</a></td><td>Ask Bubble, AI polish, reel editor chat</td><td><a href="https://www.anthropic.com/legal">Anthropic's terms</a></td></tr>
<tr><td><a href="https://commons.wikimedia.org">Wikimedia Commons</a></td><td>Pictures in answers</td><td>Each image has its own licence, shown on its page</td></tr>
<tr><td><a href="https://pubchem.ncbi.nlm.nih.gov">PubChem</a> (U.S. National Library of Medicine)</td><td>Molecule structures</td><td><a href="https://www.ncbi.nlm.nih.gov/home/about/policies/">NCBI policies</a></td></tr>
<tr><td><a href="https://www.youtube.com">YouTube</a></td><td>Videos played in answers</td><td><a href="https://www.youtube.com/t/terms">YouTube Terms of Service</a></td></tr>
<tr><td>Apple frameworks</td><td>Screen capture, camera, speech recognition, Vision</td><td>Part of macOS</td></tr>
</table>
<p>Bubble isn't affiliated with or endorsed by Anthropic, Apple, Google, Meta, OpenAI, Wikimedia or the U.S. National Library of Medicine. Product names belong to their owners.</p>
"""

NOT_FOUND = head("404", "Page not found", "That page doesn't exist.") + '<div class="wrap narrow doc center"><p><a class="btn primary" href="index.html">Go to the home page</a></p></div>'

if __name__ == "__main__":
    DOCS.mkdir(exist_ok=True)
    page("index.html", "Bubble · Your personal assistant on your Mac", "Ask about anything on your screen, get emails and tasks done, talk instead of typing and record in a click. Free, private and open source, for Mac.", HOME)
    page("get-started.html", "Get started · Bubble", "Install Bubble, set up permissions, connect your AI and learn the shortcuts.",
         head("Get started", "Set up Bubble in two minutes", "Install it, say hello, and Bubble walks you through the rest. Everything after installing is optional.") + STARTED)
    page("faq.html", "FAQ · Bubble", "Answers to common questions about Bubble.", FAQ)
    doc("privacy.html", "Privacy policy", "What Bubble does with your information: nothing is collected.", PRIVACY)
    doc("terms.html", "Terms of use", "The terms for using Bubble, including acceptable use.", TERMS)
    doc("security.html", "Safety and security", "How Bubble keeps you safe: approvals, protections and how to check your download.", SECURITY)
    doc("notices.html", "Open-source notices", "Third-party projects and services Bubble works with.", NOTICES)
    page("404.html", "Not found · Bubble", "Page not found.", NOT_FOUND)
    (DOCS / ".nojekyll").write_text("")
    print("Built", len(list(DOCS.glob("*.html"))), "pages in", DOCS)
