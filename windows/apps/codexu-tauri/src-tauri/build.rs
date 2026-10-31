use sha2::{Digest, Sha256};
use std::{env, fs, path::Path};

fn pin_hub() {
    let root = Path::new("resources/companion-hub");
    println!("cargo:rerun-if-changed=resources/companion-hub");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    let manifest = root.join("WINDOWS-RESOURCES.json");
    if !manifest.exists() && env::var("PROFILE").as_deref() != Ok("release") {
        return;
    }
    let receipt: serde_json::Value = serde_json::from_slice(
        &fs::read(&manifest)
            .expect("Prepare verified companion Hub resources before a Windows release"),
    )
    .expect("Hub resource receipt is invalid");
    assert_eq!(receipt["target"], "windows-amd64", "Hub target mismatch");
    let files = receipt["files"]
        .as_object()
        .expect("Hub file inventory missing");
    for name in [
        "aigoodbro-hub.exe",
        "SOURCE.json",
        "LICENSE",
        "LICENSE.x-sys",
    ] {
        let path = root.join(name);
        let metadata = fs::symlink_metadata(&path).expect("Hub resource missing");
        assert!(
            metadata.is_file() && !metadata.file_type().is_symlink(),
            "Hub resource is not regular"
        );
        #[cfg(windows)]
        {
            use std::os::windows::fs::MetadataExt;
            assert_eq!(
                metadata.file_attributes() & 0x400,
                0,
                "Hub resource is a reparse point"
            );
        }
        let data = fs::read(path).expect("Hub resource unreadable");
        let digest = format!("{:x}", Sha256::digest(&data));
        assert_eq!(
            files[name]["sha256"].as_str(),
            Some(digest.as_str()),
            "Hub resource digest mismatch"
        );
        assert_eq!(
            files[name]["size"].as_u64(),
            Some(data.len() as u64),
            "Hub resource size mismatch"
        );
        if name == "aigoodbro-hub.exe" {
            println!("cargo:rustc-env=AIGOODBRO_HUB_BINARY_SHA256={digest}");
        }
    }
}

fn pin_provider_pool() {
    let root = Path::new("resources/provider-pool");
    println!("cargo:rerun-if-changed=resources/provider-pool");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    let manifest = root.join("WINDOWS-RESOURCES.json");
    if !manifest.exists() && env::var("PROFILE").as_deref() != Ok("release") {
        return;
    }
    let receipt: serde_json::Value = serde_json::from_slice(
        &fs::read(&manifest)
            .expect("Prepare verified provider-pool resources before a Windows release"),
    )
    .expect("Provider-pool resource receipt is invalid");
    assert_eq!(receipt["schemaVersion"], 1);
    assert_eq!(
        receipt["target"], "windows-amd64",
        "Provider-pool target mismatch"
    );
    let files = receipt["files"]
        .as_object()
        .expect("Provider-pool file inventory missing");
    assert_eq!(files.len(), 4, "Provider-pool resource inventory mismatch");
    for name in [
        "aigoodbro-antigravity-proxy.exe",
        "SOURCE.json",
        "LICENSE.CLIProxyAPI",
        "LICENSE.Hazmat",
    ] {
        let path = root.join(name);
        let metadata = fs::symlink_metadata(&path).expect("Provider-pool resource missing");
        assert!(
            metadata.is_file() && !metadata.file_type().is_symlink(),
            "Provider-pool resource is not regular"
        );
        #[cfg(windows)]
        {
            use std::os::windows::fs::MetadataExt;
            assert_eq!(
                metadata.file_attributes() & 0x400,
                0,
                "Provider-pool resource is a reparse point"
            );
        }
        let data = fs::read(path).expect("Provider-pool resource unreadable");
        let digest = format!("{:x}", Sha256::digest(&data));
        assert_eq!(
            files[name]["sha256"].as_str(),
            Some(digest.as_str()),
            "Provider-pool resource digest mismatch"
        );
        assert_eq!(
            files[name]["size"].as_u64(),
            Some(data.len() as u64),
            "Provider-pool resource size mismatch"
        );
        if name == "aigoodbro-antigravity-proxy.exe" {
            println!("cargo:rustc-env=AIGOODBRO_PROVIDER_POOL_BINARY_SHA256={digest}");
        }
        if name == "SOURCE.json" {
            println!("cargo:rustc-env=AIGOODBRO_PROVIDER_POOL_SOURCE_SHA256={digest}");
        }
    }
}

