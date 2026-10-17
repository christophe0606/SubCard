// SPDX-License-Identifier: Apache-2.0
// GPUI 0.2.2 exposes window-close interception but not macOS's application
// termination veto. Route Dock Quit / system termination through our Quit action.
#[cfg(target_os = "macos")]
mod macos {
    use std::{
        cell::{Cell, RefCell},
        ffi::{c_char, c_void},
    };
    thread_local! {
        static ALLOW: Cell<bool> = const { Cell::new(false) };
        static REQUEST: RefCell<Option<Box<dyn FnMut()>>> = RefCell::new(None);
    }
    // These are standard macOS Objective-C runtime entry points. send_object is
    // used only for selectors returning an object and taking no arguments.
    #[link(name = "objc")]
    unsafe extern "C" {
        fn objc_getClass(name: *const c_char) -> *mut c_void;
        fn sel_registerName(name: *const c_char) -> *mut c_void;
        #[link_name = "objc_msgSend"]
        fn send_object(receiver: *mut c_void, selector: *mut c_void) -> *mut c_void;
        fn object_getClass(object: *mut c_void) -> *mut c_void;
        fn class_addMethod(
            class: *mut c_void,
            name: *mut c_void,
            implementation: *const c_void,
            types: *const c_char,
        ) -> i8;
    }
    extern "C" fn should_terminate(_: *mut c_void, _: *mut c_void, _: *mut c_void) -> usize {
        if ALLOW.with(Cell::get) {
            return 1;
        } // NSTerminateNow
        REQUEST.with(|callback| {
            if let Ok(mut callback) = callback.try_borrow_mut()
                && let Some(callback) = callback.as_mut()
            {
                callback();
            }
        });
        0 // NSTerminateCancel until Save / Don't Save explicitly approves Quit.
    }
    pub fn install(callback: impl FnMut() + 'static) {
        REQUEST.with(|request| *request.borrow_mut() = Some(Box::new(callback)));
        // SAFETY: Called on the UI thread after GPUI installed its app delegate.
        // The method signature matches NSApplicationDelegate's macOS 64-bit ABI.
        unsafe {
            let application = send_object(
                objc_getClass(c"NSApplication".as_ptr()),
                sel_registerName(c"sharedApplication".as_ptr()),
            );
            let delegate = send_object(application, sel_registerName(c"delegate".as_ptr()));
            assert!(!delegate.is_null());
            assert_ne!(
                class_addMethod(
                    object_getClass(delegate),
                    sel_registerName(c"applicationShouldTerminate:".as_ptr()),
                    should_terminate as *const c_void,
                    c"Q@:@".as_ptr()
                ),
                0,
                "Unable to install document termination protection"
            );
        }
    }
    pub fn allow_exit() {
        ALLOW.with(|value| value.set(true));
    }
}
#[cfg(target_os = "macos")]
pub use macos::*;
#[cfg(not(target_os = "macos"))]
pub fn allow_exit() {}
