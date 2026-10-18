// SPDX-License-Identifier: Apache-2.0
use crate::{SubCardView, text_input::TextInput};
use gpui::{prelude::*, *};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{cell::Cell, rc::Rc, time::Instant};

fn default_unique() -> bool {
    true
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Field {
    pub id: i32,
    pub name: String,
    pub kind: String,
    #[serde(default = "default_unique")]
    pub unique: bool,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Table {
    pub id: i32,
    pub name: String,
    pub color: String,
    pub x: f64,
    pub y: f64,
    pub fields: Vec<Field>,
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
    pub view: Viewport,
    pub can_undo: bool,
    pub can_redo: bool,
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
pub struct ERState {
    pub graph: Graph,
    reveal: Option<Reveal>,
    pub selected: Option<i32>,
    pub edge: Option<i32>,
    pub focus: FocusHandle,
    pub name: Entity<TextInput>,
    name_baseline: String,
    _subscriptions: Vec<Subscription>,
    pending: Option<i32>,
    link_start: Option<(f64, f64)>,
    drag: Option<Drag>,
    preview: Option<(i32, f64, f64)>,
    link_preview: Option<(f64, f64)>,
    bounds: Rc<Cell<Bounds<Pixels>>>,
    sidebar: f32,
    resizing: bool,
}
impl ERState {
    pub fn new(window: &mut Window, cx: &mut Context<SubCardView>) -> Self {
        let name = cx.new(|cx| TextInput::new(String::new(), cx).with_placeholder("Table name"));
        let mut subscriptions = Vec::new();
        for input in [&name] {
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
            pending: None,
            link_start: None,
            drag: None,
            preview: None,
            link_preview: None,
            bounds: Rc::new(Cell::new(Bounds::default())),
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
    points
        .windows(2)
        .max_by(|a, b| distance(a[0], a[1]).total_cmp(&distance(b[0], b[1])))
        .map(|s| {
            (
                (s[0].0 + s[1].0) / 2. - 10_f64.max(10. / scale),
                (s[0].1 + s[1].1) / 2. - 24_f64.max(24. / scale),
            )
        })
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
impl SubCardView {
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
    }
    fn er_load_names(&mut self, cx: &mut Context<Self>) {
        let name = self
            .er
            .graph
            .tables
            .iter()
            .find(|t| Some(t.id) == self.er.selected)
            .map(|t| t.name.clone())
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
        if let Some(t) = self
            .er
            .graph
            .tables
            .iter()
            .find(|t| Some(t.id) == self.er.selected)
        {
            let name = self.er.name.read(cx).content.to_string();
            if let Err(e) = self
                .document
                .er_command(json!({"op":"update_table","id":t.id,"name":name,"color":t.color}))
            {
                self.error = Some(e);
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
        self.er_load_names(cx);
        w.focus(&self.er.focus);
        cx.notify();
    }
    fn er_begin_connection(&mut self, cx: &mut Context<Self>) {
        self.er_commit_names(cx);
        if !self.document.schema_locked() && !self.document.using_document() {
            self.er.pending = self.er.selected;
            self.er.link_preview = None;
            self.er.link_start = None;
            cx.notify();
        }
    }
    fn er_connect(&mut self, target: i32, cx: &mut Context<Self>) {
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
        if let Some(id) = self.er.edge {
            self.er_command(json!({"op":"delete_connection","id":id}), cx);
        } else if let Some(id) = self.er.selected {
            self.er_command(json!({"op":"delete_table","id":id}), cx);
        }
    }
    fn er_fit(&mut self, cx: &mut Context<Self>) {
        let mut v = self.er.graph.view.clone();
        if self.er.graph.tables.is_empty() {
            v = Viewport::default();
        } else {
            let (mut l, mut t, mut r, mut b) = (f64::MAX, f64::MAX, 0_f64, 0_f64);
            for table in &self.er.graph.tables {
                l = l.min(table.x);
                t = t.min(table.y);
                r = r.max(table.x + 320.);
                b = b.max(table.y + table.height());
            }
            let bounds = self.er.bounds.get();
            v.zoom = ((f64::from(bounds.size.width) - 60.) / (r - l + 80.))
                .min((f64::from(bounds.size.height) - 60.) / (b - t + 80.))
                / v.calibration;
            v.pan_x = (l - 40.).max(0.);
            v.pan_y = (t - 40.).max(0.);
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
                .graph
                .tables
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
                    p.0 >= q.0 && p.0 <= q.0 + width && p.1 >= q.1 && p.1 <= q.1 + height
                });
                label_hit
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
            self.er_command(json!({"op":"move_table","id":id,"x":x,"y":y}), cx);
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
        let selected = self.er.selected;
        let selected_edge = self.er.edge;
        let pending = self.er.pending;
        let link = self.er.link_preview;
        let bounds = self.er.bounds.clone();
        let bounds_paint = bounds.clone();
        let toolbar = div()
            .flex()
            .flex_wrap()
            .gap_2()
            .p_2()
            .border_b_1()
            .border_color(rgb(0xd2d9e2))
            .child(button("+ Table", schema, cx, |s, w, cx| s.er_add(w, cx)))
            .child(button(
                "+ Relationship",
                schema && selected.is_some(),
                cx,
                |s, _, cx| s.er_begin_connection(cx),
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
            .child(button("Undo", edit && graph.can_undo, cx, |s, _, cx| {
                s.er_command(json!({"op":"undo"}), cx)
            }))
            .child(button("Redo", edit && graph.can_redo, cx, |s, _, cx| {
                s.er_command(json!({"op":"redo"}), cx)
            }))
            .child(button("Paste", schema, cx, |s, w, cx| s.er_paste(w, cx)))
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
            .on_action(cx.listener(|s, _: &crate::Undo, _, cx| {
                if s.er.graph.can_undo {
                    s.er_command(json!({"op":"undo"}), cx);
                }
            }))
            .on_action(cx.listener(|s, _: &crate::Redo, _, cx| {
                if s.er.graph.can_redo {
                    s.er_command(json!({"op":"redo"}), cx);
                }
            }))
            .on_action(cx.listener(|s, _: &crate::Copy, _, cx| s.er_copy(cx)))
            .on_action(cx.listener(|s, _: &crate::Paste, w, cx| s.er_paste(w, cx)))
            .on_action(cx.listener(|s, _: &crate::text_input::Delete, _, cx| s.er_delete(cx)))
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
                .child("Cardinality")
                .child(button(if many {"One to many (1:N)"} else {"One to one (1:1)"},schema,cx,move|s,_,cx|s.er_command(json!({"op":"update_connection","id":id,"many":!many,"cascade":false}),cx)))
                .when(many,|d|d.child(button(if cascade {"Delete source record: cascade"}else{"Delete source record: block"},schema,cx,move|s,_,cx|s.er_command(json!({"op":"update_connection","id":id,"many":true,"cascade":!cascade}),cx))))
                .child(button("Delete relationship",schema,cx,move|s,_,cx|s.er_command(json!({"op":"delete_connection","id":id}),cx)));
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
            panel = panel.child(colors)
                .child(button("Create relationship", schema, cx, |s,_,cx| s.er_begin_connection(cx)))
                .child("Choose a table to complete the arrow, or drag the right circle to another table.");
            panel = panel
                .child(
                    div()
                        .border_t_1()
                        .pt_2()
                        .flex()
                        .gap_2()
                        .child(button("Copy", true, cx, |s, _, cx| s.er_copy(cx)))
                        .child(button("Duplicate", schema, cx, |s, w, cx| {
                            s.er_duplicate(w, cx)
                        })),
                )
                .child(button("Delete table", schema, cx, move |s, _, cx| {
                    s.er_command(json!({"op":"delete_table","id":id}), cx)
                }));
        } else {
            panel=panel.child("Select a table or relationship arrow to edit its properties.")
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
        let draw_line = |points: &[(f64, f64)], selected: bool, w: &mut Window| {
            if points.len() < 2 {
                return;
            }
            let mut p = PathBuilder::stroke(px(if selected { 3. } else { 1.6 }));
            p.move_to(screen(points[0]));
            for q in &points[1..] {
                p.line_to(screen(*q));
            }
            if let Some(q) = points.last() {
                let q = screen(*q);
                p.move_to(q + point(px(-8.), px(-5.)));
                p.line_to(q);
                p.line_to(q + point(px(-8.), px(5.)));
            }
            if let Ok(path) = p.build() {
                w.paint_path(path, rgb(if selected { 0x0066dd } else { 0x64748b }));
            }
        };
        for e in &g.edges {
            let points = route(tables, e, &g.edges);
            draw_line(&points, Some(e.id) == selected_edge, w);
            if let Some(position) = label_position(&points, s) {
                let p = screen(position);
                label(
                    if e.many { "1:N" } else { "1:1" },
                    p,
                    (13. * s).max(10.) as f32,
                    black(),
                    w,
                    cx,
                );
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
                px(5.),
                white(),
                px(if selected { 3. } else { 1. }),
                c,
                Default::default(),
            ));
            w.paint_quad(fill(
                Bounds::new(p, size(rect.size.width, px((60. * s) as f32))),
                color(&t.color),
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
            circle(port(t, false), false, w);
            circle(port(t, true), pending == Some(t.id), w);
        }
        if let Some(tid) = pending {
            if let (Some(t), Some(p)) = (tables.iter().find(|t| t.id == tid), link) {
                draw_line(&[port(t, true), p], true, w);
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
    fn relationship_direction_hidden_keys_and_parallel_routes() {
        use super::{Edge, Field, label_position, route};
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
            }],
        };
        let b = Table {
            id: 2,
            name: "B".into(),
            color: "#397DB8".into(),
            x: 600.,
            y: 100.,
            fields: vec![],
        };
        assert_eq!(a.height(), 64.);
        let edge = Edge {
            id: 3,
            table: 1,
            field: 0,
            target: 2,
            many: true,
            cascade: false,
        };
        let legacy = Edge {
            id: 4,
            table: 2,
            field: 7,
            target: 1,
            many: false,
            cascade: false,
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
        };
        let self_route = route(&tables, &self_edge, std::slice::from_ref(&self_edge));
        assert_eq!(self_route.len(), 6);
        assert!(self_route.iter().any(|p| p.1 > 164.));
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
