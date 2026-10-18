// SPDX-License-Identifier: Apache-2.0
use crate::{SubCardView, text_input::TextInput};
use gpui::{prelude::*, *};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
    time::{Duration, Instant},
};

fn default_unique() -> bool {
    true
}
fn default_nullable() -> bool {
    true
}

const DATATYPES: [(&str, &str); 10] = [
    ("string", "String"),
    ("url", "URL"),
    ("date", "Date"),
    ("time", "Time"),
    ("datetime", "Date-time"),
    ("decimal", "Binary coded decimal (BCD)"),
    ("float", "Float"),
    ("integer", "Integer"),
    ("boolean", "Boolean"),
    ("blob", "Blob"),
];
fn default_media() -> String {
    "binary".into()
}
fn default_scale() -> u32 {
    2
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Field {
    pub id: i32,
    pub name: String,
    pub kind: String,
    #[serde(default = "default_unique")]
    pub unique: bool,
    #[serde(default)]
    pub indexed: bool,
    #[serde(default = "default_nullable")]
    pub nullable: bool,
    #[serde(default = "default_media")]
    pub media: String,
    #[serde(default = "default_scale")]
    pub scale: u32,
    #[serde(default)]
    pub check: String,
    #[serde(default, rename = "checkDisplay")]
    pub check_display: String,
}
impl Field {
    fn ordinary(&self) -> bool {
        DATATYPES.iter().any(|(kind, _)| *kind == self.kind)
    }
    fn title(&self) -> &str {
        DATATYPES
            .iter()
            .find(|(kind, _)| *kind == self.kind)
            .map(|(_, title)| *title)
            .unwrap_or(&self.kind)
    }
    fn indexable(&self) -> bool {
        self.ordinary() && self.kind != "blob" && self.kind != "decimal"
    }
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Constraint {
    pub id: i32,
    pub name: String,
    pub expression: String,
    #[serde(default, rename = "displayExpression")]
    pub display_expression: String,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Table {
    pub id: i32,
    pub name: String,
    pub color: String,
    pub x: f64,
    pub y: f64,
    pub fields: Vec<Field>,
    #[serde(default)]
    pub constraints: Vec<Constraint>,
}
impl Table {
    fn height(&self) -> f64 {
        64.
    }
}
#[derive(Clone, Deserialize)]
pub struct Edge {
    pub id: i32,
    pub table: i32,
    pub field: i32,
    pub target: i32,
    pub many: bool,
    pub cascade: bool,
    #[serde(default, rename = "referenceName")]
    pub reference_name: String,
    #[serde(default, rename = "inverseName")]
    pub inverse_name: String,
}
impl Edge {
    fn source_table(&self) -> i32 {
        if self.field == 0 {
            self.table
        } else {
            self.target
        }
    }
    fn destination_table(&self) -> i32 {
        if self.field == 0 {
            self.target
        } else {
            self.table
        }
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Viewport {
    pub zoom: f64,
    pub pan_x: f64,
    pub pan_y: f64,
    pub calibration: f64,
}
impl Default for Viewport {
    fn default() -> Self {
        Self {
            zoom: 1.,
            pan_x: 0.,
            pan_y: 0.,
            calibration: 1.,
        }
    }
}
impl Viewport {
    fn panned(&self, target: &Self, progress: f64) -> Self {
        let t = progress.clamp(0., 1.);
        let eased = t * t * (3. - 2. * t);
        let mut result = target.clone();
        result.pan_x = self.pan_x + (target.pan_x - self.pan_x) * eased;
        result.pan_y = self.pan_y + (target.pan_y - self.pan_y) * eased;
        result
    }
    fn revealing_table(&self, table: &Table, width: f64, height: f64) -> Self {
        if width <= 0. || height <= 0. {
            return self.clone();
        }
        let scale = self.zoom * self.calibration;
        let pan = |current: f64, start: f64, length: f64, viewport: f64| {
            let visible = (viewport - 14.).max(1.);
            let inset = 24_f64.min(visible / 4.);
            let leading = start - inset / scale;
            let trailing = start + length - (visible - inset) / scale;
            if length * scale > visible - 2. * inset {
                leading
            } else {
                current.max(trailing).min(leading)
            }
        };
        let mut result = self.clone();
        result.pan_x = pan(self.pan_x, table.x, 320., width);
        result.pan_y = pan(self.pan_y, table.y, table.height(), height);
        result
    }
}
#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Graph {
    pub tables: Vec<Table>,
    pub edges: Vec<Edge>,
    #[serde(default)]
    pub views: Vec<DataView>,
    pub view: Viewport,
    pub can_undo: bool,
    pub can_redo: bool,
}
#[derive(Clone, Deserialize)]
pub struct ViewColumn {
    pub field: i32,
    pub group: String,
}
#[derive(Clone, Deserialize)]
pub struct ViewAvailableColumn {
    pub field: i32,
    pub name: String,
    pub groups: Vec<String>,
}
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DataView {
    pub id: i32,
    pub name: String,
    pub table: i32,
    pub x: f64,
    pub y: f64,
    pub columns: Vec<ViewColumn>,
    pub available_columns: Vec<ViewAvailableColumn>,
    pub grouped: bool,
}
impl DataView {
    fn node(&self) -> Table {
        Table {
            id: self.id,
            name: format!("▤ {}", self.name),
            color: "#7651A8".into(),
            x: self.x,
            y: self.y,
            fields: vec![],
            constraints: vec![],
        }
    }
}
fn group_title(group: &str) -> &'static str {
    match group {
        "count" => "Count",
        "sum" => "Sum",
        "avg" => "Average",
        "min" => "Minimum",
        "max" => "Maximum",
        _ => "None",
    }
}
#[derive(Clone, Copy, PartialEq)]
enum ERMenu {
    Create,
    Source(i32),
    Group(i32, i32),
}
#[derive(Clone)]
enum Drag {
    Table(i32, f64, f64, f64, f64),
    Pan(f64, f64, Viewport),
    Horizontal,
    Vertical,
}
struct Reveal {
    from: Viewport,
    to: Viewport,
    began: Instant,
}
#[derive(Clone, Copy, PartialEq)]
enum CheckTarget {
    Field(i32),
    Table(Option<i32>),
}
pub struct ERState {
    pub graph: Graph,
    reveal: Option<Reveal>,
    pub selected: Option<i32>,
    pub edge: Option<i32>,
    pub focus: FocusHandle,
    pub name: Entity<TextInput>,
    name_baseline: String,
    pub selected_field: Option<i32>,
    field_name: Entity<TextInput>,
    field_baseline: String,
    reference_name: Entity<TextInput>,
    reference_baseline: String,
    inverse_name: Entity<TextInput>,
    inverse_baseline: String,
    field_menu: Option<bool>, // true: add; false: change datatype.
    dropdown: Option<ERMenu>,
    check_editor: Option<CheckTarget>,
    check_name: Entity<TextInput>,
    check_expression: Entity<TextInput>,
    _subscriptions: Vec<Subscription>,
    pending: Option<i32>,
    link_start: Option<(f64, f64)>,
    drag: Option<Drag>,
    preview: Option<(i32, f64, f64)>,
    link_preview: Option<(f64, f64)>,
    bounds: Rc<Cell<Bounds<Pixels>>>,
    name_bounds: Rc<RefCell<Vec<(i32, NameRect)>>>,
    sidebar: f32,
    resizing: bool,
}
impl ERState {
    pub fn new(window: &mut Window, cx: &mut Context<SubCardView>) -> Self {
        let name = cx.new(|cx| TextInput::new(String::new(), cx).with_placeholder("Table name"));
        let field_name =
            cx.new(|cx| TextInput::new(String::new(), cx).with_placeholder("Field name"));
        let reference_name =
            cx.new(|cx| TextInput::new(String::new(), cx).with_placeholder("Reference name"));
        let inverse_name = cx.new(|cx| {
            TextInput::new(String::new(), cx).with_placeholder("Inverse name (optional)")
        });
        let mut subscriptions = Vec::new();
        let check_name =
            cx.new(|cx| TextInput::new(String::new(), cx).with_placeholder("Constraint name"));
        let check_expression =
            cx.new(|cx| TextInput::new(String::new(), cx).with_placeholder("CHECK expression"));
        for input in [&check_name, &check_expression] {
            subscriptions.push(cx.observe(input, |_, _, cx| cx.notify()));
            subscriptions.push(cx.subscribe_in(
                input,
                window,
                |s, _, _: &crate::text_input::Submitted, _, cx| s.er_apply_check(cx),
            ));
        }
        for input in [&name, &field_name, &reference_name, &inverse_name] {
            subscriptions.push(cx.on_blur(&input.focus_handle(cx), window, |s, _, cx| {
                s.er_commit_names(cx)
            }));
            subscriptions.push(cx.subscribe_in(
                input,
                window,
                |s, _, _: &crate::text_input::Submitted, w, cx| {
                    s.er_commit_names(cx);
                    w.focus(&s.er.focus);
                },
            ));
            subscriptions.push(cx.observe(input, |_, _, cx| cx.notify()));
        }
        Self {
            graph: Graph::default(),
            reveal: None,
            selected: None,
            edge: None,
            focus: cx.focus_handle(),
            name,
            _subscriptions: subscriptions,
            name_baseline: String::new(),
            selected_field: None,
            field_name,
            field_baseline: String::new(),
            reference_name,
            reference_baseline: String::new(),
            inverse_name,
            inverse_baseline: String::new(),
            field_menu: None,
            dropdown: None,
            check_editor: None,
            check_name,
            check_expression,
            pending: None,
            link_start: None,
            drag: None,
            preview: None,
            link_preview: None,
            bounds: Rc::new(Cell::new(Bounds::default())),
            name_bounds: Rc::new(RefCell::new(Vec::new())),
            sidebar: 285.,
            resizing: false,
        }
    }
    fn viewport(&self) -> Viewport {
        self.reveal
            .as_ref()
            .map(|r| r.from.panned(&r.to, r.began.elapsed().as_secs_f64() / 0.5))
            .unwrap_or_else(|| self.graph.view.clone())
    }
    fn scale(&self) -> f64 {
        self.graph.view.zoom * self.graph.view.calibration
    }
    fn position(&self, p: Point<Pixels>) -> (f64, f64) {
        let b = self.bounds.get();
        (
            f64::from(p.x - b.origin.x) / self.scale() + self.viewport().pan_x,
            f64::from(p.y - b.origin.y) / self.scale() + self.viewport().pan_y,
        )
    }
    fn target(&self, p: (f64, f64)) -> Option<i32> {
        self.port(p, false).or_else(|| {
            self.tables()
                .iter()
                .rev()
                .find(|t| p.0 >= t.x && p.0 <= t.x + 320. && p.1 >= t.y && p.1 <= t.y + t.height())
                .map(|t| t.id)
        })
    }
    fn tables(&self) -> Vec<Table> {
        self.graph
            .tables
            .iter()
            .cloned()
            .chain(self.graph.views.iter().map(DataView::node))
            .map(|mut t| {
                if let Some((id, x, y)) = self.preview {
                    if t.id == id {
                        t.x = x;
                        t.y = y;
                    }
                }
                t
            })
            .collect()
    }
    fn extent(&self) -> (f64, f64) {
        let b = self.bounds.get();
        self.tables().iter().fold(
            (
                f64::from(b.size.width) / self.scale(),
                f64::from(b.size.height) / self.scale(),
            ),
            |(w, h), t| (w.max(t.x + 400.), h.max(t.y + t.height() + 80.)),
        )
    }
    fn port(&self, p: (f64, f64), right: bool) -> Option<i32> {
        self.tables()
            .iter()
            .rev()
            .filter(|t| !self.graph.views.iter().any(|v| v.id == t.id))
            .find(|t| distance(p, port(t, right)) < 12_f64.max(14. / self.scale()))
            .map(|t| t.id)
    }
}

fn distance(a: (f64, f64), b: (f64, f64)) -> f64 {
    (a.0 - b.0).hypot(a.1 - b.1)
}
fn port(t: &Table, right: bool) -> (f64, f64) {
    (t.x + if right { 320. } else { 0. }, t.y + 30.)
}
fn arrowhead(destination: (f64, f64), has_port: bool) -> [(f64, f64); 3] {
    let tip = (
        destination.0 - if has_port { 7. } else { 0. },
        destination.1,
    );
    [(tip.0 - 8., tip.1 - 5.), tip, (tip.0 - 8., tip.1 + 5.)]
}
fn route(g: &[Table], e: &Edge, edges: &[Edge]) -> Vec<(f64, f64)> {
    let Some(a) = g.iter().find(|t| t.id == e.source_table()) else {
        return vec![];
    };
    let Some(b) = g.iter().find(|t| t.id == e.destination_table()) else {
        return vec![];
    };
    let p = port(a, true);
    let q = port(b, false);
    let lane = edges
        .iter()
        .filter(|other| {
            other.source_table() == e.source_table()
                && other.destination_table() == e.destination_table()
        })
        .position(|other| other.id == e.id)
        .unwrap_or(0) as f64;
    if q.0 > p.0 + 50. && lane == 0. {
        let mid = (p.0 + q.0) / 2.;
        vec![p, (mid, p.1), (mid, q.1), q]
    } else {
        let bottom = (a.y + a.height()).max(b.y + b.height()) + 40. + lane * 24.;
        vec![
            p,
            (p.0 + 30., p.1),
            (p.0 + 30., bottom),
            (q.0 - 30., bottom),
            (q.0 - 30., q.1),
            q,
        ]
    }
}
fn label_position(points: &[(f64, f64)], scale: f64) -> Option<(f64, f64)> {
    if points.len() < 2 {
        return None;
    }
    let mut remaining = points.windows(2).map(|s| distance(s[0], s[1])).sum::<f64>() / 2.;
    for segment in points.windows(2) {
        let (a, b) = (segment[0], segment[1]);
        let length = distance(a, b);
        if length > 0. && remaining <= length {
            let fraction = remaining / length;
            return Some((
                a.0 + fraction * (b.0 - a.0),
                a.1 + fraction * (b.1 - a.1) - 12_f64.max(12. / scale),
            ));
        }
        remaining -= length;
    }
    points.first().map(|p| (p.0, p.1 - 12_f64.max(12. / scale)))
}
#[derive(Clone, Copy, Debug)]
struct NameRect {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}
impl NameRect {
    fn intersects(self, other: Self, gap: f64) -> bool {
        self.x < other.x + other.width + gap
            && self.x + self.width > other.x - gap
            && self.y < other.y + other.height + gap
            && self.y + self.height > other.y - gap
    }
    fn contains(self, p: (f64, f64)) -> bool {
        p.0 >= self.x && p.0 <= self.x + self.width && p.1 >= self.y && p.1 <= self.y + self.height
    }
}
fn endpoint_label_rect(
    endpoint: (f64, f64),
    source: bool,
    size: (f64, f64),
    obstacles: &[NameRect],
    gap: f64,
) -> NameRect {
    let mut rect = NameRect {
        x: if source {
            endpoint.0 + gap
        } else {
            endpoint.0 - gap - size.0
        },
        y: endpoint.1 - gap - size.1,
        width: size.0,
        height: size.1,
    };
    for _ in 0..=obstacles.len() {
        let top = obstacles
            .iter()
            .filter(|o| rect.intersects(**o, gap))
            .map(|o| o.y)
            .min_by(f64::total_cmp);
        let Some(top) = top else {
            return rect;
        };
        rect.y = top - gap - rect.height - 0.01;
    }
    rect
}
fn segment_distance(p: (f64, f64), a: (f64, f64), b: (f64, f64)) -> f64 {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let len = dx * dx + dy * dy;
    let u = if len == 0. {
        0.
    } else {
        (((p.0 - a.0) * dx + (p.1 - a.1) * dy) / len).clamp(0., 1.)
    };
    distance(p, (a.0 + u * dx, a.1 + u * dy))
}
fn color(s: &str) -> Hsla {
    rgb(u32::from_str_radix(s.trim_start_matches('#'), 16).unwrap_or(0x397db8)).into()
}
fn button(
    label: impl Into<SharedString>,
    enabled: bool,
    cx: &mut Context<SubCardView>,
    action: impl Fn(&mut SubCardView, &mut Window, &mut Context<SubCardView>) + 'static,
) -> Stateful<Div> {
    let label = label.into();
    div()
        .id(label.clone())
        .child(label)
        .px_2()
        .py_1()
        .rounded_md()
        .bg(rgb(0xe5eaf1))
        .cursor_pointer()
        .when(!enabled, |d| d.opacity(0.4))
        .on_click(cx.listener(move |this, _, w, cx| {
            if enabled {
                action(this, w, cx);
            }
        }))
}
fn remove_check_button(
    id: String,
    enabled: bool,
    cx: &mut Context<SubCardView>,
    action: impl Fn(&mut SubCardView, &mut Window, &mut Context<SubCardView>) + 'static,
) -> Stateful<Div> {
    div()
        .id(SharedString::from(id))
        .size(px(28.))
        .flex()
        .items_center()
        .justify_center()
        .rounded_full()
        .bg(rgb(0xe5eaf1))
        .text_color(rgb(0xb42318))
        .text_size(px(20.))
        .child("×")
        .cursor_pointer()
        .when(!enabled, |d| d.opacity(0.4))
        .on_click(cx.listener(move |s, _, w, cx| {
            if enabled {
                action(s, w, cx);
            }
        }))
}
impl SubCardView {
    fn er_edit_check(&mut self, target: CheckTarget, cx: &mut Context<Self>) {
        self.er_commit_names(cx);
        let Some(t) = self
            .er
            .graph
            .tables
            .iter()
            .find(|t| Some(t.id) == self.er.selected)
        else {
            return;
        };
        let (name, expression) = match target {
            CheckTarget::Field(id) => (
                String::new(),
                t.fields
                    .iter()
                    .find(|f| f.id == id)
                    .map(|f| f.check_display.clone())
                    .unwrap_or_default(),
            ),
            CheckTarget::Table(id) => t
                .constraints
                .iter()
                .find(|c| Some(c.id) == id)
                .map(|c| (c.name.clone(), c.display_expression.clone()))
                .unwrap_or_default(),
        };
        self.er.check_editor = Some(target);
        self.er
            .check_name
            .update(cx, |i, cx| i.set_content(name, cx));
        self.er
            .check_expression
            .update(cx, |i, cx| i.set_content(expression, cx));
        cx.notify();
    }
    fn er_check_error(&self, cx: &App) -> Option<String> {
        let t = self
            .er
            .graph
            .tables
            .iter()
            .find(|t| Some(t.id) == self.er.selected)?;
        if let Err(e) = self
            .document
            .validate_check(t.id, self.er.check_expression.read(cx).content.as_ref())
        {
            return Some(e);
        }
        if let Some(CheckTarget::Table(id)) = self.er.check_editor {
            let name = self.er.check_name.read(cx).content.as_ref();
            if name.trim().is_empty() {
                return Some("Enter a constraint name.".into());
            }
            if name.len() > 128 || name.chars().any(|c| c < ' ' || c == '\u{7f}') {
                return Some(
                    "Use a name of at most 128 UTF-8 bytes without control characters.".into(),
                );
            }
            if t.constraints
                .iter()
                .any(|c| Some(c.id) != id && c.name.to_lowercase() == name.to_lowercase())
            {
                return Some("This table already has a constraint with that name.".into());
            }
        }
        None
    }
    fn er_apply_check(&mut self, cx: &mut Context<Self>) {
        if self.document.schema_locked()
            || self.document.using_document()
            || self.er_check_error(cx).is_some()
        {
            return;
        }
        let Some(table) = self.er.selected else {
            return;
        };
        let expression = self.er.check_expression.read(cx).content.to_string();
        let value = match self.er.check_editor {
            Some(CheckTarget::Field(id)) => {
                json!({"op":"update_field","table":table,"id":id,"check":expression})
            }
            Some(CheckTarget::Table(None)) => {
                json!({"op":"add_constraint","table":table,"name":self.er.check_name.read(cx).content.to_string(),"expression":expression})
            }
            Some(CheckTarget::Table(Some(id))) => {
                json!({"op":"update_constraint","table":table,"id":id,"name":self.er.check_name.read(cx).content.to_string(),"expression":expression})
            }
            None => return,
        };
        self.er_command(value, cx);
        if self.error.is_none() {
            self.er.check_editor = None;
        }
        cx.notify();
    }
    fn er_check_editor_panel(&self, enabled: bool, cx: &mut Context<Self>) -> Div {
        let error = self.er_check_error(cx);
        let mut editor = div()
            .flex()
            .flex_col()
            .gap_2()
            .p_2()
            .border_1()
            .rounded_md()
            .border_color(rgb(0x93b7ea));
        if matches!(self.er.check_editor, Some(CheckTarget::Table(_))) {
            editor = editor
                .child("Constraint name")
                .child(self.er.check_name.clone());
        }
        editor = editor.child("Expression").child(self.er.check_expression.clone())
            .child("Enter only the expression, without CHECK(...). Quote field names with double quotes.");
        if let Some(t) = self
            .er
            .graph
            .tables
            .iter()
            .find(|t| Some(t.id) == self.er.selected)
        {
            let fields = t
                .fields
                .iter()
                .filter(|f| f.ordinary())
                .map(|f| format!("\"{}\"", f.name.replace('"', "\"\"")))
                .collect::<Vec<_>>()
                .join(", ");
            editor = editor.child(format!("Fields: id, {fields}"));
        }
        editor
            .child(
                div()
                    .text_color(if error.is_some() {
                        rgb(0xb42318)
                    } else {
                        rgb(0x258775)
                    })
                    .child(error.clone().unwrap_or_else(|| "Valid CHECK syntax".into())),
            )
            .child(
                div()
                    .flex()
                    .gap_2()
                    .child(button("Cancel", true, cx, |s, _, cx| {
                        s.er.check_editor = None;
                        cx.notify();
                    }))
                    .child(button(
                        "Apply",
                        enabled && error.is_none(),
                        cx,
                        |s, _, cx| s.er_apply_check(cx),
                    )),
            )
    }
    pub fn er_refresh(&mut self) {
        match self
            .document
            .er_json()
            .and_then(|s| serde_json::from_str(&s).map_err(|e| e.to_string()))
        {
            Ok(g) => self.er.graph = g,
            Err(e) => self.error = Some(e),
        }
        if !self
            .er
            .graph
            .tables
            .iter()
            .any(|t| Some(t.id) == self.er.selected)
            && !self
                .er
                .graph
                .views
                .iter()
                .any(|v| Some(v.id) == self.er.selected)
        {
            self.er.selected = None;
        }
        if !self
            .er
            .graph
            .edges
            .iter()
            .any(|t| Some(t.id) == self.er.edge)
        {
            self.er.edge = None;
        }
        if self.document.schema_locked()
            || self.document.using_document()
            || !self
                .er
                .graph
                .tables
                .iter()
                .any(|t| Some(t.id) == self.er.pending)
        {
            self.er.pending = None;
            self.er.link_preview = None;
        }
    }
    pub fn er_has_draft(&self, cx: &App) -> bool {
        self.er.name.read(cx).content.as_ref() != self.er.name_baseline
            || self.er.field_name.read(cx).content.as_ref() != self.er.field_baseline
            || self.er.reference_name.read(cx).content.as_ref() != self.er.reference_baseline
            || self.er.inverse_name.read(cx).content.as_ref() != self.er.inverse_baseline
    }
    fn er_load_names(&mut self, cx: &mut Context<Self>) {
        let edge = self
            .er
            .graph
            .edges
            .iter()
            .find(|e| Some(e.id) == self.er.edge);
        let reference = edge.map(|e| e.reference_name.clone()).unwrap_or_default();
        let inverse = edge.map(|e| e.inverse_name.clone()).unwrap_or_default();
        self.er.reference_baseline = reference.clone();
        self.er.inverse_baseline = inverse.clone();
        if self.er.reference_name.read(cx).content.as_ref() != reference {
            self.er
                .reference_name
                .update(cx, |i, cx| i.set_content(reference, cx));
        }
        if self.er.inverse_name.read(cx).content.as_ref() != inverse {
            self.er
                .inverse_name
                .update(cx, |i, cx| i.set_content(inverse, cx));
        }
        let field_name = self
            .er
            .graph
            .tables
            .iter()
            .find(|t| Some(t.id) == self.er.selected)
            .and_then(|t| {
                t.fields
                    .iter()
                    .find(|f| Some(f.id) == self.er.selected_field && f.ordinary())
            })
            .map(|f| f.name.clone());
        if field_name.is_none() {
            self.er.selected_field = None;
        }
        let field_name = field_name.unwrap_or_default();
        self.er.field_baseline = field_name.clone();
        if self.er.field_name.read(cx).content.as_ref() != field_name {
            self.er
                .field_name
                .update(cx, |i, cx| i.set_content(field_name, cx));
        }
        let name = self
            .er
            .graph
            .tables
            .iter()
            .find(|t| Some(t.id) == self.er.selected)
            .map(|t| t.name.clone())
            .or_else(|| {
                self.er
                    .graph
                    .views
                    .iter()
                    .find(|v| Some(v.id) == self.er.selected)
                    .map(|v| v.name.clone())
            })
            .unwrap_or_default();
        self.er.name_baseline = name.clone();
        if self.er.name.read(cx).content.as_ref() != name {
            self.er.name.update(cx, |i, cx| i.set_content(name, cx));
        }
    }
    pub fn er_commit_names(&mut self, cx: &mut Context<Self>) {
        if !self.er_has_draft(cx) {
            return;
        }
        if let Some(id) = self.er.edge {
            let reference = self.er.reference_name.read(cx).content.to_string();
            let inverse = self.er.inverse_name.read(cx).content.to_string();
            if reference != self.er.reference_baseline || inverse != self.er.inverse_baseline {
                let mut value = json!({"op":"update_connection","id":id,"inverseName":inverse});
                if reference != self.er.reference_baseline {
                    value["referenceName"] = json!(reference);
                }
                if let Err(e) = self.document.er_command(value) {
                    self.error = Some(e);
                }
            }
        }
        if let Some(v) = self
            .er
            .graph
            .views
            .iter()
            .find(|v| Some(v.id) == self.er.selected)
        {
            let name = self.er.name.read(cx).content.to_string();
            if name != self.er.name_baseline {
                if let Err(e) = self
                    .document
                    .er_command(json!({"op":"update_data_view","id":v.id,"name":name}))
                {
                    self.error = Some(e);
                }
            }
        }
        if let Some(t) = self
            .er
            .graph
            .tables
            .iter()
            .find(|t| Some(t.id) == self.er.selected)
        {
            let name = self.er.name.read(cx).content.to_string();
            if name != self.er.name_baseline {
                if let Err(e) = self
                    .document
                    .er_command(json!({"op":"update_table","id":t.id,"name":name,"color":t.color}))
                {
                    self.error = Some(e);
                }
            }
            if let Some(f) = t
                .fields
                .iter()
                .find(|f| Some(f.id) == self.er.selected_field && f.ordinary())
            {
                let name = self.er.field_name.read(cx).content.to_string();
                if name != self.er.field_baseline {
                    if let Err(e) = self
                        .document
                        .er_command(json!({"op":"update_field","table":t.id,"id":f.id,"name":name}))
                    {
                        self.error = Some(e);
                    }
                }
            }
        }
        self.er_refresh();
        self.er_load_names(cx);
        cx.notify();
    }
    fn er_command(&mut self, value: Value, cx: &mut Context<Self>) {
        self.er.reveal = None;
        self.er_commit_names(cx);
        match self.document.er_command(value) {
            Ok(()) => self.error = None,
            Err(e) => self.error = Some(e),
        }
        self.er_refresh();
        self.er_load_names(cx);
        cx.notify();
    }
    fn er_view(&mut self, mut v: Viewport, cx: &mut Context<Self>) {
        v.zoom = v.zoom.clamp(0.0001, 4.);
        v.pan_x = v.pan_x.clamp(-1e9, 1e9);
        v.pan_y = v.pan_y.clamp(-1e9, 1e9);
        v.calibration = v.calibration.clamp(0.25, 4.);
        self.er_command(json!({"op":"view","zoom":v.zoom,"panX":v.pan_x,"panY":v.pan_y,"calibration":v.calibration}),cx);
    }
    fn er_select(
        &mut self,
        table: Option<i32>,
        edge: Option<i32>,
        w: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.er_commit_names(cx);
        self.er.selected = table;
        self.er.edge = edge;
        self.er.selected_field = None;
        self.er.field_menu = None;
        self.er.check_editor = None;
        self.er.dropdown = None;
        self.er_load_names(cx);
        w.focus(&self.er.focus);
        cx.notify();
    }
    fn er_select_field(&mut self, id: Option<i32>, cx: &mut Context<Self>) {
        self.er_commit_names(cx);
        self.er.selected_field = id;
        self.er.field_menu = None;
        self.er.check_editor = None;
        self.er_load_names(cx);
        cx.notify();
    }
    fn er_add_field(&mut self, kind: &str, cx: &mut Context<Self>) {
        self.er_commit_names(cx);
        if let Some(t) = self
            .er
            .graph
            .tables
            .iter()
            .find(|t| Some(t.id) == self.er.selected)
        {
            let id = t.id;
            let count = t.fields.len();
            let mut n = 1;
            while t
                .fields
                .iter()
                .any(|f| f.name.to_lowercase() == format!("field {n}"))
            {
                n += 1;
            }
            self.er_command(
                json!({"op":"add_field","table":id,"name":format!("Field {n}"),"kind":kind}),
                cx,
            );
            if let Some(t) = self.er.graph.tables.iter().find(|t| t.id == id) {
                if t.fields.len() == count + 1 {
                    let added = t.fields.last().map(|f| f.id);
                    self.er_select_field(added, cx);
                }
            }
        }
    }
    fn er_begin_connection(&mut self, cx: &mut Context<Self>) {
        self.er_commit_names(cx);
        if !self.document.schema_locked() && !self.document.using_document() {
            self.er.pending = self
                .er
                .selected
                .filter(|id| self.er.graph.tables.iter().any(|t| t.id == *id));
            self.er.link_preview = None;
            self.er.link_start = None;
            cx.notify();
        }
    }
    fn er_connect(&mut self, target: i32, cx: &mut Context<Self>) {
        if self.er.graph.views.iter().any(|v| v.id == target) {
            self.er.pending = None;
            self.er.link_preview = None;
            return;
        }
        let Some(source) = self.er.pending.take() else {
            return;
        };
        let count = self.er.graph.edges.len();
        self.er_command(
            json!({"op":"add_connection","table":source,"target":target}),
            cx,
        );
        self.er.link_preview = None;
        self.er.link_start = None;
        if self.er.graph.edges.len() == count + 1 {
            self.er.selected = None;
            self.er.edge = self.er.graph.edges.last().map(|e| e.id);
            self.er_load_names(cx);
        }
        cx.notify();
    }
    fn er_add(&mut self, w: &mut Window, cx: &mut Context<Self>) {
        let start = self.er.viewport();
        self.er_commit_names(cx);
        let count = self.er.graph.tables.len();
        let mut n = count + 1;
        while self
            .er
            .graph
            .tables
            .iter()
            .any(|t| t.name.to_lowercase() == format!("table {n}"))
        {
            n += 1;
        }
        self.er_command(json!({"op":"add_table","name":format!("Table {n}"),"x":(self.er.graph.view.pan_x+60.+(self.er.graph.tables.len()%3) as f64*380.).clamp(0.,100000.),"y":(self.er.graph.view.pan_y+60.+(self.er.graph.tables.len()/3)as f64*200.).clamp(0.,100000.)}),cx);
        if self.er.graph.tables.len() != count + 1 {
            return;
        }
        if let Some(added) = self.er.graph.tables.last().cloned() {
            self.er_select(Some(added.id), None, w, cx);
            let bounds = self.er.bounds.get();
            let view = self.er.graph.view.revealing_table(
                &added,
                f64::from(bounds.size.width),
                f64::from(bounds.size.height),
            );
            self.er_view(view, cx);
            let target = self.er.graph.view.clone();
            if start.pan_x != target.pan_x || start.pan_y != target.pan_y {
                self.er.reveal = Some(Reveal {
                    from: start,
                    to: target,
                    began: Instant::now(),
                });
                cx.notify();
            }
        }
    }
    fn er_add_view(&mut self, w: &mut Window, cx: &mut Context<Self>) {
        self.er_commit_names(cx);
        let count = self.er.graph.views.len();
        let mut n = count + 1;
        while self
            .er
            .graph
            .views
            .iter()
            .any(|v| v.name.to_lowercase() == format!("view {n}"))
        {
            n += 1;
        }
        let table = self
            .er
            .graph
            .tables
            .iter()
            .find(|t| Some(t.id) == self.er.selected)
            .or_else(|| self.er.graph.tables.first())
            .map(|t| t.id)
            .unwrap_or(0);
        self.er_command(
            json!({"op":"add_data_view","name":format!("View {n}"),"table":table,
            "x":(self.er.viewport().pan_x+80.).clamp(0.,100000.),
            "y":(self.er.viewport().pan_y+160.).clamp(0.,100000.)}),
            cx,
        );
        if self.er.graph.views.len() != count + 1 {
            return;
        }
        if let Some(v) = self.er.graph.views.last().cloned() {
            self.er_select(Some(v.id), None, w, cx);
            let bounds = self.er.bounds.get();
            let viewport = self.er.viewport().revealing_table(
                &v.node(),
                f64::from(bounds.size.width),
                f64::from(bounds.size.height),
            );
            self.er_view(viewport, cx);
        }
    }
    fn er_copy(&mut self, cx: &mut Context<Self>) {
        self.er_commit_names(cx);
        if let Some(t) = self
            .er
            .graph
            .tables
            .iter()
            .find(|t| Some(t.id) == self.er.selected)
        {
            cx.write_to_clipboard(ClipboardItem::new_string(
                json!({"subcardTable":1,"table":t}).to_string(),
            ));
        }
    }
    fn er_paste(&mut self, w: &mut Window, cx: &mut Context<Self>) {
        let value = cx
            .read_from_clipboard()
            .and_then(|c| c.text())
            .and_then(|s| serde_json::from_str::<Value>(&s).ok());
        if let Some(v) = value.filter(|v| v["subcardTable"] == 1) {
            self.er_command(json!({"op":"paste_table","table":v["table"]}), cx);
            self.er_select(self.er.graph.tables.last().map(|t| t.id), None, w, cx);
        } else {
            self.error = Some("Clipboard does not contain a SubCard table.".into());
            cx.notify();
        }
    }
    fn er_duplicate(&mut self, w: &mut Window, cx: &mut Context<Self>) {
        self.er_commit_names(cx);
        if let Some(t) = self
            .er
            .graph
            .tables
            .iter()
            .find(|t| Some(t.id) == self.er.selected)
            .cloned()
        {
            self.er_command(json!({"op":"paste_table","table":t}), cx);
            self.er_select(self.er.graph.tables.last().map(|t| t.id), None, w, cx);
        }
    }
    fn er_delete(&mut self, cx: &mut Context<Self>) {
        if let Some(v) = self
            .er
            .graph
            .views
            .iter()
            .find(|v| Some(v.id) == self.er.selected)
        {
            self.er_command(json!({"op":"delete_data_view","id":v.id}), cx);
        } else if let Some(id) = self.er.edge {
            self.er_command(json!({"op":"delete_connection","id":id}), cx);
        } else if let Some(id) = self.er.selected {
            self.er_command(json!({"op":"delete_table","id":id}), cx);
        }
    }
    fn er_fit(&mut self, cx: &mut Context<Self>) {
        let mut v = self.er.graph.view.clone();
        if self.er.tables().is_empty() {
            v = Viewport::default();
        } else {
            let (mut l, mut t, mut r, mut b) = (f64::MAX, f64::MAX, 0_f64, 0_f64);
            for table in &self.er.tables() {
                l = l.min(table.x);
                t = t.min(table.y);
                r = r.max(table.x + 320.);
                b = b.max(table.y + table.height());
            }
            for (_, rect) in self.er.name_bounds.borrow().iter() {
                l = l.min(rect.x);
                t = t.min(rect.y);
                r = r.max(rect.x + rect.width);
                b = b.max(rect.y + rect.height);
            }
            let bounds = self.er.bounds.get();
            v.zoom = ((f64::from(bounds.size.width) - 60.) / (r - l + 80.))
                .min((f64::from(bounds.size.height) - 60.) / (b - t + 80.))
                / v.calibration;
            v.pan_x = l - 40.;
            v.pan_y = t - 40.;
        }
        self.er_view(v, cx);
    }
    fn er_down(&mut self, event: &MouseDownEvent, w: &mut Window, cx: &mut Context<Self>) {
        self.er_commit_names(cx);
        w.focus(&self.er.focus);
        if self.er.reveal.is_some() {
            self.er_view(self.er.viewport(), cx);
        }
        let p = self.er.position(event.position);
        let b = self.er.bounds.get();
        let x = f32::from(event.position.x - b.origin.x);
        let y = f32::from(event.position.y - b.origin.y);
        let (ew, eh) = self.er.extent();
        let s = self.er.scale();
        if y > f32::from(b.size.height) - 14.
            && (ew - self.er.graph.view.pan_x.min(0.)) * s > f64::from(b.size.width) + 1.
        {
            self.er.drag = Some(Drag::Horizontal);
            self.er_drag(event.position, cx);
            return;
        }
        if x > f32::from(b.size.width) - 14.
            && (eh - self.er.graph.view.pan_y.min(0.)) * s > f64::from(b.size.height) + 1.
        {
            self.er.drag = Some(Drag::Vertical);
            self.er_drag(event.position, cx);
            return;
        }
        if self.er.pending.is_some() {
            if let Some(target) = self.er.target(p) {
                self.er_connect(target, cx);
            } else {
                self.er.pending = None;
                self.er.link_preview = None;
            }
            return;
        }
        if let Some(source) = self
            .er
            .port(p, true)
            .filter(|_| !self.document.schema_locked() && !self.document.using_document())
        {
            self.er_select(Some(source), None, w, cx);
            self.er_begin_connection(cx);
            self.er.link_start = Some(p);
            self.er.link_preview = Some(p);
            return;
        }
        if let Some(id) = self.er.target(p) {
            let t = self
                .er
                .tables()
                .iter()
                .find(|t| t.id == id)
                .unwrap()
                .clone();
            self.er_select(Some(id), None, w, cx);
            if !self.document.using_document() {
                self.er.drag = Some(Drag::Table(t.id, t.x, t.y, p.0, p.1));
            }
            return;
        }
        let hit = self
            .er
            .graph
            .edges
            .iter()
            .rev()
            .find(|e| {
                let points = route(&self.er.tables(), e, &self.er.graph.edges);
                let label_hit = label_position(&points, self.er.scale()).is_some_and(|q| {
                    let scale = self.er.scale();
                    let width = (26. * scale).max(26.) / scale;
                    let height = (20. * scale).max(20.) / scale;
                    (p.0 - q.0).abs() <= width / 2. && (p.1 - q.1).abs() <= height / 2.
                });
                label_hit
                    || self
                        .er
                        .name_bounds
                        .borrow()
                        .iter()
                        .any(|(id, rect)| *id == e.id && rect.contains(p))
                    || points
                        .windows(2)
                        .any(|s| segment_distance(p, s[0], s[1]) < 10. / self.er.scale())
            })
            .map(|e| e.id);
        self.er_select(None, hit, w, cx);
        self.er.drag = Some(Drag::Pan(
            f64::from(event.position.x),
            f64::from(event.position.y),
            self.er.graph.view.clone(),
        ));
    }
    fn er_drag(&mut self, p: Point<Pixels>, cx: &mut Context<Self>) {
        if self.er.drag.is_none() && self.er.pending.is_none() {
            return;
        }
        if let Some(d) = self.er.drag.clone() {
            match d {
                Drag::Table(id, x, y, sx, sy) => {
                    let q = self.er.position(p);
                    self.er.preview = Some((
                        id,
                        (x + q.0 - sx).clamp(0., 100000.),
                        (y + q.1 - sy).clamp(0., 100000.),
                    ));
                }
                Drag::Pan(x, y, mut v) => {
                    v.pan_x -= (f64::from(p.x) - x) / self.er.scale();
                    v.pan_y -= (f64::from(p.y) - y) / self.er.scale();
                    self.er_view(v, cx);
                }
                Drag::Horizontal => {
                    let b = self.er.bounds.get();
                    let (extent, _) = self.er.extent();
                    let fraction = f64::from(p.x - b.origin.x) / f64::from(b.size.width);
                    let mut v = self.er.graph.view.clone();
                    let origin = self.er.graph.view.pan_x.min(0.);
                    v.pan_x = origin
                        + (extent - origin - f64::from(b.size.width) / self.er.scale()).max(0.)
                            * fraction.clamp(0., 1.);
                    self.er_view(v, cx);
                }
                Drag::Vertical => {
                    let b = self.er.bounds.get();
                    let (_, extent) = self.er.extent();
                    let fraction = f64::from(p.y - b.origin.y) / f64::from(b.size.height);
                    let mut v = self.er.graph.view.clone();
                    let origin = self.er.graph.view.pan_y.min(0.);
                    v.pan_y = origin
                        + (extent - origin - f64::from(b.size.height) / self.er.scale()).max(0.)
                            * fraction.clamp(0., 1.);
                    self.er_view(v, cx);
                }
            }
        } else if self.er.pending.is_some() {
            self.er.link_preview = Some(self.er.position(p));
        }
        cx.notify();
    }
    fn er_up(&mut self, event: &MouseUpEvent, cx: &mut Context<Self>) {
        if let Some((id, x, y)) = self.er.preview.take() {
            let op = if self.er.graph.views.iter().any(|v| v.id == id) {
                "move_data_view"
            } else {
                "move_table"
            };
            self.er_command(json!({"op":op,"id":id,"x":x,"y":y}), cx);
        }
        if self.er.pending.is_some() {
            let p = self.er.position(event.position);
            // Clicking the source port arms it; dragging completes immediately.
            let dragged = self
                .er
                .link_start
                .is_some_and(|start| distance(start, p) * self.er.scale() >= 5.);
            if dragged {
                if let Some(target) = self.er.target(p) {
                    self.er_connect(target, cx);
                } else {
                    self.er.pending = None;
                    self.er.link_preview = None;
                }
            }
            self.er.link_start = None;
        }
        self.er.drag = None;
        cx.notify();
    }
    pub fn er_render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.er_refresh();
        let edit = !self.document.using_document();
        let schema = edit && !self.document.schema_locked();
        if self
            .er
            .reveal
            .as_ref()
            .is_some_and(|r| r.began.elapsed().as_secs_f64() >= 0.5)
        {
            self.er.reveal = None;
        }
        if self.er.reveal.is_some() {
            window.request_animation_frame();
        }
        let mut graph = self.er.graph.clone();
        graph.view = self.er.viewport();
        let tables = self.er.tables();
        let can_undo = graph.can_undo;
        let can_redo = graph.can_redo;
        let selected = self.er.selected;
        let selected_table = graph.tables.iter().any(|t| Some(t.id) == selected);
        let selected_view = graph.views.iter().any(|v| Some(v.id) == selected);
        let selected_edge = self.er.edge;
        let text_focus = self.er.name.focus_handle(cx).is_focused(window)
            || self.er.field_name.focus_handle(cx).is_focused(window)
            || self.er.reference_name.focus_handle(cx).is_focused(window)
            || self.er.inverse_name.focus_handle(cx).is_focused(window);
        let paste_available = cx
            .read_from_clipboard()
            .and_then(|c| c.text())
            .and_then(|s| serde_json::from_str::<Value>(&s).ok())
            .is_some_and(|v| v["subcardTable"] == 1);
        let pending = self.er.pending;
        let link = self.er.link_preview;
        let bounds = self.er.bounds.clone();
        let bounds_paint = bounds.clone();
        let name_bounds = self.er.name_bounds.clone();
        let toolbar = div()
            .flex()
            .flex_wrap()
            .gap_2()
            .p_2()
            .border_b_1()
            .border_color(rgb(0xd2d9e2))
            .child(self.er_dropdown(
                "+ Create ▾".into(),
                ERMenu::Create,
                edit,
                vec![
                    ("Table".into(), schema, json!({"op":"$table"})),
                    (
                        "Connection".into(),
                        schema && selected_table,
                        json!({"op":"$connection"}),
                    ),
                    ("View".into(), edit, json!({"op":"$view"})),
                ],
                cx,
            ))
            .child(button("−", true, cx, |s, _, cx| {
                let mut v = s.er.viewport();
                v.zoom /= 1.2;
                s.er_view(v, cx);
            }))
            .child(button("+", true, cx, |s, _, cx| {
                let mut v = s.er.viewport();
                v.zoom *= 1.2;
                s.er_view(v, cx);
            }))
            .child(button(
                if graph.view.zoom < 0.01 {
                    format!("{:.2}%", graph.view.zoom * 100.)
                } else {
                    format!("{}%", (graph.view.zoom * 100.).round() as i32)
                },
                true,
                cx,
                |s, _, cx| {
                    let mut v = s.er.viewport();
                    v.zoom = 1.;
                    s.er_view(v, cx);
                },
            ))
            .child(button("Fit", true, cx, |s, _, cx| s.er_fit(cx)))
            .when(pending.is_some(), |d| {
                d.child(button("Choose a table • Cancel", true, cx, |s, _, cx| {
                    s.er.pending = None;
                    s.er.link_preview = None;
                    cx.notify();
                }))
            });
        let canvas = div()
            .id("er-canvas")
            .relative()
            .size_full()
            .overflow_hidden()
            .bg(rgb(0xf3f6fa))
            .child(
                canvas(
                    move |b, _, _| {
                        bounds.set(b);
                    },
                    move |b, _, w, cx| {
                        bounds_paint.set(b);
                        paint(
                            &graph,
                            &tables,
                            selected,
                            selected_edge,
                            pending,
                            link,
                            &name_bounds,
                            b,
                            w,
                            cx,
                        );
                    },
                )
                .size_full(),
            )
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|s, e, w, cx| s.er_down(e, w, cx)),
            )
            .on_mouse_move(cx.listener(|s, e: &MouseMoveEvent, _, cx| s.er_drag(e.position, cx)))
            .on_mouse_up(MouseButton::Left, cx.listener(|s, e, _, cx| s.er_up(e, cx)))
            .on_mouse_up_out(MouseButton::Left, cx.listener(|s, e, _, cx| s.er_up(e, cx)))
            .on_scroll_wheel(cx.listener(|s, e: &ScrollWheelEvent, _, cx| {
                let d = e.delta.pixel_delta(px(24.));
                let mut v = s.er.viewport();
                if e.modifiers.control || e.modifiers.platform {
                    v.zoom *= (f64::from(d.y) * 0.005).exp();
                } else {
                    v.pan_x -= f64::from(d.x) / s.er.scale();
                    v.pan_y -= f64::from(d.y) / s.er.scale();
                }
                s.er_view(v, cx);
            }));
        let inspector = self.er_inspector(cx);
        div()
            .flex()
            .flex_col()
            .flex_1()
            .min_h_0()
            .track_focus(&self.er.focus)
            .key_context("ERCanvas")
            .when(!text_focus && edit && can_undo, |d| {
                d.on_action(
                    cx.listener(|s, _: &crate::Undo, _, cx| s.er_command(json!({"op":"undo"}), cx)),
                )
            })
            .when(!text_focus && edit && can_redo, |d| {
                d.on_action(
                    cx.listener(|s, _: &crate::Redo, _, cx| s.er_command(json!({"op":"redo"}), cx)),
                )
            })
            .when(!text_focus && selected_table, |d| {
                d.on_action(cx.listener(|s, _: &crate::Copy, _, cx| s.er_copy(cx)))
            })
            .when(!text_focus && schema && selected_table, |d| {
                d.on_action(cx.listener(|s, _: &crate::Cut, _, cx| {
                    s.er_copy(cx);
                    s.er_delete(cx);
                }))
            })
            .when(!text_focus && schema && paste_available, |d| {
                d.on_action(cx.listener(|s, _: &crate::Paste, w, cx| s.er_paste(w, cx)))
            })
            .when(!text_focus && schema && selected_table, |d| {
                d.on_action(cx.listener(|s, _: &crate::Duplicate, w, cx| s.er_duplicate(w, cx)))
            })
            .when(
                !text_focus
                    && edit
                    && (selected_view || (schema && (selected_table || selected_edge.is_some()))),
                |d| {
                    d.on_action(
                        cx.listener(|s, _: &crate::text_input::Delete, _, cx| s.er_delete(cx)),
                    )
                },
            )
            .child(toolbar)
            .child(
                div()
                    .flex()
                    .flex_1()
                    .min_h_0()
                    .child(div().flex_1().min_w_0().child(canvas))
                    .child(
                        div()
                            .id("inspector-divider")
                            .w(px(6.))
                            .h_full()
                            .bg(rgb(0xcbd5e1))
                            .cursor_col_resize()
                            .on_mouse_down(
                                MouseButton::Left,
                                cx.listener(|s, _, _, cx| {
                                    s.er.resizing = true;
                                    cx.notify();
                                }),
                            ),
                    )
                    .child(inspector),
            )
            .on_mouse_move(cx.listener(|s, e: &MouseMoveEvent, w, cx| {
                if s.er.resizing {
                    s.er.sidebar =
                        (f32::from(w.viewport_size().width - e.position.x)).clamp(240., 500.);
                    cx.notify();
                }
            }))
            .on_mouse_up(
                MouseButton::Left,
                cx.listener(|s, _, _, _| s.er.resizing = false),
            )
            .on_mouse_up_out(
                MouseButton::Left,
                cx.listener(|s, _, _, _| s.er.resizing = false),
            )
    }
    fn er_dropdown(
        &self,
        title: String,
        key: ERMenu,
        enabled: bool,
        entries: Vec<(String, bool, Value)>,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let mut control = div()
            .relative()
            .child(button(title, enabled, cx, move |s, _, cx| {
                s.er.dropdown = if s.er.dropdown == Some(key) {
                    None
                } else {
                    Some(key)
                };
                cx.notify();
            }));
        if self.er.dropdown == Some(key) && enabled {
            let mut popup = div()
                .id(SharedString::from(format!(
                    "dropdown-{:?}",
                    match key {
                        ERMenu::Create => (0, 0),
                        ERMenu::Source(id) => (id, 0),
                        ERMenu::Group(id, f) => (id, f),
                    }
                )))
                .absolute()
                .top(px(32.))
                .when(matches!(key, ERMenu::Group(_, _)), |d| d.right_0())
                .when(!matches!(key, ERMenu::Group(_, _)), |d| d.left_0())
                .w(px(190.))
                .max_h(px(300.))
                .overflow_y_scroll()
                .flex()
                .flex_col()
                .gap_1()
                .p_1()
                .rounded_md()
                .bg(white())
                .border_1()
                .border_color(rgb(0xc5ccd8))
                .shadow_md()
                .occlude()
                .on_mouse_down_out(cx.listener(move |s, _, _, cx| {
                    if s.er.dropdown == Some(key) {
                        s.er.dropdown = None;
                        cx.notify();
                    }
                }));
            for (title, allowed, command) in entries {
                popup = popup.child(button(title, allowed, cx, move |s, w, cx| {
                    s.er.dropdown = None;
                    match command["op"].as_str() {
                        Some("$table") => s.er_add(w, cx),
                        Some("$connection") => s.er_begin_connection(cx),
                        Some("$view") => s.er_add_view(w, cx),
                        _ => s.er_command(command.clone(), cx),
                    }
                }));
            }
            control = control.child(deferred(popup).with_priority(2));
        }
        control
    }
    fn er_view_properties(
        &self,
        view: &DataView,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let edit = !self.document.using_document();
        let id = view.id;
        let source_title = self
            .er
            .graph
            .tables
            .iter()
            .find(|t| t.id == view.table)
            .map(|t| t.name.as_str())
            .unwrap_or("Choose a table");
        let mut sources = vec![(
            "Choose a table".into(),
            true,
            json!({"op":"update_data_view","id":id,"table":0}),
        )];
        for t in &self.er.graph.tables {
            sources.push((
                t.name.clone(),
                true,
                json!({"op":"update_data_view","id":id,"table":t.id}),
            ));
        }
        let mut panel = div()
            .flex()
            .flex_col()
            .gap_3()
            .child(div().font_weight(FontWeight::BOLD).child("View"))
            .child("View name");
        panel = if edit {
            panel.child(self.er.name.clone())
        } else {
            panel.child(view.name.clone())
        };
        panel = panel.child("Source table").child(self.er_dropdown(
            format!("{source_title} ▾"),
            ERMenu::Source(id),
            edit,
            sources,
            cx,
        ));
        for included in [true, false] {
            panel = panel.child(
                div()
                    .border_t_1()
                    .border_color(rgb(0xe2e6ed))
                    .pt_3()
                    .font_weight(FontWeight::BOLD)
                    .child(if included {
                        "Selected columns"
                    } else {
                        "Ignored columns"
                    }),
            );
            let fields: Vec<_> = if included {
                view.columns
                    .iter()
                    .filter_map(|c| view.available_columns.iter().find(|f| f.field == c.field))
                    .collect()
            } else {
                view.available_columns
                    .iter()
                    .filter(|f| !view.columns.iter().any(|c| c.field == f.field))
                    .collect()
            };
            if fields.is_empty() {
                panel = panel.child(div().text_color(rgb(0x64748b)).child(if view.table == 0 {
                    "Choose a source table first."
                } else if included {
                    "Choose columns below to include them in this view."
                } else {
                    "All columns are selected."
                }));
            }
            let mut chips = div().flex().flex_wrap().gap_2();
            for field in fields {
                let fid = field.field;
                let current = view
                    .columns
                    .iter()
                    .find(|c| c.field == fid)
                    .map(|c| c.group.as_str())
                    .unwrap_or("none");
                let caption = if current == "none" {
                    field.name.clone()
                } else {
                    format!("{} · {}", field.name, group_title(current))
                };
                let mut chip = div()
                    .flex()
                    .items_center()
                    .gap_1()
                    .px_2()
                    .py_1()
                    .rounded_lg()
                    .border_1()
                    .border_color(rgb(0xcbd5e1))
                    .bg(rgb(if included { 0xe4efff } else { 0xf2f4f7 }));
                if included {
                    chip = chip.child(button("⊗", edit, cx, move |s, _, cx| {
                        s.er_command(json!({"op":"set_view_column","id":id,"field":fid,"included":false}), cx);
                    })).child(div().max_w(px(150.)).child(caption));
                    if field.groups.len() > 1 {
                        let choices = field.groups.iter().map(|group| (
                            format!("{}{}", if group == current { "✓ " } else { "" }, group_title(group)), true,
                            json!({"op":"set_view_column","id":id,"field":fid,"included":true,"group":group})
                        )).collect();
                        chip = chip.child(self.er_dropdown(
                            "▾".into(),
                            ERMenu::Group(id, fid),
                            edit,
                            choices,
                            cx,
                        ));
                    }
                } else {
                    chip = chip.child(button(caption, edit, cx, move |s, _, cx| {
                        s.er_command(json!({"op":"set_view_column","id":id,"field":fid,"included":true,"group":"none"}), cx);
                    }));
                }
                chips = chips.child(chip);
            }
            panel = panel.child(chips);
        }
        if view.grouped {
            panel = panel.child(div().text_color(rgb(0x64748b)).child(
                "Columns set to None define the groups. Aggregate columns summarize each group.",
            ));
        }
        panel
    }
    fn er_inspector(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let edit = !self.document.using_document();
        let schema = edit && !self.document.schema_locked();
        let mut panel = div()
            .id("er-inspector")
            .w(px(self.er.sidebar))
            .h_full()
            .flex_shrink_0()
            .overflow_y_scroll()
            .bg(white())
            .p_4()
            .flex()
            .flex_col()
            .gap_3()
            .text_size(px(14.))
            .child(div().text_size(px(21.)).child("Model details"));
        if let Some(e) = self
            .er
            .graph
            .edges
            .iter()
            .find(|e| Some(e.id) == self.er.edge)
        {
            let source = self
                .er
                .graph
                .tables
                .iter()
                .find(|t| t.id == e.source_table())
                .unwrap();
            let target = self
                .er
                .graph
                .tables
                .iter()
                .find(|t| t.id == e.destination_table())
                .unwrap();
            let id = e.id;
            let many = e.many;
            let cascade = e.cascade;
            panel = panel.child(div().font_weight(FontWeight::BOLD).child("Relationship"))
                .child(format!("From: {}", source.name)).child(format!("To: {}", target.name))
                .child("Reference name")
                .child(if schema { self.er.reference_name.clone().into_any_element() } else { div().child(e.reference_name.clone()).into_any_element() })
                .child(div().text_size(px(12.)).child(format!("Field in {}", target.name)))
                .child("Inverse name (optional)")
                .child(if schema { self.er.inverse_name.clone().into_any_element() } else { div().child(e.inverse_name.clone()).into_any_element() })
                .child(div().text_size(px(12.)).child(format!("Reverse role in {}; shown on 1:1 arrows.", source.name)))
                .child("Cardinality")
                .child(button(if many {"One to many (1:N)"} else {"One to one (1:1)"},schema,cx,move|s,_,cx|s.er_command(json!({"op":"update_connection","id":id,"many":!many,"cascade":false}),cx)))
                .when(many,|d|d.child(button(if cascade {"Delete source record: cascade"}else{"Delete source record: block"},schema,cx,move|s,_,cx|s.er_command(json!({"op":"update_connection","id":id,"many":true,"cascade":!cascade}),cx))))
                .child(button("Delete relationship",schema,cx,move|s,_,cx|s.er_command(json!({"op":"delete_connection","id":id}),cx)));
        } else if let Some(view) = self
            .er
            .graph
            .views
            .iter()
            .find(|v| Some(v.id) == self.er.selected)
        {
            panel = panel.child(self.er_view_properties(view, cx));
        } else if let Some(t) = self
            .er
            .graph
            .tables
            .iter()
            .find(|t| Some(t.id) == self.er.selected)
        {
            let id = t.id;
            panel = panel
                .child(div().font_weight(FontWeight::BOLD).child(t.name.clone()))
                .child("Table name");
            if schema {
                panel = panel.child(self.er.name.clone());
            } else {
                panel = panel.child(t.name.clone());
            }
            panel = panel.child("Table color");
            let mut colors = div().flex().gap_2();
            for c in [
                "#397DB8", "#7651A8", "#258775", "#BA6B28", "#B64762", "#556275",
            ] {
                colors=colors.child(div().id(SharedString::from(c)).size(px(24.)).rounded_full().bg(color(c))
                    .cursor_pointer().when(t.color==c,|d|d.border_2().border_color(black()))
                    .on_click(cx.listener(move|s,_,_,cx| {
                        if edit {
                            s.er_commit_names(cx);
                            if let Some(t)=s.er.graph.tables.iter().find(|t|t.id==id) {
                                s.er_command(json!({"op":"update_table","id":id,"name":t.name,"color":c}),cx);
                            }
                        }
                    })));
            }
            panel = panel.child(colors);
            panel = panel
                .child(
                    div()
                        .border_t_1()
                        .pt_2()
                        .font_weight(FontWeight::BOLD)
                        .child("Fields"),
                )
                .child(button(
                    "Add field ▾",
                    schema && t.fields.len() < 128,
                    cx,
                    |s, _, cx| {
                        s.er_commit_names(cx);
                        s.er.field_menu = if s.er.field_menu == Some(true) {
                            None
                        } else {
                            Some(true)
                        };
                        cx.notify();
                    },
                ));
            if self.er.field_menu == Some(true) && schema {
                let mut choices = div().flex().flex_col().gap_1();
                for (kind, title) in DATATYPES {
                    choices = choices.child(button(title, true, cx, move |s, _, cx| {
                        s.er_add_field(kind, cx)
                    }));
                }
                panel = panel.child(choices);
            }
            if !t.fields.iter().any(Field::ordinary) {
                panel = panel.child("Add fields such as a name, birthday or photo.");
            }
            for f in t.fields.iter().filter(|f| f.ordinary()) {
                let fid = f.id;
                panel = panel.child(
                    button(
                        format!(
                            "{} {} · {}{}",
                            if self.er.selected_field == Some(fid) {
                                "▾"
                            } else {
                                "▸"
                            },
                            f.name,
                            f.title(),
                            if f.indexed || f.unique {
                                " · indexed"
                            } else {
                                ""
                            }
                        ),
                        true,
                        cx,
                        move |s, w, cx| {
                            let next = if s.er.selected_field == Some(fid) {
                                None
                            } else {
                                Some(fid)
                            };
                            s.er_select_field(next, cx);
                            w.focus(&s.er.focus);
                        },
                    )
                    .id(("field-row", fid as usize))
                    .when(self.er.selected_field == Some(fid), |d| d.bg(rgb(0xcfe1fa))),
                );
                if self.er.selected_field == Some(fid) {
                    let mut details = div()
                        .id(("field-details", fid as usize))
                        .flex()
                        .flex_col()
                        .gap_3()
                        .p_3()
                        .ml_2()
                        .border_l_2()
                        .border_color(rgb(0x93b7ea))
                        .bg(rgb(0xf5f8fc))
                        .child("Field name");
                    if schema {
                        details = details.child(self.er.field_name.clone());
                    } else {
                        details = details.child(f.name.clone());
                    }
                    details = details.child(button(
                        format!("Datatype: {} ▾", f.title()),
                        schema,
                        cx,
                        |s, _, cx| {
                            s.er_commit_names(cx);
                            s.er.field_menu = if s.er.field_menu == Some(false) {
                                None
                            } else {
                                Some(false)
                            };
                            cx.notify();
                        },
                    ));
                    if self.er.field_menu == Some(false) && schema {
                        let mut choices = div().flex().flex_col().gap_1();
                        for (kind, title) in DATATYPES {
                            choices = choices.child(button(title, true, cx, move |s, _, cx| {
                                s.er_command(
                                    json!({"op":"update_field","table":id,"id":fid,"kind":kind}),
                                    cx,
                                );
                                s.er.field_menu = None;
                            }));
                        }
                        details = details.child(choices);
                    }
                    let nullable = f.nullable;
                    details = details.child(button(
                        if nullable { "Allow NULL: yes" } else { "Allow NULL: no" },
                        schema,
                        cx,
                        move |s, _, cx| {
                            s.er_command(
                                json!({"op":"update_field","table":id,"id":fid,"nullable":!nullable}),
                                cx,
                            )
                        },
                    ));
                    let unique = f.unique;
                    details = details
                        .child(button(
                            if unique {
                                "Unique values: yes"
                            } else {
                                "Unique values: no"
                            },
                            schema,
                            cx,
                            move |s, _, cx| {
                                s.er_command(
                                    json!({"op":"update_field","table":id,"id":fid,"unique":!unique}),
                                    cx,
                                )
                            },
                        ))
                        .child("NULL means no value; empty text is still a value.");
                    if unique && nullable {
                        details = details.child("Multiple records may have no value. Values that are present must be unique.");
                    }
                    if f.indexable() {
                        let indexed = f.indexed || unique;
                        details = details.child(button(
                            if indexed {
                                "Indexed: yes"
                            } else {
                                "Indexed: no"
                            },
                            schema && !unique,
                            cx,
                            move |s, _, cx| {
                                s.er_command(
                                json!({"op":"update_field","table":id,"id":fid,"indexed":!indexed}),
                                cx,
                            )
                            },
                        ));
                    }
                    if unique {
                        details = details.child("Uniqueness automatically creates an index.");
                    }
                    if f.kind == "decimal" {
                        let scale = f.scale;
                        details=details.child(format!("Decimal places: {scale}"))
                        .child(div().flex().gap_2()
                            .child(button("Fewer places",schema && scale>0,cx,move|s,_,cx|s.er_command(json!({"op":"update_field","table":id,"id":fid,"scale":scale.saturating_sub(1)}),cx)))
                            .child(button("More places",schema && scale<18,cx,move|s,_,cx|s.er_command(json!({"op":"update_field","table":id,"id":fid,"scale":scale+1}),cx))))
                        .child("Exact decimal, up to 18 digits. Uniqueness compares exact decimal values.");
                    }
                    if f.kind == "url" {
                        details=details.child("An absolute URL, such as https://example.com or mailto:person@example.com.");
                    }
                    if f.kind == "blob" {
                        details = details.child("Content");
                        let mut purposes = div().flex().flex_wrap().gap_1();
                        for (media, title) in [
                            ("binary", "Binary data"),
                            ("image", "Image"),
                            ("video", "Video"),
                            ("sound", "Sound"),
                            ("document", "Document"),
                        ] {
                            purposes = purposes.child(
                                button(title, schema, cx, move |s, _, cx| {
                                    s.er_command(
                                    json!({"op":"update_field","table":id,"id":fid,"media":media}),
                                    cx,
                                )
                                })
                                .when(f.media == media, |d| d.bg(rgb(0xcfe1fa))),
                            );
                        }
                        details=details.child(purposes).child("Stored inside the stack, for example a person’s photo. Uniqueness compares the stored bytes.");
                    }
                    details = details.child("CHECK constraint");
                    if !f.check.is_empty() {
                        details = details.child(div().flex().gap_2().items_start()
                            .child(button(f.check_display.clone(), schema, cx, move |s, _, cx| s.er_edit_check(CheckTarget::Field(fid), cx)).flex_1().min_w_0())
                            .child(remove_check_button(format!("remove-field-check-{fid}"), schema, cx, move |s, _, cx| {
                                s.er.check_editor = None;
                                s.er_command(json!({"op":"update_field","table":id,"id":fid,"check":""}), cx);
                            })));
                    } else {
                        details = details.child(button(
                            "Add CHECK expression",
                            schema,
                            cx,
                            move |s, _, cx| s.er_edit_check(CheckTarget::Field(fid), cx),
                        ));
                    }
                    if self.er.check_editor == Some(CheckTarget::Field(fid)) {
                        details = details.child(self.er_check_editor_panel(schema, cx));
                    }
                    details = details.child(button("Delete field", schema, cx, move |s, _, cx| {
                        s.er_command(json!({"op":"delete_field","table":id,"id":fid}), cx)
                    }));
                    panel = panel.child(details.with_animation(
                        ("field-disclosure", fid as usize),
                        Animation::new(Duration::from_millis(220)).with_easing(ease_in_out),
                        |element, progress| element.opacity(progress),
                    ));
                }
            }
            panel = panel.child(
                div()
                    .border_t_1()
                    .pt_2()
                    .font_weight(FontWeight::BOLD)
                    .child("Table CHECK constraints"),
            );
            for constraint in &t.constraints {
                let cid = constraint.id;
                panel = panel.child(
                    div()
                        .flex()
                        .gap_2()
                        .items_start()
                        .child(
                            button(
                                format!("{}: {}", constraint.name, constraint.display_expression),
                                schema,
                                cx,
                                move |s, _, cx| s.er_edit_check(CheckTarget::Table(Some(cid)), cx),
                            )
                            .flex_1()
                            .min_w_0(),
                        )
                        .child(remove_check_button(
                            format!("remove-table-check-{cid}"),
                            schema,
                            cx,
                            move |s, _, cx| {
                                s.er.check_editor = None;
                                s.er_command(
                                    json!({"op":"delete_constraint","table":id,"id":cid}),
                                    cx,
                                );
                            },
                        )),
                );
            }
            panel = panel.child(button("Add named constraint", schema && t.constraints.len() < 32, cx, |s, _, cx| s.er_edit_check(CheckTarget::Table(None), cx)))
                .child("Every CHECK must pass. NULL results are accepted; use Allow NULL to require a field value.");
            if matches!(self.er.check_editor, Some(CheckTarget::Table(_))) {
                panel = panel.child(self.er_check_editor_panel(schema, cx));
            }
        } else {
            panel=panel.child("Select a table, view or relationship arrow to edit its properties.")
                .child("Drag table headers to move. Drag the background or scroll to pan. Ctrl/Command + scroll zooms.");
        }
        panel
            .child(
                div()
                    .border_t_1()
                    .border_color(rgb(0xd2d9e2))
                    .pt_3()
                    .child("100% title em = 1 cm. Calibrate with a ruler for this display."),
            )
            .child(
                div()
                    .flex()
                    .gap_2()
                    .child(button("Scale −", true, cx, |s, _, cx| {
                        let mut v = s.er.viewport();
                        v.calibration /= 1.05;
                        s.er_view(v, cx);
                    }))
                    .child(format!("{:.2}×", self.er.graph.view.calibration))
                    .child(button("Scale +", true, cx, |s, _, cx| {
                        let mut v = s.er.viewport();
                        v.calibration *= 1.05;
                        s.er_view(v, cx);
                    })),
            )
    }
}
fn label(text: &str, p: Point<Pixels>, font_size: f32, color: Hsla, w: &mut Window, cx: &mut App) {
    if font_size < 3. {
        return;
    }
    let run = TextRun {
        len: text.len(),
        font: w.text_style().font(),
        color,
        background_color: None,
        underline: None,
        strikethrough: None,
    };
    let line = w
        .text_system()
        .shape_line(text.to_owned().into(), px(font_size), &[run], None);
    line.paint(p, px(font_size * 1.2), w, cx).ok();
}
#[allow(clippy::too_many_arguments)]
fn paint(
    g: &Graph,
    tables: &[Table],
    selected: Option<i32>,
    selected_edge: Option<i32>,
    pending: Option<i32>,
    link: Option<(f64, f64)>,
    name_bounds: &RefCell<Vec<(i32, NameRect)>>,
    bounds: Bounds<Pixels>,
    w: &mut Window,
    cx: &mut App,
) {
    let s = g.view.zoom * g.view.calibration;
    let screen = |p: (f64, f64)| {
        bounds.origin
            + point(
                px(((p.0 - g.view.pan_x) * s) as f32),
                px(((p.1 - g.view.pan_y) * s) as f32),
            )
    };
    w.with_content_mask(Some(ContentMask { bounds }), |w| {
        let step = 32. * s;
        if step > 7. {
            let mut x = (-g.view.pan_x * s) % step;
            while x < f64::from(bounds.size.width) {
                let mut y = (-g.view.pan_y * s) % step;
                while y < f64::from(bounds.size.height) {
                    w.paint_quad(fill(
                        Bounds::new(
                            bounds.origin + point(px(x as f32), px(y as f32)),
                            size(px(1.5), px(1.5)),
                        ),
                        rgb(0xcbd5e1),
                    ));
                    y += step;
                }
                x += step;
            }
        }
        let draw_line =
            |points: &[(f64, f64)], selected: bool, has_target_port: bool, w: &mut Window| {
                if points.len() < 2 {
                    return;
                }
                let mut p = PathBuilder::stroke(px(if selected { 3. } else { 1.6 }));
                p.move_to(screen(points[0]));
                for q in &points[1..] {
                    p.line_to(screen(*q));
                }
                if let Some(q) = points.last() {
                    let head = arrowhead(*q, has_target_port).map(screen);
                    p.move_to(head[0]);
                    p.line_to(head[1]);
                    p.line_to(head[2]);
                }
                if let Ok(path) = p.build() {
                    w.paint_path(path, rgb(if selected { 0x0066dd } else { 0x64748b }));
                }
            };
        let mut obstacles: Vec<_> = tables
            .iter()
            .map(|t| NameRect {
                x: t.x,
                y: t.y,
                width: 320.,
                height: t.height(),
            })
            .collect();
        let mut cardinality_bounds = Vec::new();
        for e in &g.edges {
            if let Some(p) = label_position(&route(tables, e, &g.edges), s) {
                let font_size = (13. * s).max(10.) as f32;
                let text = if e.many { "1:N" } else { "1:1" };
                let run = TextRun {
                    len: text.len(),
                    font: w.text_style().font(),
                    color: black(),
                    background_color: None,
                    underline: None,
                    strikethrough: None,
                };
                let line = w
                    .text_system()
                    .shape_line(text.into(), px(font_size), &[run], None);
                let width = f64::from(line.width) / s;
                let height = f64::from(font_size) * 1.2 / s;
                let rect = NameRect {
                    x: p.0 - width / 2.,
                    y: p.1 - height / 2.,
                    width,
                    height,
                };
                obstacles.push(rect);
                cardinality_bounds.push((e.id, rect));
            }
        }
        name_bounds.borrow_mut().clear();
        for e in &g.edges {
            let points = route(tables, e, &g.edges);
            draw_line(&points, Some(e.id) == selected_edge, true, w);
            if let Some((_, rect)) = cardinality_bounds.iter().find(|(id, _)| *id == e.id) {
                let p = screen((rect.x, rect.y));
                label(
                    if e.many { "1:N" } else { "1:1" },
                    p,
                    (13. * s).max(10.) as f32,
                    black(),
                    w,
                    cx,
                );
            }
            for (text, source, endpoint) in [
                (e.reference_name.as_str(), false, points.last()),
                (
                    if e.many { "" } else { e.inverse_name.as_str() },
                    true,
                    points.first(),
                ),
            ] {
                let Some(endpoint) = endpoint else {
                    continue;
                };
                if text.is_empty() {
                    continue;
                }
                let font_size = (13. * s).max(10.) as f32;
                let run = TextRun {
                    len: 0,
                    font: w.text_style().font(),
                    color: if Some(e.id) == selected_edge {
                        rgb(0x0066dd).into()
                    } else {
                        black()
                    },
                    background_color: None,
                    underline: None,
                    strikethrough: None,
                };
                let shape = |text: &str| {
                    let mut run = run.clone();
                    run.len = text.len();
                    w.text_system()
                        .shape_line(text.to_owned().into(), px(font_size), &[run], None)
                };
                let mut text = text.to_owned();
                let mut line = shape(&text);
                while f64::from(line.width) > 180. * s.max(0.6) && !text.is_empty() {
                    text.pop();
                    line = shape(&format!("{text}…"));
                }
                let rect = endpoint_label_rect(
                    *endpoint,
                    source,
                    (
                        (f64::from(line.width) + 10.) / s,
                        (f64::from(font_size) * 1.2 + 6.) / s,
                    ),
                    &obstacles,
                    8_f64.max(5. / s),
                );
                obstacles.push(rect);
                name_bounds.borrow_mut().push((e.id, rect));
                let p = screen((rect.x, rect.y));
                w.paint_quad(fill(
                    Bounds::new(
                        p,
                        size(px((rect.width * s) as f32), px((rect.height * s) as f32)),
                    ),
                    white(),
                ));
                line.paint(p + point(px(5.), px(3.)), px(font_size * 1.2), w, cx)
                    .ok();
            }
        }
        for t in tables {
            let p = screen((t.x, t.y));
            let rect = Bounds::new(p, size(px((320. * s) as f32), px((t.height() * s) as f32)));
            let selected = Some(t.id) == selected;
            let c = if selected {
                rgb(0x0066dd).into()
            } else {
                color(&t.color)
            };
            w.paint_quad(quad(
                rect,
                px((8. * s) as f32),
                color(&t.color),
                px(if selected { 3. } else { 1. }),
                c,
                Default::default(),
            ));
            let clip = Bounds::new(
                p + point(px((14. * s) as f32), px(0.)),
                size(px((292. * s) as f32), px((60. * s) as f32)),
            );
            w.with_content_mask(Some(ContentMask { bounds: clip }), |w| {
                label(
                    &t.name,
                    p + point(px((14. * s) as f32), px((12. * s) as f32)),
                    (72. / 2.54 * s) as f32,
                    white(),
                    w,
                    cx,
                )
            });
            let circle = |q: (f64, f64), active: bool, w: &mut Window| {
                let r = px((6. * s) as f32);
                w.paint_quad(quad(
                    Bounds::new(screen(q) - point(r, r), size(r * 2., r * 2.)),
                    r,
                    if active {
                        rgb(0x0066dd)
                    } else {
                        white().into()
                    },
                    px(1.5),
                    rgb(0x0066dd),
                    Default::default(),
                ));
            };
            if !g.views.iter().any(|v| v.id == t.id) {
                circle(port(t, false), false, w);
                circle(port(t, true), pending == Some(t.id), w);
            }
        }
        if let Some(tid) = pending {
            if let (Some(t), Some(p)) = (tables.iter().find(|t| t.id == tid), link) {
                draw_line(&[port(t, true), p], true, false, w);
            }
        }
        if tables.is_empty() {
            label(
                "Add a table to start your data model",
                bounds.origin + point(px(28.), px(40.)),
                20.,
                rgb(0x64748b).into(),
                w,
                cx,
            );
        }
        let (ew, eh) = tables.iter().fold(
            (
                f64::from(bounds.size.width) / s,
                f64::from(bounds.size.height) / s,
            ),
            |(a, b), t| (a.max(t.x + 400.), b.max(t.y + t.height() + 80.)),
        );
        let origin_x = g.view.pan_x.min(0.);
        let origin_y = g.view.pan_y.min(0.);
        let ew = ew.max(g.view.pan_x + f64::from(bounds.size.width) / s) - origin_x;
        let eh = eh.max(g.view.pan_y + f64::from(bounds.size.height) / s) - origin_y;
        if ew * s > f64::from(bounds.size.width) + 1. {
            let width = f32::from(bounds.size.width);
            let len = (width * f64::from(bounds.size.width) as f32 / (ew * s) as f32).max(24.);
            let x = ((g.view.pan_x - origin_x) / (ew - f64::from(bounds.size.width) / s))
                .clamp(0., 1.) as f32
                * (width - len);
            w.paint_quad(fill(
                Bounds::new(
                    bounds.bottom_left() - point(px(0.), px(12.)),
                    size(bounds.size.width, px(12.)),
                ),
                rgb(0xe2e8f0),
            ));
            w.paint_quad(quad(
                Bounds::new(
                    bounds.bottom_left() + point(px(x), px(-11.)),
                    size(px(len), px(10.)),
                ),
                px(5.),
                rgb(0x94a3b8),
                px(0.),
                transparent_black(),
                Default::default(),
            ));
        }
        if eh * s > f64::from(bounds.size.height) + 1. {
            let height = f32::from(bounds.size.height);
            let len = (height * f64::from(bounds.size.height) as f32 / (eh * s) as f32).max(24.);
            let y = ((g.view.pan_y - origin_y) / (eh - f64::from(bounds.size.height) / s))
                .clamp(0., 1.) as f32
                * (height - len);
            w.paint_quad(fill(
                Bounds::new(
                    bounds.top_right() - point(px(12.), px(0.)),
                    size(px(12.), bounds.size.height),
                ),
                rgb(0xe2e8f0),
            ));
            w.paint_quad(quad(
                Bounds::new(
                    bounds.top_right() + point(px(-11.), px(y)),
                    size(px(10.), px(len)),
                ),
                px(5.),
                rgb(0x94a3b8),
                px(0.),
                transparent_black(),
                Default::default(),
            ));
        }
    });
}