fn main() {
    pin_hub();
    pin_provider_pool();
    pin_companion_setup();
    tauri_build::build();
}

fn pin_companion_setup() {
    // Reviewed Windows-native payload; update these only with its source receipt.
    const MANIFEST: &str = "62d9cec9fc00419d3e72b5989a514ffb698e449fac8214daf793aef6a87b5ff9";
    const SOURCE: &str = "41120183e3bcb2efd4a34cd137ec8311b878e5c09584a8c5309dc9c64961d67d";
    let root = Path::new("resources/companion-setup");
    println!("cargo:rerun-if-changed=resources/companion-setup");
    println!("cargo:rerun-if-changed=../../../companion/SOURCE.json");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }
    if !root.exists() && env::var("PROFILE").as_deref() != Ok("release") {
        return;
    }
    fn regular(path: &Path) -> Vec<u8> {
        let metadata = fs::symlink_metadata(path).expect("Companion resource missing");
        assert!(
            metadata.is_file() && !metadata.file_type().is_symlink(),
            "Companion resource is not regular"
        );
        assert!(metadata.len() <= 256 * 1024, "Companion resource too large");
        #[cfg(windows)]
        {
            use std::os::windows::fs::MetadataExt;
            assert_eq!(
                metadata.file_attributes() & 0x400,
                0,
                "Companion resource is a reparse point"
            );
        }
        fs::read(path).expect("Companion resource unreadable")
    }
    fn digest(bytes: &[u8]) -> String {
        format!("{:x}", Sha256::digest(bytes))
    }
    let source = regular(Path::new("../../../companion/SOURCE.json"));
    assert_eq!(digest(&source), SOURCE, "Companion source pin changed");
    let source: serde_json::Value =
        serde_json::from_slice(&source).expect("Companion source receipt invalid");
    let manifest = regular(&root.join("manifest.json"));
    assert_eq!(
        digest(&manifest),
        MANIFEST,
        "Companion manifest pin changed"
    );
    let manifest: serde_json::Value =
        serde_json::from_slice(&manifest).expect("Companion manifest invalid");
    let entries = manifest["files"]
        .as_array()
        .expect("Companion manifest files missing");
    assert_eq!(entries.len(), 16);
    let receipt: serde_json::Value =
        serde_json::from_slice(&regular(&root.join("COMPANION-SETUP-RESOURCES.json")))
            .expect("Companion resource receipt invalid");
    assert_eq!(receipt["target"], "windows-companion-abi1");
    assert_eq!(receipt["sourceSHA256"], SOURCE);
    assert_eq!(receipt["manifestSHA256"], MANIFEST);
    assert_eq!(receipt["resourceFiles"]["manifest.json"], MANIFEST);
    assert_eq!(
        receipt["resourceFiles"]
            .as_object()
            .expect("Companion inventory missing")
            .len(),
        17
    );
    for entry in entries {
        let relative = entry["path"].as_str().expect("Companion path missing");
        // The complete manifest is pinned above, including fixed safe paths.
        let source_path = if relative == "bin/next-dispatch.py" {
            "next-dispatch.py".to_owned()
        } else {
            format!("payload/{relative}")
        };
        let hash = digest(&regular(&root.join(relative)));
        assert_eq!(
            entry["sha256"].as_str(),
            Some(hash.as_str()),
            "Companion payload changed"
        );
        assert_eq!(
            source["sourceFiles"][&source_path].as_str(),
            Some(hash.as_str()),
            "Companion source payload mismatch"
        );
        assert_eq!(
            receipt["resourceFiles"][relative].as_str(),
            Some(hash.as_str()),
            "Companion resource inventory mismatch"
        );
    }
    println!("cargo:rustc-env=AIGOODBRO_COMPANION_SETUP_MANIFEST_SHA256={MANIFEST}");
}
