# Lavalier contributor guide

Lavalier is a native macOS menu-bar app in Swift (AppKit, no third-party packages): hold a push-to-talk key, the microphone streams to ElevenLabs' realtime speech-to-text, Claude Haiku tidies the transcript, and the text is inserted at the cursor. The [README](README.md) owns the public description and claims, and [docs/SETUP.md](docs/SETUP.md) owns installation. This file is the map for people and agents changing the code.

Installing Lavalier for someone is not the same job as changing it: for an install, follow docs/SETUP.md and stop there.

## Where things live

| Area | Files |
| --- | --- |
| Package and products (`Lavalier` app, `lavalier-cli` harness, `LavalierCore` library, tests) | `Package.swift` |
| Build, bundle and sign | `build.sh`, `Resources/Info.plist` |
| App start, headless commands (`--print-permissions`, `--test-connection` and others) | `Sources/Lavalier/main.swift`, `Sources/Lavalier/AppDelegate.swift` |
| Dictation flow: key down, recording, pipeline, insertion, errors on screen | `Sources/Lavalier/DictationController.swift` |
| Microphone capture, device changes, silence watchdog | `Sources/Lavalier/AudioCapture.swift` |
| Watching push-to-talk shortcuts (event taps) | `Sources/Lavalier/HotkeyMonitor.swift` |
| Inserting text (Accessibility write or paste) | `Sources/Lavalier/TextInserter.swift`, `Sources/LavalierCore/InsertionPolicy.swift`, `Sources/LavalierCore/PasteboardSnapshot.swift` |
| Menu-bar item and menu | `Sources/Lavalier/StatusItemController.swift`, `Sources/Lavalier/UsageMenuText.swift` |
| Settings window (General, Keys, Dictionary, Shortcuts) | `Sources/Lavalier/SettingsWindow.swift` |
| Permissions model and window | `Sources/Lavalier/Permissions.swift`, `Sources/Lavalier/PermissionsWindow.swift` |
| Floating panel and launch cue | `Sources/Lavalier/DictationHUD.swift` |
| Unified-log lines | `Sources/Lavalier/Log.swift` |
| Pipeline: speech-to-text, then clean-up, with timings | `Sources/LavalierCore/Pipeline.swift` |
| ElevenLabs realtime WebSocket client and subscription check | `Sources/LavalierCore/ElevenLabsRealtime.swift` |
| Segment commits for long dictations | `Sources/LavalierCore/SegmentCommitPlanner.swift`, `Sources/LavalierCore/DictationLimits.swift` |
| Claude clean-up: prompt, model, request, speculative start | `Sources/LavalierCore/Cleanup.swift`, `Sources/LavalierCore/CleanupLatency.swift` |
| Keychain storage of the two API keys | `Sources/LavalierCore/Keychain.swift` |
| Settings stored in user defaults | `Sources/LavalierCore/Settings.swift` |
| Shortcut model (modifier keys, key combinations, mouse buttons) | `Sources/LavalierCore/Hotkey.swift`, `Sources/LavalierCore/HotkeyBinding.swift` |
| Personal dictionary | `Sources/LavalierCore/PersonalDictionary.swift` |
| Usage tally and timing log | `Sources/LavalierCore/Usage.swift` |
| Error types and the messages users see | `Sources/LavalierCore/Errors.swift` |
| Menu-bar icon drawings | `Sources/LavalierCore/MenuBarGlyph.swift` |
| WAV reader for test clips | `Sources/LavalierCore/Audio.swift` |
| Live test harness (real keys, real services) | `Sources/lavalier-cli/main.swift`, `scripts/make_long_clip.sh` |
| Unit tests (XCTest) | `Tests/LavalierCoreTests/` |
| CI and repository checks | `.github/workflows/checks.yml`, `.github/tripwire.sh`, `.github/check-shell-blocks.sh`, `.github/tests/` |

## Checks

Run from the repository root on macOS 14 or later with Xcode (tested with Xcode 27.0, Swift 6.4):

```sh
swift build
swift test
LAVALIER_SIGN_IDENTITY=- ./build.sh
build/Lavalier.app/Contents/MacOS/Lavalier --render-glyphs .build/glyphs
bash .github/check-shell-blocks.sh
python3 -m unittest discover -s .github/tests -v
bash .github/tripwire.sh origin/main
```

`swift test` must report every test passing (71 at version 0.1.0). The tests need no network and no API keys. The long-dictation tests run a fake ElevenLabs server bound to 127.0.0.1. The Keychain tests create and then delete items under the service names `Lavalier.tests` and `Lavalier.tests.presence` in the login keychain of the user running them, and look up `Lavalier.tests.empty`, which must not exist. Two settings tests keep their preferences in the fixed domains `lavalier.tests.hotkeys` and `lavalier.tests.hotkey-default`, emptied on every run. `LAVALIER_SIGN_IDENTITY=- ./build.sh` builds the app bundle signed ad hoc, as CI does; drop the variable to sign with your own Apple Development certificate. `--render-glyphs` writes every menu-bar icon in every state as PNG files and is a quick check that the built app starts. Pass the branch you will merge into to the tripwire (`origin/main` in a clone of the GitHub repository); with no argument it checks the whole tree but cannot spot newly silenced checks.

