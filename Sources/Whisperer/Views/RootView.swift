import SwiftUI
import WhispererCore

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.route }, set: { if let r = $0 { model.route = r } })) {
                Section { item(.home); item(.modes); item(.vocabulary) }
                Section { item(.configuration); item(.sound); item(.models) }
                Section { item(.history) }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) { statusFooter }
        } detail: {
            VStack(spacing: 0) {
                if let err = model.lastError { errorBanner(err) }
                detail
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 680, minHeight: 520)
    }

    func item(_ r: Route) -> some View {
        Label { Text(r.title) } icon: { IconTile(symbol: r.symbol, color: r.color) }.tag(r)
    }

    @ViewBuilder var detail: some View {
        switch model.route {
        case .home: HomeView()
        case .modes: ModesView()
        case .vocabulary: VocabularyView()
        case .configuration: ConfigurationView()
        case .sound: SoundView()
        case .models: ModelsView()
        case .history: HistoryView()
        }
    }

    var statusFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(model.hotkeyActive && model.micAuthorized ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(model.preparingModel ? "Preparing voice model…" :
                     model.hotkeyActive && model.micAuthorized ? "Ready · \(model.settings.activeMode.name)" : "Needs permissions")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("Tap \(model.settings.triggerKey.label)").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func errorBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.system(size: 12)).lineLimit(2)
            Spacer()
            Button { model.lastError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }
}
