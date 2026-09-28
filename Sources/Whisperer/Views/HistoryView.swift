import AppKit
import AVFoundation
import SwiftUI
import WhispererCore

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var selected: Recording?
    @State private var limit = 200

    var body: some View {
        let filtered = self.filtered   // one search per render, not one per use
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search history", text: $query).textFieldStyle(.plain)
                    Text("\(filtered.count.formatted())").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                Divider()
                if !model.historyLoaded {
                    ProgressView("Reading history…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filtered.isEmpty {
                    Text(query.isEmpty ? "Nothing recorded yet. Tap \(model.settings.triggerKey.label) anywhere to start." : "No matches")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list(filtered)
                }
            }
            .frame(minWidth: 300)
            if let rec = selected {
                RecordingDetail(rec: rec) { selected = nil }
                    .id(rec.id)
                    .frame(minWidth: 280, idealWidth: 320)
            }
        }
        .onChange(of: query) { _, _ in limit = 200 }
    }

    var filtered: [Recording] { HistoryStore.search(model.history, query) }

    func list(_ filtered: [Recording]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                let shown = Array(filtered.prefix(limit))
                ForEach(groups(shown), id: \.0) { day, recs in
                    Section {
                        ForEach(recs) { r in row(r) }
                    } header: {
                        Text(day).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.bar)
                    }
                }
                if filtered.count > limit {
                    Button("Show more (\((filtered.count - limit).formatted()) older)") { limit += 400 }
                        .buttonStyle(.borderless).padding(.vertical, 10).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    func groups(_ list: [Recording]) -> [(String, [Recording])] {
        let cal = Calendar.current
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM yyyy"
        var out: [(String, [Recording])] = []
        for r in list {
            let label = cal.isDateInToday(r.date) ? "Today" : cal.isDateInYesterday(r.date) ? "Yesterday" : f.string(from: r.date)
            if out.last?.0 == label { out[out.count - 1].1.append(r) } else { out.append((label, [r])) }
        }
        return out
    }

    func row(_ r: Recording) -> some View {
        let isSel = selected?.id == r.id
        return VStack(alignment: .leading, spacing: 5) {
            if r.noVoice {
                Text("No voice found in recording").italic().foregroundStyle(.secondary)
            } else {
                Text(r.result).lineLimit(3)
            }
            HStack(spacing: 6) {
                Text(r.date.formatted(date: .omitted, time: .shortened))
                if !r.appName.isEmpty { Text("· \(r.appName)") }
                if r.source == .superwhisper { Pill(text: "SUPERWHISPER") }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isSel ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
        .onTapGesture { selected = r }
        .contextMenu {
            Button("Copy text") { copy(r.result) }.disabled(r.result.isEmpty)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([r.folder]) }
        }
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct RecordingDetail: View {
    @EnvironmentObject var model: AppModel
    let rec: Recording
    var close: () -> Void
    @State private var player: AVAudioPlayer?
    @State private var playing = false
    @State private var retranscribeModel = "medium"
    @State private var working = false
    @State private var alternate: String?
    @State private var copied = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(rec.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                Text(rec.noVoice ? "No voice found in recording" : rec.result)
                    .font(.system(size: 14)).textSelection(.enabled)
                    .foregroundStyle(rec.noVoice ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Button { copy(rec.result) } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .disabled(rec.result.isEmpty)
                    Button { togglePlay() } label: { Label(playing ? "Stop" : "Play", systemImage: playing ? "stop.fill" : "play.fill") }
                        .disabled(!FileManager.default.fileExists(atPath: rec.audioURL.path))
                }

                Card {
                    info("Duration", String(format: "%.1f s", Double(rec.durationMs) / 1000))
                    info("Words", "\(rec.words)")
                    info("Model", rec.modelName.isEmpty ? "unknown" : rec.modelName)
                    if !rec.modeName.isEmpty { info("Mode", rec.modeName) }
                    if !rec.appName.isEmpty { info("App", rec.appName) }
                    if rec.processingMs > 0 { info("Processing", "\(rec.processingMs) ms") }
                    info("Source", rec.source == .superwhisper ? "Superwhisper (read only)" : "Whisperer", last: true)
                }

                Card(title: "Transcribe again") {
                    Row(title: "Model") {
                        Picker("", selection: $retranscribeModel) {
                            ForEach(ModelCatalog.all.filter { model.installedModelIDs.contains($0.id) }) { Text($0.name).tag($0.id) }
                        }.labelsHidden().frame(width: 190)
                    }
                    Row(title: rec.isEditable ? "Replaces the saved text" : "Shown here only, Superwhisper's file is untouched", divider: false) {
                        if working { ProgressView().controlSize(.small) }
                        else { Button("Run") { retranscribe() }.disabled(!FileManager.default.fileExists(atPath: rec.audioURL.path)) }
                    }
                }
                if let alternate {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(alternate).textSelection(.enabled).font(.system(size: 13))
                        Button("Copy") { copy(alternate) }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.1)))
                }

                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([rec.folder]) }
                    Spacer()
                    if rec.isEditable {
                        Button("Delete", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .padding(18)
        }
        .onAppear {
            retranscribeModel = model.settings.activeMode.voiceModelID
            if !model.installedModelIDs.contains(retranscribeModel), let first = model.installedModelIDs.sorted().first { retranscribeModel = first }
        }
        .onDisappear { player?.stop() }
        .confirmationDialog("Move this recording to the Bin?", isPresented: $confirmDelete) {
            Button("Move to Bin", role: .destructive) { delete() }
        }
    }

    func info(_ k: String, _ v: String, last: Bool = false) -> some View {
        Row(title: k, divider: !last) { Text(v).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    func togglePlay() {
        if playing { player?.stop(); playing = false; return }
        guard let p = try? AVAudioPlayer(contentsOf: rec.audioURL) else { return }
        player = p
        p.play()
        playing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + p.duration + 0.1) { if player === p { playing = false } }
    }

    func retranscribe() {
        working = true
        let path = model.paths.modelFile(retranscribeModel).path
        let engine = model.engine
        let settings = model.settings
        let rec = self.rec
        let name = ModelCatalog.find(retranscribeModel)?.name ?? retranscribeModel
        let modelID = retranscribeModel
        let mode = settings.activeMode
        var opts = TranscribeOptions()
        opts.language = mode.language
        opts.translate = mode.translateToEnglish
        opts.prompt = TextProcessing.prompt(vocabulary: settings.vocabulary)
        opts.beamSearch = settings.beamSearch
        opts.vadModelPath = model.paths.vadModel?.path   // long recordings: same anti-loop as dictation
        model.transcribeQueue.async {
            var text = "", raw = "", ms = 0, err: String?
            do {
                let audio = try WAV.read(rec.audioURL)
                let t = try engine.transcribe(AudioLevel.normalize(audio), modelPath: path, options: opts)
                raw = t.text; ms = t.processingMs
                text = TextProcessing.finalize(t.text, replacements: settings.replacements, autocapitalize: mode.autocapitalize)
                if rec.isEditable {
                    try HistoryStore.update(rec, fields: ["result": text, "rawResult": raw, "modelName": name,
                                                          "modelKey": modelID, "processingTime": ms, "noVoice": text.isEmpty,
                                                          "languageDetected": t.language, "error": ""])
                }
            } catch { err = error.localizedDescription }
            DispatchQueue.main.async {
                working = false
                model.engineUsed()   // restarts the unload timer, whichever model is now loaded
                if let err { model.lastError = err; return }
                if rec.isEditable, let fresh = HistoryStore.parse(folder: rec.folder, source: .whisperer),
                   let i = model.history.firstIndex(where: { $0.id == rec.id }) {
                    model.history[i] = fresh
                }
                alternate = "\(name), \(ms) ms:\n\(text)"
            }
        }
    }

    func delete() {
        player?.stop()
        try? FileManager.default.trashItem(at: rec.folder, resultingItemURL: nil)
        model.history.removeAll { $0.id == rec.id }
        close()
    }
}
