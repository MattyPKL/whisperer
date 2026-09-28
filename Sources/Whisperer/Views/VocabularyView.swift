import SwiftUI
import WhispererCore

struct VocabularyView: View {
    @EnvironmentObject var model: AppModel
    @State private var entry = ""
    @State private var replaceWith = ""
    @State private var replacing = false
    @FocusState private var focus: Field?
    enum Field { case entry, with }

    var body: some View {
        Page(title: "Vocabulary", subtitle: "Words are passed to the model as spelling hints. Replacements rewrite the text after transcription.") {
            HStack(spacing: 8) {
                TextField("New word or replacement", text: $entry)
                    .textFieldStyle(.plain).focused($focus, equals: .entry)
                    .onSubmit { replacing ? (focus = .with) : addWord() }
                if replacing {
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Replace with", text: $replaceWith).textFieldStyle(.plain).focused($focus, equals: .with)
                        .onSubmit(addReplacement)
                }
                Spacer()
                Button("Add word") { addWord() }.buttonStyle(.borderless).disabled(entry.isEmpty || replacing)
                Button(replacing ? "Done" : "Replace with…") {
                    if replacing { addReplacement() } else { replacing = true; focus = .with }
                }
                .buttonStyle(.borderless).keyboardShortcut(.return, modifiers: .command)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))

            if !model.settings.replacements.isEmpty {
                Card(title: "Replacements") {
                    ForEach(model.settings.replacements) { r in
                        Row(title: r.original, divider: r.id != model.settings.replacements.last?.id) {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
                                Text(r.with).font(.system(size: 13, weight: .medium))
                                Button { model.settings.replacements.removeAll { $0.id == r.id } } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Card(title: "Words") {
                if model.settings.vocabulary.isEmpty {
                    Row(title: "No words yet", divider: false) { EmptyView() }
                }
                ForEach(model.settings.vocabulary, id: \.self) { w in
                    Row(title: w, divider: w != model.settings.vocabulary.last) {
                        Button { model.settings.vocabulary.removeAll { $0 == w } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear { focus = .entry }
    }

    func addWord() {
        let w = entry.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        if !model.settings.vocabulary.contains(w) { model.settings.vocabulary.append(w) }
        entry = ""
    }

    func addReplacement() {
        let o = entry.trimmingCharacters(in: .whitespaces), w = replaceWith.trimmingCharacters(in: .whitespaces)
        guard !o.isEmpty else { replacing = false; return }
        model.settings.replacements.removeAll { $0.original.lowercased() == o.lowercased() }
        model.settings.replacements.append(Replacement(original: o, with: w))
        entry = ""; replaceWith = ""; replacing = false; focus = .entry
    }
}
