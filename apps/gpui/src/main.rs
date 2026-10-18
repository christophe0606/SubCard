// SPDX-License-Identifier: Apache-2.0
mod document;
mod er;
mod lifecycle;
mod text_input;

use document::Document;
use gpui::{prelude::*, *};
use std::path::PathBuf;
use text_input::{Copy, Cut, Paste, Redo, SelectAll, Undo};

actions!(
    subcard,
    [
        NewDocument,
        OpenDocument,
        Save,
        SaveAs,
        Duplicate,
        EditDocument,
        UseDocument,
        Close,
        Quit,
        ConfirmQuit,
        About,
        Hide,
        HideOthers,
        ShowAll,
        Minimize,
        Zoom
    ]
);

#[derive(Clone, Copy, PartialEq, Eq)]
enum Intent {
    New,
    Open,
    Close,
    Quit,
}

struct SubCardView {
    document: Document,
    busy: bool,
    active_menu: Option<&'static str>,
    error: Option<String>,
    er: er::ERState,
}

impl SubCardView {
    fn new(document: Document, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let entity = cx.weak_entity();
        window.on_window_should_close(cx, move |window, cx| {
            entity
                .update(cx, |this, cx| {
                    this.er_commit_names(cx);
                    if this.document.changed() || this.busy {
                        this.request(Intent::Close, window, cx);
                        false
                    } else {
                        true
                    }
                })
                .unwrap_or(true)
        });
        let er = er::ERState::new(window, cx);
        window.focus(&er.focus);
        Self {
            er,
            document,
            busy: false,
            active_menu: None,
            error: None,
        }
    }

