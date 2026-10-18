// SPDX-License-Identifier: Apache-2.0
import SubCardCore
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

enum ERDatatype: String, CaseIterable, Identifiable {
  case string, url, date, time, datetime, decimal, float, integer, boolean, blob
  var id: String { rawValue }
  var title: String {
    switch self {
    case .string: return "String"
    case .url: return "URL"
    case .date: return "Date"
    case .time: return "Time"
    case .datetime: return "Date-time"
    case .decimal: return "Binary coded decimal (BCD)"
    case .float: return "Float"
    case .integer: return "Integer"
    case .boolean: return "Boolean"
    case .blob: return "Blob"
    }
  }
  var indexable: Bool { self != .blob && self != .decimal }
}
struct ERField: Codable, Identifiable {
  var id: Int
  var name: String
  var kind: String
  var unique: Bool
  var indexed: Bool = false
  var nullable: Bool = true
  var media: String = "binary"
  var scale: Int = 2
  var check: String = ""
  var checkDisplay: String = ""
  var datatype: ERDatatype? { ERDatatype(rawValue: kind) }
  var typeTitle: String { datatype?.title ?? kind }
  enum CodingKeys: String, CodingKey {
    case id, name, kind, unique, indexed, nullable, media, scale, check, checkDisplay
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(Int.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    kind = try c.decode(String.self, forKey: .kind)
    unique =
      try c.decodeIfPresent(Bool.self, forKey: .unique) ?? (kind == "index" || kind == "secondary")
    indexed = try c.decodeIfPresent(Bool.self, forKey: .indexed) ?? false
    nullable = try c.decodeIfPresent(Bool.self, forKey: .nullable) ?? true
    media = try c.decodeIfPresent(String.self, forKey: .media) ?? "binary"
    scale = try c.decodeIfPresent(Int.self, forKey: .scale) ?? 2
    check = try c.decodeIfPresent(String.self, forKey: .check) ?? ""
    checkDisplay = try c.decodeIfPresent(String.self, forKey: .checkDisplay) ?? check
  }
}
struct ERConstraint: Codable, Identifiable {
  var id: Int
  var name: String
  var expression: String
  var displayExpression: String
  enum CodingKeys: String, CodingKey { case id, name, expression, displayExpression }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(Int.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    expression = try c.decode(String.self, forKey: .expression)
    displayExpression = try c.decodeIfPresent(String.self, forKey: .displayExpression) ?? expression
  }
}
struct ERTable: Codable, Identifiable {
  var id: Int
  var name: String
  var color: String
  var x: Double
  var y: Double
  var fields: [ERField]
  var constraints: [ERConstraint] = []
  enum CodingKeys: String, CodingKey { case id, name, color, x, y, fields, constraints }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(Int.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    color = try c.decode(String.self, forKey: .color)
    x = try c.decode(Double.self, forKey: .x)
    y = try c.decode(Double.self, forKey: .y)
    fields = try c.decode([ERField].self, forKey: .fields)
    constraints = try c.decodeIfPresent([ERConstraint].self, forKey: .constraints) ?? []
  }
  var height: Double { 64 }
  var dataFields: [ERField] { fields.filter { $0.datatype != nil } }
  init(view: ERDataView) {
    id = view.id; name = "▤ " + view.name; color = "#7651A8"
    x = view.x; y = view.y; fields = []; constraints = []
  }
}
struct ERViewColumn: Codable { var field: Int; var group: String }
struct ERViewAvailableColumn: Decodable, Identifiable {
  var field: Int; var name: String; var kind: String; var groups: [String]
  var id: Int { field }
}
struct ERDataView: Decodable, Identifiable {
  var id: Int; var name: String; var table: Int; var x: Double; var y: Double
  var columns: [ERViewColumn]
  var availableColumns: [ERViewAvailableColumn]
  var sql: String; var grouped: Bool
}
func erGroupTitle(_ group: String) -> String {
  switch group {
  case "count": return "Count"
  case "sum": return "Sum"
  case "avg": return "Average"
  case "min": return "Minimum"
  case "max": return "Maximum"
  default: return "None"
  }
}
struct EREdge: Codable, Identifiable {
  var id: Int
  var table: Int
  var field: Int
  var target: Int
  var targetField: Int
  var many: Bool
  var cascade: Bool
  // Older documents store foreign-key direction; present their conceptual direction.
  var sourceTable: Int { field == 0 ? table : target }
  var destinationTable: Int { field == 0 ? target : table }
}
struct ERGraph: Decodable {
  var tables: [ERTable] = []
  var edges: [EREdge] = []
  var view = ERViewport()
  var canUndo = false
  var canRedo = false
  var views: [ERDataView] = []
  var nodes: [ERTable] { tables + views.map { ERTable(view: $0) } }
  init() {}
  enum CodingKeys: String, CodingKey { case tables, edges, view, canUndo, canRedo, views }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    tables = try c.decode([ERTable].self, forKey: .tables)
    edges = try c.decode([EREdge].self, forKey: .edges)
    view = try c.decode(ERViewport.self, forKey: .view)
    canUndo = try c.decode(Bool.self, forKey: .canUndo)
    canRedo = try c.decode(Bool.self, forKey: .canRedo)
    views = try c.decodeIfPresent([ERDataView].self, forKey: .views) ?? []
  }
}

