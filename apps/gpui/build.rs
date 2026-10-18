// SPDX-License-Identifier: Apache-2.0
use std::{env, path::PathBuf};

fn main() {
    let backend = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap()).join("../../backend");
    let source = backend.join("src/SubCardCore.cpp");
    let header = backend.join("include/SubCardCore.h");
    let sqlite = backend.join("../vendor/sqlite");

    println!("cargo:rerun-if-changed={}", source.display());
    println!("cargo:rerun-if-changed={}", header.display());
    println!(
        "cargo:rerun-if-changed={}",
        backend.join("src/Document.cpp").display()
    );
    println!("cargo:rerun-if-changed={}", sqlite.display());
    println!(
        "cargo:rerun-if-changed={}",
        backend.join("src/UserData.cpp").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        backend.join("src/UserData.h").display()
    );

    println!(
        "cargo:rerun-if-changed={}",
        backend.join("src/ERModel.cpp").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        backend.join("src/ERModel.h").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        backend.join("src/UTF8.h").display()
    );
    cc::Build::new()
        .cpp(true)
        .std("c++17")
        .include(backend.join("include"))
        .include(sqlite.join("include"))
        .file(source)
        .file(backend.join("src/Document.cpp"))
        .file(backend.join("src/UserData.cpp"))
        .file(backend.join("src/ERModel.cpp"))
        .warnings(true)
        .compile("subcard_core");

    cc::Build::new()
        .file(sqlite.join("src/sqlite3.c"))
        .include(sqlite.join("include"))
        .define("SQLITE_THREADSAFE", "1")
        .define("SQLITE_OMIT_LOAD_EXTENSION", None)
        .define("SQLITE_DQS", "0")
        .define("SQLITE_TEMP_STORE", "3")
        .warnings(false)
        .compile("subcard_sqlite");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        println!("cargo:rustc-link-lib=pthread");
        println!("cargo:rustc-link-lib=m");
    }
}
