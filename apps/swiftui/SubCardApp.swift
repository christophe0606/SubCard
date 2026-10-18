// SPDX-License-Identifier: Apache-2.0
import SubCardCore
import SwiftUI

// Temporary controls for the shared session mode; full mode-specific views
// will be designed with the card editor and use-mode workflows.
struct DocumentModeControls: View {
    let usingDocument: Bool
    let schemaLocked: Bool
    let toggle: () -> Void
    var body: some View {
        HStack {
            Text(usingDocument ? "Use mode" : "Editing mode")
            Spacer()
            Button(usingDocument ? "Edit document" : "Use document", action: toggle)
        }
        if schemaLocked {
            Text("User schema locked").font(.caption).foregroundStyle(.secondary)
        }
    }
}

#if os(macOS)
import AppKit
import UniformTypeIdentifiers

extension UTType {
    static let subcard = UTType(exportedAs: "org.subcard.document", conformingTo: .database)
}

@MainActor
final class DocumentStore: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var changed = false
    @Published private(set) var usingDocument = false
    @Published private(set) var schemaLocked = false
    @Published private(set) var url: URL?
    private var owner: CoreDocument
    var document: OpaquePointer { owner.pointer }
    var finishEREditing: (Bool) -> Void = { _ in }
    private var pendingEREdits = false
    func erDraftChanged(_ pending: Bool) { pendingEREdits = pending; refresh() }
    weak var window: NSWindow?
    var name: String { url?.lastPathComponent ?? "Untitled" }

    init() {
        guard let document = subcard_document_new() else {
            fatalError(String(cString: subcard_last_error()))
        }
        self.owner = CoreDocument(document)
        refresh()
    }

    func refresh() {
        text = String(cString: subcard_document_text(document))
        changed = subcard_document_is_changed(document) != 0 || pendingEREdits
        usingDocument = subcard_document_mode(document) == SUBCARD_MODE_USE
        schemaLocked = subcard_document_schema_is_locked(document) != 0
        let path = String(cString: subcard_document_path(document))
        url = path.isEmpty ? nil : URL(fileURLWithPath: path)
        window?.title = "\(name) — SubCard"
        window?.representedURL = url
        window?.isDocumentEdited = changed
    }

    private func reportError() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "SubCard couldn’t complete the operation"
        alert.informativeText = String(cString: subcard_last_error())
        alert.runModal()
    }

    func setText(_ text: String) {
        guard !text.utf8.contains(0) else { return }
        if subcard_document_set_text(document, text) == 0 { reportError() }
        refresh()
    }

    func toggleMode() {
        finishEREditing(false)
        if subcard_document_set_mode(document, usingDocument ? SUBCARD_MODE_EDIT : SUBCARD_MODE_USE) == 0 { reportError() }
        refresh()
    }

    @discardableResult
    func save(as saveAs: Bool = false) -> Bool {
        finishEREditing(false)
        guard changed else { return true }
        var destination = url
        if saveAs || destination == nil {
            let panel = NSSavePanel()
            panel.title = "Save SubCard Document"
            panel.allowedContentTypes = [.subcard]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = destination?.lastPathComponent ?? "Untitled.subcard"
            panel.directoryURL = destination?.deletingLastPathComponent()
            guard panel.runModal() == .OK, let selected = panel.url else { return false }
            destination = selected
        }
        guard let destination else { return false }
        if subcard_document_save(document, destination.path) == 0 {
            reportError()
            return false
        }
        refresh()
        return true
    }

    func confirmReplacement() -> Bool {
        finishEREditing(false)
        guard changed else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes to “\(name)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    @discardableResult
    func newDocument() -> Bool {
        guard confirmReplacement() else { return false }
        guard let next = subcard_document_new() else { reportError(); return false }
        finishEREditing(true)
        owner = CoreDocument(next)
        refresh()
        return true
    }

    @discardableResult
    func openDocument(at selected: URL? = nil) -> Bool {
        guard confirmReplacement() else { return false }
        var selected = selected
        if selected == nil {
            let panel = NSOpenPanel()
            panel.title = "Open SubCard Document"
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK else { return false }
            selected = panel.url
        }
        guard let selected else { return false }
        guard let next = subcard_document_open(selected.path) else { reportError(); return false }
        finishEREditing(true)
        owner = CoreDocument(next)
        refresh()
        return true
    }

    func attach(_ window: NSWindow) {
        self.window = window
        refresh()
    }

    func windowClosed() {
        window = nil
        // Closing ends this document's lifetime, including Don't Save. Keep a
        // clean model for the next New command while macOS keeps the app open.
        if let next = subcard_document_new() { finishEREditing(true); owner = CoreDocument(next); refresh() }
    }
}

// Kept inside the main-actor store; this owner releases each C++ handle once.
private final class CoreDocument {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { subcard_document_close(pointer) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let document = DocumentStore()
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.document.confirmReplacement() ? .terminateNow : .terminateCancel
    }
}

private struct WindowObserver: NSViewRepresentable {
    let store: DocumentStore
    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            if let window = view.window {
                if window.delegate !== coordinator {
                    coordinator.originalDelegate = window.delegate
                    window.delegate = coordinator
                }
                store.attach(window)
            }
        }
    }
    final class Coordinator: NSObject, NSWindowDelegate {
        let store: DocumentStore
        weak var originalDelegate: (any NSWindowDelegate)?
        init(store: DocumentStore) { self.store = store }
        func windowShouldClose(_ sender: NSWindow) -> Bool { store.confirmReplacement() }
        func windowWillClose(_ notification: Notification) {
            store.windowClosed()
            originalDelegate?.windowWillClose?(notification)
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (originalDelegate?.responds(to: selector) ?? false)
        }
        override func forwardingTarget(for selector: Selector!) -> Any? { originalDelegate }
    }
}

private struct DocumentCommands: Commands {
    @ObservedObject var store: DocumentStore
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") { if store.newDocument() { openWindow(id: "document") } }
                .keyboardShortcut("n", modifiers: .command)
            Button("Open…") { if store.openDocument() { openWindow(id: "document") } }
                .keyboardShortcut("o", modifiers: .command)
            Divider()
            Button("Close") { store.window?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
            Divider()
            Button("Save") { store.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!store.changed)
            Button("Save As…") { store.save(as: true) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!store.changed)
        }
    }
}

@main
struct SubCardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppDelegate.document
    @FocusState private var editorIsFocused: Bool
    var body: some Scene {
        Window("SubCard", id: "document") {
            VStack(spacing: 0) {
                HStack {
                    Text(store.name).font(.headline)
                    Text(store.changed ? "Edited" : "Saved").foregroundStyle(.secondary)
                    Spacer()
                    DocumentModeControls(usingDocument: store.usingDocument, schemaLocked: store.schemaLocked, toggle: store.toggleMode)
                }.padding(12)
                Divider()
                ERCanvasEditor(document: store.document, changed: store.refresh,
                    registerEditor: { store.finishEREditing = $0 }, draftChanged: { [weak store] in store?.erDraftChanged($0) })
            }
            .frame(minWidth: 720, minHeight: 480)
            .background(WindowObserver(store: store))
            .onOpenURL { store.openDocument(at: $0) }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { DocumentCommands(store: store); ERCommands() }
    }
}
#else
@main
struct SubCardApp: App {
    var body: some Scene {
        WindowGroup("SubCard") { PhoneDocumentView() }
    }
}
#endif
