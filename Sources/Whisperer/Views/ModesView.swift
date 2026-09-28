import AppKit
import SwiftUI
import WhispererCore

struct ModesView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Mode?

    var body: some View {
        Page(title: "Modes", subtitle: "The active mode (green dot) is used unless the app you are in is linked to another mode.") {
            HStack {
                Spacer()
                Button { editing = Mode(key: "", name: "New mode", voiceModelID: model.settings.activeMode.voiceModelID) } label: {
                    Label("Create mode", systemImage: "plus")
                }
            }
            VStack(spacing: 8) {
                ForEach(model.settings.modes) { m in modeRow(m) }
            }
        }
        .sheet(item: $editing) { m in ModeEditor(mode: m) { saved in save(saved, original: m) } }
    }

    func modeRow(_ m: Mode) -> some View {
        let active = m.key == model.settings.activeModeKey
        let installed = model.installedModelIDs.contains(m.voiceModelID)
        return HStack(spacing: 10) {
            Image(systemName: "mic.fill").foregroundStyle(.secondary)
            Text(m.name).font(.system(size: 13, weight: .medium))
            if active { Circle().fill(Color.green).frame(width: 7, height: 7) }
            if !m.activationApps.isEmpty { Pill(text: "\(m.activationApps.count) app\(m.activationApps.count == 1 ? "" : "s")") }
            Spacer()
            Text(ModelCatalog.find(m.voiceModelID)?.name ?? m.voiceModelID).font(.system(size: 11))
                .foregroundStyle(installed ? Color.secondary : Color.orange)
            if !installed { Pill(text: "NOT DOWNLOADED", color: .orange) }
            Menu {
                Button("Make active") { model.setActiveMode(m.key) }.disabled(active)
                Button("Edit…") { editing = m }
                Divider()
                Button("Delete", role: .destructive) { delete(m) }.disabled(model.settings.modes.count <= 1)
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(active ? 0.07 : 0.045)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editing = m }
        .onTapGesture { model.setActiveMode(m.key) }
    }

    func save(_ m: Mode, original: Mode) {
        var m = m
        if m.key.isEmpty {
            var key = SuperwhisperImport.slug(m.name), n = 2
            while model.settings.modes.contains(where: { $0.key == key }) { key = SuperwhisperImport.slug(m.name) + "-\(n)"; n += 1 }
            m.key = key
            model.settings.modes.append(m)
        } else if let i = model.settings.modes.firstIndex(where: { $0.key == original.key }) {
            model.settings.modes[i] = m
        }
    }

    func delete(_ m: Mode) {
        model.settings.modes.removeAll { $0.key == m.key }
        if model.settings.activeModeKey == m.key, let first = model.settings.modes.first { model.settings.activeModeKey = first.key }
    }
}

struct ModeEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var mode: Mode
    var onSave: (Mode) -> Void

    static let languages: [(String, String)] = [("en,pl", "English or Polish (detects which)"), ("en", "English"),
        ("pl", "Polish"), ("auto", "Detect any language"),
        ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch")]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(mode.key.isEmpty ? "Create mode" : "Edit mode").font(.system(size: 17, weight: .semibold))
            Card {
                Row(title: "Name") { TextField("", text: $mode.name).textFieldStyle(.roundedBorder).frame(width: 220) }
                Row(title: "Voice model") {
                    Picker("", selection: $mode.voiceModelID) {
                        ForEach(ModelCatalog.all) { m in
                            Text(m.name + (model.installedModelIDs.contains(m.id) ? "" : " (not downloaded)")).tag(m.id)
                        }
                    }.labelsHidden().frame(width: 260)
                }
                Row(title: "Language") {
                    Picker("", selection: $mode.language) {
                        ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                    }.labelsHidden().frame(width: 200)
                }
                Row(title: "Translate to English", help: "Speak any language, get English text.") { Toggle("", isOn: $mode.translateToEnglish).labelsHidden().toggleStyle(.switch) }
                Row(title: "Capitalise first letter", divider: false) { Toggle("", isOn: $mode.autocapitalize).labelsHidden().toggleStyle(.switch) }
            }
            Card(title: "Auto-switch in these apps") {
                ForEach(mode.activationApps, id: \.self) { id in
                    Row(title: appName(id)) {
                        Button { mode.activationApps.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                Row(title: "Add a running app", divider: false) {
                    Menu("Choose…") {
                        ForEach(runningApps, id: \.0) { app in
                            Button(app.1) { if !mode.activationApps.contains(app.0) { mode.activationApps.append(app.0) } }
                        }
                    }.fixedSize()
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(mode); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(mode.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    var runningApps: [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { a in a.bundleIdentifier.map { ($0, a.localizedName ?? $0) } }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    func appName(_ id: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path) } ?? id
    }
}
