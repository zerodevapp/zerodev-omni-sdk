use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const REPO: &str = "zerodevapp/zerodev-omni-sdk";
const MANIFEST: &str = include_str!("native-libs.sha256");

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=native-libs.sha256");
    println!("cargo:rerun-if-env-changed=ZERODEV_LIB_DIR");

    let lib_dir = find_lib_dir();

    println!("cargo:rustc-link-search=native={}", lib_dir.display());
    println!("cargo:rustc-link-lib=static=zerodev_aa");
    // secp256k1 is bundled inside libzerodev_aa.a via zabi — no separate archive.

    #[cfg(target_os = "macos")]
    {
        println!("cargo:rustc-link-lib=c");
        println!("cargo:rustc-link-lib=framework=Security");
    }

    #[cfg(target_os = "linux")]
    println!("cargo:rustc-link-lib=c");
}

fn find_lib_dir() -> PathBuf {
    // 1. Explicit env var (skips integrity check — caller's responsibility)
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

    // 3. Auto-download from GitHub Releases (SHA-256 verified against manifest)
    download_prebuilt()
}

fn platform_tag() -> &'static str {
    // Matches keys in native-libs.sha256.
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    return "aarch64-macos";
    #[cfg(all(target_os = "macos", target_arch = "x86_64"))]
    return "x86_64-macos";
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    return "x86_64-linux-gnu";
    #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
    return "aarch64-linux-gnu";
    #[cfg(not(any(
        all(target_os = "macos", target_arch = "aarch64"),
        all(target_os = "macos", target_arch = "x86_64"),
        all(target_os = "linux", target_arch = "x86_64"),
        all(target_os = "linux", target_arch = "aarch64"),
    )))]
    compile_error!("Unsupported platform for zerodev-aa");
}

/// Tarball asset name on GitHub Releases.
fn tarball_name(platform: &str) -> String {
    // Tarball assets drop the "-gnu" suffix from Linux targets.
    let asset_tag = match platform {
        "x86_64-linux-gnu" => "x86_64-linux",
        "aarch64-linux-gnu" => "aarch64-linux",
        other => other,
    };
    format!("zerodev-aa-native-{asset_tag}.tar.gz")
}

/// Parsed manifest: release tag + per-target expected SHA-256.
struct Manifest {
    tag: String,
    expected_hash: String,
}

fn parse_manifest(platform: &str) -> Manifest {
    let mut tag: Option<String> = None;
    let mut expected: Option<String> = None;

    for raw in MANIFEST.lines() {
        let line = raw.trim();
        // Tag directive: `# tag: native-vX.Y.Z`
        if let Some(rest) = line.strip_prefix("# tag:") {
            tag = Some(rest.trim().to_string());
            continue;
        }
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        // `<target>  <sha256>`
        let mut parts = line.split_whitespace();
        let target = parts.next().unwrap_or("");
        let hash = parts.next().unwrap_or("");
        if target == platform && hash.len() == 64 {
            expected = Some(hash.to_ascii_lowercase());
        }
    }

    Manifest {
        tag: tag.expect("native-libs.sha256 is missing `# tag:` directive"),
        expected_hash: expected.unwrap_or_else(|| {
            panic!("native-libs.sha256 has no entry for target `{platform}`")
        }),
    }
}

fn download_prebuilt() -> PathBuf {
    let platform = platform_tag();
    let manifest = parse_manifest(platform);

    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let cache_dir = out_dir.join("zerodev-native");

    // Already extracted + verified for this exact hash? Re-use it.
    let lib_path = cache_dir.join("libzerodev_aa.a");
    let stamp = cache_dir.join(".verified");
    if lib_path.exists()
        && fs::read_to_string(&stamp)
            .map(|s| s.trim().eq_ignore_ascii_case(&manifest.expected_hash))
            .unwrap_or(false)
    {
        return cache_dir;
    }

    // Fresh fetch: wipe any prior contents so a stale (unverified) lib can't
    // sneak through if the cache was left in a half-extracted state.
    if cache_dir.exists() {
        fs::remove_dir_all(&cache_dir).expect("Failed to clear cache dir");
    }
    fs::create_dir_all(&cache_dir).expect("Failed to create cache dir");

    let tarball = tarball_name(platform);
    let tarball_path = cache_dir.join(&tarball);
    let url = format!(
        "https://github.com/{REPO}/releases/download/{tag}/{tarball}",
        tag = manifest.tag,
    );

    eprintln!("Downloading native libraries from {url}");
    let status = Command::new("curl")
        .args(["-sSL", "--fail", "-o"])
        .arg(&tarball_path)
        .arg(&url)
        .status();
    match status {
        Ok(s) if s.success() => {}
        _ => panic!(
            "Failed to download native library from {url}.\n\
             Check your internet connection, or set ZERODEV_LIB_DIR to a locally-built archive."
        ),
    }

    // Verify SHA-256 BEFORE extracting — never write attacker-controlled bytes
    // to disk paths derived from a tarball we haven't authenticated.
    let actual = sha256_hex(&tarball_path);
    if !actual.eq_ignore_ascii_case(&manifest.expected_hash) {
        // Wipe the bad tarball before bailing.
        let _ = fs::remove_file(&tarball_path);
        panic!(
            "Native library integrity check failed for {tarball}.\n\
             expected: {expected}\n\
             actual:   {actual}\n\
             The release asset at {url} does not match the SHA-256 pinned in\n\
             native-libs.sha256 shipped with this crate. This is either a\n\
             corrupted download or a supply-chain tamper — refusing to link.",
            expected = manifest.expected_hash,
        );
    }

    let status = Command::new("tar")
        .args(["xzf"])
        .arg(&tarball_path)
        .arg("-C")
        .arg(&cache_dir)
        .status();
    match status {
        Ok(s) if s.success() => {}
        _ => panic!("Failed to extract {tarball}"),
    }

    let _ = fs::remove_file(&tarball_path);

    if !lib_path.exists() {
        panic!("Tarball {tarball} did not contain libzerodev_aa.a");
    }

    // Stamp the cache so subsequent builds skip the network roundtrip.
    let _ = fs::write(&stamp, &manifest.expected_hash);

    cache_dir
}

/// SHA-256 hex of a file. Shells out to the system tool so we don't need a
/// crypto dep in build.rs.
fn sha256_hex(path: &Path) -> String {
    // Prefer `sha256sum` (Linux). Fall back to `shasum -a 256` (macOS).
    let (cmd, args): (&str, &[&str]) = if Command::new("sha256sum").arg("--version").output().is_ok() {
        ("sha256sum", &[])
    } else {
        ("shasum", &["-a", "256"])
    };

    let out = Command::new(cmd)
        .args(args)
        .arg(path)
        .output()
        .unwrap_or_else(|e| panic!("Failed to run {cmd} for SHA-256: {e}"));

    if !out.status.success() {
        panic!(
            "{cmd} failed for {}: {}",
            path.display(),
            String::from_utf8_lossy(&out.stderr),
        );
    }

    // Output: "<hex>  <path>\n"
    let stdout = String::from_utf8_lossy(&out.stdout);
    stdout
        .split_whitespace()
        .next()
        .unwrap_or("")
        .to_ascii_lowercase()
}
