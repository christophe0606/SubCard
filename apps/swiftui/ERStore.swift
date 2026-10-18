// SPDX-License-Identifier: Apache-2.0
import SubCardCore
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

struct ERField: Codable, Identifiable {
  var id: Int
  var name: String
  var kind: String
  var unique: Bool
}
struct ERTable: Codable, Identifiable {
  var id: Int
  var name: String
  var color: String
  var x: Double
  var y: Double
  var fields: [ERField]
  var height: Double { 64 + Double(fields.count) * 32 }
}
struct EREdge: Codable, Identifiable {
  var id: Int
  var table: Int
  var field: Int
  var target: Int
  var targetField: Int
  var many: Bool
  var cascade: Bool
}
struct ERGraph: Decodable {
  var tables: [ERTable] = []
  var edges: [EREdge] = []
  var view = ERViewport()
  var canUndo = false
  var canRedo = false
}

@MainActor
final class ERStore: ObservableObject {
  @Published var graph = ERGraph()
  @Published var selectedTable: Int?
  @Published var selectedEdge: Int?
  @Published var selectedField: Int?
  @Published var tableNameDraft = ""
  @Published var fieldNameDraft = ""
  private var tableNameBaseline = ""
  private var fieldNameBaseline = ""
  var hasDraft: Bool { tableNameDraft != tableNameBaseline || fieldNameDraft != fieldNameBaseline }
  var field: ERField? { table?.fields.first { $0.id == selectedField } }
  @Published var error: String?
  @Published var showDetails = false
  var canvasSize = CGSize.zero
  var document: OpaquePointer?
  var didChange: (() -> Void)?
  var editable: Bool { document.map { subcard_document_mode($0) == SUBCARD_MODE_EDIT } ?? false }
  var locked: Bool { document.map { subcard_document_schema_is_locked($0) != 0 } ?? true }
  var table: ERTable? { graph.tables.first { $0.id == selectedTable } }
  var edge: EREdge? { graph.edges.first { $0.id == selectedEdge } }
  func attach(_ pointer: OpaquePointer, changed: @escaping () -> Void) {
    if document != pointer {
      selectedTable = nil
      selectedEdge = nil
      selectedField = nil
      tableNameDraft = ""
      fieldNameDraft = ""
      tableNameBaseline = ""
      fieldNameBaseline = ""
      showDetails = false
    }
    document = pointer
    didChange = changed
    refresh()
  }
  func refresh() {
    guard let document, let json = subcard_document_er_json(document) else { return }
    do {
      graph = try JSONDecoder().decode(ERGraph.self, from: Data(String(cString: json).utf8))
    } catch { self.error = error.localizedDescription }
    if !graph.tables.contains(where: { $0.id == selectedTable }) { selectedTable = nil }
    if !graph.edges.contains(where: { $0.id == selectedEdge }) { selectedEdge = nil }
    if field == nil { selectedField = nil }
    if let selectedField { selectedEdge = graph.edges.first { $0.field == selectedField }?.id }
    if tableNameDraft == tableNameBaseline || table == nil {
      tableNameDraft = table?.name ?? ""
      tableNameBaseline = tableNameDraft
    }
    if fieldNameDraft == fieldNameBaseline || field == nil {
      fieldNameDraft = field?.name ?? ""
      fieldNameBaseline = fieldNameDraft
    }
  }
  // Drafts belong to the current selection. All model actions and document
  // lifecycle actions flush them before reading or replacing that selection.
  func commitNames() {
    if let t = table, tableNameDraft != tableNameBaseline {
      let name = tableNameDraft
      execute("update_table", ["id": t.id, "name": name, "color": t.color])
      tableNameDraft = table?.name ?? ""
      tableNameBaseline = tableNameDraft
    }
    if let t = table, let f = field, fieldNameDraft != fieldNameBaseline {
      let name = fieldNameDraft
      execute("update_index", ["table": t.id, "id": f.id, "name": name])
      fieldNameDraft = field?.name ?? ""
      fieldNameBaseline = fieldNameDraft
    }
  }
  func command(_ op: String, _ properties: [String: Any] = [:]) {
    commitNames()
    execute(op, properties)
  }
  private func execute(_ op: String, _ properties: [String: Any]) {
    guard let document else { return }
    var values = properties
    values["op"] = op
    do {
      let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
      let json = String(decoding: data, as: UTF8.self)
      if subcard_document_er_command(document, json) == 0 {
        error = String(cString: subcard_last_error())
      }
    } catch { self.error = error.localizedDescription }
    refresh()
    didChange?()
  }
  func select(table: Int? = nil, edge: Int? = nil, field: Int? = nil, details: Bool = true) {
    commitNames()
    let connection = graph.edges.first { $0.id == edge }
    selectedTable = table ?? connection?.table
    selectedField = field ?? connection?.field
    selectedEdge = edge ?? graph.edges.first { $0.field == selectedField }?.id
    tableNameDraft = self.table?.name ?? ""
    tableNameBaseline = tableNameDraft
    fieldNameDraft = self.field?.name ?? ""
    fieldNameBaseline = fieldNameDraft
    #if os(iOS)
      if details && selectedTable != nil { showDetails = true }
    #endif
  }
  func addField(_ kind: String, details: Bool = true) {
    commitNames()
    guard let t = table else { return }
    let label = kind == "index" ? "Index" : "Connection"
    var n = 1
    while t.fields.contains(where: { $0.name.lowercased() == "\(label) \(n)".lowercased() }) { n += 1 }
    command("add_index", ["table": t.id, "name": "\(label) \(n)", "kind": kind])
    select(table: t.id, field: table?.fields.last?.id, details: details)
  }
  func destination(_ e: EREdge) -> String {
    guard let target = graph.tables.first(where: { $0.id == e.target }) else { return "" }
    let key =
      e.targetField == 0
      ? "id (primary key)" : target.fields.first { $0.id == e.targetField }?.name ?? ""
    return "\(target.name) → \(key)"
  }
  func addTable() {
    commitNames()
    let count = graph.tables.count
    var n = count + 1
    while graph.tables.contains(where: { $0.name.lowercased() == "table \(n)" }) { n += 1 }
    command(
      "add_table",
      [
        "name": "Table \(n)",
        "x": min(100000, max(0, graph.view.panX + 60 + Double(graph.tables.count % 3) * 380)),
        "y": min(100000, max(0, graph.view.panY + 60 + Double(graph.tables.count / 3) * 200)),
      ])
    guard graph.tables.count == count + 1, let added = graph.tables.last else { return }
    select(table: added.id, details: false)
    view(graph.view.revealing(CGRect(x: added.x, y: added.y, width: 320, height: added.height), in: canvasSize))
  }
  func updateTable(_ t: ERTable, name: String? = nil, color: String? = nil) {
    commitNames()
    guard let current = graph.tables.first(where: { $0.id == t.id }) else { return }
    command(
      "update_table", ["id": t.id, "name": name ?? current.name, "color": color ?? current.color])
  }
  func copy() { _ = copyToClipboard() }
  private func copyToClipboard() -> Bool {
    commitNames()
    guard let table, let data = try? JSONEncoder().encode(table),
      let obj = try? JSONSerialization.jsonObject(with: data),
      let payload = try? JSONSerialization.data(withJSONObject: ["subcardTable": 1, "table": obj]),
      let text = String(data: payload, encoding: .utf8)
    else { return false }
    #if os(macOS)
      NSPasteboard.general.clearContents()
      return NSPasteboard.general.setString(text, forType: .string)
    #else
      UIPasteboard.general.string = text
      return true
    #endif
  }
  func cut() {
    guard editable, !locked, let selectedTable, copyToClipboard() else { return }
    command("delete_table", ["id": selectedTable])
  }
  func paste() {
    #if os(macOS)
      let text = NSPasteboard.general.string(forType: .string)
    #else
      let text = UIPasteboard.general.string
    #endif
    guard let text, let data = text.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      obj["subcardTable"] as? Int == 1, let table = obj["table"]
    else {
      error = "Clipboard does not contain a SubCard table."
      return
    }
    command("paste_table", ["table": table])
    select(table: graph.tables.last?.id, details: false)
  }
  func duplicate() {
    commitNames()
    guard let table, let data = try? JSONEncoder().encode(table),
      let obj = try? JSONSerialization.jsonObject(with: data)
    else { return }
    command("paste_table", ["table": obj])
    select(table: graph.tables.last?.id, details: false)
  }
  func deleteSelection() {
    if let selectedEdge {
      command("delete_connection", ["id": selectedEdge])
    } else if let selectedTable {
      command("delete_table", ["id": selectedTable])
    }
  }
  func view(_ v: ERViewport) {
    command(
      "view",
      [
        "zoom": v.zoom, "panX": v.panX, "panY": v.panY,
        "calibration": v.calibration,
      ])
  }
  func zoom(_ factor: Double) {
    var v = graph.view
    v.zoom = min(4, max(0.0001, v.zoom * factor))
    view(v)
  }
}
