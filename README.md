# Expanded Input

**Version:** 1.0.0
**Game version:** World of Warcraft Retail, Midnight 12.1.5 (Interface 120105)
**Author:** SothosVoidstar

Expanded Input makes long chat posts readable while you write them. WoW's chat input is a single line, so a long emote or reply scrolls out of view as you type. Expanded Input shows a word-wrapped copy of your text in a panel that grows out of the input box, so you can read back your whole post, spot typos, and click straight to the spot you want to fix.

It was made with roleplayers in mind, but works for anyone who writes long messages.

---

## Features

- **Readable, growing panel.** A word-wrapped copy of what you're typing appears next to the chat input and grows as your text gets longer. Past a maximum height, it scrolls with the mouse wheel.
- **Grows in the direction you choose.** Up, down, or automatically towards the side of the screen with the most room.
- **Attaches to the input box or the whole window.** For WIM, it sits on top of the entire message window by default, so your conversation partner's replies stay readable. It follows the window when you move or resize it.
- **Click to edit:**
  - Click in the panel to put the cursor there.
  - Drag to select text.
  - Double-click to select a word.
  - Shift-click to select from the cursor to where you click.
  - The chat input becomes active again straight away, so you can just keep typing.
- **RP colours, the way Total RP 3 shows them once the message is sent:**
  - `"speech"` and `“speech”` in your /say colour.
  - `*emotes*` in your /emote colour.
  - `((out of character))` in grey.
  - Optionally, `<emotes>` written with angle brackets too.
- **Cursor marker.** A gold `|` shows where your text cursor is.
- **Info line.** Shows the channel, the character count and, for long posts, roughly how many messages it will be split into (for example `Emote · 312 chars · ~2 posts`).
- **Works with other addons' input boxes.** Blizzard's chat (all tabs and pop-out whisper windows) works out of the box. Other addons' boxes, such as WIM, can be added with `/ei learn`.
- **Midnight-aware.** Pauses itself during boss encounters, Mythic+ runs, PvP matches and chat lockdown, and switches back on by itself afterwards.

## What it does NOT do

- **It does not replace WoW's chat.** You still type in the normal input box. Chat tabs, channels, resizing and moving the chat frame all stay Blizzard's.
- **It does not split or send messages.** If you want to post more than 255 characters, use a post splitter such as Chattery or EmoteSplitter alongside it. The "~X posts" count is only an estimate, because splitters break at word boundaries.
- **It does not change your text.** Language or dialect addons transform your text when it's sent, so the panel shows what you typed, not the transformed version.
- **It does not read Total RP 3's own colour settings.** The RP colours use your normal /say and /emote chat colours.
- **It does not work during boss encounters, Mythic+ or PvP matches.** That's on purpose: Blizzard restricts chat addons there. The normal chat box keeps working as usual.
- **It does not work with addons that replace the input box entirely,** such as Yapper or ComfyChatting. Those already have their own large editors.

---

## Installation

1. Download and unzip `ExpandedInput.zip`.
2. Place the `ExpandedInput` folder in `World of Warcraft\_retail_\Interface\AddOns\`.
3. Start the game, or type `/reload` if you're already logged in.
4. Type `/ei test` to see a 10-second preview.

If the game lists the addon as "out of date" after a patch, type `/dump select(4, GetBuildInfo())` in chat and put that number after `## Interface:` in `ExpandedInput.toc`.

## Settings

Open them with `/ei`, or via **Esc → Options → AddOns → Expanded Input**.

| Setting | Default | What it does |
|---|---|---|
| Expand direction | Automatic | Up, down, or towards the side with the most room. |
| Show the panel | When text doesn't fit | Only when your text no longer fits on one line, or whenever you type. |
| Attach to (Blizzard chat) | The input box | The panel sits against the input box, or against the whole chat window. |
| Attach to (other addons, e.g. WIM) | The whole window | Same choice for other addons' input boxes. |
| Maximum height (lines) | 12 | Beyond this, the panel scrolls. |
| Background opacity | 85% | How see-through the panel is. |
| Show cursor position | On | The gold `\|` cursor marker. |
| Show channel and character count | On | The info line above your text. |
| Click in the panel to edit | On | Click, drag, double-click and shift-click. Off: clicks pass through the panel. |
| RP colours | On | Colours speech, emotes and OOC text. |
| Also colour \<emotes\> | Off | Treat text between `<` and `>` as an emote too. |
| Tell me when it pauses / resumes | On | A short line in chat when the addon pauses or is active again. |

