import SwiftUI
import WhispererCore

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.toggleRecording) var toggleRecording
    @AppStorage("homeRange") var range = "all"

    var body: some View {
        Page(title: "Home") {
            if !model.micAuthorized || !model.axTrusted { permissions }

            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $range) {
                    Text("All time").tag("all"); Text("Last 7 days").tag("week"); Text("Today").tag("today")
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
                statsCard
                if !model.historyLoaded {
                    Text("Reading history…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            Card(title: "Get started") {
                action("record.circle", "Start recording", "Turn your voice to text with a single tap.",
                       trailing: AnyView(KeyCap(text: model.settings.triggerKey.label))) { toggleRecording() }
                action("keyboard", "Customize your shortcut", "Pick the key that starts and stops dictation.") { model.route = .configuration }
                action("sparkles", "Create a mode", "A model, language and app list for each kind of work.") { model.route = .modes }
                action("book.closed", "Add vocabulary", "Teach it names, brands and terms it gets wrong.", divider: false) { model.route = .vocabulary }
            }

            Card(title: "How it works") {
                Row(title: "Tap \(model.settings.triggerKey.label)", help: nil) { Text("start, tap again to finish").foregroundStyle(.secondary).font(.system(size: 12)) }
                Row(title: "Hold \(model.settings.triggerKey.label)", help: nil) { Text("push to talk, release to finish").foregroundStyle(.secondary).font(.system(size: 12)) }
                Row(title: "Esc", help: nil) { Text("cancel the recording").foregroundStyle(.secondary).font(.system(size: 12)) }
                Row(title: "⌥ ⇧ K", help: nil, divider: false) { Text("switch mode").foregroundStyle(.secondary).font(.system(size: 12)) }
            }
        }
    }

    var stats: UsageStats {
        let s = model.stats
        switch range { case "week": return s.week; case "today": return s.today; default: return s.all }
    }

    var statsCard: some View {
        HStack(spacing: 0) {
            stat("\(stats.averageWPM) WPM", "Average speed")
            stat(stats.words.formatted(), "Words")
            stat("\(stats.appsUsed)", "Apps used")
            stat(saved, "Saved")
        }
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    var saved: String {
        let h = stats.hoursSaved
        return h >= 1 ? "\(Int(h.rounded())) hours" : "\(Int((h * 60).rounded())) min"
    }

    func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 15, weight: .semibold))
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 16)
    }

    func action(_ symbol: String, _ title: String, _ sub: String, trailing: AnyView? = nil, divider: Bool = true,
                _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 13, weight: .medium))
                        Text(sub).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    trailing
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
                if divider { Divider().padding(.leading, 44).opacity(0.5) }
            }
        }
        .buttonStyle(.plain)
    }

    var permissions: some View {
        Card(title: "Permissions") {
            Row(title: "Microphone", help: "Needed to hear you.") {
                if model.micAuthorized { Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12)) }
                else { Button("Grant") { model.requestMicrophone() } }
            }
            Row(title: "Accessibility", help: "Needed to see the shortcut key and paste into other apps.", divider: false) {
                if model.axTrusted { Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12)) }
                else { Button("Open Settings") { model.requestAccessibility() } }
            }
        }
    }
}
