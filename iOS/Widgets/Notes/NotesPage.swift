import PhoneScreenKit
import SwiftUI

/// Apple Notes, via the Mac (iOS has no Notes API): recent notes, full text, quick new note, open on the Mac.
struct NotesPage: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var openID: String?
    @State private var composing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let id = openID, let note = model.notes?.first(where: { $0.id == id }) {
                NoteDetail(note: note, text: model.noteBodies[id],
                           back: { withAnimation(.snappy) { openID = nil } },
                           showOnMac: { model.showNoteOnMac(id) })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                list.transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 36)
        .sheet(isPresented: $composing) {
            NoteComposer { text in model.createNote(text) }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                WidgetHeader(title: "Заметки", symbol: "note.text")
                Button { composing = true } label: {
                    Image(systemName: "square.and.pencil").font(.title2).frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .pointerTarget { composing = true }
            }
            if let notes = model.notes {
                if notes.isEmpty {
                    Text("Заметок нет").foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(notes) { note in
                            NoteRow(note: note)
                                .contentShape(Rectangle())
                                .onTapGesture { open(note) }
                                .pointerTarget { open(note) }
                        }
                    }
                }
                .pointerScrollable()
            } else {
                Spacer()
                ProgressView().frame(maxWidth: .infinity)
                Text("Загружаю заметки с Mac… При первом запуске macOS спросит разрешение для «Заметок».")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
    }

    private func open(_ note: NoteSummary) {
        model.openNote(note.id)
        withAnimation(.snappy) { openID = note.id }
    }
}

private struct NoteRow: View {
    let note: NoteSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.title.isEmpty ? "Без названия" : note.title).font(.headline).lineLimit(1)
            HStack(spacing: 6) {
                Text(note.modified.formatted(.relative(presentation: .named)))
                    .foregroundStyle(.secondary)
                Text(note.snippet).foregroundStyle(.tertiary).lineLimit(1)
            }
            .font(.subheadline)
            if let folder = note.folder {
                Label(folder, systemImage: "folder").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
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
                Button(action: back) { Label("Заметки", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(.yellow)
                    .pointerTarget(action: back)
                Spacer()
                Button(action: showOnMac) { Label("Открыть на Mac", systemImage: "macbook") }
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
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .pointerScrollable()
            Text("Изменено \(note.modified.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct NoteComposer: View {
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($focused)
                .padding()
                .navigationTitle("Новая заметка")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Сохранить") { save(text); dismiss() }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .onAppear { focused = true }
        }
        .preferredColorScheme(.dark)
    }
}