@MainActor
final class ERStore: ObservableObject {
  @Published var graph = ERGraph()
  @Published var selectedTable: Int?
  @Published var selectedEdge: Int?
  @Published var selectedField: Int?
  @Published var fieldNameDraft = ""
  private var fieldNameBaseline = ""
  @Published var pendingSource: Int?
  @Published var tableNameDraft = ""
  private var tableNameBaseline = ""
  var hasDraft: Bool { tableNameDraft != tableNameBaseline || fieldNameDraft != fieldNameBaseline }
  @Published var error: String?
  @Published var showDetails = false
  // Transient command routing; native text editing takes precedence over table actions.
  @Published var editingText = false
  @Published var textSelectionVersion = 0
  @Published private(set) var animatedViewport: ERViewport?
  private var revealTask: Task<Void, Never>?
  var viewport: ERViewport { animatedViewport ?? graph.view }
  var canvasSize = CGSize.zero
  var document: OpaquePointer?
  var didChange: (() -> Void)?
  var editable: Bool { document.map { subcard_document_mode($0) == SUBCARD_MODE_EDIT } ?? false }
  var locked: Bool { document.map { subcard_document_schema_is_locked($0) != 0 } ?? true }
  var table: ERTable? { graph.tables.first { $0.id == selectedTable } }
  var dataView: ERDataView? { graph.views.first { $0.id == selectedTable } }
  var field: ERField? { table?.dataFields.first { $0.id == selectedField } }
  var edge: EREdge? { graph.edges.first { $0.id == selectedEdge } }
  func attach(_ pointer: OpaquePointer, changed: @escaping () -> Void) {
    if document != pointer {
      cancelReveal()
      selectedTable = nil
      selectedEdge = nil
      selectedField = nil
      fieldNameDraft = ""
      fieldNameBaseline = ""
      pendingSource = nil
      tableNameDraft = ""
      tableNameBaseline = ""
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
    if !graph.nodes.contains(where: { $0.id == selectedTable }) { selectedTable = nil }
    if !graph.edges.contains(where: { $0.id == selectedEdge }) { selectedEdge = nil }
    if !editable || locked || !graph.tables.contains(where: { $0.id == pendingSource }) {
      pendingSource = nil
    }
    if field == nil { selectedField = nil }
    if fieldNameDraft == fieldNameBaseline || field == nil {
      fieldNameDraft = field?.name ?? ""
      fieldNameBaseline = fieldNameDraft
    }
    if tableNameDraft == tableNameBaseline || (table == nil && dataView == nil) {
      tableNameDraft = table?.name ?? dataView?.name ?? ""
      tableNameBaseline = tableNameDraft
    }
  }
  // Drafts belong to the current selection. All model actions and document
  // lifecycle actions flush them before reading or replacing that selection.
  func commitNames() {
    if let v = dataView, tableNameDraft != tableNameBaseline {
      execute("update_data_view", ["id": v.id, "name": tableNameDraft])
      tableNameDraft = dataView?.name ?? ""
      tableNameBaseline = tableNameDraft
    }
    if let t = table, tableNameDraft != tableNameBaseline {
      let name = tableNameDraft
      execute("update_table", ["id": t.id, "name": name, "color": t.color])
      tableNameDraft = table?.name ?? ""
      tableNameBaseline = tableNameDraft
    }
    if let t = table, let f = field, fieldNameDraft != fieldNameBaseline {
      let name = fieldNameDraft
      execute("update_field", ["table": t.id, "id": f.id, "name": name])
      fieldNameDraft = field?.name ?? ""
      fieldNameBaseline = fieldNameDraft
    }
  }
  func selectField(_ id: Int?) {
    commitNames()
    selectedField = id
    fieldNameDraft = field?.name ?? ""
    fieldNameBaseline = fieldNameDraft
  }
  func addField(_ type: ERDatatype) {
    commitNames()
    guard let t = table else { return }
    var n = 1
    while t.fields.contains(where: { $0.name.lowercased() == "field \(n)" }) { n += 1 }
    let count = t.fields.count
    command("add_field", ["table": t.id, "name": "Field \(n)", "kind": type.rawValue])
    if table?.fields.count == count + 1 { selectField(table?.dataFields.last?.id) }
  }
  func updateField(_ f: ERField, _ properties: [String: Any]) {
    guard let t = table else { return }
    var values = properties
    values["table"] = t.id
    values["id"] = f.id
    command("update_field", values)
  }
  func checkValidation(_ expression: String, table: Int) -> String? {
    guard let document else { return "The document is closed." }
    if subcard_document_validate_check(document, Int32(table), expression) == 0 {
      return String(cString: subcard_last_error())
    }
    return nil
  }
  func command(_ op: String, _ properties: [String: Any] = [:]) {
    commitNames()
    cancelReveal()
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
  func select(table: Int? = nil, edge: Int? = nil, details: Bool = true) {
    commitNames()
    selectedTable = table
    selectedEdge = edge
    selectedField = nil
    fieldNameDraft = ""
    fieldNameBaseline = ""
    tableNameDraft = self.table?.name ?? dataView?.name ?? ""
    tableNameBaseline = tableNameDraft
    #if os(iOS)
      if details && (selectedTable != nil || selectedEdge != nil) { showDetails = true }
    #endif
  }
  // Compact navigation covers the canvas; desktop selection updates the adjacent inspector.
  // UIKit supplies the actual tap count, so separate single taps never act as a double tap.
  func selectTableFromCanvas(_ id: Int, tapCount: Int, compact: Bool) {
    select(table: id, details: false)
    showDetails = compact && tapCount >= 2
  }
  func beginConnection() {
    commitNames()
    guard editable, !locked, let selectedTable, table != nil else { return }
    pendingSource = selectedTable
  }
  func connect(to target: Int) {
    guard !graph.views.contains(where: { $0.id == target }) else { pendingSource = nil; return }
    guard let source = pendingSource else { return }
    let count = graph.edges.count
    command("add_connection", ["table": source, "target": target])
    pendingSource = nil
    if graph.edges.count == count + 1 { select(edge: graph.edges.last?.id) }
  }
  func tableName(_ id: Int) -> String { graph.tables.first { $0.id == id }?.name ?? "" }
  func relationshipTitle(_ e: EREdge) -> String {
    let source = tableName(e.sourceTable)
    let target = tableName(e.destinationTable)
    return "\(source) → \(target)"
  }
  func addTable() {
    let start = viewport
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
    let target = graph.view.revealing(
      CGRect(x: added.x, y: added.y, width: 320, height: added.height), in: canvasSize)
    view(target)
    animateReveal(from: start, to: graph.view)
  }
  func addDataView() {
    commitNames()
    let count = graph.views.count
    var n = count + 1
    while graph.views.contains(where: { $0.name.lowercased() == "view \(n)" }) { n += 1 }
    command("add_data_view", ["name": "View \(n)", "table": table?.id ?? graph.tables.first?.id ?? 0,
      "x": min(100000, max(0, viewport.panX + 80)),
      "y": min(100000, max(0, viewport.panY + 160))])
    guard graph.views.count == count + 1, let added = graph.views.last else { return }
    select(table: added.id)
    view(viewport.revealing(CGRect(x: added.x, y: added.y, width: 320, height: 64), in: canvasSize))
  }
  func setViewColumn(_ field: Int, included: Bool, group: String = "none") {
    guard let v = dataView else { return }
    command("set_view_column", ["id": v.id, "field": field, "included": included, "group": group])
  }
  func updateTable(_ t: ERTable, name: String? = nil, color: String? = nil) {
    commitNames()
    guard let current = graph.tables.first(where: { $0.id == t.id }) else { return }
    command(
      "update_table", ["id": t.id, "name": name ?? current.name, "color": color ?? current.color])
  }
  func copy() { _ = copyToClipboard() }
  private func clipboardText() -> String? {
    commitNames()
    guard let table, let data = try? JSONEncoder().encode(table),
      let obj = try? JSONSerialization.jsonObject(with: data),
      let payload = try? JSONSerialization.data(withJSONObject: ["subcardTable": 1, "table": obj]),
      let text = String(data: payload, encoding: .utf8)
    else { return nil }
    return text
  }
  #if os(macOS)
    var canPasteTable: Bool {
      guard let text = NSPasteboard.general.string(forType: .string),
        let data = text.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return false }
      return obj["subcardTable"] as? Int == 1 && obj["table"] != nil
    }
    func clipboardProviders(cutting: Bool = false) -> [NSItemProvider] {
      guard let text = clipboardText() else { return [] }
      let providers = [NSItemProvider(object: text as NSString)]
      if cutting, editable, !locked { deleteSelection() }
      return providers
    }
  #endif
  private func copyToClipboard() -> Bool {
    guard let text = clipboardText() else { return false }
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
    if let v = dataView {
      command("delete_data_view", ["id": v.id])
    } else if let selectedEdge {
      command("delete_connection", ["id": selectedEdge])
    } else if let selectedTable {
      command("delete_table", ["id": selectedTable])
    }
  }
  func cancelReveal() {
    revealTask?.cancel()
    revealTask = nil
    animatedViewport = nil
  }
  func interruptReveal() {
    guard let current = animatedViewport else { return }
    view(current)
  }
  private func animateReveal(from start: ERViewport, to target: ERViewport) {
    guard start.panX != target.panX || start.panY != target.panY else { return }
    animatedViewport = start
    let began = ProcessInfo.processInfo.systemUptime
    revealTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        let progress = (ProcessInfo.processInfo.systemUptime - began) / 0.5
        guard progress < 1 else { break }
        self?.animatedViewport = start.panned(toward: target, progress: progress)
        do { try await Task.sleep(nanoseconds: 16_666_667) } catch { return }
      }
      if !Task.isCancelled { self?.animatedViewport = nil }
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
    var v = viewport
    v.zoom = min(4, max(0.0001, v.zoom * factor))
    view(v)
  }
}
