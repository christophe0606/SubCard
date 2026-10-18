// SPDX-License-Identifier: Apache-2.0
import SubCardCore
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

private func erColor(_ hex: String) -> Color {
  let n = UInt32(hex.dropFirst(), radix: 16) ?? 0x397DB8
  return Color(
    red: Double((n >> 16) & 255) / 255, green: Double((n >> 8) & 255) / 255,
    blue: Double(n & 255) / 255)
}

struct ERCanvasEditor: View {
  let document: OpaquePointer
  let changed: () -> Void
  let registerEditor: (@escaping (Bool) -> Void) -> Void
  let draftChanged: (Bool) -> Void
  @StateObject private var store = ERStore()
  var body: some View {
    Group {
      #if os(macOS)
        HSplitView {
          ERCanvasSurface(store: store).frame(minWidth: 360)
          ERInspector(store: store).frame(minWidth: 240, idealWidth: 285, maxWidth: 450)
        }
      #else
        ERCanvasSurface(store: store)
          .navigationDestination(isPresented: $store.showDetails) {
            ERInspector(store: store).navigationTitle(store.dataView == nil ? "Details" : "View")
          }
      #endif
    }
    #if os(macOS)
      .focusedSceneObject(store)
      .onReceive(
        NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)
      ) { _ in
        store.textSelectionVersion &+= 1
      }
    #endif
    .onAppear { attach(document) }
    .onChange(of: store.tableNameDraft) { _ in draftChanged(store.hasDraft) }
    .onChange(of: store.fieldNameDraft) { _ in draftChanged(store.hasDraft) }
    .id(document)
    .onChange(of: document) { pointer in attach(pointer) }
    .alert(
      "Canvas operation failed",
      isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })
    ) {
      Button("OK") { store.error = nil }
    } message: {
      Text(store.error ?? "")
    }
  }
  private func attach(_ pointer: OpaquePointer) {
    store.attach(pointer, changed: changed)
    registerEditor { [weak store] detach in
      store?.commitNames()
      draftChanged(false)
      if detach {
        store?.cancelReveal()
        store?.document = nil
      }
    }
  }
}

