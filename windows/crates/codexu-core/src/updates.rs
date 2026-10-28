//! Windows counterpart of AppUpdateDownloadPolicy. Release content is data;
//! no remote command, path or caller-selected URL is ever executable input.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{io::Read, path::Path};
use url::Url;

pub const RELEASE_API: &str =
    "https://api.github.com/repos/BLACKIELF/AgentHub-AiGoodBro/releases/latest";
pub const MAX_PACKAGE_SIZE: u64 = 1_073_741_824;
pub const MAX_RELEASE_SIZE: usize = 2_097_152;
pub const MAX_CHECKSUM_SIZE: usize = 16_384;

#[derive(Clone, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub struct Version([u64; 3]);

impl Version {
    pub fn parse(input: &str) -> Option<Self> {
        let text = input.strip_prefix('v').unwrap_or(input);
        let parts: Vec<_> = text.split('.').collect();
        if parts.len() != 3 {
            return None;
        }
        let mut result = [0; 3];
        for (index, part) in parts.iter().enumerate() {
            if part.is_empty() || !part.bytes().all(|byte| byte.is_ascii_digit()) {
                return None;
            }
            result[index] = part.parse().ok()?;
        }
        Some(Self(result))
    }

    pub fn normalized(&self) -> String {
        format!("{}.{}.{}", self.0[0], self.0[1], self.0[2])
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct ReleaseAsset {
    pub name: String,
    pub browser_download_url: String,
    pub size: u64,
    pub digest: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct Release {
    pub tag_name: String,
    pub name: Option<String>,
    pub body: Option<String>,
    pub html_url: String,
    pub draft: bool,
    pub prerelease: bool,
    pub published_at: Option<String>,
    pub assets: Vec<ReleaseAsset>,
}

#[derive(Clone, Debug)]
pub struct DownloadPlan {
    pub tag: String,
    pub asset: ReleaseAsset,
    pub sha256: Option<String>,
    pub checksum: Option<ReleaseAsset>,
}

#[derive(Clone, Debug, Serialize)]
pub struct UpdateInfo {
    pub current_version: String,
    pub available_version: Option<String>,
    pub release_notes: String,
    pub published_at: Option<String>,
    pub can_download: bool,
    pub asset_name: Option<String>,
    pub asset_size: Option<u64>,
    pub reason_code: Option<String>,
}

fn secure_url(raw: &str) -> Option<Url> {
    let url = Url::parse(raw).ok()?;
    (url.scheme() == "https"
        && url.username().is_empty()
        && url.password().is_none()
        && url.port_or_known_default() == Some(443)
        && url.fragment().is_none())
    .then_some(url)
}

fn repository_path(url: &Url) -> Option<Vec<&str>> {
    if url.host_str()? != "github.com" || url.query().is_some() {
        return None;
    }
    let parts: Vec<_> = url.path().trim_start_matches('/').split('/').collect();
    if parts.len() < 2
        || !parts[0].eq_ignore_ascii_case("BLACKIELF")
        || !["AgentHub-AiGoodBro", "codex-account-manager-next"]
            .iter()
            .any(|name| parts[1].eq_ignore_ascii_case(name))
    {
        return None;
    }
    Some(parts)
}

pub fn trusted_release_url(raw: &str, tag: &str) -> bool {
    secure_url(raw).is_some_and(|url| {
        repository_path(&url).is_some_and(|parts| {
            parts.len() == 5
                && parts[2] == "releases"
                && parts[3] == "tag"
                && parts[4] == tag
                && Version::parse(tag).is_some()
        })
    })
}

pub fn safe_filename(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 240
        && !name.starts_with('.')
        && !name.ends_with(['.', ' '])
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}

pub fn trusted_asset_url(raw: &str, tag: &str, filename: &str) -> bool {
    safe_filename(filename)
        && Version::parse(tag).is_some()
        && secure_url(raw).is_some_and(|url| {
            repository_path(&url).is_some_and(|parts| {
                parts.len() == 6
                    && parts[2] == "releases"
                    && parts[3] == "download"
                    && parts[4] == tag
                    && parts[5] == filename
            })
        })
}

pub fn trusted_redirect_url(raw: &str, tag: &str, filename: &str) -> bool {
    trusted_asset_url(raw, tag, filename)
        || secure_url(raw).is_some_and(|url| {
            matches!(
                url.host_str(),
                Some("release-assets.githubusercontent.com" | "objects.githubusercontent.com")
            ) && url.path().starts_with("/github-production-release-asset-")
        })
}

pub fn normalized_hash(raw: &str) -> Option<String> {
    (raw.len() == 64 && raw.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .then(|| raw.to_ascii_lowercase())
}

pub fn checksum_hash(bytes: &[u8], filename: &str) -> Option<String> {
    if bytes.len() > MAX_CHECKSUM_SIZE || !safe_filename(filename) {
        return None;
    }
    let text = std::str::from_utf8(bytes).ok()?;
    let mut lines = text.lines().filter(|line| !line.trim().is_empty());
    let mut fields = lines.next()?.split_whitespace();
    let hash = normalized_hash(fields.next()?)?;
    let recorded = fields.next()?;
    let recorded = recorded.strip_prefix('*').unwrap_or(recorded);
    if fields.next().is_some() || lines.next().is_some() || recorded != filename {
        return None;
    }
    Some(hash)
}

pub fn select_update(
    bytes: &[u8],
    current_version: &str,
    architecture: &str,
) -> Result<(UpdateInfo, Option<DownloadPlan>), &'static str> {
    if bytes.len() > MAX_RELEASE_SIZE {
        return Err("release_response_too_large");
    }
    let release: Release = serde_json::from_slice(bytes).map_err(|_| "invalid_release")?;
    let current = Version::parse(current_version).ok_or("invalid_current_version")?;
    let latest = Version::parse(&release.tag_name).ok_or("invalid_release_version")?;
    if release.draft
        || release.prerelease
        || release
            .published_at
            .as_deref()
            .and_then(|v| chrono::DateTime::parse_from_rfc3339(v).ok())
            .is_none()
        || !trusted_release_url(&release.html_url, &release.tag_name)
        || release.assets.len() > 100
    {
        return Err("untrusted_release");
    }
    let mut info = UpdateInfo {
        current_version: current.normalized(),
        available_version: None,
        release_notes: String::new(),
        published_at: release.published_at.clone(),
        can_download: false,
        asset_name: None,
        asset_size: None,
        reason_code: None,
    };
    if latest <= current {
        return Ok((info, None));
    }
    info.available_version = Some(latest.normalized());
    info.release_notes = release
        .body
        .unwrap_or_default()
        .chars()
        .take(32_768)
        .collect();
    if architecture != "x86_64" {
        info.reason_code = Some("unsupported_architecture".into());
        return Ok((info, None));
    }
    let version = latest.normalized();
    let names = [
        format!("AiGoodBro-{version}-windows-x86_64.msi"),
        format!("CodexAccountManagerNext-{version}-windows-x86_64.msi"),
        format!("AiGoodBro-{version}-windows-x86_64-setup.exe"),
        format!("CodexAccountManagerNext-{version}-windows-x86_64-setup.exe"),
    ];
    let asset = names.iter().find_map(|name| {
        let mut matches = release.assets.iter().filter(|asset| &asset.name == name);
        let first = matches.next()?;
        matches.next().is_none().then_some(first.clone())
    });
    let Some(asset) = asset else {
        info.reason_code = Some("windows_package_unavailable".into());
        return Ok((info, None));
    };
    if asset.size == 0
        || asset.size > MAX_PACKAGE_SIZE
        || !trusted_asset_url(&asset.browser_download_url, &release.tag_name, &asset.name)
    {
        return Err("untrusted_package");
    }
    let sha256 = match asset.digest.as_deref() {
        Some(value) => Some(
            value
                .strip_prefix("sha256:")
                .and_then(normalized_hash)
                .ok_or("invalid_digest")?,
        ),
        None => None,
    };
    let checksum = if sha256.is_none() {
        let name = format!("{}.sha256", asset.name);
        let matches: Vec<_> = release.assets.iter().filter(|a| a.name == name).collect();
        match matches.as_slice() {
            [sum]
                if sum.size > 0
                    && sum.size <= MAX_CHECKSUM_SIZE as u64
                    && trusted_asset_url(
                        &sum.browser_download_url,
                        &release.tag_name,
                        &sum.name,
                    ) =>
            {
                Some((*sum).clone())
            }
            _ => {
                info.reason_code = Some("checksum_unavailable".into());
                return Ok((info, None));
            }
        }
    } else {
        None
    };
    info.can_download = true;
    info.asset_name = Some(asset.name.clone());
    info.asset_size = Some(asset.size);
    Ok((
        info,
        Some(DownloadPlan {
            tag: release.tag_name,
            asset,
            sha256,
            checksum,
        }),
    ))
}

pub fn verify_file(
    path: &Path,
    expected_size: u64,
    expected_hash: &str,
) -> Result<(), &'static str> {
    let metadata = std::fs::symlink_metadata(path).map_err(|_| "download_missing")?;
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.len() != expected_size
        || normalized_hash(expected_hash).is_none()
    {
        return Err("package_changed");
    }
    let mut file = std::fs::File::open(path).map_err(|_| "download_unreadable")?;
    let mut digest = Sha256::new();
    let mut bytes = [0u8; 65_536];
    let mut size = 0u64;
    loop {
        let count = file.read(&mut bytes).map_err(|_| "download_unreadable")?;
        if count == 0 {
            break;
        }
        size += count as u64;
        if size > expected_size {
            return Err("package_changed");
        }
        digest.update(&bytes[..count]);
    }
    if size != expected_size
        || format!("{:x}", digest.finalize()) != expected_hash.to_ascii_lowercase()
    {
        return Err("checksum_mismatch");
    }
    Ok(())
}

/// A canonical Windows path can have a `\\?\` prefix even when the selected
/// AppData path does not. Inspect existing ancestors instead of comparing the
/// two spellings, and reject links/reparse points before creating staging data.
pub fn safe_download_directory(path: &Path) -> bool {
    if !path.is_absolute()
        || path.components().any(|part| {
            matches!(
                part,
                std::path::Component::ParentDir | std::path::Component::CurDir
            )
        })
    {
        return false;
    }
    for ancestor in path.ancestors() {
        match std::fs::symlink_metadata(ancestor) {
            Ok(metadata) => {
                if !metadata.is_dir() || metadata.file_type().is_symlink() {
                    return false;
                }
                #[cfg(windows)]
                {
                    use std::os::windows::fs::MetadataExt;
                    if metadata.file_attributes() & 0x400 != 0 {
                        return false;
                    }
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => (),
            Err(_) => return false,
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    fn release() -> serde_json::Value {
        serde_json::json!({
            "tag_name":"v9.2.1", "name":"Update", "body":"Real release notes", "html_url":"https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/tag/v9.2.1",
            "draft":false,"prerelease":false,"published_at":"2026-10-29T00:00:00Z",
            "assets":[{"name":"AiGoodBro-9.2.1-windows-x86_64.msi","browser_download_url":"https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v9.2.1/AiGoodBro-9.2.1-windows-x86_64.msi","size":4,"digest":format!("sha256:{}", "a".repeat(64))}]
        })
    }
    fn select(
        value: &serde_json::Value,
    ) -> Result<(UpdateInfo, Option<DownloadPlan>), &'static str> {
        select_update(&serde_json::to_vec(value).unwrap(), "9.2.0", "x86_64")
    }
    #[test]
    fn newer_trusted_release_and_exact_platform_required() {
        let value = release();
        let (info, plan) = select(&value).unwrap();
        assert!(info.can_download);
        assert_eq!(info.available_version.as_deref(), Some("9.2.1"));
        assert_eq!(plan.unwrap().asset.size, 4);
        assert!(
            select_update(&serde_json::to_vec(&value).unwrap(), "9.2.1", "x86_64")
                .unwrap()
                .1
                .is_none()
        );
        assert!(
            !select_update(&serde_json::to_vec(&value).unwrap(), "9.2.0", "aarch64")
                .unwrap()
                .0
                .can_download
        );
        for version in [
            "1.2",
            "1.2.3-beta",
            "1.2.3/evil",
            "1.2.3?x",
            "-1.2.3",
            "1.2.3.4",
        ] {
            assert!(Version::parse(version).is_none());
        }
    }
    #[test]
    fn rejects_draft_malformed_and_untrusted_downloads() {
        for key in ["draft", "prerelease"] {
            let mut value = release();
            value[key] = true.into();
            assert!(select(&value).is_err());
        }
        for url in ["https://example.invalid/package.msi", "http://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v9.2.1/AiGoodBro-9.2.1-windows-x86_64.msi", "https://github.com@evil.invalid/a.msi", "https://github.com:8443/BLACKIELF/AgentHub-AiGoodBro/releases/download/v9.2.1/AiGoodBro-9.2.1-windows-x86_64.msi"] {
            let mut value = release(); value["assets"][0]["browser_download_url"] = url.into(); assert!(select(&value).is_err());
        }
        let mut value = release();
        value["assets"][0]["digest"] = "sha256:broken".into();
        assert!(select(&value).is_err());
        let mut value = release();
        value["assets"][0]["size"] = (MAX_PACKAGE_SIZE + 1).into();
        assert!(select(&value).is_err());
        let mut value = release();
        value["published_at"] = "unknown".into();
        assert!(select(&value).is_err());
    }
    #[test]
    fn checksum_fallback_is_required_and_bound_to_filename() {
        let mut value = release();
        value["assets"][0]["digest"] = serde_json::Value::Null;
        assert!(!select(&value).unwrap().0.can_download);
        let mut sum = value["assets"][0].clone();
        let filename = "AiGoodBro-9.2.1-windows-x86_64.msi.sha256";
        sum["name"] = filename.into();
        sum["browser_download_url"] = format!(
            "https://github.com/BLACKIELF/AgentHub-AiGoodBro/releases/download/v9.2.1/{filename}"
        )
        .into();
        value["assets"].as_array_mut().unwrap().push(sum);
        assert!(select(&value).unwrap().1.unwrap().checksum.is_some());
        let h = "a".repeat(64);
        assert_eq!(
            checksum_hash(format!("{h}  package.msi\n").as_bytes(), "package.msi"),
            Some(h.clone())
        );
        assert_eq!(
            checksum_hash(format!("{h} *package.msi\n").as_bytes(), "package.msi"),
            Some(h.clone())
        );
        for text in [
            format!("{h}  other.msi"),
            format!("{h}  ../package.msi"),
            format!("{h}  package.msi\n{h}  second.msi"),
            format!("{h}  package.msi extra"),
        ] {
            assert!(checksum_hash(text.as_bytes(), "package.msi").is_none());
        }
    }
    #[test]
    fn download_reverified_after_tampering() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("package.msi");
        std::fs::write(&path, b"test").unwrap();
        let hash = format!("{:x}", Sha256::digest(b"test"));
        assert!(verify_file(&path, 4, &hash).is_ok());
        std::fs::write(&path, b"evil").unwrap();
        assert_eq!(verify_file(&path, 4, &hash), Err("checksum_mismatch"));
        std::fs::write(&path, b"longer").unwrap();
        assert_eq!(verify_file(&path, 4, &hash), Err("package_changed"));
    }
}