#[cfg(test)]
mod viewport_tests {
    use super::{Table, Viewport};
    #[::core::prelude::v1::test]
    fn data_view_projection_uses_shared_core_and_preserves_hidden_identity() {
        use crate::document::Document;
        use serde_json::json;
        let mut doc = Document::new().unwrap();
        for command in [
            json!({"op":"add_table","name":"Sales","x":10,"y":10}),
            json!({"op":"add_field","table":1,"name":"Amount","kind":"float"}),
            json!({"op":"add_data_view","name":"Totals","table":1,"x":400,"y":10}),
        ] {
            doc.er_command(command).unwrap();
        }
        let graph: super::Graph = serde_json::from_str(&doc.er_json().unwrap()).unwrap();
        assert_eq!(graph.views.len(), 1);
        let view = &graph.views[0];
        assert_eq!(view.columns[0].group, "none");
        assert_eq!(view.available_columns[0].name, "Amount");
        assert_eq!(view.node().id, view.id);
        assert!(view.node().fields.is_empty());
        assert!(doc.er_json().unwrap().contains("__subcard_row_id"));
        doc.er_command(
            json!({"op":"set_view_column","id":view.id,"field":2,"included":true,"group":"sum"}),
        )
        .unwrap();
        let graph: super::Graph = serde_json::from_str(&doc.er_json().unwrap()).unwrap();
        assert!(graph.views[0].grouped);
        assert!(!doc.er_json().unwrap().contains("__subcard_row_id"));
        doc.er_command(json!({"op":"undo"})).unwrap();
        assert!(doc.er_json().unwrap().contains("__subcard_row_id"));
        doc.er_command(json!({"op":"set_view_column","id":view.id,"field":2,"included":false}))
            .unwrap();
        doc.er_command(json!({"op":"set_view_column","id":view.id,"field":2,"included":true}))
            .unwrap();
        let graph: super::Graph = serde_json::from_str(&doc.er_json().unwrap()).unwrap();
        assert_eq!(graph.views[0].columns[0].group, "none");
    }
    #[::core::prelude::v1::test]
    fn custom_checks_validate_and_round_trip_through_shared_core() {
        use crate::document::Document;
        use serde_json::json;
        let mut doc = Document::new().unwrap();
        doc.er_command(json!({"op":"add_table","name":"People","x":10,"y":10}))
            .unwrap();
        doc.er_command(json!({"op":"add_field","table":1,"name":"Age","kind":"integer"}))
            .unwrap();
        assert!(doc.validate_check(1, "\"Age\" >= 0").is_ok());
        assert!(doc.validate_check(1, "\"Age\" >").is_err());
        assert!(doc.validate_check(1, "(SELECT 1)").is_err());
        doc.er_command(json!({"op":"update_field","table":1,"id":2,"check":"\"Age\" >= 0"}))
            .unwrap();
        for (name, expression) in [("Adult", "\"Age\" >= 18"), ("Age limit", "\"Age\" <= 150")] {
            doc.er_command(
                json!({"op":"add_constraint","table":1,"name":name,"expression":expression}),
            )
            .unwrap();
        }
        let graph: serde_json::Value = serde_json::from_str(&doc.er_json().unwrap()).unwrap();
        let table: Table = serde_json::from_value(graph["tables"][0].clone()).unwrap();
        assert_eq!(table.constraints.len(), 2);
        assert_eq!(table.fields[0].check_display, "\"Age\" >= 0");
        doc.er_command(json!({"op":"paste_table","table":table}))
            .unwrap();
        let graph: serde_json::Value = serde_json::from_str(&doc.er_json().unwrap()).unwrap();
        let copy: Table = serde_json::from_value(graph["tables"][1].clone()).unwrap();
        assert_eq!(copy.fields[0].check, format!("f{} >= 0", copy.fields[0].id));
        assert_eq!(copy.constraints[0].display_expression, "\"Age\" >= 18");
        assert_ne!(copy.constraints[0].id, table.constraints[0].id);
    }
    #[::core::prelude::v1::test]
    fn relationship_direction_hidden_keys_and_parallel_routes() {
        use super::{Edge, Field, default_media, default_scale, label_position, route};
        let a = Table {
            id: 1,
            name: "A".into(),
            color: "#397DB8".into(),
            x: 10.,
            y: 100.,
            fields: vec![Field {
                id: 7,
                name: "legacy hidden key".into(),
                kind: "secondary".into(),
                unique: true,
                indexed: false,
                nullable: true,
                media: default_media(),
                scale: default_scale(),
                check: String::new(),
                check_display: String::new(),
            }],
            constraints: vec![],
        };
        let b = Table {
            id: 2,
            name: "B".into(),
            color: "#397DB8".into(),
            x: 600.,
            y: 100.,
            fields: vec![],
            constraints: vec![],
        };
        assert_eq!(a.height(), 64.);
        let edge = Edge {
            id: 3,
            table: 1,
            field: 0,
            target: 2,
            many: true,
            cascade: false,
            reference_name: "Reference".into(),
            inverse_name: "Inverse".into(),
        };
        let legacy = Edge {
            id: 4,
            table: 2,
            field: 7,
            target: 1,
            many: false,
            cascade: false,
            reference_name: "Reference".into(),
            inverse_name: "Inverse".into(),
        };
        assert_eq!((edge.source_table(), edge.destination_table()), (1, 2));
        assert_eq!((legacy.source_table(), legacy.destination_table()), (1, 2));
        let tables = vec![a, b];
        let edges = vec![edge, legacy];
        let first = route(&tables, &edges[0], &edges);
        let second = route(&tables, &edges[1], &edges);
        assert_eq!(first.first(), Some(&(330., 130.)));
        assert_eq!(first.last(), Some(&(600., 130.)));
        assert_ne!(first, second);
        assert_ne!(label_position(&first, 1.), label_position(&second, 1.));
        let self_edge = Edge {
            id: 5,
            table: 1,
            field: 0,
            target: 1,
            many: true,
            cascade: false,
            reference_name: "Reference".into(),
            inverse_name: "Inverse".into(),
        };
        let self_route = route(&tables, &self_edge, std::slice::from_ref(&self_edge));
        assert_eq!(self_route.len(), 6);
        assert!(self_route.iter().any(|p| p.1 > 164.));
    }
    #[::core::prelude::v1::test]
    fn relationship_names_and_endpoint_clearance() {
        use super::{Edge, NameRect, endpoint_label_rect};
        use serde_json::json;
        let head = super::arrowhead((100., 30.), true);
        assert_eq!(head, [(85., 25.), (93., 30.), (85., 35.)]);
        assert_eq!(super::arrowhead((100., 30.), false)[1], (100., 30.));
        assert_eq!(
            super::label_position(&[(0., 0.), (100., 0.), (100., 0.), (200., 0.)], 1.),
            Some((100., -12.))
        );
        assert_eq!(
            super::label_position(&[(0., 0.), (20., 0.), (20., 100.)], 1.),
            Some((20., 28.))
        );
        assert_eq!(super::label_position(&[], 1.), None);
        let old: Edge = serde_json::from_value(serde_json::json!({
            "id":3,"table":1,"field":0,"target":2,"many":true,"cascade":false
        }))
        .unwrap();
        assert!(old.reference_name.is_empty() && old.inverse_name.is_empty());
        let mut doc = crate::document::Document::new().unwrap();
        for cmd in [
            json!({"op":"add_table","name":"Colors","x":10,"y":100}),
            json!({"op":"add_table","name":"Products","x":355,"y":100}),
            json!({"op":"add_connection","table":1,"target":2,"referenceName":"Color","inverseName":"Products"}),
            json!({"op":"update_connection","id":3,"many":false}),
        ] {
            doc.er_command(cmd).unwrap();
        }
        let g: super::Graph = serde_json::from_str(&doc.er_json().unwrap()).unwrap();
        assert_eq!(g.edges[0].reference_name, "Color");
        assert_eq!(g.edges[0].inverse_name, "Products");
        assert!(!g.edges[0].many);
        for scale in [0.01, 0.25, 1., 4., 16.] {
            let mut obstacles = vec![
                NameRect {
                    x: 10.,
                    y: 100.,
                    width: 320.,
                    height: 64.,
                },
                NameRect {
                    x: 355.,
                    y: 100.,
                    width: 320.,
                    height: 64.,
                },
                NameRect {
                    x: 0.,
                    y: 20.,
                    width: 320.,
                    height: 64.,
                },
            ];
            for endpoint in [(355., 130.), (10., 130.), (330., 130.)] {
                for source in [false, true] {
                    let rect = endpoint_label_rect(
                        endpoint,
                        source,
                        (190. / scale, 25. / scale),
                        &obstacles,
                        8_f64.max(5. / scale),
                    );
                    assert!(obstacles.iter().all(|o| !rect.intersects(*o, 0.)));
                    obstacles.push(rect);
                }
            }
        }
    }
    #[::core::prelude::v1::test]
    fn typed_field_options_round_trip_without_changing_canvas_geometry() {
        let mut table: Table = serde_json::from_value(serde_json::json!({
            "id":1,"name":"People","color":"#397DB8","x":10.,"y":10.,
            "fields":[
                {"id":2,"name":"Homepage","kind":"url","unique":true,"indexed":false,"nullable":false,"media":"binary","scale":2},
                {"id":3,"name":"Photo","kind":"blob","unique":true,"indexed":false,"media":"image","scale":2},
                {"id":4,"name":"Balance","kind":"decimal","unique":false,"indexed":false,"media":"binary","scale":4},
                {"id":5,"name":"Legacy hidden key","kind":"index"}
            ]
        })).unwrap();
        assert_eq!(table.height(), 64.);
        assert_eq!(table.fields.iter().filter(|f| f.ordinary()).count(), 3);
        assert!(table.fields[0].indexable() && !table.fields[0].indexed && table.fields[0].unique);
        assert!(!table.fields[0].nullable);
        assert!(table.fields[1].nullable && table.fields[1].unique);
        assert_eq!(table.fields[0].title(), "URL");
        assert!(!table.fields[1].indexable() && !table.fields[2].indexable());
        assert!(table.fields[3].unique); // Legacy default stays compatible.
        let copy: Table = serde_json::from_str(&serde_json::to_string(&table).unwrap()).unwrap();
        assert_eq!(copy.fields[1].media, "image");
        assert!(!copy.fields[0].nullable && copy.fields[0].unique && copy.fields[1].nullable);
        assert_eq!(copy.fields[2].scale, 4);
        table.fields.clear();
        assert_eq!(table.height(), copy.height());
    }
    #[::core::prelude::v1::test]
    fn animated_reveal_preserves_scale_and_moves_continuously() {
        let start = Viewport {
            zoom: 2.,
            calibration: 1.3,
            pan_x: -500.,
            pan_y: 800.,
        };
        let target = Viewport {
            pan_x: 1200.,
            pan_y: -300.,
            ..start.clone()
        };
        let mut previous = start.clone();
        for step in 0..=20 {
            let current = start.panned(&target, step as f64 / 20.);
            assert!(current.pan_x >= previous.pan_x && current.pan_y <= previous.pan_y);
            assert_eq!((current.zoom, current.calibration), (2., 1.3));
            previous = current;
        }
        assert_eq!(start.panned(&target, -1.).pan_x, start.pan_x);
        assert_eq!(start.panned(&target, 2.).pan_y, target.pan_y);
        assert_eq!(start.panned(&target, 0.5).pan_x, 350.);
    }
    #[::core::prelude::v1::test]
    fn new_table_is_visible_without_changing_zoom() {
        for (width, height) in [(428., 600.), (900., 500.)] {
            for zoom in [0.0001, 0.25, 1., 2., 4.] {
                for calibration in [0.25, 1., 4.] {
                    for (x, y) in [(0., 0.), (800., 900.), (100000., 100000.)] {
                        let t = Table {
                            id: 1,
                            name: "New table".into(),
                            color: "#397DB8".into(),
                            x,
                            y,
                            fields: vec![],
                            constraints: vec![],
                        };
                        let original = Viewport {
                            zoom,
                            calibration,
                            pan_x: -500.,
                            pan_y: 12000.,
                        };
                        let result = original.revealing_table(&t, width, height);
                        let scale = zoom * calibration;
                        let left = (x - result.pan_x) * scale;
                        let top = (y - result.pan_y) * scale;
                        assert_eq!(result.zoom, zoom);
                        assert_eq!(result.calibration, calibration);
                        assert!(left >= 24. - 1e-6 && top >= 24. - 1e-6);
                        if 320. * scale <= width - 62. {
                            assert!(left + 320. * scale <= width - 38. + 1e-6);
                        } else {
                            assert!((left - 24.).abs() < 1e-6);
                        }
                        if t.height() * scale <= height - 62. {
                            assert!(top + t.height() * scale <= height - 38. + 1e-6);
                        } else {
                            assert!((top - 24.).abs() < 1e-6);
                        }
                    }
                }
            }
        }
    }
    #[::core::prelude::v1::test]
    fn visible_table_does_not_move_camera() {
        let t = Table {
            id: 1,
            name: "Visible".into(),
            color: "#397DB8".into(),
            x: 50.,
            y: 60.,
            fields: vec![],
            constraints: vec![],
        };
        let camera = Viewport {
            pan_x: 10.,
            pan_y: 20.,
            ..Default::default()
        };
        let result = camera.revealing_table(&t, 900., 600.);
        assert_eq!((result.pan_x, result.pan_y), (10., 20.));
        let unmeasured = camera.revealing_table(&t, 0., 0.);
        assert_eq!((unmeasured.pan_x, unmeasured.pan_y), (10., 20.));
    }
}
