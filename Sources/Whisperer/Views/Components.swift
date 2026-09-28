import SwiftUI
import WhispererCore

/// Grouped settings card, same shape as Superwhisper's rounded sections.
struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        }
    }
}

struct Row<Trailing: View>: View {
    var title: String
    var help: String? = nil
    var divider = true
    @ViewBuilder var trailing: Trailing
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13))
                if let help {
                    Image(systemName: "questionmark.circle").font(.system(size: 11)).foregroundStyle(.secondary).help(help)
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            if divider { Divider().padding(.leading, 14).opacity(0.5) }
        }
    }
}

struct Page<Content: View>: View {
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 22, weight: .semibold))
                    if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                content
            }
            .padding(.horizontal, 26).padding(.top, 18).padding(.bottom, 30)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct IconTile: View {
    var symbol: String
    var color: Color
    var size: CGFloat = 20
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.55, weight: .semibold)).foregroundStyle(.white))
    }
}

struct KeyCap: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.1)))
    }
}

struct Meter: View {
    var value: Int   // 1...5
    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { i in
                Capsule().fill(i <= value ? Color.primary.opacity(0.7) : Color.primary.opacity(0.12)).frame(width: 12, height: 3)
            }
        }
    }
}

struct Pill: View {
    var text: String
    var color: Color = .secondary
    var body: some View {
        Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

extension Route {
    var title: String {
        switch self {
        case .home: return "Home"
        case .modes: return "Modes"
        case .vocabulary: return "Vocabulary"
        case .configuration: return "Configuration"
        case .sound: return "Sound"
        case .models: return "Models library"
        case .history: return "History"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .modes: return "sparkles"
        case .vocabulary: return "book.closed.fill"
        case .configuration: return "gauge.with.dots.needle.33percent"
        case .sound: return "speaker.wave.2.fill"
        case .models: return "books.vertical.fill"
        case .history: return "clock.arrow.circlepath"
        }
    }
    var color: Color {
        switch self {
        case .home: return .orange
        case .modes: return .blue
        case .vocabulary: return .blue
        case .configuration, .sound, .models: return .gray
        case .history: return .purple
        }
    }
}