private struct ERInspector: View {
  @ObservedObject var store: ERStore
  private enum Editing: Hashable {
    case table
    case field(Int)
  }
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var editing: Editing?
  @State private var checkDraft: ERCheckDraft?
  private let colors = ["#397DB8", "#7651A8", "#258775", "#BA6B28", "#B64762", "#556275"]
  private var schemaEditable: Bool { store.editable && !store.locked }
  private var fieldAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.22) }
  var body: some View {
    ScrollViewReader { reader in
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("Model details").font(.title2).bold()
          if let e = store.edge {
            Text("Relationship").font(.headline)
            Text("From: \(store.tableName(e.sourceTable))")
            Text("To: \(store.tableName(e.destinationTable))")
            connectionProperties(e)
            Button("Delete relationship", role: .destructive) {
              finishEditing()
              store.command("delete_connection", ["id": e.id])
            }.disabled(!schemaEditable)
          } else if let v = store.dataView {
            ERDataViewProperties(store: store, view: v)
          } else if let t = store.table {
            Text(t.name).font(.headline).accessibilityIdentifier("modelTableName")
            nameInput("Table name", text: $store.tableNameDraft, focus: .table)
            Text("Table color").font(.headline)
            HStack {
              ForEach(colors, id: \.self) { color in
                Button {
                  finishEditing()
                  store.updateTable(t, color: color)
                } label: {
                  Circle().fill(erColor(color)).frame(width: 24, height: 24)
                    .overlay(
                      Circle().stroke(t.color == color ? Color.primary : Color.clear, lineWidth: 2))
                }.buttonStyle(.plain).accessibilityLabel("Color \(color)")
              }
            }.disabled(!store.editable)
            Divider()
            fields(t)
            Divider()
            tableConstraints(t)
            Divider()
            #if os(iOS)
              HStack {
                Button("Copy") {
                  finishEditing()
                  store.copy()
                }
                Button("Duplicate") {
                  finishEditing()
                  store.duplicate()
                }.disabled(!schemaEditable)
              }
              Button("Delete table", role: .destructive) {
                finishEditing()
                store.command("delete_table", ["id": t.id])
              }.disabled(!schemaEditable)
            #endif
          } else {
            Text("Select a table, view or relationship arrow to edit its properties.").foregroundStyle(
              .secondary)
            Text(
              "Drag a table to move it. Drag its right circle to another table to create a relationship."
            )
          }
          Divider()
          Text("100% scale calibration").font(.headline)
          Text("At 100%, the title font em is 1 cm. Adjust against a ruler for this display.").font(
            .caption)
          Slider(
            value: Binding(
              get: { store.graph.view.calibration },
              set: { value in
                finishEditing()
                var v = store.graph.view
                v.calibration = value
                store.view(v)
              }), in: 0.25...4)
          Text("\(store.graph.view.calibration, specifier: "%.2f")×")
          if store.locked {
            Text("Schema locked: this document has held real data.").font(.caption)
          }
        }.padding()
      }
      .buttonStyle(.bordered)
      .onChange(of: editing) { value in
        store.editingText = value != nil
        store.commitNames()
      }
      .onDisappear {
        finishEditing()
        store.editingText = false
      }
      .sheet(item: $checkDraft) { draft in
        ERCheckEditor(store: store, draft: draft)
      }
      .onChange(of: store.selectedField) { id in
        if let id {
          withAnimation(fieldAnimation) { reader.scrollTo("field-\(id)", anchor: .top) }
        }
      }
    }
  }
  private func finishEditing() {
    store.commitNames()
    editing = nil
  }
  private func fields(_ table: ERTable) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Fields").font(.headline)
        Spacer()
        Menu("Add field") {
          ForEach(ERDatatype.allCases) { type in
            Button(type.title) {
              finishEditing()
              store.addField(type)
            }
          }
        }.disabled(!schemaEditable || table.fields.count >= 128)
      }
      if table.dataFields.isEmpty {
        Text("Add fields to describe each record, such as a name, birthday or photo.")
          .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(table.dataFields) { field in
        let expanded = store.selectedField == field.id
        VStack(alignment: .leading, spacing: 0) {
          Button {
            finishEditing()
            withAnimation(fieldAnimation) { store.selectField(expanded ? nil : field.id) }
          } label: {
            HStack(spacing: 8) {
              Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .foregroundStyle(.secondary)
              Text(field.name).lineLimit(1).foregroundStyle(.primary)
              Spacer(minLength: 4)
              Text(field.typeTitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
              if field.indexed || field.unique {
                Image(systemName: "magnifyingglass").accessibilityLabel("Indexed")
              }
            }
            .padding(12).frame(minHeight: 44).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("fieldRow-\(field.id)")
          .accessibilityValue(expanded ? "Expanded" : "Collapsed")
          .accessibilityHint(expanded ? "Collapse field details" : "Expand field details")
          if expanded {
            Divider()
            fieldProperties(table, field: field)
              .padding(12)
              .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
          }
        }
        .background(Color.primary.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
          RoundedRectangle(cornerRadius: 10).stroke(
            expanded ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .id("field-\(field.id)")
      }
    }
    .animation(fieldAnimation, value: store.selectedField)
  }
  private func nameInput(_ title: String, text: Binding<String>, focus: Editing) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      if schemaEditable {
        #if os(iOS)
          HStack(spacing: 8) {
            TextField(title, text: text)
              .textFieldStyle(.plain).focused($editing, equals: focus)
              .submitLabel(.done).onSubmit { finishEditing() }
              .textInputAutocapitalization(.words)
            Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
              .accessibilityHidden(true).allowsHitTesting(false)
          }
          .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 44)
          .background(
            Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(
              editing == focus ? Color.accentColor : Color.secondary.opacity(0.6),
              lineWidth: editing == focus ? 2 : 1))
        #else
          TextField(title, text: text)
            .textFieldStyle(.roundedBorder).focused($editing, equals: focus)
            .onSubmit { finishEditing() }
        #endif
      } else {
        Text(text.wrappedValue).frame(maxWidth: .infinity, alignment: .leading)
          .foregroundStyle(.secondary)
      }
    }
  }
  private func fieldProperties(_ table: ERTable, field: ERField) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      if let type = field.datatype {
        nameInput("Field name", text: $store.fieldNameDraft, focus: .field(field.id))
        Picker(
          "Datatype",
          selection: Binding(
            get: { type },
            set: { value in
              finishEditing()
              store.updateField(field, ["kind": value.rawValue])
            })
        ) {
          ForEach(ERDatatype.allCases) { value in Text(value.title).tag(value) }
        }.disabled(!schemaEditable)
        Toggle(
          "Allow NULL",
          isOn: Binding(
            get: { field.nullable },
            set: { value in
              finishEditing()
              store.updateField(field, ["nullable": value])
            })
        ).disabled(!schemaEditable)
        Toggle(
          "Unique values",
          isOn: Binding(
            get: { field.unique },
            set: { value in
              finishEditing()
              store.updateField(field, ["unique": value])
            })
        ).disabled(!schemaEditable)
        Text("NULL means no value; empty text is still a value.")
          .font(.caption).foregroundStyle(.secondary)
        if field.unique && field.nullable {
          Text("Multiple records may have no value. Values that are present must be unique.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if type.indexable {
          Toggle(
            "Indexed",
            isOn: Binding(
              get: { field.indexed || field.unique },
              set: { value in
                finishEditing()
                store.updateField(field, ["indexed": value])
              })
          ).disabled(!schemaEditable || field.unique)
        }
        if field.unique {
          Text("Uniqueness automatically creates an index.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if type == .decimal {
          Stepper(
            "Decimal places: \(field.scale)",
            value: Binding(
              get: { field.scale },
              set: { value in
                finishEditing()
                store.updateField(field, ["scale": value])
              }), in: 0...18
          ).disabled(!schemaEditable)
          Text("Exact decimal, up to 18 digits. Uniqueness compares exact decimal values.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if type == .url {
          Text("An absolute URL, such as https://example.com or mailto:person@example.com.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if type == .blob {
          Picker(
            "Content",
            selection: Binding(
              get: { field.media },
              set: { value in
                finishEditing()
                store.updateField(field, ["media": value])
              })
          ) {
            Text("Binary data").tag("binary")
            Text("Image").tag("image")
            Text("Video").tag("video")
            Text("Sound").tag("sound")
            Text("Document").tag("document")
          }.disabled(!schemaEditable)
          Text(
            "Stored inside the stack, for example a person’s photo. Uniqueness compares the stored bytes."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        Divider()
        Text("CHECK constraint").font(.headline)
        if !field.check.isEmpty {
          HStack(alignment: .top) {
            Button {
              finishEditing()
              checkDraft = ERCheckDraft(
                table: table.id, field: field.id, expression: field.checkDisplay)
            } label: {
              Text(field.checkDisplay).font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(!schemaEditable)
            removeConstraint("Delete field CHECK") {
              store.command("update_field", ["table": table.id, "id": field.id, "check": ""])
            }
          }
        } else {
          Button("Add CHECK expression") {
            finishEditing()
            checkDraft = ERCheckDraft(table: table.id, field: field.id)
          }.disabled(!schemaEditable)
        }
        Button("Delete field", role: .destructive) {
          finishEditing()
          store.command("delete_field", ["table": table.id, "id": field.id])
        }.disabled(!schemaEditable)
      }
    }
  }
  private func removeConstraint(_ label: String, action: @escaping () -> Void) -> some View {
    Button(role: .destructive) {
      finishEditing()
      action()
    } label: {
      Image(systemName: "xmark.circle.fill").font(.title3)
        .frame(minWidth: 44, minHeight: 44)
    }
    .buttonStyle(.plain).accessibilityLabel(label).help(label)
    .disabled(!schemaEditable)
  }
  private func tableConstraints(_ table: ERTable) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Table CHECK constraints").font(.headline)
      ForEach(table.constraints) { constraint in
        HStack(alignment: .top) {
          Button {
            finishEditing()
            checkDraft = ERCheckDraft(
              table: table.id, constraint: constraint.id,
              name: constraint.name, expression: constraint.displayExpression)
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(constraint.name).fontWeight(.semibold)
              Text(constraint.displayExpression).font(.system(.caption, design: .monospaced))
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.disabled(!schemaEditable)
          removeConstraint("Delete constraint \(constraint.name)") {
            store.command("delete_constraint", ["table": table.id, "id": constraint.id])
          }
        }
      }
      Button("Add named constraint") {
        finishEditing()
        checkDraft = ERCheckDraft(table: table.id)
      }.disabled(!schemaEditable || table.constraints.count >= 32)
      Text(
        "Every CHECK must pass. NULL results are accepted; use Allow NULL to require a field value."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
  }
  private func connectionProperties(_ e: EREdge) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker(
        "Cardinality",
        selection: Binding(
          get: { e.many },
          set: { many in
            finishEditing()
            store.command(
              "update_connection", ["id": e.id, "many": many, "cascade": many && e.cascade])
          })
      ) {
        Text("One to one (1:1)").tag(false)
        Text("One to many (1:N)").tag(true)
      }
      if e.many {
        Picker(
          "Deleting a source record",
          selection: Binding(
            get: { e.cascade },
            set: { cascade in
              finishEditing()
              store.command("update_connection", ["id": e.id, "many": true, "cascade": cascade])
            })
        ) {
          Text("Block deletion").tag(false)
          Text("Cascade deletion").tag(true)
        }
      }
    }.disabled(!schemaEditable)
  }
}

private struct ERDataViewProperties: View {
  @ObservedObject var store: ERStore
  let view: ERDataView
  @FocusState private var nameFocused: Bool
  private var selected: [ERViewAvailableColumn] {
    view.columns.compactMap { c in view.availableColumns.first { $0.field == c.field } }
  }
  private var ignored: [ERViewAvailableColumn] {
    view.availableColumns.filter { f in !view.columns.contains { $0.field == f.field } }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("View", systemImage: "tablecells").font(.headline)
      TextField("View name", text: $store.tableNameDraft).textFieldStyle(.roundedBorder)
        .focused($nameFocused).onSubmit { store.commitNames() }
        .disabled(!store.editable).accessibilityIdentifier("viewName")
      Picker("Source table", selection: Binding(get: { view.table }, set: { id in
        store.command("update_data_view", ["id": view.id, "table": id])
      })) {
        Text("Choose a table").tag(0)
        ForEach(store.graph.tables) { Text($0.name).tag($0.id) }
      }.pickerStyle(.menu).disabled(!store.editable).accessibilityIdentifier("viewSourceTable")
      Text("Selected columns").font(.headline)
      if selected.isEmpty {
        Text("Choose columns below to include them in this view.").font(.caption).foregroundStyle(.secondary)
      }
      chips(selected, included: true)
      Divider()
      Text("Ignored columns").font(.headline)
      if ignored.isEmpty {
        Text(view.table == 0 ? "Choose a source table first." : "All columns are selected.")
          .font(.caption).foregroundStyle(.secondary)
      }
      chips(ignored, included: false)
      if view.grouped {
        Text("Columns set to None define the groups. Aggregate columns summarize each group.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if view.columns.isEmpty && view.table != 0 {
        Text("Select at least one column to complete the view.").font(.caption).foregroundStyle(.secondary)
      }
    }
    .onChange(of: nameFocused) { focused in
      store.editingText = focused
      if !focused { store.commitNames() }
    }
    .onDisappear { store.commitNames(); store.editingText = false }
  }
  private func chips(_ fields: [ERViewAvailableColumn], included: Bool) -> some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 8) {
      ForEach(fields) { f in
        HStack(spacing: 8) {
          if included {
            Button { store.setViewColumn(f.field, included: false) } label: {
              Image(systemName: "xmark.circle.fill")
                .frame(minWidth: 28, minHeight: 36)
            }.buttonStyle(.plain).accessibilityLabel("Ignore \(f.name)")
            columnTitle(f)
            Spacer(minLength: 0)
            if f.groups.count > 1 {
              Menu {
                ForEach(f.groups, id: \.self) { group in
                  Button {
                    store.setViewColumn(f.field, included: true, group: group)
                  } label: {
                    if view.columns.first(where: { $0.field == f.field })?.group == group {
                      Label(erGroupTitle(group), systemImage: "checkmark")
                    } else { Text(erGroupTitle(group)) }
                  }
                }
              } label: {
                Image(systemName: "chevron.down").frame(minWidth: 24, minHeight: 36)
              }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Group \(f.name)")
            }
          } else {
            Button { store.setViewColumn(f.field, included: true) } label: {
              columnTitle(f).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            }.buttonStyle(.plain).accessibilityLabel("Include \(f.name)")
          }
        }.padding(.horizontal, 10).padding(.vertical, 4)
          .background(RoundedRectangle(cornerRadius: 10).fill(included ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08)))
          .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
          .disabled(!store.editable)
      }
    }
  }
  private func columnTitle(_ f: ERViewAvailableColumn) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(f.name).fontWeight(.medium).lineLimit(2)
      if let c = view.columns.first(where: { $0.field == f.field }), c.group != "none" {
        Text(erGroupTitle(c.group)).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

private struct ERCheckDraft: Identifiable {
  let id = UUID()
  var table: Int
  var field: Int? = nil
  var constraint: Int? = nil
  var name = ""
  var expression = ""
}

private struct ERCheckEditor: View {
  @ObservedObject var store: ERStore
  @State var draft: ERCheckDraft
  @Environment(\.dismiss) private var dismiss
  private var table: ERTable? { store.graph.tables.first { $0.id == draft.table } }
  private var syntaxError: String? { store.checkValidation(draft.expression, table: draft.table) }
  private var nameError: String? {
    guard draft.field == nil else { return nil }
    if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Enter a constraint name."
    }
    if draft.name.utf8.count > 128
      || draft.name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    {
      return "Use a name of at most 128 UTF-8 bytes without control characters."
    }
    if table?.constraints.contains(where: {
      $0.id != draft.constraint && $0.name.lowercased() == draft.name.lowercased()
    }) == true {
      return "This table already has a constraint with that name."
    }
    return nil
  }
  var body: some View {
    #if os(iOS)
      NavigationStack {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) { inputs }.padding(20)
        }
        .navigationTitle(draft.field == nil ? "Table constraint" : "Field CHECK")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Apply", action: apply).disabled(!canApply)
          }
        }
      }
    #else
      VStack(alignment: .leading, spacing: 16) {
        Text(draft.field == nil ? "Named table constraint" : "Field CHECK expression").font(.title2)
          .bold()
        inputs
        HStack {
          Spacer()
          Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
          Button("Apply", action: apply).keyboardShortcut(.defaultAction).disabled(!canApply)
        }
      }.padding(20).frame(width: 490)
    #endif
  }
  @ViewBuilder private var inputs: some View {
    if draft.field == nil {
      Text("Constraint name").font(.caption).foregroundStyle(.secondary)
      TextField("Constraint name", text: $draft.name).textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("constraintName")
    }
    Text("Expression").font(.headline)
    ERCheckInput(text: $draft.expression)
      .frame(minHeight: 120, maxHeight: 200)
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.5)))
    Text("Enter only the expression, without CHECK(...). Quote field names with double quotes.")
      .font(.caption).foregroundStyle(.secondary)
    if let table {
      Text(
        "Fields: "
          + (["id"]
          + table.dataFields.map {
            "\"" + $0.name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
          }).joined(separator: ", ")
      )
      .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
    }
    if let error = syntaxError ?? nameError {
      Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier(
        "checkValidationError")
    } else {
      Label("Valid CHECK syntax", systemImage: "checkmark.circle.fill")
        .font(.caption).foregroundStyle(.green)
    }
  }
  private var canApply: Bool {
    syntaxError == nil && nameError == nil && store.editable && !store.locked
  }
  private func apply() {
    guard canApply else { return }
    store.error = nil
    if let field = draft.field {
      store.command("update_field", ["table": draft.table, "id": field, "check": draft.expression])
    } else {
      var properties: [String: Any] = [
        "table": draft.table, "name": draft.name, "expression": draft.expression,
      ]
      if let id = draft.constraint { properties["id"] = id }
      store.command(draft.constraint == nil ? "add_constraint" : "update_constraint", properties)
    }
    if store.error == nil { dismiss() }
  }
}

