// SPDX-License-Identifier: Apache-2.0
use std::{
    ffi::{CStr, CString, c_char, c_int, c_void},
    path::{Path, PathBuf},
    ptr::NonNull,
};

unsafe extern "C" {
    fn subcard_document_new() -> *mut c_void;
    fn subcard_document_open(path: *const c_char) -> *mut c_void;
    fn subcard_document_close(doc: *mut c_void);
    fn subcard_document_path(doc: *mut c_void) -> *const c_char;
    fn subcard_document_is_changed(doc: *mut c_void) -> c_int;
    fn subcard_document_save(doc: *mut c_void, path: *const c_char) -> c_int;
    fn subcard_document_mode(doc: *mut c_void) -> c_int;
    fn subcard_document_schema_is_locked(doc: *mut c_void) -> c_int;
    fn subcard_document_set_mode(doc: *mut c_void, mode: c_int) -> c_int;
    fn subcard_document_er_json(doc: *mut c_void) -> *const c_char;
    fn subcard_document_er_command(doc: *mut c_void, json: *const c_char) -> c_int;
    fn subcard_last_error() -> *const c_char;
}

// Owned, UI-thread-confined C++ handle. All borrowed strings are copied before
// mutating the handle; Drop releases it exactly once.
pub struct Document(NonNull<c_void>);
fn string(ptr: *const c_char) -> String {
    // SAFETY: SubCardCore guarantees non-null null-terminated borrowed UTF-8.
    unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned()
}
fn error() -> String {
    unsafe { string(subcard_last_error()) }
}
fn path_string(path: &Path) -> Result<CString, String> {
    CString::new(path.to_str().ok_or("The file path is not UTF-8.")?)
        .map_err(|_| "The file path contains a null character.".into())
}
impl Document {
    pub fn new() -> Result<Self, String> {
        NonNull::new(unsafe { subcard_document_new() })
            .map(Self)
            .ok_or_else(error)
    }
    pub fn open(path: &Path) -> Result<Self, String> {
        let path = path_string(path)?;
        NonNull::new(unsafe { subcard_document_open(path.as_ptr()) })
            .map(Self)
            .ok_or_else(error)
    }
    pub fn er_json(&self) -> Result<String, String> {
        let ptr = unsafe { subcard_document_er_json(self.0.as_ptr()) };
        if ptr.is_null() {
            Err(error())
        } else {
            Ok(string(ptr))
        }
    }
    pub fn er_command(&mut self, value: serde_json::Value) -> Result<(), String> {
        let json = CString::new(value.to_string()).map_err(|_| "Invalid command")?;
        if unsafe { subcard_document_er_command(self.0.as_ptr(), json.as_ptr()) } == 0 {
            Err(error())
        } else {
            Ok(())
        }
    }
    pub fn path(&self) -> Option<PathBuf> {
        let path = unsafe { string(subcard_document_path(self.0.as_ptr())) };
        if path.is_empty() {
            None
        } else {
            Some(path.into())
        }
    }
    pub fn changed(&self) -> bool {
        unsafe { subcard_document_is_changed(self.0.as_ptr()) != 0 }
    }
    pub fn using_document(&self) -> bool {
        unsafe { subcard_document_mode(self.0.as_ptr()) == 1 }
    }
    pub fn schema_locked(&self) -> bool {
        unsafe { subcard_document_schema_is_locked(self.0.as_ptr()) != 0 }
    }
    pub fn toggle_mode(&mut self) -> Result<(), String> {
        let next = if self.using_document() { 0 } else { 1 };
        if unsafe { subcard_document_set_mode(self.0.as_ptr(), next) } == 0 {
            Err(error())
        } else {
            Ok(())
        }
    }
    pub fn save(&mut self, path: &Path) -> Result<(), String> {
        let path = path_string(path)?;
        if unsafe { subcard_document_save(self.0.as_ptr(), path.as_ptr()) } == 0 {
            Err(error())
        } else {
            Ok(())
        }
    }
}
impl Drop for Document {
    fn drop(&mut self) {
        unsafe { subcard_document_close(self.0.as_ptr()) };
    }
}
