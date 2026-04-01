fn main() {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let lib_dir = std::path::Path::new(&manifest_dir)
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("zig-out")
        .join("lib");

    if lib_dir.exists() {
        println!("cargo:rustc-link-search=native={}", lib_dir.display());
    } else {
        panic!(
            "Library directory not found: {}. Run `make build` from the project root first.",
            lib_dir.display()
        );
    }

    println!("cargo:rustc-link-lib=static=zerodev_aa");
    println!("cargo:rustc-link-lib=static=secp256k1");

    // Link system C runtime
    #[cfg(target_os = "macos")]
    {
        println!("cargo:rustc-link-lib=c");
        println!("cargo:rustc-link-lib=framework=Security");
    }

    #[cfg(target_os = "linux")]
    println!("cargo:rustc-link-lib=c");

    println!("cargo:rerun-if-changed=build.rs");
}