private struct ERCanvasSurface: View {
  @ObservedObject var store: ERStore
  @FocusState private var canvasFocused: Bool
  @State private var dragStart: CGPoint?
  @State private var moving: Int?
  @State private var startedConnection = false
  @State private var preview: CGPoint?
  @State private var initialView = ERViewport()
  @State private var linkPreview: CGPoint?
  @State private var pinchStart: ERViewport?
  @State private var pinchAnchor = CGPoint.zero
  private let width = 320.0
  private var canDelete: Bool {
    store.editable && (store.dataView != nil || (!store.locked && (store.table != nil || store.edge != nil)))
  }
  private var scale: Double { store.viewport.zoom * store.viewport.calibration }
  private var tables: [ERTable] {
    store.graph.nodes.map { t in
      var t = t
      if t.id == moving, let preview {
        t.x = preview.x
        t.y = preview.y
      }
      return t
    }
  }
  private var extent: CGSize {
    CGSize(
      width: (tables.map { $0.x + width + 40 }.max() ?? 0),
      height: (tables.map { $0.y + $0.height + 80 }.max() ?? 0))
  }
  var body: some View {
    GeometryReader { outer in
      VStack(spacing: 0) {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 14) {
            Menu {
              Button("Table", systemImage: "tablecells") { store.addTable() }
                .disabled(store.locked)
              Button("Connection", systemImage: "arrow.triangle.branch") { store.beginConnection() }
                .disabled(store.locked || store.table == nil)
              Button("View", systemImage: "rectangle.on.rectangle") { store.addDataView() }
            } label: {
              Label("Create", systemImage: "plus")
            }.buttonStyle(.borderedProminent).disabled(!store.editable)
              .accessibilityLabel("Create")
            Menu {
              Button("Fit to Window", systemImage: "arrow.up.left.and.arrow.down.right") {
                fit(outer.size)
              }
              Divider()
              ForEach([25, 50, 75, 100, 125, 150, 175, 200], id: \.self) { percent in
                Button {
                  store.view(
                    store.viewport.zoomed(
                      to: Double(percent) / 100,
                      at: CGPoint(x: outer.size.width / 2, y: max(0, outer.size.height - 48) / 2)))
                } label: {
                  if abs(store.viewport.zoom * 100 - Double(percent)) < 0.001 {
                    Label("\(percent)%", systemImage: "checkmark")
                  } else {
                    Text("\(percent)%")
                  }
                }
              }
            } label: {
              Label(store.viewport.zoomLabel, systemImage: "chevron.down")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Zoom")
            .accessibilityValue(store.viewport.zoomLabel)
            #if os(iOS)
              Menu {
                Button("Undo", systemImage: "arrow.uturn.backward") { store.command("undo") }
                  .disabled(!store.graph.canUndo || !store.editable)
                Button("Redo", systemImage: "arrow.uturn.forward") { store.command("redo") }
                  .disabled(!store.graph.canRedo || !store.editable)
                Divider()
                Button("Copy", systemImage: "doc.on.doc", action: store.copy).disabled(
                  store.table == nil)
                Button("Cut", systemImage: "scissors", action: store.cut)
                  .disabled(store.table == nil || store.locked || !store.editable)
                Button("Paste", systemImage: "doc.on.clipboard", action: store.paste)
                  .disabled(store.locked || !store.editable)
                Button("Duplicate", systemImage: "plus.square.on.square", action: store.duplicate)
                  .disabled(store.table == nil || store.locked || !store.editable)
                Divider()
                Button(
                  "Delete", systemImage: "trash", role: .destructive, action: store.deleteSelection
                )
                .disabled(
                  (store.table == nil && store.edge == nil && store.dataView == nil)
                    || (store.locked && store.dataView == nil) || !store.editable)
              } label: {
                Label("Edit", systemImage: "ellipsis").labelStyle(.iconOnly)
              }
              .buttonStyle(.bordered)
            #endif
            if store.pendingSource != nil {
              Button("Cancel link") {
                store.pendingSource = nil
                linkPreview = nil
              }
            }
          }.buttonStyle(.bordered).padding(10)
        }
        Divider()
        HStack(spacing: 0) {
          GeometryReader { geo in
            Canvas { ctx, size in draw(&ctx, size: size) }
              .onAppear { store.canvasSize = geo.size }
              .onChange(of: geo.size) { size in store.canvasSize = size }
              .background(Color.primary.opacity(0.035))
              #if os(macOS)
                .background(
                  ERWheelHandler { dx, dy, zooming in
                    if zooming {
                      store.zoom(exp(dy * 0.005))
                    } else {
                      var v = store.viewport
                      v.panX -= dx / scale
                      v.panY -= dy / scale
                      store.view(v)
                    }
                  })
              #endif
              .contentShape(Rectangle())
              #if os(iOS)
                .overlay(ERCanvasTouchInput(drag: drag, end: end, cancel: cancelDrag, pinch: pinch))
              #else
                .focusable().focused($canvasFocused)
                .onAppear { canvasFocused = true }
                .onDeleteCommand(perform: canDelete ? { store.deleteSelection() } : nil)
                .onCopyCommand(perform: store.table == nil ? nil : { store.clipboardProviders() })
                .onCutCommand(
                  perform: store.table == nil || !store.editable || store.locked
                    ? nil : { store.clipboardProviders(cutting: true) }
                )
                .onPasteCommand(
                  of: ["public.utf8-plain-text"],
                  validator: { _ in
                    store.editable && !store.locked && store.canPasteTable ? true : nil
                  }, perform: { _ in store.paste() }
                )
                .gesture(
                  DragGesture(minimumDistance: 0)
                    .onChanged { drag(start: $0.startLocation, location: $0.location) }
                    .onEnded { end(start: $0.startLocation, location: $0.location) }
                )
                .simultaneousGesture(
                  MagnificationGesture().onChanged { factor in
                    if pinchStart == nil {
                      cancelDrag()
                      pinchStart = store.viewport
                      pinchAnchor = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                    if let start = pinchStart {
                      store.view(start.zoomed(to: start.zoom * factor, at: pinchAnchor))
                    }
                  }.onEnded { _ in pinchStart = nil })
              #endif
              .overlay(alignment: .bottomLeading) {
                if store.graph.nodes.isEmpty {
                  Text(
                    "Add a table to start your data model\nDrag the background to pan • Choose a zoom percentage or pinch"
                  )
                  .foregroundStyle(.secondary).padding(24).allowsHitTesting(false)
                } else if store.pendingSource != nil {
                  Text("Choose a table to complete the relationship").font(.caption).padding(8)
                    .background(.regularMaterial).allowsHitTesting(false)
                }
              }
            if extent.height * scale > geo.size.height || store.viewport.panY != 0 {
              ERScrollbar(
                value: Binding(
                  get: { store.viewport.panY },
                  set: { y in
                    var v = store.viewport
                    v.panY = y
                    store.view(v)
                  }),
                extent: max(
                  extent.height,
                  max(geo.size.height / scale, geo.size.height / scale + store.viewport.panY))
                  - min(0, store.viewport.panY),
                viewport: geo.size.height / scale, vertical: true,
                origin: min(0, store.viewport.panY)
              )
              .frame(width: 14).frame(maxWidth: .infinity, alignment: .trailing)
            }
          }
        }
        if extent.width * scale > outer.size.width || store.viewport.panX != 0 {
          ERScrollbar(
            value: Binding(
              get: { store.viewport.panX },
              set: { x in
                var v = store.viewport
                v.panX = x
                store.view(v)
              }),
            extent: max(
              extent.width,
              max(outer.size.width / scale, outer.size.width / scale + store.viewport.panX))
              - min(0, store.viewport.panX),
            viewport: outer.size.width / scale, vertical: false,
            origin: min(0, store.viewport.panX)
          ).frame(height: 14)
        }
      }
    }
  }
  private func point(_ p: CGPoint) -> CGPoint {
    CGPoint(x: p.x / scale + store.viewport.panX, y: p.y / scale + store.viewport.panY)
  }
  private func screen(_ p: CGPoint) -> CGPoint {
    CGPoint(x: (p.x - store.viewport.panX) * scale, y: (p.y - store.viewport.panY) * scale)
  }
  private func port(_ table: ERTable, right: Bool) -> CGPoint {
    CGPoint(x: table.x + (right ? width : 0), y: table.y + 30)
  }
  private func hitPort(_ p: CGPoint, right: Bool) -> Int? {
    for t in tables.reversed() {
      if store.graph.views.contains(where: { $0.id == t.id }) { continue }
      let q = port(t, right: right)
      if hypot(p.x - q.x, p.y - q.y) < max(12, 14 / scale) { return t.id }
    }
    return nil
  }
  private func hitTarget(_ p: CGPoint) -> Int? {
    if let id = hitPort(p, right: false) { return id }
    return tables.reversed().first {
      CGRect(x: $0.x, y: $0.y, width: width, height: $0.height).contains(p)
    }?.id
  }
  private func route(_ e: EREdge) -> [CGPoint] {
    guard let a = tables.first(where: { $0.id == e.sourceTable }),
      let b = tables.first(where: { $0.id == e.destinationTable })
    else { return [] }
    let p = port(a, right: true)
    let q = port(b, right: false)
    let lane =
      store.graph.edges.filter {
        $0.sourceTable == e.sourceTable && $0.destinationTable == e.destinationTable
      }.firstIndex { $0.id == e.id } ?? 0
    if q.x > p.x + 50 && lane == 0 {
      let mid = (p.x + q.x) / 2
      return [p, CGPoint(x: mid, y: p.y), CGPoint(x: mid, y: q.y), q]
    }
    let bottom = max(a.y + a.height, b.y + b.height) + 40 + Double(lane) * 24
    return [
      p, CGPoint(x: p.x + 30, y: p.y), CGPoint(x: p.x + 30, y: bottom),
      CGPoint(x: q.x - 30, y: bottom), CGPoint(x: q.x - 30, y: q.y), q,
    ]
  }
  private func labelPoint(_ points: [CGPoint]) -> CGPoint? {
    guard
      let (a, b) = zip(points, points.dropFirst()).max(by: {
        hypot($0.0.x - $0.1.x, $0.0.y - $0.1.y) < hypot($1.0.x - $1.1.x, $1.0.y - $1.1.y)
      })
    else { return nil }
    return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 12)
  }
  private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
    let step = 32 * scale
    if step > 7 {
      let startX = (-store.viewport.panX * scale).truncatingRemainder(dividingBy: step)
      let startY = (-store.viewport.panY * scale).truncatingRemainder(dividingBy: step)
      for x in stride(from: startX, to: size.width, by: step) {
        for y in stride(from: startY, to: size.height, by: step) {
          ctx.fill(
            Path(ellipseIn: CGRect(x: x, y: y, width: 1.4, height: 1.4)),
            with: .color(.secondary.opacity(0.25)))
        }
      }
    }
    func line(_ points: [CGPoint], selected: Bool) {
      guard let first = points.first else { return }
      var path = Path()
      path.move(to: screen(first))
      for p in points.dropFirst() { path.addLine(to: screen(p)) }
      ctx.stroke(
        path, with: .color(selected ? .accentColor : .secondary), lineWidth: selected ? 3 : 1.6)
      if let last = points.last {
        let q = screen(last)
        var arrow = Path()
        arrow.move(to: CGPoint(x: q.x - 8, y: q.y - 5))
        arrow.addLine(to: q)
        arrow.addLine(to: CGPoint(x: q.x - 8, y: q.y + 5))
        ctx.stroke(arrow, with: .color(selected ? .accentColor : .secondary), lineWidth: 2)
      }
    }
    for e in store.graph.edges {
      let points = route(e)
      line(points, selected: e.id == store.selectedEdge)
      if let label = labelPoint(points) {
        ctx.draw(
          Text(e.many ? "1:N" : "1:1").font(.system(size: max(10, 13 * scale))).foregroundColor(
            e.id == store.selectedEdge ? .accentColor : .primary), at: screen(label))
      }
    }
    for t in tables {
      let p = screen(CGPoint(x: t.x, y: t.y))
      let rect = CGRect(x: p.x, y: p.y, width: width * scale, height: t.height * scale)
      let selected = t.id == store.selectedTable
      ctx.fill(Path(roundedRect: rect, cornerRadius: 8 * scale), with: .color(erColor(t.color)))
      ctx.stroke(
        Path(roundedRect: rect, cornerRadius: 8 * scale),
        with: .color(selected ? .accentColor : erColor(t.color)), lineWidth: selected ? 3 : 1)
      // Clip long names to the rectangle without changing the 100% type size.
      var title = ctx
      title.clip(
        to: Path(
          CGRect(x: p.x + 16 * scale, y: p.y, width: (width - 26) * scale, height: 60 * scale)))
      title.draw(
        Text(t.name).font(.system(size: 72 / 2.54 * scale, weight: .semibold)).foregroundColor(
          .white), at: CGPoint(x: p.x + 16 * scale, y: p.y + 30 * scale), anchor: .leading)
      if !store.graph.views.contains(where: { $0.id == t.id }) {
        circle(&ctx, port(t, right: false), selected: false)
        circle(&ctx, port(t, right: true), selected: store.pendingSource == t.id)
      }
    }
    if let source = store.pendingSource, let table = tables.first(where: { $0.id == source }),
      let linkPreview
    {
      line([port(table, right: true), linkPreview], selected: true)
    }
  }
  private func circle(_ ctx: inout GraphicsContext, _ center: CGPoint, selected: Bool) {
    let p = screen(center)
    let rect = CGRect(x: p.x - 6 * scale, y: p.y - 6 * scale, width: 12 * scale, height: 12 * scale)
    ctx.fill(Path(ellipseIn: rect), with: .color(selected ? .accentColor : .white))
    ctx.stroke(Path(ellipseIn: rect), with: .color(.blue), lineWidth: 1.6)
  }
  private func drag(start: CGPoint, location: CGPoint) {
    guard pinchStart == nil else { return }
    let translation = CGSize(width: location.x - start.x, height: location.y - start.y)
    let p = point(start)
    if dragStart == nil {
      #if os(macOS)
        canvasFocused = true
        store.editingText = false
      #endif
      store.interruptReveal()
      dragStart = p
      initialView = store.viewport
      if store.pendingSource != nil {
        // A toolbar action or a tap on the right circle armed the source table.
      } else if let source = hitPort(p, right: true), store.editable && !store.locked {
        store.select(table: source, details: false)
        store.beginConnection()
        startedConnection = true
      } else if let id = hitTarget(p), let t = tables.first(where: { $0.id == id }) {
        store.select(table: id, details: false)
        if store.editable {
          moving = id
          preview = CGPoint(x: t.x, y: t.y)
        }
      }
    }
    if let moving, let table = store.graph.nodes.first(where: { $0.id == moving }) {
      preview = CGPoint(
        x: min(100000, max(0, table.x + translation.width / scale)),
        y: min(100000, max(0, table.y + translation.height / scale)))
    } else if store.pendingSource != nil {
      linkPreview = point(location)
    } else if hypot(translation.width, translation.height) > 4 {
      var v = initialView
      v.panX = initialView.panX - translation.width / scale
      v.panY = initialView.panY - translation.height / scale
      store.view(v)
    }
  }
  private func end(start: CGPoint, location: CGPoint, tapCount: Int = 1) {
    guard pinchStart == nil else { return }
    let p = point(location)
    let tapped = hypot(location.x - start.x, location.y - start.y) < 5
    if let moving, let preview {
      if !tapped {
        let op = store.graph.views.contains(where: { $0.id == moving }) ? "move_data_view" : "move_table"
        store.command(op, ["id": moving, "x": preview.x, "y": preview.y])
      } else {
        selectCanvasTable(moving, tapCount: tapCount)
      }
    } else if store.pendingSource != nil {
      if !(startedConnection && tapped) {
        if let target = hitTarget(p) {
          store.connect(to: target)
        } else {
          store.pendingSource = nil
        }
      }
    } else if tapped, let target = hitTarget(p) {
      selectCanvasTable(target, tapCount: tapCount)
    } else if tapped {
      var hit: Int?
      for e in store.graph.edges.reversed() {
        let points = route(e)
        if let label = labelPoint(points) {
          let q = screen(label)
          if abs(location.x - q.x) <= max(22, 18 * scale)
            && abs(location.y - q.y) <= max(12, 10 * scale)
          {
            hit = e.id
            break
          }
        }
        for (a, b) in zip(points, points.dropFirst()) {
          let dx = b.x - a.x
          let dy = b.y - a.y
          let len = dx * dx + dy * dy
          let u = len == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len))
          if hypot(p.x - a.x - u * dx, p.y - a.y - u * dy) < 10 / scale {
            hit = e.id
            break
          }
        }
        if hit != nil { break }
      }
      store.select(edge: hit)
    }
    moving = nil
    startedConnection = false
    preview = nil
    dragStart = nil
    linkPreview = nil
  }
  private func selectCanvasTable(_ id: Int, tapCount: Int) {
    #if os(iOS)
      store.selectTableFromCanvas(id, tapCount: tapCount, compact: true)
    #else
      store.selectTableFromCanvas(id, tapCount: tapCount, compact: false)
    #endif
  }
  private func cancelDrag() {
    store.pendingSource = nil
    moving = nil
    startedConnection = false
    preview = nil
    dragStart = nil
    linkPreview = nil
  }
  #if os(iOS)
    private func pinch(_ state: UIGestureRecognizer.State, _ anchor: CGPoint, _ factor: CGFloat) {
      switch state {
      case .began:
        cancelDrag()
        pinchStart = store.viewport
        pinchAnchor = anchor
      case .changed, .ended:
        if let start = pinchStart {
          store.view(start.zoomed(to: start.zoom * factor, at: pinchAnchor))
        }
        if state == .ended { pinchStart = nil }
      case .cancelled, .failed:
        pinchStart = nil
      default: break
      }
    }
  #endif
  private func fit(_ size: CGSize) {
    guard let left = tables.map(\.x).min(), let top = tables.map(\.y).min(),
      let right = tables.map({ $0.x + width }).max(),
      let bottom = tables.map({ $0.y + $0.height }).max()
    else {
      store.view(ERViewport())
      return
    }
    var v = store.viewport
    v.zoom = min(
      4,
      max(
        0.0001,
        min((size.width - 70) / (right - left + 80), (size.height - 110) / (bottom - top + 80))
          / v.calibration))
    v.panX = max(0, left - 40)
    v.panY = max(0, top - 40)
    store.view(v)
  }
}

