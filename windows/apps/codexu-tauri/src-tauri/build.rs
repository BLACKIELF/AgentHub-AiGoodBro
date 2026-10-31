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
    tauri_build::build();
}
