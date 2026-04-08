use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const VERSION: &str = "0.0.1-alpha";
const REPO: &str = "zerodevapp/zerodev-omni-sdk";

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=ZERODEV_LIB_DIR");

    let lib_dir = find_lib_dir();

    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=static=zerodev_aa");
    println!("cargo:rustc-link-lib=static=secp256k1");

    #[cfg(target_os = "macos")]
    {
        println!("cargo:rustc-link-lib=c");
        println!("cargo:rustc-link-lib=framework=Security");
    }

    #[cfg(target_os = "linux")]
    println!("cargo:rustc-link-lib=c");
}

fn find_lib_dir() -> PathBuf {
    // 1. Explicit env var
    if let Ok(dir) = env::var("ZERODEV_LIB_DIR") {
        let p = PathBuf::from(&dir);
        if p.join("libzerodev_aa.a").exists() {
            return p;
        }
        panic!("ZERODEV_LIB_DIR={dir} does not contain libzerodev_aa.a");
    }

    // 2. Local dev: relative to manifest (../../zig-out/lib)
    let manifest_dir = env::var("CARGO_MANIFEST_DIR").unwrap();
    let local = Path::new(&manifest_dir)
        .parent().unwrap()
        .parent().unwrap()
        .join("zig-out").join("lib");
    if local.join("libzerodev_aa.a").exists() {
        return local;
    }

    // 3. Auto-download from GitHub Releases
    let cache_dir = download_prebuilt();
    if cache_dir.join("libzerodev_aa.a").exists() {
        return cache_dir;
    }

    panic!(
        "Could not find native libraries. Options:\n\
         1. Build from source: `make build` in the SDK root\n\
         2. Set ZERODEV_LIB_DIR to a directory containing libzerodev_aa.a\n\
         3. Check your internet connection (auto-download failed)"
    );
}

fn platform_tag() -> &'static str {
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    return "aarch64-macos";
    #[cfg(all(target_os = "macos", target_arch = "x86_64"))]
    return "x86_64-macos";
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    return "x86_64-linux";
    #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
    return "aarch64-linux";
    #[cfg(not(any(
        all(target_os = "macos", target_arch = "aarch64"),
        all(target_os = "macos", target_arch = "x86_64"),
        all(target_os = "linux", target_arch = "x86_64"),
        all(target_os = "linux", target_arch = "aarch64"),
    )))]
    compile_error!("Unsupported platform for zerodev-aa");
}

fn download_prebuilt() -> PathBuf {
    let tag = platform_tag();
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let cache_dir = out_dir.join("zerodev-native");

    // Already cached?
    if cache_dir.join("libzerodev_aa.a").exists() {
        return cache_dir;
    }

    let tarball = format!("zerodev-aa-native-{tag}.tar.gz");
    let url = format!("https://github.com/{REPO}/releases/download/native-v{VERSION}/{tarball}");

    eprintln!("Downloading native libraries from {url}");

    fs::create_dir_all(&cache_dir).expect("Failed to create cache dir");

    let status = Command::new("curl")
        .args(["-sSL", "--fail", "-o"])
        .arg(cache_dir.join(&tarball))
        .arg(&url)
        .status();

    match status {
        Ok(s) if s.success() => {}
        _ => {
            eprintln!("Failed to download {url}");
            return cache_dir;
        }
    }

    let status = Command::new("tar")
        .args(["xzf"])
        .arg(cache_dir.join(&tarball))
        .arg("-C")
        .arg(&cache_dir)
        .status();

    match status {
        Ok(s) if s.success() => {}
        _ => eprintln!("Failed to extract {tarball}"),
    }

    // Clean up tarball
    let _ = fs::remove_file(cache_dir.join(&tarball));

    cache_dir
}