private struct ERScrollbar: View {
  @Binding var value: Double
  let extent: Double
  let viewport: Double
  let vertical: Bool
  var origin = 0.0
  var body: some View {
    GeometryReader { geo in
      let length = vertical ? geo.size.height : geo.size.width
      let thumb = min(length, max(24, length * viewport / max(extent, 1)))
      let offset = (length - thumb) * min(1, max(0, (value - origin) / max(1, extent - viewport)))
      ZStack(alignment: .topLeading) {
        Rectangle().fill(Color.secondary.opacity(0.12))
        Capsule().fill(Color.secondary.opacity(0.6))
          .frame(width: vertical ? 10 : thumb, height: vertical ? thumb : 10)
          .offset(x: vertical ? 2 : offset, y: vertical ? offset : 2)
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0).onChanged { d in
          let p = vertical ? d.location.y : d.location.x
          value =
            origin
            + min(
              max(0, extent - viewport),
              max(0, (p - thumb / 2) / max(1, length - thumb) * (extent - viewport)))
        })
    }
    .accessibilityElement().accessibilityLabel(
      vertical ? "Vertical canvas scrollbar" : "Horizontal canvas scrollbar"
    )
    .accessibilityValue("\(Int(value))")
    .accessibilityAdjustableAction { direction in
      value = min(
        origin + max(0, extent - viewport),
        max(origin, value + (direction == .increment ? 40 : -40)))
    }
  }
}