    fn request(&mut self, intent: Intent, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            if intent == Intent::Quit {
                cancel_quit(cx);
            }
            return;
        }
        self.er_commit_names(cx);
        self.active_menu = None;
        if matches!(intent, Intent::New | Intent::Open) || !self.document.changed() {
            self.perform(intent, window, cx);
            return;
        }
        // Quit also visits background documents: their sheets must be visible.
        window.activate_window();
        self.busy = true;
        let answer = window.prompt(
            PromptLevel::Warning,
            "Do you want to save the changes to this document?",
            Some("Your changes will be lost if you don't save them."),
            &["Save", "Cancel", "Don't Save"],
            cx,
        );
        cx.spawn_in(window, async move |this, cx| {
            let answer = answer.await.unwrap_or(1);
            this.update_in(cx, |this, window, cx| {
                this.busy = false;
                match answer {
                    0 => this.save(false, Some(intent), window, cx),
                    2 => this.perform(intent, window, cx),
                    _ => {
                        if intent == Intent::Quit {
                            cancel_quit(cx);
                        }
                        cx.notify();
                    }
                }
            })
            .ok();
        })
        .detach();
        cx.notify();
    }

    fn perform(&mut self, intent: Intent, window: &mut Window, cx: &mut Context<Self>) {
        match intent {
            Intent::New => match Document::new().and_then(|doc| open_document_window(doc, cx)) {
                Ok(()) => {}
                Err(e) => self.show_error(e, window, cx),
            },
            Intent::Close => window.remove_window(),
            Intent::Quit => cx.defer(continue_quit),
            Intent::Open => {
                self.busy = true;
                let paths = cx.prompt_for_paths(PathPromptOptions {
                    files: true,
                    directories: false,
                    multiple: false,
                    prompt: Some("Open SubCard Document".into()),
                });
                cx.spawn_in(window, async move |this, cx| {
                    let paths = paths.await;
                    this.update_in(cx, |this, window, cx| {
                        this.busy = false;
                        match paths {
                            Ok(Ok(Some(paths))) => {
                                if let Some(path) = paths.first() {
                                    if let Err(e) = Document::open(path)
                                        .and_then(|doc| open_document_window(doc, cx))
                                    {
                                        this.show_error(e, window, cx);
                                    }
                                }
                            }
                            Ok(Err(error)) => this.show_error(error.to_string(), window, cx),
                            _ => {}
                        }
                        cx.notify();
                    })
                    .ok();
                })
                .detach();
            }
        }
    }

    fn show_error(&mut self, error: String, window: &mut Window, cx: &mut Context<Self>) {
        self.error = Some(error.clone());
        let response = window.prompt(
            PromptLevel::Critical,
            "SubCard couldn't complete the operation",
            Some(&error),
            &["OK"],
            cx,
        );
        cx.spawn(async move |_, _| {
            response.await.ok();
        })
        .detach();
        cx.notify();
    }

    fn save_to(
        &mut self,
        path: PathBuf,
        after: Option<Intent>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match self.document.save(&path) {
            Ok(()) => {
                self.error = None;
                if let Some(intent) = after {
                    self.perform(intent, window, cx);
                }
            }
            Err(error) => {
                if after == Some(Intent::Quit) {
                    cancel_quit(cx);
                }
                self.show_error(error, window, cx);
            }
        }
        cx.notify();
    }

    fn save(
        &mut self,
        save_as: bool,
        after: Option<Intent>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.er_commit_names(cx);
        if self.busy || !self.document.changed() {
            return;
        }
        self.active_menu = None;
        if !save_as && let Some(path) = self.document.path() {
            self.save_to(path, after, window, cx);
            return;
        }
        self.busy = true;
        let current = self.document.path();
        let directory = current
            .as_ref()
            .and_then(|p| p.parent().map(|p| p.to_owned()))
            .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
        let name = current
            .as_ref()
            .and_then(|p| p.file_name())
            .and_then(|p| p.to_str())
            .unwrap_or("Untitled.subcard");
        let path = cx.prompt_for_new_path(&directory, Some(name));
        cx.spawn_in(window, async move |this, cx| {
            let path = path.await;
            this.update_in(cx, |this, window, cx| {
                this.busy = false;
                match path {
                    Ok(Ok(Some(path))) => this.save_to(path, after, window, cx),
                    Ok(Err(error)) => {
                        if after == Some(Intent::Quit) {
                            cancel_quit(cx);
                        }
                        this.show_error(error.to_string(), window, cx);
                    }
                    _ => {
                        if after == Some(Intent::Quit) {
                            cancel_quit(cx);
                        }
                    }
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
        cx.notify();
    }
    fn toggle_mode(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.er_commit_names(cx);
        if let Err(e) = self.document.toggle_mode() {
            self.show_error(e, window, cx);
        }
        self.active_menu = None;
        window.focus(&self.er.focus);
        cx.notify();
    }
    // Platforms without a native global menubar use an application menubar,
    // separate from the canvas toolbar, with the same action/focus validation.
    fn desktop_menu_item<A: Action + Clone>(
        &self,
        title: &'static str,
        action: A,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Stateful<Div> {
        let enabled = !self.busy && window.is_action_available(&action, cx);
        div()
            .id(title)
            .px_3()
            .py_1()
            .child(title)
            .when(!enabled, |d| d.opacity(0.4))
            .on_click(cx.listener(move |s, _, w, cx| {
                if enabled {
                    s.active_menu = None;
                    w.dispatch_action(Box::new(action.clone()), cx);
                    cx.notify();
                }
            }))
    }
    fn desktop_menu_bar(
        &self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let mut headings = div().flex().gap_3().p_2();
        for title in ["File", "Edit", "View"] {
            headings = headings.child(div().id(title).child(title).cursor_pointer().on_click(
                cx.listener(move |s, _, _, cx| {
                    s.active_menu = if s.active_menu == Some(title) {
                        None
                    } else {
                        Some(title)
                    };
                    cx.notify();
                }),
            ));
        }
        let mut bar = div().flex().flex_col().child(headings);
        let mut items = div().flex().flex_col().bg(white()).border_b_1().py_1();
        match self.active_menu {
            Some("File") => {
                items = items
                    .child(self.desktop_menu_item("New", NewDocument, window, cx))
                    .child(self.desktop_menu_item("Open…", OpenDocument, window, cx))
                    .child(self.desktop_menu_item("Save", Save, window, cx))
                    .child(self.desktop_menu_item("Save As…", SaveAs, window, cx))
                    .child(self.desktop_menu_item("Close", Close, window, cx));
            }
            Some("Edit") => {
                items = items
                    .child(self.desktop_menu_item("Undo", Undo, window, cx))
                    .child(self.desktop_menu_item("Redo", Redo, window, cx))
                    .child(self.desktop_menu_item("Cut", Cut, window, cx))
                    .child(self.desktop_menu_item("Copy", Copy, window, cx))
                    .child(self.desktop_menu_item("Paste", Paste, window, cx))
                    .child(self.desktop_menu_item("Duplicate", Duplicate, window, cx))
                    .child(self.desktop_menu_item("Delete", text_input::Delete, window, cx))
                    .child(self.desktop_menu_item("Select All", SelectAll, window, cx));
            }
            Some("View") => {
                items = items
                    .child(self.desktop_menu_item("Edit document", EditDocument, window, cx))
                    .child(self.desktop_menu_item("Use document", UseDocument, window, cx));
            }
            _ => {}
        }
        if self.active_menu.is_some() {
            bar = bar.child(items);
        }
        bar
    }
}

impl Render for SubCardView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let dirty = self.document.changed() || self.er_has_draft(cx);
        let name = self
            .document
            .path()
            .and_then(|p| p.file_name().map(|p| p.to_string_lossy().into_owned()))
            .unwrap_or("Untitled".into());
        window.set_window_title(&format!("{name} — SubCard"));
        window.set_window_edited(dirty);
        div()
            .on_action(cx.listener(|this, _: &About, w, cx| {
                let response = w.prompt(
                    PromptLevel::Info,
                    "SubCard",
                    Some("Version 0.1.0\nA modern multiplatform HyperCard-inspired application."),
                    &["OK"],
                    cx,
                );
                cx.spawn(async move |_, _| {
                    response.await.ok();
                })
                .detach();
                this.active_menu = None;
            }))
            .on_action(cx.listener(|_, _: &Minimize, w, _| w.minimize_window()))
            .on_action(cx.listener(|_, _: &Zoom, w, _| w.zoom_window()))
            .size_full()
            .flex()
            .flex_col()
            .bg(rgb(0xf6f6f6))
            .text_color(rgb(0x202020))
            .on_action(cx.listener(|this, _: &NewDocument, w, cx| this.request(Intent::New, w, cx)))
            .on_action(
                cx.listener(|this, _: &OpenDocument, w, cx| this.request(Intent::Open, w, cx)),
            )
            .on_action(cx.listener(|this, _: &Close, w, cx| this.request(Intent::Close, w, cx)))
            .on_action(cx.listener(|_, _: &Quit, _, cx| begin_quit(cx)))
            .on_action(cx.listener(|_, _: &ConfirmQuit, _, cx| begin_quit(cx)))
            .when(dirty && !self.busy, |el| {
                el.on_action(cx.listener(|this, _: &Save, w, cx| this.save(false, None, w, cx)))
                    .on_action(cx.listener(|this, _: &SaveAs, w, cx| this.save(true, None, w, cx)))
            })
            .when(!self.busy && self.document.using_document(), |el| {
                el.on_action(cx.listener(|s, _: &EditDocument, w, cx| s.toggle_mode(w, cx)))
            })
            .when(!self.busy && !self.document.using_document(), |el| {
                el.on_action(cx.listener(|s, _: &UseDocument, w, cx| s.toggle_mode(w, cx)))
            })
            .when(!cfg!(target_os = "macos"), |el| {
                el.child(self.desktop_menu_bar(window, cx))
            })
            .child(self.er_render(window, cx))
            .when_some(self.error.clone(), |d, error| {
                d.child(div().p_2().text_color(rgb(0xb00020)).child(error))
            })
    }
}

#[derive(Default)]
struct QuitDocuments {
    active: bool,
    remaining: Vec<WindowHandle<SubCardView>>,
}
impl Global for QuitDocuments {}
fn cancel_quit(cx: &mut App) {
    *cx.global_mut::<QuitDocuments>() = QuitDocuments::default();
}
fn begin_quit(cx: &mut App) {
    if cx.global::<QuitDocuments>().active {
        return;
    }
    let remaining = cx
        .windows()
        .into_iter()
        .filter_map(|w| w.downcast::<SubCardView>())
        .collect();
    cx.set_global(QuitDocuments {
        active: true,
        remaining,
    });
    cx.defer(continue_quit);
}
fn continue_quit(cx: &mut App) {
    if !cx.global::<QuitDocuments>().active {
        return;
    }
    if let Some(window) = cx.global_mut::<QuitDocuments>().remaining.pop() {
        if window
            .update(cx, |s, w, cx| s.request(Intent::Quit, w, cx))
            .is_err()
        {
            cx.defer(continue_quit);
        }
    } else {
        lifecycle::allow_exit();
        cx.quit();
    }
}
fn open_document_window(document: Document, cx: &mut App) -> Result<(), String> {
    let bounds = Bounds::centered(None, size(px(1180.), px(760.)), cx);
    cx.open_window(
        WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(bounds)),
            window_min_size: Some(size(px(720.), px(480.))),
            titlebar: Some(TitlebarOptions {
                title: Some("Untitled — SubCard".into()),
                ..Default::default()
            }),
            app_id: Some("org.subcard.gpui".into()),
            ..Default::default()
        },
        |w, cx| cx.new(|cx| SubCardView::new(document, w, cx)),
    )
    .map_err(|e| e.to_string())?;
    cx.activate(true);
    Ok(())
}

fn main() {
    Application::new().run(|cx: &mut App| {
        cx.bind_keys([
            KeyBinding::new("secondary-z", Undo, Some("ERCanvas")),
            KeyBinding::new("secondary-shift-z", Redo, Some("ERCanvas")),
            KeyBinding::new("secondary-c", Copy, Some("ERCanvas")),
            KeyBinding::new("secondary-x", Cut, Some("ERCanvas")),
            KeyBinding::new("secondary-d", Duplicate, Some("ERCanvas")),
            KeyBinding::new("secondary-v", Paste, Some("ERCanvas")),
            KeyBinding::new("delete", text_input::Delete, Some("ERCanvas")),
            KeyBinding::new("backspace", text_input::Delete, Some("ERCanvas")),
            KeyBinding::new("secondary-n", NewDocument, None),
            KeyBinding::new("secondary-o", OpenDocument, None),
            KeyBinding::new("secondary-s", Save, None),
            KeyBinding::new("secondary-shift-s", SaveAs, None),
            KeyBinding::new("secondary-w", Close, None),
            KeyBinding::new("secondary-q", Quit, None),
            KeyBinding::new("enter", text_input::Submit, Some("TextInput")),
            KeyBinding::new("secondary-a", SelectAll, Some("TextInput")),
            KeyBinding::new("secondary-c", Copy, Some("TextInput")),
            KeyBinding::new("secondary-x", Cut, Some("TextInput")),
            KeyBinding::new("secondary-v", Paste, Some("TextInput")),
            KeyBinding::new("secondary-z", Undo, Some("TextInput")),
            KeyBinding::new(
                if cfg!(target_os = "windows") {
                    "ctrl-y"
                } else {
                    "secondary-shift-z"
                },
                Redo,
                Some("TextInput"),
            ),
            KeyBinding::new("backspace", text_input::Backspace, Some("TextInput")),
            KeyBinding::new("delete", text_input::Delete, Some("TextInput")),
            KeyBinding::new("left", text_input::Left, Some("TextInput")),
            KeyBinding::new("right", text_input::Right, Some("TextInput")),
            KeyBinding::new("shift-left", text_input::SelectLeft, Some("TextInput")),
            KeyBinding::new("shift-right", text_input::SelectRight, Some("TextInput")),
            KeyBinding::new("home", text_input::Home, Some("TextInput")),
            KeyBinding::new("end", text_input::End, Some("TextInput")),
        ]);
        #[cfg(target_os = "macos")]
        cx.bind_keys([
            KeyBinding::new("cmd-h", Hide, None),
            KeyBinding::new("cmd-alt-h", HideOthers, None),
            KeyBinding::new("cmd-m", Minimize, None),
            KeyBinding::new("cmd-left", text_input::Home, Some("TextInput")),
            KeyBinding::new("cmd-right", text_input::End, Some("TextInput")),
            KeyBinding::new(
                "ctrl-cmd-space",
                text_input::ShowCharacterPalette,
                Some("TextInput"),
            ),
        ]);
        cx.on_action(|_: &Hide, cx| cx.hide());
        cx.on_action(|_: &HideOthers, cx| cx.hide_other_apps());
        cx.on_action(|_: &ShowAll, cx| cx.unhide_other_apps());
        cx.set_menus(vec![
            Menu {
                name: "SubCard".into(),
                items: vec![
                    MenuItem::action("About SubCard", About),
                    MenuItem::separator(),
                    MenuItem::os_submenu("Services", SystemMenuType::Services),
                    MenuItem::separator(),
                    MenuItem::action("Hide SubCard", Hide),
                    MenuItem::action("Hide Others", HideOthers),
                    MenuItem::action("Show All", ShowAll),
                    MenuItem::separator(),
                    MenuItem::action("Quit SubCard", Quit),
                ],
            },
            Menu {
                name: "File".into(),
                items: vec![
                    MenuItem::action("New", NewDocument),
                    MenuItem::action("Open…", OpenDocument),
                    MenuItem::separator(),
                    MenuItem::action("Close", Close),
                    MenuItem::action("Save", Save),
                    MenuItem::action("Save As…", SaveAs),
                ],
            },
            Menu {
                name: "Edit".into(),
                items: vec![
                    MenuItem::os_action("Undo", Undo, OsAction::Undo),
                    MenuItem::os_action("Redo", Redo, OsAction::Redo),
                    MenuItem::separator(),
                    MenuItem::os_action("Cut", Cut, OsAction::Cut),
                    MenuItem::os_action("Copy", Copy, OsAction::Copy),
                    MenuItem::os_action("Paste", Paste, OsAction::Paste),
                    MenuItem::separator(),
                    MenuItem::action("Duplicate", Duplicate),
                    MenuItem::action("Delete", text_input::Delete),
                    MenuItem::separator(),
                    MenuItem::os_action("Select All", SelectAll, OsAction::SelectAll),
                ],
            },
            Menu {
                name: "View".into(),
                items: vec![
                    MenuItem::action("Edit document", EditDocument),
                    MenuItem::action("Use document", UseDocument),
                ],
            },
            Menu {
                name: "Window".into(),
                items: vec![
                    MenuItem::action("Minimize", Minimize),
                    MenuItem::action("Zoom", Zoom),
                ],
            },
        ]);
        cx.set_global(QuitDocuments::default());
        open_document_window(Document::new().expect("Cannot create document"), cx)
            .expect("Unable to open SubCard");
        #[cfg(target_os = "macos")]
        {
            let app = cx.to_async();
            lifecycle::install(move || {
                app.update(begin_quit).ok();
            });
        }
        cx.on_window_closed(|cx| {
            if cx.windows().is_empty() {
                lifecycle::allow_exit();
                cx.quit();
            }
        })
        .detach();
        cx.activate(true);
    });
}
