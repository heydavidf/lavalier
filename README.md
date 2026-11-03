# Lavalier

Push-to-talk dictation for the Mac menu bar. Hold a key, speak, let go: ElevenLabs turns your speech into text, Claude tidies it, and the text appears wherever your cursor is.

You say:

> Um, so I think we should, uh, move the meeting to Thursday. No, wait, I mean Friday afternoon, and let Sarah know.

Lavalier types:

> I think we should move the meeting to Friday afternoon, and let Sarah know.

(Recorded output for a synthetic test clip.) Filler words go, punctuation arrives, and when you correct yourself mid-sentence only the correction is kept.

Lavalier is a small personal tool, shared as it is. It works for its author every day, but it is young (version 0.1.0): expect rough edges, and read [Compatibility and limitations](#compatibility-and-limitations) first.

## Before you start: you need your own API keys

**Lavalier ships with no API keys.** To use it you need two keys of your own, and both services charge your account for what you use:

- **ElevenLabs**, for speech to text. On the author's account this used about 35 credits per minute of speech.
- **Anthropic**, for the Claude clean-up. A typical one-sentence dictation used about 320 input and 30 output tokens. Dictations under four words skip this step.

You paste the keys into Lavalier's Settings window once it is running, and it stores them in your macOS Keychain. They never go into a file, the code or a chat. [docs/SETUP.md](docs/SETUP.md) shows where to create both keys.

## Install

You need macOS 14 or later, Xcode, and about 30 minutes for the first setup, including creating the two accounts.

### With a coding agent

Paste this into Claude Code, Codex or a similar agent running on your Mac:

> Set up Lavalier for me from https://github.com/heydavidf/lavalier. Follow its docs/SETUP.md: first tell me what it needs and what it costs, including that I need my own ElevenLabs and Anthropic API keys, then build it and guide me through the permissions, my keys and a first dictation. Don't ask me to paste my keys into this chat.

The agent can build the app, but you do the parts that need a person: creating the accounts, switching on permissions in System Settings, pasting the keys into Lavalier, and speaking.

### By hand

```sh
git clone https://github.com/heydavidf/lavalier.git
cd lavalier
./build.sh
open build/Lavalier.app
```

Then follow [docs/SETUP.md](docs/SETUP.md) from step 4: grant the Microphone and Accessibility permissions, paste your keys in Settings > Keys, choose a push-to-talk key in Settings > Shortcuts (the default, Right Control, does not exist on MacBook keyboards), and dictate into TextEdit.

## How it works

1. While you hold the key, Lavalier streams your microphone to ElevenLabs' realtime speech-to-text (`scribe_v2_realtime`, English) and shows the words in a small panel.
2. When you let go, Claude Haiku 5.5 removes filler words, adds punctuation and keeps only your corrected wording.
3. Lavalier inserts the text at the cursor: through the Accessibility interface in native Mac apps, and by pasting in browsers and Electron apps (your clipboard is put back afterwards, unless it held something Lavalier cannot read, such as some app-specific data).

Long dictations work too: up to 10 minutes per hold.

What goes where:

| Data | Where |
|---|---|
| Your voice | Streamed to ElevenLabs while the key is held. Not saved on your Mac. |
| The transcript | Sent to Anthropic for clean-up, then inserted. Kept in memory for Copy Last Dictation. |
| API keys | Your macOS Keychain (service "Lavalier"). |
| Personal dictionary | `~/Library/Application Support/Lavalier/dictionary.txt`: names and words you want spelled your way. The words go to Anthropic with every clean-up, and to ElevenLabs as well if you switch on keyterms. |
| Usage counts | `~/Library/Application Support/Lavalier/usage.json`: Claude calls and tokens per month, and the last dictation's timings (no text). |
| Text log | Off by default. If you switch it on in Settings, `timings.jsonl` in the same folder keeps transcripts, timings and the name of the app that received the text, never audio. It grows until you delete it. |

ElevenLabs and Anthropic handle your audio and text under their own terms and privacy policies.

## Compatibility and limitations

- Tested on macOS 26 on Apple silicon with Xcode 27.0. macOS 14 and 15, and Intel Macs, are expected to work but are not tested.
- You build it yourself; there is no downloadable app. Without an Apple Development certificate, macOS asks for the permissions again after every rebuild ([Signing](docs/SETUP.md#signing)).
- English only, and the clean-up writes British spelling.
- It needs an internet connection; there is no offline mode.
- Text insertion was tested in the apps its author uses. Some apps may behave differently; please report them.
- The automated tests run without network access or keys. The live services were tested by the author with real keys and real speech, not in CI.

## Settings at a glance

| Tab | What you can change |
|---|---|
| General | Clean-up on or off, sound cues, the floating panel, the menu-bar icon, the local text log, Launch at login |
| Keys | Save, remove and test your ElevenLabs and Anthropic keys |
| Dictionary | Names and words to spell your way. Optionally also sent to ElevenLabs as keyterms, which costs about 20% more credits |
| Shortcuts | One or more push-to-talk keys, key combinations or mouse buttons |

## Update, remove and get help

- **Update:** quit Lavalier, then `git pull` and `./build.sh` in the clone. Your keys, settings and dictionary are kept. Details: [docs/SETUP.md#update](docs/SETUP.md#update).
- **Remove:** [docs/SETUP.md#uninstall](docs/SETUP.md#uninstall) lists every file, preference and Keychain item to delete.
- **Help:** open an issue on GitHub. Never include your API keys. Lavalier's log lines never contain your dictated text or keys, but they do show where the app is (a path with your Mac user name), your microphone's name and any error text from ElevenLabs or Anthropic, so read them before posting. Security problems: see [SECURITY.md](SECURITY.md).

This is maintained by one person in spare time, so replies may take a while.

## Contributing

Bug reports and small pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). [AGENTS.md](AGENTS.md) maps the code and lists the checks for people and coding agents changing it.

## Licence

MIT, see [LICENSE](LICENSE). Lavalier is not affiliated with ElevenLabs or Anthropic.
