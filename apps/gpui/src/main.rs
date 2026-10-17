// SPDX-License-Identifier: Apache-2.0
use gpui::{
    App, AppContext, Application, Bounds, Context, IntoElement, KeyBinding, Menu, MenuItem, Render,
    SharedString, Styled, TitlebarOptions, Window, WindowBounds, WindowOptions, actions, div,
    prelude::*, px, rgb, size,
};
use std::ffi::{CStr, c_char};

unsafe extern "C" {
    fn subcard_greeting() -> *const c_char;
}

fn greeting() -> SharedString {
    // SAFETY: SubCardCore.h guarantees a non-null, immutable, null-terminated
    // UTF-8 string that remains valid for the lifetime of the process.
    let text = unsafe { CStr::from_ptr(subcard_greeting()) };
    text.to_str()
        .expect("SubCardCore must return UTF-8")
        .to_owned()
        .into()
}

actions!(subcard, [Quit]);

struct SubCardView {
    greeting: SharedString,
}

impl Render for SubCardView {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div()
            .flex()
            .size_full()
            .items_center()
            .justify_center()
            .bg(rgb(0xf5f5f5))
            .text_color(rgb(0x202020))
            .text_size(px(32.0))
            .child(self.greeting.clone())
    }
}

fn main() {
    let greeting = greeting();
    Application::new().run(move |cx: &mut App| {
        cx.on_action(|_: &Quit, cx| cx.quit());
        cx.bind_keys([KeyBinding::new("secondary-q", Quit, None)]);
        cx.set_menus(vec![Menu {
            name: "SubCard".into(),
            items: vec![MenuItem::action("Quit SubCard", Quit)],
        }]);
        cx.on_window_closed(|cx| {
            if cx.windows().is_empty() {
                cx.quit();
            }
        })
        .detach();

        let bounds = Bounds::centered(None, size(px(640.0), px(400.0)), cx);
        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                window_min_size: Some(size(px(320.0), px(200.0))),
                titlebar: Some(TitlebarOptions {
                    title: Some("SubCard".into()),
                    ..Default::default()
                }),
                app_id: Some("org.subcard.gpui".into()),
                ..Default::default()
            },
            |_, cx| cx.new(|_| SubCardView { greeting }),
        )
        .expect("Unable to open the SubCard window");
        cx.activate(true);
    });
}
