// SPDX-License-Identifier: Apache-2.0
use std::{env, path::PathBuf};

fn main() {
    let backend = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap()).join("../../backend");
    let source = backend.join("src/SubCardCore.cpp");
    let header = backend.join("include/SubCardCore.h");

    println!("cargo:rerun-if-changed={}", source.display());
    println!("cargo:rerun-if-changed={}", header.display());

    cc::Build::new()
        .cpp(true)
        .std("c++17")
        .include(backend.join("include"))
        .file(source)
        .warnings(true)
        .compile("subcard_core");
}
