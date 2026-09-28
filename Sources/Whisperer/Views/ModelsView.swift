import AppKit
import SwiftUI
import WhispererCore

struct ModelsView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var confirmDelete: VoiceModel?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search models", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, 26).padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    watchBanner
                    header
                    ForEach(models) { m in row(m); Divider().opacity(0.4) }
                    Text("Models run on this Mac with Metal. Files live in \(model.paths.models.path). Downloads come from huggingface.co/ggerganov/whisper.cpp.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 14)
                }
                .padding(.horizontal, 26).padding(.vertical, 12)
            }
        }
        .alert(item: $confirmDelete) { m in
            Alert(title: Text("Delete \(m.name)?"), message: Text("Frees \(m.sizeLabel). You can download it again any time."),
                  primaryButton: .destructive(Text("Delete")) { delete(m) }, secondaryButton: .cancel())
        }
    }

    var models: [VoiceModel] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? ModelCatalog.all : ModelCatalog.all.filter { $0.name.localizedCaseInsensitiveContains(q) }
        let starred = Set(model.settings.starredModelIDs)
        return list.sorted { a, b in
            let ra = (starred.contains(a.id) ? 0 : 1, model.installedModelIDs.contains(a.id) ? 0 : 1)
            let rb = (starred.contains(b.id) ? 0 : 1, model.installedModelIDs.contains(b.id) ? 0 : 1)
            return ra != rb ? ra < rb : false
        }
    }

    /// Result of the weekly check for newer voice models (ModelWatch).
    var watchBanner: some View {
        let w = model.modelWatch
        let found = (w?.newModels ?? []) + ((w?.engineUpdate ?? false) ? ["whisper.cpp \(w?.latestEngine ?? "")"] : [])
        let when = w.map { RelativeDateTimeFormatter().localizedString(for: $0.lastChecked, relativeTo: Date()) } ?? "not yet"
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: found.isEmpty ? "checkmark.seal.fill" : "sparkles")
                .foregroundStyle(found.isEmpty ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 3) {
                if found.isEmpty {
                    Text("You're on the best model: \(ModelCatalog.find(ModelCatalog.best)?.name ?? ModelCatalog.best)").font(.system(size: 12, weight: .semibold))
                } else {
                    Text("Newer than Whisperer knows: \(found.joined(separator: ", "))").font(.system(size: 12, weight: .semibold))
                }
                Text("Checked for newer models \(when); checks again every week." + (w?.error.map { " Last try failed: \($0)" } ?? ""))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.checkingModels ? "Checking…" : "Check now") { model.checkForBetterModels(force: true) }
                .disabled(model.checkingModels).controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .padding(.bottom, 10)
    }

    var header: some View {
        HStack {
            Text("Model name").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 28)
            Text("Speed").frame(width: 80, alignment: .leading)
            Text("Accuracy").frame(width: 80, alignment: .leading)
            Text("On this Mac").frame(width: 150, alignment: .trailing)
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 8)
    }

    func row(_ m: VoiceModel) -> some View {
        let installed = model.installedModelIDs.contains(m.id)
        let starred = model.settings.starredModelIDs.contains(m.id)
        let usedBy = model.settings.modes.filter { $0.voiceModelID == m.id }.map(\.name)
        return HStack {
            Button { toggleStar(m) } label: { Image(systemName: starred ? "star.fill" : "star") }
                .buttonStyle(.borderless).foregroundStyle(starred ? Color.yellow : Color.secondary)
                .help("Starred models are the fallback when a mode's model is missing")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(m.name).font(.system(size: 13, weight: installed ? .medium : .regular))
                        .foregroundStyle(installed ? Color.primary : Color.secondary)
                    if m.englishOnly { Pill(text: "EN") }
                    if m.id == ModelCatalog.best { Pill(text: "BEST") }
                }
                if !usedBy.isEmpty { Text("Used by " + usedBy.joined(separator: ", ")).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Meter(value: m.speed).frame(width: 80, alignment: .leading)
            Meter(value: m.accuracy).frame(width: 80, alignment: .leading)
            HStack(spacing: 8) {
                Text(m.sizeLabel).font(.system(size: 11, weight: .medium)).foregroundStyle(installed ? .primary : .secondary)
                if let p = model.downloads[m.id] {
                    ProgressView(value: p).frame(width: 50)
                    Button { ModelDownloader.shared.cancel(m.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
                } else if installed {
                    Button { confirmDelete = m } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        .foregroundStyle(.secondary).disabled(!usedBy.isEmpty).help(usedBy.isEmpty ? "Delete" : "In use by a mode")
                } else {
                    Button { ModelDownloader.shared.start(m) } label: { Image(systemName: "arrow.down.circle") }.buttonStyle(.borderless)
                        .help("Download")
                }
            }
            .frame(width: 150, alignment: .trailing)
        }
        .padding(.vertical, 9)
    }

    func toggleStar(_ m: VoiceModel) {
        if let i = model.settings.starredModelIDs.firstIndex(of: m.id) { model.settings.starredModelIDs.remove(at: i) }
        else { model.settings.starredModelIDs.append(m.id) }
    }

    func delete(_ m: VoiceModel) {
        let url = model.paths.modelFile(m.id)
        let engine = model.engine
        // Unload on the transcription queue so a running job finishes first and the UI never blocks.
        model.transcribeQueue.async {
            if engine.loadedPath == url.path { engine.unload() }
            DispatchQueue.main.async {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                model.refreshInstalledModels()
            }
        }
    }
}
