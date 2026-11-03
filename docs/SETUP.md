# Setting up Lavalier

This guide takes you from nothing to your first dictation. It is written for you and for a coding agent helping you (Claude Code, Codex, Cursor or similar). Allow about 30 minutes the first time, most of it waiting for Xcode and creating two accounts.

## For agents: read this before you start

You are helping a person install Lavalier on their own Mac. Follow the steps below in order.

- **Lavalier ships with no API keys.** Before you build anything, explain this to the person using the message in step 1, and make sure they understand that both services bill their own accounts.
- **Keep keys out of the conversation.** Never ask the person to paste a key into the chat, a terminal command, a file or an issue. Keys go only into Lavalier's own Settings window (step 5), which stores them in the macOS Keychain. Do not read, print or export the Keychain items. If the person pastes a key into the chat anyway, tell them to delete that key in the service's dashboard and create a new one.
- **Several steps need the person at the Mac:** creating accounts, granting permissions in System Settings, pasting keys, and pressing a key to speak. Stop at those steps and tell them exactly what to click.
- Explain each command before you run it. Install nothing beyond what this guide lists. Do not change System Settings or turn on Launch at login yourself.
- This guide installs the app. Changing Lavalier's code is a different job: read [AGENTS.md](../AGENTS.md) for that.

## 1. What you need (tell the person this first)

Agents: say this to the person in your own words before step 2.

> Lavalier doesn't come with any API keys. The public code contains none, so you need two keys of your own:
>
> 1. An **ElevenLabs** API key. ElevenLabs turns your speech into text while you hold the key.
> 2. An **Anthropic** API key. Claude tidies the text (filler words, punctuation, corrections you make while speaking).
>
> Both services charge your own account for what you use. On the author's account, live transcription used about 35 ElevenLabs credits per minute of speech, and the Claude clean-up of a typical one-sentence dictation used about 320 input and 30 output tokens. Check both services' current prices before you start. A Claude.ai chat subscription is billed separately from API use.
>
> Once Lavalier is running, you'll paste each key into its own Settings window. It saves them in your Mac's Keychain and nowhere else. Please don't paste them into our chat.

Everything you need:

