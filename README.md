# Whisperer

Voice to text for macOS, on your own Mac. Tap a key anywhere, speak, and the text is typed where your cursor
is. Nothing is sent to the internet: speech is transcribed locally with [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
on the Mac's GPU. Every recording is kept (audio and text) and searchable in the app.

It speaks English and Polish out of the box and works out which one you are using, per recording.

**Needs:** a Mac with Apple Silicon (M1 or newer) and macOS 26 (Tahoe) or later. About 2 GB of disk for the
voice model.

## Install (about 5 minutes)

1. Download `Whisperer-<version>.zip` from the latest release on this page (right-hand side, **Releases**)
   and double-click it.
2. Drag **Whisperer.app** into your **Applications** folder.
3. The app is not notarised by Apple, so macOS blocks it the first time. Open **Terminal** and paste:

       xattr -dr com.apple.quarantine /Applications/Whisperer.app

   then open Whisperer from Applications. (Or: try to open it once, then System Settings > Privacy &
   Security > scroll down > **Open Anyway**.)
4. Allow the **Microphone** when asked.
5. Allow **Accessibility**: System Settings > Privacy & Security > Accessibility > turn **Whisperer** on.
   This is what lets it hear the shortcut key in other apps and paste the text for you.
6. In the app, open **Models library** and download **Whisper Large v3 Turbo** (1.6 GB, once). It is
   marked BEST.

The first dictation after install takes up to a minute while the Mac prepares the model for its GPU. After
that it is about a second.

## Use it

| What | How |
|---|---|
| Dictate, hands free | tap **Right Option**, speak, tap again. The text is pasted where your cursor is |
| Push to talk | hold **Right Option** while you speak, let go to paste |
| Lock hands free | double tap **Right Option**: keeps recording until your next tap |
| Cancel | **Esc** while recording |
| Switch mode | Option + Shift + K |
| Copy the last text again | menu bar icon > Copy Last Transcript |

Option pressed together with another key (Option+Arrow, Option+3) is ignored, so your normal shortcuts keep
working. The key can be changed in **Configuration**.

Long recordings are fine: up to 30 minutes by default (Configuration > Longest recording, up to 60). The last
minute counts down in the recording window, and at the limit it stops and transcribes rather than throwing
anything away. Ten minutes of speech takes about 20 seconds to transcribe. While you talk the audio is
written to disk, so if anything crashes the recording is recovered into History on the next launch.

**Modes** hold the language and model: "English or Polish (detects which)" is the default. **Vocabulary**
takes names and words it should spell your way, and replacements (for example "claude code" to
"Claude Code"). **History** keeps every recording; you can play it, copy it, or re-transcribe it with a
different model.

Once a week the app checks whether a newer Whisper model or whisper.cpp release exists and tells you on the
Models library page. It never installs anything by itself.

## Where things are

| Path | What |
|---|---|
| `~/Whisperer/recordings/` | every recording: `output.wav` + `meta.json` |
| `~/Whisperer/settings.json` | settings, modes, vocabulary |
| `~/Whisperer/models/` | downloaded voice models |

If you used Superwhisper, its recordings in `~/superwhisper` show up in History too (read only, never changed),
and its vocabulary and modes are imported once.

## Build it yourself

    brew install whisper-cpp        # 1.9.x
    ./build.sh                      # checks, release build, bundle, install to ~/Applications, launch

Needs the Xcode Command Line Tools. `swift build --product CoreChecks && .build/debug/CoreChecks` runs the
core checks.
