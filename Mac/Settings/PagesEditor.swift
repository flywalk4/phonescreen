import PhoneScreenKit
import SwiftUI

/// Settings → Pages: which pages the phone shows, in what order, and which widgets sit on each.
struct PagesEditor: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Страницы").font(.system(size: 26, weight: .bold))
                Text("Что показывает iPhone: страницы листаются свайпом, трекпадом или ⌃⌥← →.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)
            HSplitView {
                sidebar.frame(minWidth: 230, idealWidth: 250, maxWidth: 320)
                detail.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
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
                // Layout thumbnails, wrapping when the pane is narrow (a segmented control of six didn't fit).
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(PageLayout.allCases, id: \.self) { layout in
                        let selected = layout == page.layout
                        Button { model.pages[index].setLayout(layout) } label: {
                            VStack(spacing: 6) {
                                LayoutGlyph(layout: layout).frame(width: 24, height: 34)
                                Text(layout.title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(selected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.08)))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(layout.title)
                    }
                }
                Toggle("Без карточек — виджеты прямо на фоне", isOn: Binding(
                    get: { page.bare == true },
                    set: { model.pages[index].bare = $0 ? true : nil }))
                    .toggleStyle(.switch).controlSize(.small)
                PagePreview(page: page, landscape: model.arrangement.orientation.isLandscape,
                            custom: model.widgets.installed.map { ($0.id, model.widgets.localized($0).name, $0.manifest.symbol) }) { slot, kind in
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
        // The same arrangement the phone uses: lying sideways, cards line up in a row.
        case .trio:
            if landscape {
                GeometryReader { geo in
                    HStack(spacing: 8) {
                        slot(0)
                        slot(1).frame(width: (geo.size.width - 16) / 4)
                        slot(2).frame(width: (geo.size.width - 16) / 4)
                    }
                }
            } else {
                VStack(spacing: 8) { slot(0); HStack(spacing: 8) { slot(1); slot(2) } }
            }
        case .grid:
            if landscape {
                HStack(spacing: 8) { slot(0); slot(1); slot(2); slot(3) }
            } else {
                VStack(spacing: 8) {
                    HStack(spacing: 8) { slot(0); slot(1) }
                    HStack(spacing: 8) { slot(2); slot(3) }
                }
            }
        case .stack:
            let layout = landscape ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 8))
            layout { slot(0); slot(1); slot(2) }
        case .six:
            let (rows, columns) = landscape ? (2, 3) : (3, 2)
            VStack(spacing: 8) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: 8) { ForEach(0..<columns, id: \.self) { c in slot(r * columns + c) } }
                }
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
            // A bare page shows its slots as outlines: the widgets sit on the background, with no card.
            .background {
                if page.bare == true {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                } else {
                    RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.35))
                }
            }
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
                case .stack: VStack(spacing: 2) { cell; cell; cell }
                case .six: VStack(spacing: 2) { ForEach(0..<3, id: \.self) { _ in HStack(spacing: 2) { cell; cell } } }
                }
            }
            .padding(3)
        }
    }
}

/// Settings window: a sidebar of sections (like System Settings) and the section on the right.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    private struct Section: Identifiable {
        let id: AppModel.SettingsTab
        let title: String
        let symbol: String
        let tint: Color
    }

    private let sections: [Section] = [
        Section(id: .pages, title: "Страницы", symbol: "rectangle.grid.2x2.fill", tint: .blue),
        Section(id: .widgets, title: "Виджеты", symbol: "puzzlepiece.extension.fill", tint: .purple),
        Section(id: .themes, title: "Темы", symbol: "paintpalette.fill", tint: .pink),
        Section(id: .arrangement, title: "Расположение", symbol: "iphone.gen3", tint: .orange),
    ]

    var body: some View {
        HStack(spacing: 0) {
            // Our own sidebar column (solid, gallery-app style) rather than NavigationSplitView's translucent one.
            VStack(alignment: .leading, spacing: 4) {
                SidebarHeader().padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 18)
                ForEach(sections) { section in
                    SidebarRow(title: section.title, symbol: section.symbol, tint: section.tint,
                               selected: model.settingsTab == section.id) {
                        withAnimation(.snappy(duration: 0.2)) { model.settingsTab = section.id }
                    }
                }
                Spacer()
                LanguagePicker().padding(.horizontal, 8).padding(.bottom, 14)
            }
            .padding(.horizontal, 10)
            .frame(width: 230)
            .frame(maxHeight: .infinity)
            .background(Color.black.opacity(0.22))
            Divider()
            Group {
                switch model.settingsTab {
                case .pages: PagesEditor()
                case .widgets: WidgetsSettings(widgets: model.widgets)
                case .themes: ThemesSettings(themes: model.themes)
                case .arrangement: ArrangementView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 900, minHeight: 600)
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.gradient))
                Text(title).font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.white.opacity(0.12) : hovering ? Color.white.opacity(0.05) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The product's language at the foot of the sidebar: widgets and the phone switch at once, the Mac after relaunch.
private struct LanguagePicker: View {
    @EnvironmentObject private var model: AppModel
    @State private var launchedWith = AppLanguage.choice

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Язык", systemImage: "globe").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { model.languageChoice }, set: { model.setLanguage($0) })) {
                Text("Как в системе").tag("system")
                ForEach(AppLanguage.supported, id: \.code) { Text($0.name).tag($0.code) }
            }
            .labelsHidden()
            if model.languageChoice != launchedWith {
                Button("Перезапустить") { relaunch() }.controlSize(.small)
                Text("Окна Mac сменят язык после перезапуска").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// App icon, name and whether the phone is connected — on top of the sidebar.
private struct SidebarHeader: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)))
            VStack(alignment: .leading, spacing: 2) {
                Text("PhoneScreen").font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(model.status.active == nil ? Color.orange : Color.green).frame(width: 6, height: 6)
                    Text(model.status.active.map { "iPhone · \($0.label)" } ?? "iPhone не подключён").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}
