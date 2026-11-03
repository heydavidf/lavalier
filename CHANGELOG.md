# Changelog

## 0.1.0 (proposed, first public release)

First public version of Lavalier, a push-to-talk dictation app for the Mac menu bar.

### Added

- Hold a push-to-talk shortcut to dictate; the text is inserted at the cursor when you let go.
- Live speech-to-text with ElevenLabs realtime (`scribe_v2_realtime`, English), with the words shown in a floating panel while you speak.
- Clean-up with Claude Haiku 5.5: filler words removed, punctuation added, spoken self-corrections honoured. Dictations under four words are inserted as heard.
- Right Command as the default push-to-talk key, on every Mac keyboard; change it in Settings > Shortcuts.
- Several push-to-talk shortcuts at once: modifier keys on their own, keys or key combinations, and middle or side mouse buttons (Settings > Shortcuts).
- Dictations of up to 10 minutes, committed in segments at natural pauses and joined into one text.
- Text insertion through the Accessibility interface in native apps, and by paste (with the clipboard restored) in browsers and Electron apps.
- API keys stored only in the macOS Keychain, entered in Settings > Keys, with Test Connection.
- Personal dictionary of names and words, optionally sent to ElevenLabs as keyterms.
- Permissions window, start and stop sounds, five menu-bar icon styles, ElevenLabs credit and Claude usage lines in the menu, Copy Last Dictation, Launch at login, and an optional local text log.
- `build.sh` signs with your own Apple Development certificate when you have one, and ad hoc otherwise.
- Setup guide for people and their coding agents (docs/SETUP.md), contributor guide (AGENTS.md) and CI.
