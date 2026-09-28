import PhoneScreenKit
import SwiftUI

/// Apple Notes, via the Mac (iOS has no Notes API): recent notes, full text, quick new note, open on the Mac.
struct NotesPage: View {
    @EnvironmentObject private var model: PhoneModel
    @Environment(\.widgetSize) private var size
    @State private var openID: String?
    @State private var composing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if composing {
                // Inline, not a sheet: sheets live outside the rotated UI and out of the Mac pointer's reach.
                NoteComposer(save: { model.createNote($0) }, close: { withAnimation(.snappy) { composing = false } })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let id = openID, let note = model.notes?.first(where: { $0.id == id }) {
                NoteDetail(note: note, text: model.noteBodies[id],
                           back: { withAnimation(.snappy) { openID = nil } },
                           showOnMac: { model.showNoteOnMac(id) })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                list.transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .widgetPadding()
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                WidgetHeader(title: L("Notes"), symbol: "note.text")
                if size != .small {
                    Button { startComposing() } label: {
                        Glyph(systemName: "square.and.pencil").font(size == .full ? .title2 : .body)
                            .frame(width: size == .full ? 40 : 28, height: size == .full ? 40 : 28)
                    }
                    .buttonStyle(.plain)
                    .pointerTarget { startComposing() }
                }
            }
            if let notes = model.notes {
                if notes.isEmpty {
                    Text("No notes").foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(notes) { note in
                            NoteRow(note: note, compact: size != .full)
                                .contentShape(Rectangle())
                                .onTapGesture { open(note) }
                                .pointerTarget { open(note) }
                        }
                    }
                }
                .pointerScrollable()
            } else {
                Spacer()
                ThemedSpinner().frame(maxWidth: .infinity)
                Text("Loading notes from the Mac… The first time, macOS asks for permission to use Notes.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
    }

    private func startComposing() {
        withAnimation(.snappy) { composing = true }
    }

    private func open(_ note: NoteSummary) {
        model.openNote(note.id)
        withAnimation(.snappy) { openID = note.id }
    }
}

private struct NoteRow: View {
    let note: NoteSummary
    var compact = false

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 1) {
                Text(note.title.isEmpty ? L("Untitled") : note.title).font(.caption.weight(.semibold)).lineLimit(1)
                Text(note.modified.relativeText).font(.caption2).foregroundStyle(.secondary)
                if !note.snippet.isEmpty {
                    Text(note.snippet).font(.caption2).foregroundStyle(.tertiary).lineLimit(3).padding(.top, 2)
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
        } else {
            full
        }
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.title.isEmpty ? L("Untitled") : note.title).font(.headline).lineLimit(1)
            HStack(spacing: 6) {
                Text(note.modified.relativeText)
                    .foregroundStyle(.secondary)
                Text(note.snippet).foregroundStyle(.tertiary).lineLimit(1)
            }
            .font(.subheadline)
            if let folder = note.folder {
                Label { Text(folder) } icon: { Glyph("folder") }.font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
    }
}

private struct NoteDetail: View {
    let note: NoteSummary
    let text: String?
    let back: () -> Void
    let showOnMac: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: back) { Label { Text("Notes") } icon: { Glyph("chevron.left") } }
                    .buttonStyle(.plain).foregroundStyle(.yellow)
                    .pointerTarget(action: back)
                Spacer()
                Button(action: showOnMac) { Label { Text("Open on the Mac") } icon: { Glyph("macbook") } }
                    .buttonStyle(.bordered)
                    .pointerTarget(action: showOnMac)
            }
            ScrollView {
                if let text {
                    Text(text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ThemedSpinner().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .pointerScrollable()
            Text(L("Edited %@", note.modified.text(date: .abbreviated, time: .shortened)))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct NoteComposer: View {
    let save: (String) -> Void
    let close: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Cancel", action: close)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .pointerTarget(action: close)
                Spacer()
                Text("New note").font(.headline)
                Spacer()
                Button("Save", action: commit)
                    .buttonStyle(.plain).foregroundStyle(.yellow).fontWeight(.semibold)
                    .disabled(isEmpty)
                    .pointerTarget(action: commit)
            }
            TextEditor(text: $text)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(focused ? 0.1 : 0.06)))
                .pointerTarget(highlight: false) { focused = true }
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("The first line becomes the title. You can type on the Mac's keyboard.")
                            .foregroundStyle(.tertiary).padding(16).allowsHitTesting(false)
                    }
                }
        }
        .onAppear { focused = true }
    }

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func commit() {
        guard !isEmpty else { return }
        save(text)
        close()
    }
}
