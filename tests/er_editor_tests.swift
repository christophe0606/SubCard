// SPDX-License-Identifier: Apache-2.0
import Foundation
import SubCardCore

@main
@MainActor
enum EditorTests {
  static func main() async {
    await animatedReveal()
    newTableVisibility()
    let document = subcard_document_new()!
    defer { subcard_document_close(document) }
    let store = ERStore()
    store.attach(document, changed: {})
    store.addTable()
    let first = store.table!
    store.tableNameDraft = "Customers"
    assert(store.hasDraft)
    store.commitNames()  // Return / blur / back / document-save boundary.
    assert(store.table?.name == "Customers" && !store.hasDraft)
    store.command("undo")
    assert(store.table?.name == first.name && store.tableNameDraft == first.name)
    store.command("redo")
    assert(store.table?.name == "Customers")

    // A color button captured the table before typing: its action must preserve
    // the committed name instead of restoring that captured value.
    let beforeTyping = store.table!
    store.tableNameDraft = "Clients"
    store.updateTable(beforeTyping, color: "#7651A8")
    assert(store.table?.name == "Clients" && store.table?.color == "#7651A8")
    store.addTable()
    let second = store.table!
    store.tableNameDraft = "Orders"
    store.select(table: first.id)
    assert(store.graph.tables.last?.name == "Orders")
    let before = store.graph.edges.count
    store.beginConnection()
    assert(store.pendingSource == first.id && store.graph.edges.count == before)
    store.connect(to: second.id)
    let arrow = store.edge!
    assert(arrow.sourceTable == first.id && arrow.destinationTable == second.id && arrow.many)
    assert(store.relationshipTitle(arrow) == "Clients → Orders")
    assert(store.selectedTable == nil && store.pendingSource == nil)
    assert(store.graph.tables.allSatisfy { $0.fields.isEmpty && $0.height == 64 })
    store.command("update_connection", ["id": arrow.id, "many": false, "cascade": false])
    assert(store.edge?.many == false)
    store.command("undo")
    assert(store.edge?.many == true)
    store.command("redo")
    assert(store.edge?.many == false)
    store.select(edge: arrow.id) // Selecting an arrow never selects its hidden key or a table.
    store.deleteSelection()
    assert(store.graph.edges.isEmpty && store.graph.tables.count == 2)
    store.command("undo")
    assert(store.graph.edges.count == 1)
    store.select(table: first.id)
    store.beginConnection()
    store.connect(to: 999999)
    assert(store.error != nil && store.graph.edges.count == 1 && store.pendingSource == nil)
    store.error = nil
    store.tableNameDraft = "Copy after editing"
    store.duplicate()
    assert(store.table?.name == "Copy after editing copy" && store.table?.fields.isEmpty == true)
    assert(store.graph.edges.count == 1) // A duplicated table has no accidental relationships.
    store.tableNameDraft = ""
    store.commitNames()
    assert(store.error != nil && store.table?.name == "Copy after editing copy")
    assert(!store.hasDraft)
    store.command("add_index", ["table": first.id, "name": "legacy reference", "kind": "secondary"])
    let key = store.graph.tables.first!.fields.last!
    store.command("connect", ["table": first.id, "field": key.id, "target": second.id, "targetField": 0])
    let legacy = store.graph.edges.last!
    store.select(edge: legacy.id)
    assert(store.relationshipTitle(legacy) == "Orders → Copy after editing")
    assert(store.graph.tables.first?.height == 64)
    // The document owner detaches the editor before replacing/closing a handle.
    store.document = nil
    store.commitNames()
    print("Editor name commits, table relationships, cardinality, selection and undo passed.")
  }
  static func animatedReveal() async {
    let document = subcard_document_new()!
    defer { subcard_document_close(document) }
    let store = ERStore()
    store.attach(document, changed: {})
    store.canvasSize = CGSize(width: 428, height: 600)
    store.addTable()
    store.cancelReveal()
    let start = store.viewport
    store.addTable()
    let target = store.graph.view
    assert(store.animatedViewport != nil && store.viewport.panX == start.panX)
    assert(target.panX != start.panX)
    try? await Task.sleep(nanoseconds: 120_000_000)
    let middle = store.viewport
    assert(middle.panX > min(start.panX, target.panX) && middle.panX < max(start.panX, target.panX))
    // Saving mid-animation persists the endpoint; animation frames do not dirty the file.
    let path = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!)
      .appendingPathComponent("animated-reveal-\(UUID().uuidString).subcard")
    defer { try? FileManager.default.removeItem(at: path) }
    assert(subcard_document_save(document, path.path) != 0)
    try? await Task.sleep(nanoseconds: 80_000_000)
    assert(subcard_document_is_changed(document) == 0)
    let reopened = subcard_document_open(path.path)!
    let other = ERStore()
    other.attach(reopened, changed: {})
    assert(other.graph.view.panX == target.panX)
    other.document = nil
    subcard_document_close(reopened)
    // Repeated Add Table starts from the currently visible position.
    let current = store.viewport
    store.addTable()
    assert(store.viewport.panX == current.panX)
    try? await Task.sleep(nanoseconds: 650_000_000)
    assert(store.animatedViewport == nil && store.viewport.panX == store.graph.view.panX)
    store.canvasSize = CGSize(width: 300, height: 200)
    store.addTable()
    assert(store.animatedViewport != nil)
    try? await Task.sleep(nanoseconds: 80_000_000)
    let interrupted = store.viewport
    store.interruptReveal()
    assert(store.animatedViewport == nil && abs(store.graph.view.panX - interrupted.panX) < 1e-6)
    try? await Task.sleep(nanoseconds: 550_000_000)
    assert(abs(store.viewport.panX - interrupted.panX) < 1e-6)
    store.command("undo")
    assert(store.graph.tables.count == 3) // The reveal never adds an undo step.
    store.cancelReveal()
    store.document = nil
    print("Animated reveal continuity, interruption, save endpoints and undo passed.")
  }
  static func newTableVisibility() {
    let document = subcard_document_new()!
    defer { subcard_document_close(document) }
    let store = ERStore()
    store.attach(document, changed: {})
    store.canvasSize = CGSize(width: 428, height: 600)
    for zoom in [0.25, 1.0, 2.0, 4.0] {
      store.view(ERViewport(zoom: zoom, panX: -500, panY: 1200, calibration: 1.3))
      for _ in 0..<8 {
        let count = store.graph.tables.count
        store.addTable()
        let table = store.table!
        let camera = store.graph.view
        let scale = camera.zoom * camera.calibration
        let left = (table.x - camera.panX) * scale
        let top = (table.y - camera.panY) * scale
        assert(left >= 24 - 1e-6 && left < store.canvasSize.width - 38)
        assert(top >= 24 - 1e-6 && top + table.height * scale <= store.canvasSize.height - 38 + 1e-6)
        assert(camera.zoom == zoom)
        assert(!store.showDetails)
        store.command("undo")
        assert(store.graph.tables.count == count) // Reveal did not consume undo.
        assert(store.graph.view.panX == camera.panX && store.graph.view.panY == camera.panY)
        store.command("redo")
        assert(store.graph.tables.count == count + 1)
      }
    }
    print("Add Table reveals each new table at the current zoom with one creation undo step.")
  }

}