#if os(macOS)
  private struct ERWheelHandler: NSViewRepresentable {
    let scroll: (Double, Double, Bool) -> Void
    final class WheelView: NSView {
      var monitor: Any?
      var scroll: ((Double, Double, Bool) -> Void)?
      override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> WheelView {
      let view = WheelView()
      view.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak view] event in
        guard let view, event.window === view.window,
          view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        else { return event }
        view.scroll?(
          Double(event.scrollingDeltaX), Double(event.scrollingDeltaY),
          event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control))
        return nil
      }
      return view
    }
    func updateNSView(_ view: WheelView, context: Context) { view.scroll = scroll }
    static func dismantleNSView(_ view: WheelView, coordinator: ()) {
      if let monitor = view.monitor { NSEvent.removeMonitor(monitor) }
      view.monitor = nil
    }
  }
#endif

#if os(macOS)
  struct ERCommands: Commands {
    @FocusedObject private var store: ERStore?
    private var schemaEditable: Bool { store?.editable == true && store?.locked == false }
    private var textEditor: NSTextView? {
      // Observe selection changes as well as focus/drafts for native menu validation.
      _ = store?.textSelectionVersion
      // Native Open/Save panels also have text editors, outside the inspector.
      return NSApp.keyWindow?.firstResponder as? NSTextView
    }
    private var textEditing: Bool { textEditor != nil || NSApp.modalWindow != nil }
    private func textEnabled(_ name: String) -> Bool {
      let item = NSMenuItem(title: "", action: Selector(name), keyEquivalent: "")
      guard let target = NSApp.target(forAction: Selector(name)) else { return false }
      if let validator = target as? NSMenuItemValidation { return validator.validateMenuItem(item) }
      if let validator = target as? NSUserInterfaceValidations {
        return validator.validateUserInterfaceItem(item)
      }
      return true
    }
    private func textAction(_ name: String) { NSApp.sendAction(Selector(name), to: nil, from: nil) }
    var body: some Commands {
      if store != nil {
        CommandGroup(replacing: .undoRedo) {
          Button("Undo") {
            if textEditing { textAction("undo:") } else { store?.command("undo") }
          }
          .keyboardShortcut("z", modifiers: .command)
          .disabled(
            textEditing
              ? !textEnabled("undo:") : store?.graph.canUndo != true || store?.editable != true)
          Button("Redo") {
            if textEditing { textAction("redo:") } else { store?.command("redo") }
          }
          .keyboardShortcut("z", modifiers: [.command, .shift])
          .disabled(
            textEditing
              ? !textEnabled("redo:") : store?.graph.canRedo != true || store?.editable != true)
        }
      }
      CommandGroup(after: .pasteboard) {
        Divider()
        Button("Duplicate") { store?.duplicate() }
          .keyboardShortcut("d", modifiers: .command)
          .disabled(!schemaEditable || store?.table == nil)

      }
      CommandMenu("Model") {
        Menu("Create") {
          Button("Table") { store?.addTable() }
            .keyboardShortcut("t", modifiers: [.command, .shift]).disabled(!schemaEditable)
          Button("Connection") { store?.beginConnection() }.disabled(!schemaEditable || store?.table == nil)
          Button("View") { store?.addDataView() }.disabled(store?.editable != true)
        }
      }
    }
  }
#endif
