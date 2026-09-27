import PhoneScreenKit
import SwiftUI

/// All pages at once, as live miniature tiles (pinch in to get here). Tap / click / spread a tile to open it.
struct OverviewGrid: View {
    @EnvironmentObject private var model: PhoneModel
    let pages: [PageInfo]
    let current: Int
    let open: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let columns = landscape ? 4 : 3
            let spacing: CGFloat = 10
            let tileWidth = (geo.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            // Tiles keep the page's own proportions (the pager's size), so a tile is the page, only smaller.
            let pageSize = geo.size
            let scale = tileWidth / pageSize.width
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Все страницы").font(.title3.weight(.semibold))
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(tileWidth), spacing: spacing), count: columns),
                              spacing: spacing) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                            Tile(page: page, title: page.title(customNames: model.customNames),
                                 pageSize: pageSize, scale: scale, isCurrent: index == current)
                                .contentShape(Rectangle())
                                .onTapGesture { open(index) }
                                .pointerTarget { open(index) }
                        }
                    }
                }
            }
            .pointerScrollable()
        }
    }
}

private struct Tile: View {
    let page: PageInfo
    let title: String
    let pageSize: CGSize
    let scale: CGFloat
    let isCurrent: Bool

    var body: some View {
        VStack(spacing: 6) {
            PageView(page: page)
                .environment(\.pointerInteractive, false)
                .frame(width: pageSize.width, height: pageSize.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: pageSize.width * scale, height: pageSize.height * scale, alignment: .topLeading)
                .allowsHitTesting(false)
                .background(ThemeBackground())
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isCurrent ? Color.primary : Color.primary.opacity(0.15), lineWidth: isCurrent ? 2 : 1))
            Text(title).font(.caption2).foregroundStyle(isCurrent ? .primary : .secondary).lineLimit(1)
        }
    }
}
