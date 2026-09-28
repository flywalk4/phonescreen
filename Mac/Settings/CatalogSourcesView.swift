import SwiftUI

/// The catalogs list at the top of the catalog section (Widgets and Themes): each catalog with what it offers
/// or why it failed, a remove button for the user's own, and a field to add another.
struct CatalogSourcesView: View {
    @ObservedObject var sources: CatalogSources
    @State private var adding = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sources.urls, id: \.self) { address in
                row(address)
                Divider().padding(.leading, 40)
            }
            HStack(spacing: 8) {
                Image(systemName: "plus.circle").foregroundStyle(.secondary).frame(width: 22)
                TextField("index.json address or a GitHub repository", text: $adding)
                    .textFieldStyle(.plain).font(.callout)
                    .onSubmit(add)
                Button("Add", action: add).disabled(adding.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 10).padding(.bottom, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.secondary.opacity(0.08)))
    }

    private func row(_ address: String) -> some View {
        let official = CatalogSources.isOfficial(address)
        return HStack(spacing: 8) {
            Image(systemName: official ? "checkmark.seal.fill" : "shippingbox")
                .foregroundStyle(official ? Color.accentColor : .secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(sources.name(of: address)).font(.callout.weight(.medium))
                    if official { Text("official").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(address).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            status(address)
            if !official {
                Button { sources.remove(address) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("Remove this catalog")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    @ViewBuilder
    private func status(_ address: String) -> some View {
        switch sources.results[address] {
        case .loaded(let catalog):
            Text("Widgets: \(catalog.widgets.count) · themes: \(catalog.themes?.count ?? 0)")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let reason):
            Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange).help(reason)
        case nil:
            ProgressView().controlSize(.small)
        }
    }

    private func add() {
        let text = adding
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        busy = true
        Task {
            error = await sources.add(text)
            if error == nil { adding = "" }
            busy = false
        }
    }
}
