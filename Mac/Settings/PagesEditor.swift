import PhoneScreenKit
import SwiftUI

/// Settings → Pages: which pages the phone shows, in what order, and which widgets sit on each.
struct PagesEditor: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: String?

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 230, idealWidth: 250, maxWidth: 320)
            detail.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selection == nil { selection = model.pages.first?.id } }
    }

    // MARK: - Page list

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                    HStack(spacing: 10) {
                        LayoutGlyph(layout: page.layout).frame(width: 22, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(page.title(customNames: model.widgets.names)).lineLimit(1)
                            Text(index < 9 ? "Страница \(index + 1) · ⌃⌥\(index + 1)" : "Страница \(index + 1)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(page.id)
                }
                .onMove { model.pages.move(fromOffsets: $0, toOffset: $1) }
            }
            Divider()
            HStack(spacing: 2) {
                Button { add() } label: { Image(systemName: "plus").frame(width: 22, height: 18) }
                    .help("Добавить страницу")
                Button { remove() } label: { Image(systemName: "minus").frame(width: 22, height: 18) }
                    .help("Удалить страницу")
                    .disabled(model.pages.count <= 1 || selection == nil)
                Spacer()
                Button("Сбросить") {
                    model.pages = PageInfo.defaults
                    selection = model.pages.first?.id
                }
                .help("Вернуть страницы по умолчанию")
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func add() {
        let used = Set(model.pages.flatMap(\.widgets))
        let kind = WidgetKind.allCases.first { !used.contains(.builtin($0)) } ?? .music
        let page = PageInfo(.music).with(id: UUID().uuidString, widgets: [.builtin(kind)])
        let at = selectedIndex.map { $0 + 1 } ?? model.pages.count
        model.pages.insert(page, at: at)
        selection = page.id
    }

    private func remove() {
        guard let index = selectedIndex, model.pages.count > 1 else { return }
        model.pages.remove(at: index)
        selection = model.pages[min(index, model.pages.count - 1)].id
    }

    private var selectedIndex: Int? { model.pages.firstIndex { $0.id == selection } }

    // MARK: - Page detail

    @ViewBuilder private var detail: some View {
        if let index = selectedIndex {
            let page = model.pages[index]
            VStack(alignment: .leading, spacing: 18) {
                Text(page.title(customNames: model.widgets.names)).font(.title2.weight(.semibold)).lineLimit(1)
                Picker("Раскладка", selection: Binding(get: { page.layout }, set: { model.pages[index].setLayout($0) })) {
                    ForEach(PageLayout.allCases, id: \.self) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                PagePreview(page: page, landscape: model.arrangement.orientation.isLandscape,
                            custom: model.widgets.installed.map { ($0.id, $0.manifest.name, $0.manifest.symbol) }) { slot, kind in
                    var widgets = model.pages[index].widgets
                    while widgets.count <= slot { widgets.append(kind) }
                    widgets[slot] = kind
                    model.pages[index].widgets = widgets
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("Нажмите на слот, чтобы выбрать виджет. Порядок страниц меняется перетаскиванием в списке слева. Изменения сразу появляются на iPhone.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        } else {
            Text("Выберите страницу").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The page drawn on a phone outline, in the orientation the phone lies in; every slot is a widget menu.
private struct PagePreview: View {
    let page: PageInfo
    let landscape: Bool
    /// Installed JavaScript widgets: id, name, symbol.
    let custom: [(String, String, String?)]
    let choose: (Int, WidgetRef) -> Void

    var body: some View {
        GeometryReader { geo in
            let aspect: CGFloat = landscape ? 852 / 393 : 393 / 852
            let size = fit(aspect: aspect, in: geo.size)
            ZStack {
                RoundedRectangle(cornerRadius: size.width * (landscape ? 0.07 : 0.14), style: .continuous)
                    .fill(Color(white: 0.08))
                    .overlay(RoundedRectangle(cornerRadius: size.width * (landscape ? 0.07 : 0.14), style: .continuous)
                        .stroke(Color(white: 0.4), lineWidth: 2))
                slots
                    .padding(landscape ? size.height * 0.08 : size.width * 0.07)
            }
            .frame(width: size.width, height: size.height)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder private var slots: some View {
        switch page.layout {
        case .single:
            slot(0)
        case .split:
            let layout = landscape ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 8))
            layout { slot(0); slot(1) }
        case .trio:
            if landscape {
                HStack(spacing: 8) { slot(0); VStack(spacing: 8) { slot(1); slot(2) } }
            } else {
                VStack(spacing: 8) { slot(0); HStack(spacing: 8) { slot(1); slot(2) } }
            }
        case .grid:
            VStack(spacing: 8) {
                HStack(spacing: 8) { slot(0); slot(1) }
                HStack(spacing: 8) { slot(2); slot(3) }
            }
        }
    }

    private func slot(_ i: Int) -> some View {
        let ref = page.widgets.indices.contains(i) ? page.widgets[i] : nil
        let customInfo = ref?.customID.flatMap { id in custom.first { $0.0 == id } }
        let symbol = ref?.builtin?.symbol ?? customInfo?.2 ?? (ref == nil ? "plus" : "puzzlepiece.extension")
        let title = ref?.builtin?.title ?? customInfo?.1 ?? ref?.title() ?? "Пусто"
        return Menu {
            ForEach(WidgetKind.allCases, id: \.self) { option in
                Button { choose(i, .builtin(option)) } label: { Label(option.title, systemImage: option.symbol) }
            }
            if !custom.isEmpty {
                Divider()
                ForEach(custom, id: \.0) { id, name, symbol in
                    Button { choose(i, .custom(id)) } label: { Label(name, systemImage: symbol ?? "puzzlepiece.extension") }
                }
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.caption).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.35)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private func fit(aspect: CGFloat, in size: CGSize) -> CGSize {
        let w = min(size.width, size.height * aspect)
        return CGSize(width: w, height: w / aspect)
    }
}

/// Tiny drawing of a layout for the page list.
struct LayoutGlyph: View {
    let layout: PageLayout

    var body: some View {
        let cell = RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.7))
        ZStack {
            RoundedRectangle(cornerRadius: 4).stroke(Color.secondary, lineWidth: 1.2)
            Group {
                switch layout {
                case .single: cell
                case .split: VStack(spacing: 2) { cell; cell }
                case .trio: VStack(spacing: 2) { cell; HStack(spacing: 2) { cell; cell } }
                case .grid: VStack(spacing: 2) { HStack(spacing: 2) { cell; cell }; HStack(spacing: 2) { cell; cell } }
                }
            }
            .padding(3)
        }
    }
}

/// Settings window: pages and the phone's physical placement.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            PagesEditor().tabItem { Label("Страницы", systemImage: "rectangle.grid.2x2") }.tag(AppModel.SettingsTab.pages)
            WidgetsSettings(widgets: model.widgets).tabItem { Label("Виджеты", systemImage: "puzzlepiece.extension") }.tag(AppModel.SettingsTab.widgets)
            ArrangementView().tabItem { Label("Расположение", systemImage: "iphone.gen3") }.tag(AppModel.SettingsTab.arrangement)
        }
        .frame(minWidth: 680, minHeight: 520)
    }
}
