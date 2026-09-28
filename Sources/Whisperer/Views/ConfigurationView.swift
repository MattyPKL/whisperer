import AppKit
import SwiftUI
import WhispererCore

struct ConfigurationView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Page(title: "Configuration") {
            Card(title: "Recording window") {
                HStack(spacing: 12) {
                    windowChoice("classic", "Classic", "waveform")
                    windowChoice("mini", "Mini", "waveform.circle")
                    windowChoice("none", "None", "eye.slash")
                }
                .padding(14)
            }

            Card(title: "Keyboard shortcuts") {
                Row(title: "Toggle recording", help: "Tap to start, tap again to stop. Hold to talk and let go to paste. Double tap to lock hands-free (a tap stops it). Pressed together with another key it is ignored, so shortcuts like Option+Arrow still work.") {
                    Picker("", selection: $model.settings.triggerKey) {
                        ForEach(TriggerKey.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 200)
                }
                if superwhisperRunning && model.settings.triggerKey != .rightOption && model.settings.triggerKey != .rightCommand
                    && model.settings.triggerKey != .fn {
                    Row(title: "Superwhisper is running and also listens to Left Option: both apps will record. Quit it, or keep Right Option.") { EmptyView() }
                        .foregroundStyle(.orange)
                }
                Row(title: "Hold for push to talk after", help: "Holding the key longer than this records until you let go.") {
                    Picker("", selection: $model.settings.holdThreshold) {
                        Text("0.25 s").tag(0.25); Text("0.35 s").tag(0.35); Text("0.5 s").tag(0.5); Text("0.8 s").tag(0.8)
                    }.labelsHidden().frame(width: 100)
                }
                Row(title: "Cancel recording") { KeyCap(text: "esc") }
                Row(title: "Change mode", divider: false) { HStack(spacing: 4) { KeyCap(text: "⌥"); KeyCap(text: "⇧"); KeyCap(text: "K") } }
            }

            Card(title: "Long recordings") {
                Row(title: "Longest recording", help: "At the limit the recording stops and transcribes; nothing is lost. The last minute counts down in the recording window. Every recording is saved to disk while you talk, so a crash never loses it.", divider: false) {
                    Picker("", selection: $model.settings.maxRecordingMinutes) {
                        Text("10 minutes").tag(10.0); Text("20 minutes").tag(20.0); Text("30 minutes").tag(30.0); Text("60 minutes").tag(60.0)
                    }.labelsHidden().frame(width: 130)
                }
            }

            Card(title: "Text input") {
                Row(title: "Paste result text", help: "Paste into the app you were in. Off = copy to clipboard only.") {
                    Toggle("", isOn: $model.settings.pasteResult).labelsHidden().toggleStyle(.switch)
                }
                Row(title: "Keep what I have copied", help: "Put your clipboard back after pasting.", divider: false) {
                    Toggle("", isOn: $model.settings.restoreClipboard).labelsHidden().toggleStyle(.switch)
                }
            }

            Card(title: "Voice model") {
                Row(title: "Keep model loaded for", help: "The model loads while you speak, so a short value costs nothing noticeable.") {
                    Picker("", selection: $model.settings.keepModelWarmMinutes) {
                        Text("1 minute").tag(1.0); Text("5 minutes").tag(5.0); Text("15 minutes").tag(15.0)
                        Text("1 hour").tag(60.0); Text("Always").tag(0.0)
                    }.labelsHidden().frame(width: 130)
                }
                Row(title: "Beam search", help: "Slightly slower. On your own recordings greedy decoding agreed with Superwhisper more often (4.3% vs 4.7%).") {
                    Toggle("", isOn: $model.settings.beamSearch).labelsHidden().toggleStyle(.switch)
                }
                Row(title: "Skip silence", help: "Whisper only hears the parts with speech (Silero voice detection, built in). Stops long talks repeating a sentence over and over, and is faster.", divider: false) {
                    Text(model.paths.vadModel != nil ? "On" : "Missing").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            Card(title: "Application") {
                Row(title: "Show in Dock") { Toggle("", isOn: $model.settings.showInDock).labelsHidden().toggleStyle(.switch) }
                Row(title: "Launch on login") {
                    Toggle("", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 })).labelsHidden().toggleStyle(.switch)
                }
                Row(title: "Show Superwhisper history", help: "Read your old Superwhisper recordings in place. They are never changed.") {
                    Toggle("", isOn: $model.settings.showSuperwhisperHistory).labelsHidden().toggleStyle(.switch)
                }
                Row(title: "App folder", divider: false) {
                    HStack {
                        Text(model.paths.root.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Button("Show") { NSWorkspace.shared.open(model.paths.root) }
                    }
                }
            }

            Card(title: "Permissions") {
                Row(title: "Microphone") { status(model.micAuthorized) { model.requestMicrophone() } }
                Row(title: "Accessibility (shortcut + paste)", divider: false) { status(model.axTrusted) { model.requestAccessibility() } }
            }
        }
    }

    var superwhisperRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.superduper.superwhisper").isEmpty
    }

    func windowChoice(_ key: String, _ title: String, _ symbol: String) -> some View {
        let on = model.settings.recordingWindow == key
        return Button { model.settings.recordingWindow = key } label: {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.85)).frame(height: 44)
                    .overlay(Image(systemName: symbol).foregroundStyle(.white))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(on ? Color.accentColor : Color.clear, lineWidth: 2))
                Text(title).font(.system(size: 11, weight: on ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    func status(_ ok: Bool, fix: @escaping () -> Void) -> some View {
        Group {
            if ok { Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12)) }
            else { Button("Grant", action: fix) }
        }
    }
}

struct SoundView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Page(title: "Sound") {
            Card(title: "Sound effects") {
                Row(title: "Sound effects") {
                    Picker("", selection: $model.settings.soundEffects) {
                        Text("Simple").tag("simple"); Text("Classic").tag("classic"); Text("Off").tag("off")
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
                Row(title: "Volume", divider: false) {
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $model.settings.soundVolume, in: 0...1) { editing in
                            if !editing { Sounds.play(.start, style: model.settings.soundEffects, volume: model.settings.soundVolume) }
                        }.frame(width: 200)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                    .disabled(model.settings.soundEffects == "off")
                }
            }
            Card(title: "Recording") {
                Row(title: "Quiet microphones are boosted", help: "Recordings with a low peak are raised before transcription (up to 8x).") { Text("Always on").font(.system(size: 12)).foregroundStyle(.secondary) }
                Row(title: "Silence check", help: "A recording with no speech is saved as \"No voice found\" and nothing is pasted.", divider: false) { Text("Always on").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }
    }
}