CI (`.github/workflows/checks.yml`) runs the build, the tests and the app bundle on a macOS runner, and the shell-block check, its own tests, the tripwire and gitleaks on Linux, on every push to `main`, on pull requests and weekly. It does not run `actionlint` or `zizmor`; run those yourself when you change the workflow.

### Live checks (cost money, need your own keys)

The unit tests never contact ElevenLabs or Anthropic. To check a change against the real services, use `lavalier-cli` with your own keys in the environment of your own shell (never commit them or paste them into an issue). It streams WAV files through the real pipeline, paced like speech:

```sh
say -v Daniel -o clip.aiff "Um, so I think we should, uh, move the meeting to Friday afternoon."
afconvert -f WAVE -d LEI16@16000 -c 1 clip.aiff clip.wav
swift build
.build/debug/lavalier-cli synthetic --files clip.wav --log run.jsonl
```

Each run spends ElevenLabs credits and Anthropic tokens. `scripts/make_long_clip.sh OUT.wav` builds a five-minute clip for long-dictation checks. `.gitignore` keeps `*.wav`, `*.aiff` and `*.jsonl` out of Git. Anything that needs a microphone, a held key or text landing in another app can only be checked by a person at a Mac; say so in your pull request rather than claiming it.

### Headless commands of the app

Run the binary inside the bundle (`build/Lavalier.app/Contents/MacOS/Lavalier`) with one of these; each prints and exits without showing the interface:

| Argument | What it does |
| --- | --- |
| `--print-permissions` | Microphone, Accessibility and Input Monitoring status, and whether each key is stored (presence only, never the value) |
| `--test-connection` | The same checks as Settings > Keys > Test Connection, using the stored keys |
| `--probe-hotkey` | Which key-monitoring mechanism macOS allows right now |
| `--watch-hotkeys [seconds]` | Prints each shortcut press and release, without dictating |
| `--usage-report` | The menu's usage lines; add `--simulate-remaining 5000` for the low-credit state |
| `--login-item status` | Or `register` / `unregister` |
| `--render-glyphs DIR` | Every menu-bar icon option in every state as PNG |
| `--import-keys-from-environment` | Saves `ELEVENLABS_API_KEY` and `ANTHROPIC_API_KEY` from the environment into the Keychain; for developers who already keep keys in their shell |

Run from Terminal, `--print-permissions` and `--probe-hotkey` report Terminal's own permissions, not the app's.

## Working rules

1. A bug fix ships with a committed test that fails on the old code and passes on the new. A one-off check in a temporary folder does not count.
2. Run every check above before saying a change is done, and quote the output.
3. Do not silence a check to get green: no skipped or disabled tests, no disabled rules. The tripwire fails the build unless the line says `tripwire-allow` with a reason.
4. Stop any app instance or server you started. Leave no stray files (clips, logs, glyph folders, caches) in the repository folder.
5. For non-trivial changes, a scenario test written independently of the change, by another person or another agent, is added before the change is accepted.

## Change constraints

- API keys live only in the macOS Keychain (service `Lavalier`, accounts `elevenlabs` and `anthropic`). Never write a key to a file, user defaults, a log line or test output. The app never reads keys from the environment; only `lavalier-cli` and `--import-keys-from-environment` do.
- Unified-log lines never contain keys, and never contain dictated text except the first 200 characters of an ElevenLabs reply the app cannot parse (`ElevenLabsRealtime.swift`). The local text log (`timings.jsonl`) stays off by default. Audio is never written to disk. Network sessions keep no URL cache (`urlCache = nil`), because the keys travel in request headers.
- Keep the bundle identifier `com.davidfinnegan.lavalier`, the defaults domain and the Keychain service stable: changing them resets every user's permissions and strands their saved keys.
- Without a saved shortcut list the default key is Right Command (`HotkeyChoice.default`): every Mac keyboard has it and it is rarely part of everyday shortcuts. Right Control is missing on MacBook keyboards, and a left-side modifier would start a dictation with every shortcut that uses it. A change to the default needs an issue first, because it changes what existing users hold.
- No third-party Swift packages without an issue first.
- Every message a user can see is in plain language and says what to do next (`Errors.swift`).
- No em-dashes or en-dashes in code comments, interface text or documentation.
- Record every user-visible change in `CHANGELOG.md`, and update the README and docs/SETUP.md when behaviour they describe changes.