## Commands

All commands start with `/ei` (or `/expandedinput`).

| Command | What it does |
|---|---|
| `/ei` | Open the settings. |
| `/ei help` | List all commands in chat. |
| `/ei up` / `/ei down` / `/ei auto` | Set the direction the panel grows. |
| `/ei lines <3-30>` | Set the maximum height in lines, e.g. `/ei lines 15`. |
| `/ei always` / `/ei overflow` | Show the panel whenever you type, or only when your text doesn't fit on one line. |
| `/ei attach chat box` / `/ei attach chat window` | Blizzard chat: attach to the input box or the whole chat window. |
| `/ei attach other box` / `/ei attach other window` | Other addons (WIM): attach to the input box or the whole window. |
| `/ei cursor` | Toggle the cursor marker. |
| `/ei info` | Toggle the info line (channel, characters, posts). |
| `/ei click` | Toggle click to edit. |
| `/ei colours` | Toggle RP colours (`/ei colors` works too). |
| `/ei angle` | Toggle colouring of `<emotes>`. |
| `/ei test` | Show a 10-second preview with sample text. |
| `/ei learn` | Add another addon's input box: run it, then click into that box within 15 seconds. |
| `/ei forget` | Forget all input boxes added with `/ei learn`. |
| `/ei status` | Show whether the addon is active or paused, and why. |
| `/ei window` | Troubleshooting: show which frame the panel attaches to. |
| `/ei quiet` | Toggle the pause / resume messages. |
| `/ei reset` | Reset all settings to their defaults. Added input boxes are kept. |

## Using it with WIM and other addons

Blizzard's chat works straight away. For an addon with its own message windows, such as WIM:

1. Open a conversation window in that addon.
2. Type `/ei learn` in the normal chat.
3. Click into the addon's input box within 15 seconds.

You'll see a confirmation in chat, and the box is remembered from then on. If an input box has no name, it's remembered until your next `/reload` only.

### Tested with

- Chattery
- ClickLinks
- Languages
- Total RP 3
- Eavesdropper
- Simply RP – Typing Tracker
- StoryTeller
- WIM

These were tested in normal play, trash fights and boss encounters.

---

## How it works

Expanded Input never replaces or reshapes Blizzard's input box. While you type, it only reads the text and cursor position, and draws its own panel next to the box. It breaks the text into lines itself, so it knows exactly which character sits where. That is what makes click to edit possible. Links (items, spells, profiles) are treated as one unbreakable piece, so they're never split across lines or broken by the cursor.

Only when you click in the panel does it touch the input box. It makes the box active again (the same as pressing Enter), then moves the cursor or selects text, the same as the arrow keys and shift-select do.

During restricted content in Midnight, the addon stops running entirely, so it can't interfere with Blizzard's chat restrictions.

## Troubleshooting

**The panel doesn't appear.**
- Check `/ei status`. You may be in a boss encounter, a Mythic+ run or a PvP match, where the addon pauses on purpose.
- By default, the panel only appears once your text no longer fits on one line. Use `/ei always` to show it whenever you type.

**The panel sits in the wrong place with another addon's window.**
- Type something long in that window's input box, then run `/ei window`.
- The frame marked `<<` is the one the panel attaches to.
- Use `/ei attach other box` to attach to the input box instead.

**"Action blocked" or "Interface action failed because of an AddOn".**
1. Type `/console taintLog 1`.
2. Repeat what you did, then `/reload`.
3. Check `World of Warcraft\_retail_\Logs\taint.log` to see which addon caused it.
4. Turn logging off again with `/console taintLog 0`.

If Expanded Input is involved, turning off click to edit (`/ei click`) puts it back in read-only mode.

---

## Changelog

### 1.0.0
- Initial release.
