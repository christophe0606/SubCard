// SPDX-License-Identifier: Apache-2.0
import Foundation
import SubCardCore

@main
@MainActor
enum EditorTests {
  static func main() {
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
    store.addField("index")
    let index = store.field!
    assert(index.unique)
    store.fieldNameDraft = "Account number"
    store.select(table: first.id)  // Selecting another object commits the old field.
    assert(store.table?.fields.first?.name == "Account number")
    store.addField("secondary", details: false)
    let foreignKey = store.field!
    assert(store.graph.edges.isEmpty)
    store.fieldNameDraft = "Parent account"
    store.addTable()
    let second = store.table!
    assert(store.graph.tables.first?.fields.last?.name == "Parent account")
    store.tableNameDraft = "Orders"
    store.select(table: first.id)
    assert(store.graph.tables.last?.name == "Orders")
    store.command(
      "connect",
      [
        "table": first.id, "field": foreignKey.id,
        "target": second.id, "targetField": 0,
      ])
    let arrow = store.graph.edges.first!
    store.select(edge: arrow.id)
    assert(store.selectedTable == first.id && store.selectedField == foreignKey.id)
    assert(store.destination(arrow) == "Orders → id (primary key)")
    store.deleteSelection()  // Arrow deletion leaves its owning field and table.
    assert(store.graph.edges.isEmpty && store.table?.fields.count == 2)
    store.command("undo")
    assert(store.graph.edges.count == 1)
    store.select(table: first.id, field: index.id)
    store.fieldNameDraft = "Code"
    store.command(
      "update_index",
      [
        "table": first.id, "id": index.id,
        "name": "Code", "unique": false,
      ])
    assert(store.field?.name == "Code" && store.field?.unique == false)
    store.command("undo")
    assert(store.field?.unique == true && store.fieldNameDraft == "Code")
    store.tableNameDraft = "Copy after editing"
    store.duplicate()
    assert(store.table?.name == "Copy after editing copy")
    assert(store.table?.fields.first?.name == "Code")
    store.tableNameDraft = ""
    store.commitNames()
    assert(store.error != nil && store.table?.name == "Copy after editing copy")
    assert(!store.hasDraft)
    // The document owner detaches the editor before replacing/closing a handle.
    store.document = nil
    store.commitNames()
    print("Editor name commits, selection, connection fields, uniqueness and undo passed.")
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
