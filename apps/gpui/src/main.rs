// SPDX-License-Identifier: Apache-2.0
mod document;
mod lifecycle;
mod text_input;

use document::Document;
use gpui::{prelude::*, *};
use std::path::PathBuf;
use text_input::{Copy, Cut, Paste, Redo, SelectAll, TextInput, Undo};

actions!(
    subcard,
    [
        NewDocument,
        OpenDocument,
        Save,
        SaveAs,
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

#[derive(Clone, Copy)]
enum Intent {
    New,
    Open,
    Close,
    Quit,
}

struct SubCardView {
    document: Document,
    input: Entity<TextInput>,
    busy: bool,
    file_menu: bool,
    error: Option<String>,
}

impl SubCardView {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let document = Document::new().expect("Cannot create the initial SQLite document");
        let input = cx.new(|cx| TextInput::new(document.text(), cx));
        cx.observe(&input, |this, input, cx| {
            if let Err(error) = this.document.set_text(&input.read(cx).content) {
                this.error = Some(error);
            }
            cx.notify();
        })
        .detach();
        window.focus(&input.focus_handle(cx));
        let entity = cx.weak_entity();
        window.on_window_should_close(cx, move |window, cx| {
            entity
                .update(cx, |this, cx| {
                    if this.document.changed() || this.busy {
                        this.request(Intent::Close, window, cx);
                        false
                    } else {
                        true
                    }
                })
                .unwrap_or(true)
        });
        Self {
            document,
            input,
            busy: false,
            file_menu: false,
            error: None,
        }
    }

    fn request(&mut self, intent: Intent, window: &mut Window, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        self.file_menu = false;
        if !self.document.changed() {
            self.perform(intent, window, cx);
            return;
        }
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
                    _ => cx.notify(),
                }
            })
            .ok();
        })
        .detach();
        cx.notify();
    }

    fn replace(
        &mut self,
        result: Result<Document, String>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match result {
            Ok(document) => {
                let content = document.text();
                self.document = document;
                self.input
                    .update(cx, |input, cx| input.set_content(content, cx));
                self.error = None;
                window.focus(&self.input.focus_handle(cx));
            }
            Err(error) => self.show_error(error, window, cx),
        }
        cx.notify();
    }

    fn perform(&mut self, intent: Intent, window: &mut Window, cx: &mut Context<Self>) {
        match intent {
            Intent::New => self.replace(Document::new(), window, cx),
            Intent::Close => window.remove_window(),
            Intent::Quit => {
                lifecycle::allow_exit();
                cx.quit();
            }
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
                                    this.replace(Document::open(path), window, cx);
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
            Err(error) => self.show_error(error, window, cx),
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
        if self.busy || !self.document.changed() {
            return;
        }
        self.file_menu = false;
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
                    Ok(Err(error)) => this.show_error(error.to_string(), window, cx),
                    _ => {}
                }
                cx.notify();
            })
            .ok();
        })
        .detach();
        cx.notify();
    }
}

impl Render for SubCardView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let dirty = self.document.changed();
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
                this.file_menu = false;
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
            .on_action(cx.listener(|_this, _: &Quit, _w, cx| {
                #[cfg(target_os = "macos")]
                cx.quit(); // NSApplication asks our termination hook first.
                #[cfg(not(target_os = "macos"))]
                _this.request(Intent::Quit, _w, cx);
            }))
            .on_action(
                cx.listener(|this, _: &ConfirmQuit, w, cx| this.request(Intent::Quit, w, cx)),
            )
            .when(dirty && !self.busy, |el| {
                el.on_action(cx.listener(|this, _: &Save, w, cx| this.save(false, None, w, cx)))
                    .on_action(cx.listener(|this, _: &SaveAs, w, cx| this.save(true, None, w, cx)))
            })
            .when(!cfg!(target_os = "macos"), |el| {
                el.child(
                    div()
                        .flex()
                        .p_2()
                        .gap_4()
                        .child(
                            div()
                                .id("file-menu")
                                .child("File")
                                .cursor_pointer()
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.file_menu = !this.file_menu;
                                    cx.notify();
                                })),
                        )
                        .when(self.file_menu, |el| {
                            el.child(div().id("new").child("New").cursor_pointer().on_click(
                                cx.listener(|this, _, w, cx| this.request(Intent::New, w, cx)),
                            ))
                            .child(div().id("open").child("Open…").cursor_pointer().on_click(
                                cx.listener(|this, _, w, cx| this.request(Intent::Open, w, cx)),
                            ))
                            .child(
                                div()
                                    .id("save")
                                    .child("Save")
                                    .when(!dirty, |el| el.opacity(0.4))
                                    .on_click(
                                        cx.listener(|this, _, w, cx| this.save(false, None, w, cx)),
                                    ),
                            )
                            .child(
                                div()
                                    .id("save-as")
                                    .child("Save As…")
                                    .when(!dirty, |el| el.opacity(0.4))
                                    .on_click(
                                        cx.listener(|this, _, w, cx| this.save(true, None, w, cx)),
                                    ),
                            )
                        }),
                )
            })
            .child(
                div()
                    .flex()
                    .flex_col()
                    .p_8()
                    .gap_4()
                    .child(div().text_size(px(24.)).child(name))
                    .child(div().text_color(rgb(0x606060)).child(if dirty {
                        "Edited"
                    } else {
                        "No unsaved changes"
                    }))
                    .child("Document text")
                    .child(self.input.clone())
                    .when_some(self.error.clone(), |el, error| {
                        el.child(div().text_color(rgb(0xb00020)).child(error))
                    }),
            )
    }
}

fn main() {
    Application::new().run(|cx: &mut App| {
        cx.bind_keys([
            KeyBinding::new("secondary-n", NewDocument, None),
            KeyBinding::new("secondary-o", OpenDocument, None),
            KeyBinding::new("secondary-s", Save, None),
            KeyBinding::new("secondary-shift-s", SaveAs, None),
            KeyBinding::new("secondary-w", Close, None),
            KeyBinding::new("secondary-q", Quit, None),
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
                    MenuItem::os_action("Select All", SelectAll, OsAction::SelectAll),
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
        let bounds = Bounds::centered(None, size(px(720.), px(440.)), cx);
        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                window_min_size: Some(size(px(480.), px(280.))),
                titlebar: Some(TitlebarOptions {
                    title: Some("Untitled — SubCard".into()),
                    ..Default::default()
                }),
                app_id: Some("org.subcard.gpui".into()),
                ..Default::default()
            },
            |w, cx| cx.new(|cx| SubCardView::new(w, cx)),
        )
        .expect("Unable to open SubCard");
        #[cfg(target_os = "macos")]
        {
            let app = cx.to_async();
            lifecycle::install(move || {
                app.update(|cx| cx.dispatch_action(&ConfirmQuit)).ok();
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
