// SPDX-License-Identifier: Apache-2.0
#if os(iOS)
import Foundation
import SubCardCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let subcard = UTType(exportedAs: "org.subcard.document", conformingTo: .database)
}

private struct DocumentFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    static func core() -> Self { Self(message: String(cString: subcard_last_error())) }
}

private final class PhoneCoreDocument {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { subcard_document_close(pointer) }
}

private final class DocumentSnapshot {
    let pointer: OpaquePointer
    let data: Data
    init(document: OpaquePointer) throws {
        guard let pointer = subcard_document_snapshot(document) else { throw DocumentFailure.core() }
        self.pointer = pointer
        self.data = Data(bytes: subcard_snapshot_bytes(pointer)!, count: subcard_snapshot_size(pointer))
    }
    deinit { subcard_snapshot_close(pointer) }
}

struct SQLiteFile: FileDocument {
    static var readableContentTypes: [UTType] { [.subcard] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@MainActor
final class PhoneDocumentStore: ObservableObject {
    enum Intent { case new, open, openURL(URL) }
    @Published private(set) var text: String
    @Published private(set) var changed = false
    @Published private(set) var usingDocument = false
    @Published private(set) var schemaLocked = false
    @Published private(set) var url: URL?
    @Published var error: String?
    @Published var importing = false
    @Published var exporting = false
    @Published var confirming = false
    @Published private(set) var exportFile: SQLiteFile?
    private var owner: PhoneCoreDocument
    private var snapshot: DocumentSnapshot?
    private var pending: Intent?
    private var afterSave: Intent?
    var name: String { url?.lastPathComponent ?? "Untitled" }
    var busy: Bool { importing || exporting || confirming }

    init() {
        guard let pointer = subcard_document_new() else {
            fatalError(String(cString: subcard_last_error()))
        }
        owner = PhoneCoreDocument(pointer)
        text = String(cString: subcard_document_text(pointer))
    }

    var document: OpaquePointer { owner.pointer }
    var finishEREditing: (Bool) -> Void = { _ in }
    private var pendingEREdits = false
    func erDraftChanged(_ pending: Bool) { pendingEREdits = pending; refresh() }

    func refresh() {
        text = String(cString: subcard_document_text(owner.pointer))
        changed = subcard_document_is_changed(owner.pointer) != 0 || pendingEREdits
        usingDocument = subcard_document_mode(owner.pointer) == SUBCARD_MODE_USE
        schemaLocked = subcard_document_schema_is_locked(owner.pointer) != 0
    }

    func setText(_ text: String) {
        guard !text.utf8.contains(0) else { return }
        if subcard_document_set_text(owner.pointer, text) == 0 { error = DocumentFailure.core().message }
        refresh()
    }

    func toggleMode() {
        finishEREditing(false)
        if subcard_document_set_mode(owner.pointer, usingDocument ? SUBCARD_MODE_EDIT : SUBCARD_MODE_USE) == 0 {
            error = DocumentFailure.core().message
        }
        refresh()
    }

    func request(_ intent: Intent) {
        guard !busy else { return }
        finishEREditing(false)
        if changed { pending = intent; confirming = true }
        else { perform(intent) }
    }

    private func perform(_ intent: Intent) {
        switch intent {
        case .new:
            guard let pointer = subcard_document_new() else { error = DocumentFailure.core().message; return }
            finishEREditing(true)
            owner = PhoneCoreDocument(pointer)
            url = nil
            refresh()
        case .open: importing = true
        case .openURL(let url): open(url)
        }
    }

    func discardAndContinue() {
        let intent = pending
        pending = nil
        confirming = false
        if let intent { DispatchQueue.main.async { self.perform(intent) } }
    }

    func cancelReplacement() { pending = nil; confirming = false }

    func saveAndContinue() {
        let intent = pending
        pending = nil
        confirming = false
        DispatchQueue.main.async { self.save(after: intent) }
    }

    func finishImport(_ result: Result<[URL], Error>) {
        importing = false
        switch result {
        case .success(let urls): if let url = urls.first { open(url) }
        case .failure(let failure): report(failure)
        }
    }

    private func open(_ selected: URL) {
        let accessing = selected.startAccessingSecurityScopedResource()
        defer { if accessing { selected.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var failure: Error?
        var next: PhoneCoreDocument?
        NSFileCoordinator().coordinate(readingItemAt: selected, options: [], error: &coordinationError) { location in
            if let pointer = subcard_document_open(location.path) { next = PhoneCoreDocument(pointer) }
            else { failure = DocumentFailure.core() }
        }
        if let failure = coordinationError ?? failure { report(failure); return }
        guard let next else { error = "The document could not be opened."; return }
        finishEREditing(true)
        owner = next
        url = selected // Preserve the file provider's security-scoped URL.
        refresh()
    }

    func save(as saveAs: Bool = false, after: Intent? = nil) {
        finishEREditing(false)
        guard !busy, changed else { return }
        do {
            let snapshot = try DocumentSnapshot(document: owner.pointer)
            if !saveAs, let url {
                try write(snapshot, to: url)
                continueAfterSave(after)
            } else {
                self.snapshot = snapshot
                exportFile = SQLiteFile(data: snapshot.data)
                afterSave = after
                exporting = true
            }
        } catch { report(error) }
    }

    private func write(_ snapshot: DocumentSnapshot, to destination: URL) throws {
        let accessing = destination.startAccessingSecurityScopedResource()
        defer { if accessing { destination.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var writeError: Error?
        var written = false
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { location in
            do { try snapshot.data.write(to: location, options: .atomic); written = true }
            catch { writeError = error }
        }
        if let failure = coordinationError ?? writeError { throw failure }
        guard written else { throw DocumentFailure(message: "The file provider did not complete the save.") }
        try accept(snapshot, at: destination)
    }

    private func accept(_ snapshot: DocumentSnapshot, at destination: URL) throws {
        guard subcard_document_accept_snapshot(owner.pointer, snapshot.pointer, destination.path) != 0 else {
            throw DocumentFailure.core()
        }
        url = destination
        refresh()
    }

    func finishExport(_ result: Result<URL, Error>) {
        let savedSnapshot = snapshot
        let next = afterSave
        cancelExport()
        switch result {
        case .success(let destination):
            do {
                guard let savedSnapshot else { throw DocumentFailure(message: "The saved snapshot is missing.") }
                try accept(savedSnapshot, at: destination)
                continueAfterSave(next)
            } catch { report(error) }
        case .failure(let failure): report(failure)
        }
    }

    func exportDismissed() {
        guard let dismissedSnapshot = snapshot else { return }
        // iOS 16 sets isPresented to false before calling onCompletion, and
        // supplies no cancellation callback. Let completion consume the snapshot
        // first; otherwise release a canceled export on the next main-loop turn.
        DispatchQueue.main.async {
            guard !self.exporting, self.snapshot === dismissedSnapshot else { return }
            self.cancelExport()
        }
    }

    private func cancelExport() {
        exporting = false
        snapshot = nil
        exportFile = nil
        afterSave = nil
    }

    private func continueAfterSave(_ intent: Intent?) {
        if let intent { DispatchQueue.main.async { self.perform(intent) } }
    }

    private func report(_ failure: Error) {
        if (failure as NSError).code != CocoaError.userCancelled.rawValue {
            error = failure.localizedDescription
        }
    }
}

struct PhoneDocumentView: View {
    @StateObject private var store = PhoneDocumentStore()
    @FocusState private var editing: Bool
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DocumentModeControls(usingDocument: store.usingDocument, schemaLocked: store.schemaLocked, toggle: store.toggleMode).padding(8)
                ERCanvasEditor(document: store.document, changed: store.refresh,
                    registerEditor: { store.finishEREditing = $0 }, draftChanged: { [weak store] in store?.erDraftChanged($0) }).disabled(store.busy)
            }
            .navigationTitle("SubCard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("New", systemImage: "doc.badge.plus") { editing = false; store.request(.new) }
                        Button("Open…", systemImage: "folder") { editing = false; store.request(.open) }
                        Divider()
                        Button("Save", systemImage: "square.and.arrow.down") { editing = false; store.save() }
                            .disabled(!store.changed)
                        Button("Save As…", systemImage: "doc.on.doc") { editing = false; store.save(as: true) }
                            .disabled(!store.changed)
                    } label: { Label("File", systemImage: "doc") }
                    .disabled(store.busy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { editing = false; store.save() }
                        .disabled(!store.changed || store.busy)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { store.finishEREditing(false); UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
        }
        .fileImporter(isPresented: $store.importing, allowedContentTypes: [.subcard, .database], allowsMultipleSelection: false,
                      onCompletion: store.finishImport)
        .fileExporter(isPresented: $store.exporting, document: store.exportFile, contentType: .subcard,
                      defaultFilename: store.name == "Untitled" ? "Untitled.subcard" : store.name,
                      onCompletion: store.finishExport)
        .onChange(of: store.exporting) { isPresented in
            if !isPresented { store.exportDismissed() }
        }
        .confirmationDialog("Save changes to “\(store.name)”?", isPresented: $store.confirming, titleVisibility: .visible) {
            Button("Save") { store.saveAndContinue() }
            Button("Don’t Save", role: .destructive) { store.discardAndContinue() }
            Button("Cancel", role: .cancel) { store.cancelReplacement() }
        } message: { Text("Your changes will be lost if you don’t save them.") }
        .alert("SubCard couldn’t complete the operation", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onOpenURL { editing = false; store.request(.openURL($0)) }
    }
}
#endif
