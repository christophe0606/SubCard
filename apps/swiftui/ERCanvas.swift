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
            ERInspector(store: store).navigationTitle("Details")
          }
      #endif
    }
    #if os(macOS)
      .focusedSceneValue(\.erActions, ERFocusedActions(store: store))
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
      if detach { store?.document = nil }
    }
  }
}

private struct ERInspector: View {
  @ObservedObject var store: ERStore
  private enum Editing: Hashable { case table, field }
  @FocusState private var editing: Editing?
  private let colors = ["#397DB8", "#7651A8", "#258775", "#BA6B28", "#B64762", "#556275"]
  private var schemaEditable: Bool { store.editable && !store.locked }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Model details").font(.title2).bold()
        if let t = store.table {
          Text(t.name).font(.headline).accessibilityIdentifier("modelTableName")
          TextField("Table name", text: $store.tableNameDraft)
            .textFieldStyle(.roundedBorder).focused($editing, equals: .table)
            .submitLabel(.done).onSubmit { finishEditing() }.disabled(!schemaEditable)
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
          Text("Every table has an implicit id primary key (auto increment integer).")
            .font(.caption).foregroundStyle(.secondary)
          Divider()
          HStack {
            Text("Fields").font(.headline)
            Spacer()
            Menu {
              Button("Index", systemImage: "key") { addField("index") }
              Button("Connection", systemImage: "arrow.triangle.branch") { addField("secondary") }
            } label: {
              Label("Add field", systemImage: "plus")
            }
            .disabled(!schemaEditable)
          }
          if t.fields.isEmpty {
            Text("Add an index or a connection.").foregroundStyle(.secondary)
          }
          ForEach(t.fields) { f in
            Button {
              finishEditing()
              store.select(table: t.id, field: f.id)
            } label: {
              HStack(alignment: .top) {
                Image(systemName: f.kind == "index" ? "key" : "arrow.triangle.branch")
                VStack(alignment: .leading, spacing: 3) {
                  Text(f.name).foregroundStyle(.primary)
                  Text(
                    f.kind == "index"
                      ? (f.unique ? "Index • unique" : "Index") : "Connection • foreign key"
                  )
                  .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.selectedField == f.id { Image(systemName: "checkmark") }
              }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(
                  store.selectedField == f.id ? Color.accentColor.opacity(0.12) : Color.clear
                )
                .cornerRadius(6)
            }.buttonStyle(.plain)
          }
          if let f = store.field {
            Divider()
            TextField("Field name", text: $store.fieldNameDraft)
              .textFieldStyle(.roundedBorder).focused($editing, equals: .field)
              .submitLabel(.done).onSubmit { finishEditing() }.disabled(!schemaEditable)
            if f.kind == "secondary" {
              Text("Connection (foreign key)").font(.caption).foregroundStyle(.secondary)
              if let e = store.graph.edges.first(where: { $0.field == f.id }) {
                Text("Destination").font(.headline)
                Text(store.destination(e)).textSelection(.enabled)
                connectionProperties(e)
                Button("Disconnect", role: .destructive) {
                  finishEditing()
                  store.command("delete_connection", ["id": e.id])
                }.disabled(!schemaEditable)
              } else {
                Text("Not connected").foregroundStyle(.secondary)
                Text(
                  "On the canvas, drag this field’s right circle to a table’s left circle or an index’s left circle."
                )
                .font(.caption)
              }
            } else {
              Toggle(
                "Unique",
                isOn: Binding(
                  get: { f.unique },
                  set: { unique in
                    finishEditing()
                    store.command(
                      "update_index",
                      [
                        "table": t.id, "id": f.id,
                        "name": store.field?.name ?? f.name, "unique": unique,
                      ])
                  })
              ).disabled(
                !schemaEditable || store.graph.edges.contains(where: { $0.targetField == f.id }))
              Text("Unique values identify one record and can be a connection destination.").font(
                .caption)
              if store.graph.edges.contains(where: { $0.targetField == f.id }) {
                Text("Disconnect incoming connections before turning Unique off.").font(.caption)
              }
            }
            Button("Delete field", role: .destructive) {
              finishEditing()
              store.command("delete_index", ["table": t.id, "id": f.id])
            }.disabled(!schemaEditable)
          }
          Divider()
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
        } else {
          Text("Select a table, field, or connection to edit its properties.").foregroundStyle(
            .secondary)
          Text(
            "Drag a table header to move it. Drag a connection’s right circle to a primary key or index’s left circle."
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
        if store.locked { Text("Schema locked: this document has held real data.").font(.caption) }
      }.padding()
    }
    .buttonStyle(.bordered)
    .onChange(of: editing) { _ in store.commitNames() }
    .onDisappear { finishEditing() }
  }
  private func finishEditing() {
    store.commitNames()
    editing = nil
  }
  private func addField(_ kind: String) {
    finishEditing()
    store.addField(kind)
    editing = .field
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
          "Deleting target",
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

private struct ERCanvasSurface: View {
  @ObservedObject var store: ERStore
  @State private var dragStart: CGPoint?
  @State private var moving: Int?
  @State private var tappedTable: Int?
  @State private var tappedField: Int?
  @State private var preview: CGPoint?
  @State private var initialView = ERViewport()
  @State private var pending: (Int, Int)?
  @State private var linkPreview: CGPoint?
  @State private var pinchStart: ERViewport?
  @State private var pinchAnchor = CGPoint.zero
  private let width = 320.0
  private var scale: Double { store.graph.view.zoom * store.graph.view.calibration }
  private var tables: [ERTable] {
    store.graph.tables.map { t in
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
            Button(action: store.addTable) { Label("Table", systemImage: "plus") }
              .buttonStyle(.borderedProminent)
              .accessibilityLabel("Add table")
              .disabled(!store.editable || store.locked)
            Button {
              store.addField("secondary", details: false)
            } label: {
              Label("Connection", systemImage: "arrow.triangle.branch")
            }.disabled(!store.editable || store.locked || store.table == nil)
              .accessibilityLabel("Add connection to selected table")
            Menu {
              Button("Fit to Window", systemImage: "arrow.up.left.and.arrow.down.right") {
                fit(outer.size)
              }
              Divider()
              ForEach([25, 50, 75, 100, 125, 150, 175, 200], id: \.self) { percent in
                Button {
                  store.view(
                    store.graph.view.zoomed(
                      to: Double(percent) / 100,
                      at: CGPoint(x: outer.size.width / 2, y: max(0, outer.size.height - 48) / 2)))
                } label: {
                  if abs(store.graph.view.zoom * 100 - Double(percent)) < 0.001 {
                    Label("\(percent)%", systemImage: "checkmark")
                  } else {
                    Text("\(percent)%")
                  }
                }
              }
            } label: {
              Label(store.graph.view.zoomLabel, systemImage: "chevron.down")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Zoom")
            .accessibilityValue(store.graph.view.zoomLabel)
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
                  (store.table == nil && store.edge == nil) || store.locked || !store.editable)
              } label: {
                Label("Edit", systemImage: "ellipsis").labelStyle(.iconOnly)
              }
              .buttonStyle(.bordered)
            #else
              Button("Undo") { store.command("undo") }.disabled(
                !store.graph.canUndo || !store.editable)
              Button("Redo") { store.command("redo") }.disabled(
                !store.graph.canRedo || !store.editable)
              Button("Paste", action: store.paste).disabled(store.locked || !store.editable)
            #endif
            if pending != nil {
              Button("Cancel link") {
                pending = nil
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
                      var v = store.graph.view
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
                .gesture(
                  DragGesture(minimumDistance: 0)
                    .onChanged { drag(start: $0.startLocation, location: $0.location) }
                    .onEnded { end(start: $0.startLocation, location: $0.location) }
                )
                .simultaneousGesture(
                  MagnificationGesture().onChanged { factor in
                    if pinchStart == nil {
                      cancelDrag()
                      pinchStart = store.graph.view
                      pinchAnchor = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                    if let start = pinchStart {
                      store.view(start.zoomed(to: start.zoom * factor, at: pinchAnchor))
                    }
                  }.onEnded { _ in pinchStart = nil })
              #endif
              .overlay(alignment: .bottomLeading) {
                if store.graph.tables.isEmpty {
                  Text(
                    "Add a table to start your data model\nDrag the background to pan • Choose a zoom percentage or pinch"
                  )
                  .foregroundStyle(.secondary).padding(24).allowsHitTesting(false)
                } else if pending != nil {
                  Text("Choose a left circle to complete the connection").font(.caption).padding(8)
                    .background(.regularMaterial).allowsHitTesting(false)
                }
              }
            if extent.height * scale > geo.size.height || store.graph.view.panY != 0 {
              ERScrollbar(
                value: Binding(
                  get: { store.graph.view.panY },
                  set: { y in
                    var v = store.graph.view
                    v.panY = y
                    store.view(v)
                  }),
                extent: max(
                  extent.height,
                  max(geo.size.height / scale, geo.size.height / scale + store.graph.view.panY))
                  - min(0, store.graph.view.panY),
                viewport: geo.size.height / scale, vertical: true,
                origin: min(0, store.graph.view.panY)
              )
              .frame(width: 14).frame(maxWidth: .infinity, alignment: .trailing)
            }
          }
        }
        if extent.width * scale > outer.size.width || store.graph.view.panX != 0 {
          ERScrollbar(
            value: Binding(
              get: { store.graph.view.panX },
              set: { x in
                var v = store.graph.view
                v.panX = x
                store.view(v)
              }),
            extent: max(
              extent.width,
              max(outer.size.width / scale, outer.size.width / scale + store.graph.view.panX))
              - min(0, store.graph.view.panX),
            viewport: outer.size.width / scale, vertical: false,
            origin: min(0, store.graph.view.panX)
          ).frame(height: 14)
        }
      }
    }
  }
  private func point(_ p: CGPoint) -> CGPoint {
    CGPoint(x: p.x / scale + store.graph.view.panX, y: p.y / scale + store.graph.view.panY)
  }
  private func screen(_ p: CGPoint) -> CGPoint {
    CGPoint(x: (p.x - store.graph.view.panX) * scale, y: (p.y - store.graph.view.panY) * scale)
  }
  private func port(_ table: ERTable, _ field: Int, right: Bool) -> CGPoint {
    let y = field == 0 ? 30 : 80 + Double(table.fields.firstIndex { $0.id == field } ?? 0) * 32
    return CGPoint(x: table.x + (right ? width : 0), y: table.y + y)
  }
  private func hitPort(_ p: CGPoint, right: Bool) -> (Int, Int)? {
    for t in tables.reversed() {
      let fields =
        t.fields.filter { $0.kind == (right ? "secondary" : "index") && (right || $0.unique) }.map(
          \.id)
        + (right ? [] : [0])
      for f in fields {
        let q = port(t, f, right: right)
        if hypot(p.x - q.x, p.y - q.y) < max(12, 14 / scale) { return (t.id, f) }
      }
    }
    return nil
  }
  private func hitTarget(_ p: CGPoint) -> (Int, Int)? {
    if let port = hitPort(p, right: false) { return port }
    for t in tables.reversed() where p.x >= t.x && p.x <= t.x + width {
      if p.y >= t.y && p.y < t.y + 60 { return (t.id, 0) }
      let row = Int(floor((p.y - t.y - 64) / 32))
      if row >= 0 && row < t.fields.count {
        let f = t.fields[row]
        if f.kind == "index" && f.unique { return (t.id, f.id) }
      }
    }
    return nil
  }
  private func route(_ e: EREdge) -> [CGPoint] {
    guard let a = tables.first(where: { $0.id == e.table }),
      let b = tables.first(where: { $0.id == e.target })
    else { return [] }
    let p = port(a, e.field, right: true)
    let q = port(b, e.targetField, right: false)
    if q.x > p.x + 50 {
      let mid = (p.x + q.x) / 2
      return [p, CGPoint(x: mid, y: p.y), CGPoint(x: mid, y: q.y), q]
    }
    let bottom = max(a.y + a.height, b.y + b.height) + 40
    return [
      p, CGPoint(x: p.x + 30, y: p.y), CGPoint(x: p.x + 30, y: bottom),
      CGPoint(x: q.x - 30, y: bottom), CGPoint(x: q.x - 30, y: q.y), q,
    ]
  }
  private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
    let step = 32 * scale
    if step > 7 {
      let startX = (-store.graph.view.panX * scale).truncatingRemainder(dividingBy: step)
      let startY = (-store.graph.view.panY * scale).truncatingRemainder(dividingBy: step)
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
      if points.count > 1 {
        let pairs = zip(points, points.dropFirst())
        let segment = pairs.max {
          hypot($0.0.x - $0.1.x, $0.0.y - $0.1.y) < hypot($1.0.x - $1.1.x, $1.0.y - $1.1.y)
        }
        if let (a, b) = segment {
          ctx.draw(
            Text(e.many ? "1:N" : "1:1").font(.system(size: max(10, 13 * scale))).foregroundColor(
              e.id == store.selectedEdge ? .accentColor : .primary),
            at: screen(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - 12)))
        }
      }
    }
    for t in tables {
      let p = screen(CGPoint(x: t.x, y: t.y))
      let rect = CGRect(x: p.x, y: p.y, width: width * scale, height: t.height * scale)
      let selected = t.id == store.selectedTable
      ctx.fill(Path(roundedRect: rect, cornerRadius: 8 * scale), with: .color(Color(white: 0.97)))
      ctx.fill(
        Path(CGRect(x: p.x, y: p.y, width: width * scale, height: 60 * scale)),
        with: .color(erColor(t.color)))
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
      circle(&ctx, port(t, 0, right: false), selected: false)
      for f in t.fields {
        let center = port(t, f.id, right: f.kind == "secondary")
        let fieldSelected = selected && store.selectedField == f.id
        if fieldSelected {
          ctx.fill(
            Path(
              CGRect(
                x: p.x + scale, y: screen(center).y - 16 * scale,
                width: (width - 2) * scale, height: 32 * scale)),
            with: .color(.accentColor.opacity(0.15)))
        }
        var row = ctx
        row.clip(
          to: Path(
            CGRect(
              x: p.x + 14 * scale, y: screen(center).y - 16 * scale, width: (width - 28) * scale,
              height: 32 * scale)))
        row.draw(
          Text(f.name).font(.system(size: 15 * scale)).foregroundColor(.black),
          at: CGPoint(x: p.x + 15 * scale, y: screen(center).y), anchor: .leading)
        circle(&ctx, center, selected: fieldSelected || (pending?.0 == t.id && pending?.1 == f.id))
      }
    }
    if let pending, let table = tables.first(where: { $0.id == pending.0 }), let linkPreview {
      line([port(table, pending.1, right: true), linkPreview], selected: true)
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
      dragStart = p
      initialView = store.graph.view
      if let source = hitPort(p, right: true), store.editable && !store.locked {
        pending = source
        tappedTable = source.0
        tappedField = source.1
        store.select(table: source.0, field: source.1, details: false)
      } else if pending == nil || hitPort(p, right: false) == nil,
        let t = tables.reversed().first(where: {
          CGRect(x: $0.x, y: $0.y, width: width, height: $0.height).contains(p)
        })
      {
        tappedTable = t.id
        let row = Int(floor((p.y - t.y - 64) / 32))
        if row >= 0 && row < t.fields.count {
          let f = t.fields[row]
          tappedField = f.id
          store.select(table: t.id, field: f.id, details: false)
          if f.kind == "secondary" && store.editable && !store.locked { pending = (t.id, f.id) }
        } else {
          store.select(table: t.id, details: false)
        }
        if tappedField == nil && store.editable {
          moving = t.id
          preview = CGPoint(x: t.x, y: t.y)
        }
      }
    }
    if let moving, let table = store.graph.tables.first(where: { $0.id == moving }) {
      preview = CGPoint(
        x: min(100000, max(0, table.x + translation.width / scale)),
        y: min(100000, max(0, table.y + translation.height / scale)))
    } else if pending != nil {
      linkPreview = point(location)
    } else if hypot(translation.width, translation.height) > 4 {
      var v = initialView
      v.panX = initialView.panX - translation.width / scale
      v.panY = initialView.panY - translation.height / scale
      store.view(v)
    }
  }
  private func end(start: CGPoint, location: CGPoint) {
    guard pinchStart == nil else { return }
    let translation = CGSize(width: location.x - start.x, height: location.y - start.y)
    let p = point(location)
    let tapped = hypot(translation.width, translation.height) < 5
    if let moving, let preview {
      if !tapped {
        store.command("move_table", ["id": moving, "x": preview.x, "y": preview.y])
      } else {
        store.select(table: moving)
      }
    } else if let tappedTable, tapped {
      store.select(table: tappedTable, field: tappedField)
    } else if let pending, let target = hitTarget(p) {
      store.command(
        "connect",
        ["table": pending.0, "field": pending.1, "target": target.0, "targetField": target.1])
      self.pending = nil
      linkPreview = nil
    } else if tapped && hitPort(p, right: true) == nil && hitPort(p, right: false) == nil {
      var hit: Int?
      for e in store.graph.edges.reversed() {
        let points = route(e)
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
    pending = nil
    cancelDrag()
  }
  private func cancelDrag() {
    pending = nil
    moving = nil
    tappedTable = nil
    tappedField = nil
    preview = nil
    dragStart = nil
    linkPreview = nil
  }
  #if os(iOS)
    private func pinch(_ state: UIGestureRecognizer.State, _ anchor: CGPoint, _ factor: CGFloat) {
      switch state {
      case .began:
        cancelDrag()
        pinchStart = store.graph.view
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
    var v = store.graph.view
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
  struct ERFocusedActions {
    let store: ERStore
  }
  private struct ERActionKey: FocusedValueKey { typealias Value = ERFocusedActions }
  extension FocusedValues {
    var erActions: ERFocusedActions? {
      get { self[ERActionKey.self] }
      set { self[ERActionKey.self] = newValue }
    }
  }
  struct ERCommands: Commands {
    @FocusedValue(\.erActions) private var actions
    var body: some Commands {
      CommandGroup(replacing: .undoRedo) {
        Button("Undo model change") { actions?.store.command("undo") }
          .keyboardShortcut("z", modifiers: .command)
          .disabled(actions?.store.graph.canUndo != true || actions?.store.editable != true)
        Button("Redo model change") { actions?.store.command("redo") }
          .keyboardShortcut("z", modifiers: [.command, .shift])
          .disabled(actions?.store.graph.canRedo != true || actions?.store.editable != true)
      }
      CommandMenu("Model") {
        Button("Add table") { actions?.store.addTable() }.keyboardShortcut(
          "t", modifiers: [.command, .shift]
        )
        .disabled(actions?.store.editable != true || actions?.store.locked != false)
        Button("Copy table") { actions?.store.copy() }.keyboardShortcut(
          "c", modifiers: [.command, .shift]
        )
        .disabled(actions?.store.table == nil)
        Button("Paste table") { actions?.store.paste() }.keyboardShortcut(
          "v", modifiers: [.command, .shift]
        )
        .disabled(actions?.store.editable != true || actions?.store.locked != false)
        Button("Duplicate table") { actions?.store.duplicate() }.keyboardShortcut(
          "d", modifiers: .command
        )
        .disabled(
          actions?.store.table == nil || actions?.store.editable != true
            || actions?.store.locked != false)
        Button("Delete selected object") { actions?.store.deleteSelection() }
          .disabled(
            (actions?.store.table == nil && actions?.store.edge == nil)
              || actions?.store.editable != true || actions?.store.locked != false)
      }
    }
  }
#endif
