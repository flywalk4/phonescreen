import PhoneScreenKit
import SwiftUI

/// A remote for the Mac: system actions, Dock apps and the user's Shortcuts. The phone only sends ids;
/// the Mac runs nothing it didn't offer itself.
struct LauncherPage: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var flashed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WidgetHeader(title: "Команды", symbol: "square.grid.3x3.fill")
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Система", items: model.launcher.filter { $0.kind == .system })
                    section("Dock", items: model.launcher.filter { $0.kind == .app })
                    section("Команды", items: model.launcher.filter { $0.kind == .shortcut })
                }
            }
            .pointerScrollable()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 36)
    }

    @ViewBuilder
    private func section(_ title: String, items: [LauncherItem]) -> some View {
        if !items.isEmpty {
            Text(title).font(.headline).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)], spacing: 14) {
                ForEach(items) { item in
                    LauncherTile(item: item, flashed: flashed == item.id)
                        .contentShape(Rectangle())
                        .onTapGesture { run(item) }
                        .pointerTarget { run(item) }
                }
            }
        }
    }

    private func run(_ item: LauncherItem) {
        model.run(item)
        withAnimation(.snappy(duration: 0.15)) { flashed = item.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { withAnimation { if flashed == item.id { flashed = nil } } }
    }
}

private struct LauncherTile: View {
    let item: LauncherItem
    let flashed: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if let data = item.icon, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(item.kind == .shortcut ? Color.indigo.gradient : Color.gray.opacity(0.35).gradient)
                    Image(systemName: item.symbol ?? "questionmark").font(.title2).foregroundStyle(.white)
                }
            }
            .frame(width: 56, height: 56)
            .scaleEffect(flashed ? 0.88 : 1)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(flashed ? 0.8 : 0), lineWidth: 2))
            Text(item.title).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                .frame(height: 28, alignment: .top)
        }
    }
}