| What | Details |
|---|---|
| A Mac with macOS 14 Sonoma or later | Tested on macOS 26 on Apple silicon. Intel Macs and macOS 14 and 15 are expected to work but have not been tested. |
| Xcode | Free from the Mac App Store. Tested with Xcode 27.0 (Swift 6.4). Building with only the Command Line Tools failed on the test Mac, so install the full Xcode. |
| Git | Comes with Xcode. |
| An ElevenLabs account and API key | At the time of writing, keys are created at [elevenlabs.io/app/settings/api-keys](https://elevenlabs.io/app/settings/api-keys). If you limit what the key may do, allow **Speech to Text**, and read access to your user account so the credits line and Test Connection work. Prices: [elevenlabs.io/pricing](https://elevenlabs.io/pricing). |
| An Anthropic API key | Create one in the Claude Console at [platform.claude.com/settings/keys](https://platform.claude.com/settings/keys) ([Anthropic's guide](https://platform.claude.com/docs/en/get-api-key)). The account needs API credits. |
| A microphone | The built-in one is fine. Bluetooth earphones take about a second to switch on: wait for the start sound before you speak. |

Lavalier listens in English and the clean-up writes British spelling. Other languages are not supported yet.

## 2. Check the Mac

Run these in Terminal:

```sh
sw_vers -productVersion
xcodebuild -version
git --version
```

Expected: a macOS version of 14 or higher, an Xcode version, and a Git version. If `xcodebuild` says it requires Xcode, install Xcode from the App Store, open it once to finish setup, then run `sudo xcode-select -s /Applications/Xcode.app` (it asks for the Mac's password).

## 3. Get the code and build the app

```sh
git clone https://github.com/heydavidf/lavalier.git
cd lavalier
./build.sh
```

The first build takes a minute or two. The last line should be `built build/Lavalier.app`. The app stays in the `build` folder inside the clone; keep the clone.

### Signing

`build.sh` signs the app so macOS can remember your permission choices. It uses, in this order: the identity in `LAVALIER_SIGN_IDENTITY` if you set one; the first **Apple Development** certificate in your keychain; otherwise an ad hoc signature.

- **With an Apple Development certificate** (recommended if you will update Lavalier): permissions and Keychain access survive rebuilds. Any Apple ID can make one, free: Xcode > Settings > Accounts, add your Apple ID, select it, click Manage Certificates, then + and Apple Development. Then run `./build.sh` again.
- **Ad hoc** (no certificate): `build.sh` says `signed ad hoc` at the end. Lavalier works, but macOS treats every rebuild as a new app. After each rebuild you switch the three permissions off and on again, and the Keychain asks once whether the new build may use your saved keys (click Always Allow).

## 4. Start Lavalier and grant permissions

```sh
open build/Lavalier.app
```

A small microphone icon appears in the menu bar, and a panel saying "Lavalier is running" shows for a few seconds. Lavalier has no Dock icon; everything is in that menu.

A **Permissions** window opens. Lavalier uses three macOS permissions, and only the person at the Mac can grant them:

| Permission | Why |
|---|---|
| Microphone (required) | To hear you while the key is held. Audio goes to ElevenLabs and is not stored. |
| Accessibility (required) | To watch the push-to-talk key and to put the text into the app you are using. |
| Input Monitoring | Needed when a shortcut is a keyboard key or a mouse button (step 6), or if macOS asks for it. A modifier key on its own works without it. |

Click **Request** or **Open System Settings** on each row and switch Lavalier on under System Settings > Privacy & Security. The rows update by themselves every two seconds. If a row still says "Not granted" after you switched it on, quit Lavalier (menu > Quit Lavalier) and open it again.

## 5. Add your keys (the person does this)

1. Click the menu-bar icon and choose **Settings…**, then the **Keys** tab.
2. Paste the ElevenLabs key into its field and click **Save**. Do the same for the Anthropic key.
3. Click **Test Connection**. Expected: "ElevenLabs OK: …" with your plan and remaining credits, and "Anthropic OK: key accepted."

The fields stay blank after saving on purpose; the status line shows whether a key is stored. To change a key, paste the new one and click Save. **Remove** deletes it from the Keychain.

Agents can confirm the keys are stored without seeing them. This prints only whether each key exists:

```sh
build/Lavalier.app/Contents/MacOS/Lavalier --print-permissions
```

(Run from Terminal, its permission lines describe Terminal, not Lavalier; only the key lines matter here.)

## 6. Choose your push-to-talk key

The default key is **Right Control**. MacBook keyboards have no Right Control key, so most people need to choose another one:

1. Settings > **Shortcuts** > **Add Shortcut…**, then press the key you want. A modifier key on its own (for example Right Option), a key or combination (for example F13), or a middle or side mouse button all work.
2. Remove Right Control if you don't need it.

Pick a key nothing else on your Mac uses. Right Option is on every Mac keyboard and works for most people. If you choose fn (Globe), first set System Settings > Keyboard > "Press 🌐 key to" to "Do Nothing". Holding one of the other modifier keys by mistake shows a hint naming the key Lavalier listens for.

## 7. Your first dictation

1. Open TextEdit or Notes and click into a document.
2. Hold your key, wait for the short start sound, then say: "Um, so I think we should, uh, move the meeting to Thursday, no wait, I mean Friday afternoon."
3. Let go of the key.

Within a second or two, tidied text appears at the cursor, for example "I think we should move the meeting to Friday afternoon." While you speak, a small panel near the bottom of the screen shows the words as they are heard. The menu shows the last dictation and this month's usage.

That's it: Lavalier is set up. Settings > General has **Launch at login** if you want it to start with your Mac.

## When something goes wrong

| What you see | What to do |
|---|---|
| Nothing happens when you hold the key | The menu's second line says which key Lavalier listens for. Check it is the key you hold (step 6), and that Accessibility and Input Monitoring are on (Permissions… in the menu). |
| "ElevenLabs key is missing. Open Settings and paste it." (or Anthropic) | Step 5. |
| "ElevenLabs rejected the key. Check Settings." | The key is wrong, deleted, or lacks the Speech to Text permission. Create a new key and save it. |
| "ElevenLabs credits are used up for this month." | Your ElevenLabs plan has no credits left. |
| "That was too short to transcribe. Hold the key while you speak." or "No speech was heard." | Hold the key a little longer, and wait for the start sound before speaking. |
| "Claude took too long; the raw transcript was used instead." | The untidied text was inserted. Usually temporary. |
| The text appears twice, or not at all, in one app | Tell us in an issue which app it was (see the README). Copy Last Dictation in the menu gets the text back. |

For a closer look, Lavalier writes short log lines (never your text or keys):

```sh
log show --predicate 'subsystem == "com.davidfinnegan.lavalier"' --last 10m --info
```

## Update

Quit Lavalier from its menu first, then:

```sh
cd lavalier
git pull
./build.sh
open build/Lavalier.app
```

Your keys, settings and dictionary live outside the clone and are kept. With an ad hoc signature, grant the permissions again afterwards (see Signing).

## Uninstall

1. In Settings > General, switch off **Launch at login**. In Settings > Keys, click **Remove** for both keys.
2. Quit Lavalier from its menu.
3. Delete the `lavalier` folder you cloned.
4. Remove Lavalier's files, preferences and permission entries:

```sh
rm -rf "$HOME/Library/Application Support/Lavalier"
defaults delete com.davidfinnegan.lavalier
tccutil reset All com.davidfinnegan.lavalier
```

If you deleted the app before removing the keys, remove them from the Keychain directly:

```sh
security delete-generic-password -s Lavalier -a elevenlabs
security delete-generic-password -s Lavalier -a anthropic
```

Your keys still exist in your ElevenLabs and Anthropic accounts; delete them there if you no longer need them.
