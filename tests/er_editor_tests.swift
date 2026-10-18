// SPDX-License-Identifier: Apache-2.0
import Foundation
import SubCardCore

@main
@MainActor
enum EditorTests {
  static func main() async {
    await animatedReveal()
    newTableVisibility()
    phoneTablePlacement()
    typedFields()
    customChecks()
    dataViews()
    tableTapNavigation()
    independentDocuments()
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
    assert(arrow.referenceName == "Clients" && arrow.inverseName.isEmpty)
    store.referenceNameDraft = "Customer"
    store.inverseNameDraft = "Order"
    assert(store.hasDraft)
    store.commitNames()
    assert(store.edge?.referenceName == "Customer" && store.edge?.inverseName == "Order")
    assert(!store.hasDraft)
    store.command("undo")
    assert(store.referenceNameDraft == "Clients" && store.inverseNameDraft.isEmpty)
    store.command("redo")
    assert(store.referenceNameDraft == "Customer" && store.inverseNameDraft == "Order")
    assert(store.graph.tables.allSatisfy { $0.fields.isEmpty && $0.height == 64 })
    store.command("update_connection", ["id": arrow.id, "many": false, "cascade": false])
    assert(store.edge?.many == false)
    assert(store.edge?.referenceName == "Customer" && store.edge?.inverseName == "Order")
    store.command("undo")
    assert(store.edge?.many == true)
    store.command("redo")
    assert(store.edge?.many == false)
    store.select(edge: arrow.id)  // Selecting an arrow never selects its hidden key or a table.
    store.referenceNameDraft = "Buyer"
    store.select(table: first.id)
    assert(store.graph.edges.first?.referenceName == "Buyer" && !store.hasDraft)
    store.select(edge: arrow.id)
    store.referenceNameDraft = ""
    store.commitNames()
    assert(store.error != nil && store.referenceNameDraft == "Buyer" && !store.hasDraft)
    store.error = nil
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
    assert(store.graph.edges.count == 1)  // A duplicated table has no accidental relationships.
    store.tableNameDraft = ""
    store.commitNames()
    assert(store.error != nil && store.table?.name == "Copy after editing copy")
    assert(!store.hasDraft)
    store.command(
      "add_index", ["table": first.id, "name": "legacy reference", "kind": "secondary"])
    let key = store.graph.tables.first!.fields.last!
    store.command(
      "connect", ["table": first.id, "field": key.id, "target": second.id, "targetField": 0])
    let legacy = store.graph.edges.last!
    store.select(edge: legacy.id)
    assert(store.relationshipTitle(legacy) == "Orders → Copy after editing")
    assert(store.graph.tables.first?.height == 64)
    // The document owner detaches the editor before replacing/closing a handle.
    store.document = nil
    store.commitNames()
    print("Editor name commits, table relationships, cardinality, selection and undo passed.")
  }
  static func dataViews() {
    let document = subcard_document_new()!
    defer { subcard_document_close(document) }
    let store = ERStore()
    store.attach(document, changed: {})
    store.canvasSize = CGSize(width: 700, height: 500)
    store.addTable()
    store.addField(.integer)
    let table = store.table!.id
    let field = store.field!.id
    store.addDataView()
    let view = store.dataView!
    assert(store.table == nil && store.selectedTable == view.id)
    assert(view.columns.count == 1 && view.columns[0].group == "none")
    assert(view.availableColumns[0].groups == ["none", "count", "sum", "avg", "min", "max"])
    assert(view.sql.contains("__subcard_row_id"))
    store.tableNameDraft = "Totals"
    store.setViewColumn(field, included: false)
    assert(store.dataView?.name == "Totals" && !store.hasDraft)
    assert(store.dataView?.columns.isEmpty == true && store.dataView?.sql == "")
    store.setViewColumn(field, included: true)
    assert(store.dataView?.columns[0].group == "none")
    store.setViewColumn(field, included: true, group: "sum")
    assert(store.dataView?.grouped == true && store.dataView?.sql.contains("__subcard_row_id") == false)
    store.command("undo")
    assert(store.dataView?.grouped == false && store.dataView?.sql.contains("__subcard_row_id") == true)
    store.selectTableFromCanvas(view.id, tapCount: 1, compact: true)
    assert(!store.showDetails && store.dataView?.id == view.id)
    store.selectTableFromCanvas(view.id, tapCount: 2, compact: true)
    assert(store.showDetails && store.dataView?.id == view.id)
    store.pendingSource = nil
    store.beginConnection()
    assert(store.pendingSource == nil) // Views have no relationship ports.
    store.select(table: table)
    store.beginConnection()
    store.connect(to: view.id)
    assert(store.graph.edges.isEmpty && store.pendingSource == nil)
    store.select(table: view.id)
    assert(subcard_document_write_user_data(document, SUBCARD_DATA_REAL, "INSERT INTO user_t\(table)(f\(field)) VALUES(42)") != 0)
    store.refresh()
    assert(store.locked)
    store.tableNameDraft = "Real totals"
    store.commitNames()
    assert(store.dataView?.name == "Real totals" && store.error == nil)
    store.deleteSelection()
    assert(store.graph.views.isEmpty && store.graph.tables.count == 1)
    store.command("undo")
    assert(store.graph.views.count == 1)
    store.document = nil
    print("View selection, column chips, None defaults, SQL identity, compact navigation, drafts and locked-schema metadata edits passed.")
  }
  static func customChecks() {
    let document = subcard_document_new()!
    defer { subcard_document_close(document) }
    let store = ERStore()
    store.attach(document, changed: {})
    store.addTable()
    store.addField(.integer)
    let table = store.table!.id
    let field = store.field!
    store.fieldNameDraft = "Age"
    store.commitNames()
    let before = store.graph.canUndo
    assert(store.checkValidation("\"Age\" >= 0", table: table) == nil)
    assert(store.checkValidation("\"Age\" >", table: table) != nil)
    assert(store.checkValidation("\"Missing\" > 0", table: table) != nil)
    assert(
      store.error == nil && store.field?.check.isEmpty == true && store.graph.canUndo == before)
    store.updateField(field, ["check": "\"Age\" >= 0"])
    assert(store.field?.check == "f\(field.id) >= 0")
    store.command(
      "add_constraint", ["table": table, "name": "Adult", "expression": "\"Age\" >= 18"])
    store.command(
      "add_constraint", ["table": table, "name": "Age limit", "expression": "\"Age\" <= 150"])
    assert(store.table?.constraints.count == 2)
    store.fieldNameDraft = "Age in years"
    store.commitNames()
    assert(store.field?.checkDisplay == "\"Age in years\" >= 0")
    assert(store.table?.constraints.first?.displayExpression == "\"Age in years\" >= 18")
    store.duplicate()
    assert(store.table?.constraints.count == 2)
    let copiedField = store.table!.dataFields[0]
    assert(copiedField.id != field.id && copiedField.check == "f\(copiedField.id) >= 0")
    let copiedTable = store.table!.id
    let constraint = store.table!.constraints[0]
    store.command("delete_constraint", ["table": copiedTable, "id": constraint.id])
    assert(store.table?.constraints.count == 1)
    store.command("undo")
    assert(store.table?.constraints.count == 2)
    store.updateField(copiedField, ["check": ""])
    store.selectField(copiedField.id)
    assert(store.field?.check.isEmpty == true)
    store.command("undo")
    assert(store.field?.check.isEmpty == false)
    store.document = nil
    print(
      "Constraint previews, field names, multiple named checks, copies, deletion and undo passed.")
  }
  static func independentDocuments() {
    let firstDocument = subcard_document_new()!
    let secondDocument = subcard_document_new()!
    defer {
      subcard_document_close(firstDocument)
      subcard_document_close(secondDocument)
    }
    let first = ERStore()
    let second = ERStore()
    first.attach(firstDocument, changed: {})
    second.attach(secondDocument, changed: {})
    first.addTable()
    first.tableNameDraft = "First document"
    second.addTable()
    second.tableNameDraft = "Second document"
    second.duplicate()
    assert(first.tableNameDraft == "First document" && first.hasDraft)
    assert(first.graph.tables.count == 1 && second.graph.tables.count == 2)
    first.commitNames()
    assert(first.table?.name == "First document")
    assert(second.table?.name == "Second document copy")
    let secondSnapshot = String(cString: subcard_document_er_json(secondDocument)!)
    first.command("undo")
    assert(first.table?.name == "Table 1")
    assert(String(cString: subcard_document_er_json(secondDocument)!) == secondSnapshot)
    first.deleteSelection()
    assert(first.graph.tables.isEmpty && second.graph.tables.count == 2)
    first.document = nil
    second.document = nil
    print("Independent document drafts, selections, mutations and undo histories passed.")
  }
  static func tableTapNavigation() {
    let document = subcard_document_new()!
    defer { subcard_document_close(document) }
    let store = ERStore()
    store.attach(document, changed: {})
    store.addTable()
    let first = store.table!.id
    store.addTable()
    let second = store.table!.id
    let before = String(cString: subcard_document_er_json(document)!)
    store.selectTableFromCanvas(first, tapCount: 1, compact: true)
    assert(store.selectedTable == first && !store.showDetails)
    store.selectTableFromCanvas(first, tapCount: 1, compact: true)
    assert(!store.showDetails)  // A later single tap is still selection only.
    store.selectTableFromCanvas(first, tapCount: 2, compact: true)
    assert(store.selectedTable == first && store.showDetails)
    store.showDetails = false  // Return from the iPhone details screen.
    store.selectTableFromCanvas(second, tapCount: 1, compact: true)
    assert(store.selectedTable == second && !store.showDetails)
    store.selectTableFromCanvas(first, tapCount: 1, compact: false)
    assert(store.table?.id == first && !store.showDetails)  // Adjacent desktop inspector.
    assert(String(cString: subcard_document_er_json(document)!) == before)
    // Navigation commits an existing inspector draft to its original table.
    store.tableNameDraft = "People"
    store.selectTableFromCanvas(second, tapCount: 1, compact: true)
    assert(
      store.graph.tables.first?.name == "People" && store.table?.id == second && !store.hasDraft)
    assert(subcard_document_set_mode(document, SUBCARD_MODE_USE) != 0)
    store.refresh()
    store.selectTableFromCanvas(first, tapCount: 1, compact: true)
    assert(store.table?.id == first && !store.showDetails)
    store.selectTableFromCanvas(first, tapCount: 2, compact: true)
    assert(store.showDetails)  // Read-only tables use the same selection/navigation policy.
    store.document = nil
    print(
      "Compact single/double taps, desktop selection, use-mode selection and draft ownership passed."
    )
  }
  static func typedFields() {
    let document = subcard_document_new()!
    defer { subcard_document_close(document) }
    let store = ERStore()
    store.attach(document, changed: {})
    store.addTable()
    let tableID = store.table!.id
    for type in ERDatatype.allCases {
      store.addField(type)
      assert(store.field?.kind == type.rawValue)
      assert(store.table?.height == 64)  // The canvas stays table/relationship only.
    }
    assert(store.table?.dataFields.count == 10 && store.graph.edges.isEmpty)
    let photo = store.field!
    store.fieldNameDraft = "Portrait"
    assert(store.hasDraft)
    store.updateField(photo, ["media": "image"])
    assert(store.field?.name == "Portrait" && store.field?.media == "image" && !store.hasDraft)
    store.command("undo")
    assert(store.field?.name == "Portrait" && store.field?.media == "binary")
    store.command("undo")
    assert(store.field?.name == photo.name && store.fieldNameDraft == photo.name)
    store.command("redo")
    store.command("redo")
    store.selectField(store.table!.dataFields.first!.id)
    store.fieldNameDraft = "Full name"
    store.selectField(photo.id)
    assert(store.table?.dataFields.first?.name == "Full name")
    store.fieldNameDraft = "Photo"
    store.tableNameDraft = "People"
    store.commitNames()  // The same lifecycle hook handles both draft owners.
    assert(store.table?.name == "People" && store.field?.name == "Photo" && !store.hasDraft)
    store.fieldNameDraft = ""
    store.commitNames()
    assert(store.error != nil && store.fieldNameDraft == "Photo" && !store.hasDraft)
    store.error = nil
    store.fieldNameDraft = "Saved photo"
    store.commitNames()
    let path = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]!)
      .appendingPathComponent("typed-editor-\(UUID().uuidString).subcard")
    defer { try? FileManager.default.removeItem(at: path) }
    assert(subcard_document_save(document, path.path) != 0)
    let reopened = subcard_document_open(path.path)!
    let other = ERStore()
    other.attach(reopened, changed: {})
    other.select(table: tableID)
    assert(other.table?.height == 64 && other.table?.dataFields.count == 10)
    assert(
      other.table?.dataFields.last?.name == "Saved photo"
        && other.table?.dataFields.last?.media == "image")
    other.document = nil
    subcard_document_close(reopened)
    store.command("delete_field", ["table": tableID, "id": photo.id])
    assert(store.selectedField == nil && store.fieldNameDraft.isEmpty)
    store.command("undo")
    store.selectField(photo.id)
    assert(store.field?.media == "image")
    let url = store.table!.dataFields.first { $0.kind == "url" }!
    store.selectField(url.id)
    store.fieldNameDraft = "Homepage"
    store.updateField(url, ["nullable": false, "unique": true])
    assert(
      store.field?.name == "Homepage" && store.field?.nullable == false
        && store.field?.unique == true
    )
    store.command("undo")
    assert(store.field?.nullable == true && store.field?.unique == false)
    store.command("redo")
    store.updateField(url, ["kind": "blob"])
    assert(
      store.field?.indexed == false && store.field?.unique == true && store.field?.nullable == false
    )
    store.select(table: tableID)
    assert(store.selectedField == nil && store.fieldNameDraft.isEmpty)
    store.duplicate()
    assert(store.table?.dataFields.count == 10 && store.table?.height == 64)
    assert(store.table?.dataFields.last?.media == "image" && store.graph.edges.isEmpty)
    let copiedURL = store.table!.dataFields.first { $0.name == "Homepage" }!
    assert(copiedURL.unique && !copiedURL.nullable && copiedURL.kind == "blob")
    // Legacy generated keys remain hidden from the field list.
    store.command("add_index", ["table": store.table!.id, "name": "hidden", "kind": "index"])
    assert(store.table?.fields.count == 11 && store.table?.dataFields.count == 10)
    store.document = nil
    print(
      "Typed inspector fields, draft ownership, fixed canvas height, copy and persistence passed.")
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
    assert(store.graph.tables.count == 3)  // The reveal never adds an undo step.
    store.cancelReveal()
    store.document = nil
    print("Animated reveal continuity, interruption, save endpoints and undo passed.")
  }
  static func phoneTablePlacement() {
    let document = subcard_document_new()!
    defer { subcard_document_close(document) }
    let store = ERStore()
    store.attach(document, changed: {})
    store.phoneTablePlacement = true
    store.canvasSize = CGSize(width: 390, height: 700)
    store.addTable()
    let first = store.table!
    store.addTable()
    let second = store.table!
    assert(second.x == first.x && second.y > first.y + first.height)
    assert(store.graph.view.zoom == 1 && !store.showDetails)
    store.command("undo")
    assert(store.graph.tables.count == 1)
    store.command("redo")
    assert(store.graph.tables.last?.y == second.y)
    // Reselecting an earlier table skips the occupied slot below it.
    store.select(table: first.id)
    store.addTable()
    let third = store.table!
    assert(third.x == first.x && third.y > second.y + second.height)
    // Rotation affects the next insertion, without rearranging existing tables.
    store.canvasSize = CGSize(width: 800, height: 330)
    store.addTable()
    let fourth = store.table!
    assert(fourth.x > third.x + 320 && fourth.y == third.y)
    assert(store.graph.tables.first?.x == first.x && store.graph.tables.first?.y == first.y)
    store.select(table: nil)
    store.addTable()
    assert(store.table!.x > fourth.x + 320 && store.table!.y == fourth.y)
    store.cancelReveal()
    store.document = nil
    print("Phone portrait/landscape placement, selection anchors, collision avoidance and undo passed.")
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
        assert(
          top >= 24 - 1e-6 && top + table.height * scale <= store.canvasSize.height - 38 + 1e-6)
        assert(camera.zoom == zoom)
        assert(!store.showDetails)
        store.command("undo")
        assert(store.graph.tables.count == count)  // Reveal did not consume undo.
        assert(store.graph.view.panX == camera.panX && store.graph.view.panY == camera.panY)
        store.command("redo")
        assert(store.graph.tables.count == count + 1)
      }
    }
    print("Add Table reveals each new table at the current zoom with one creation undo step.")
  }

}
