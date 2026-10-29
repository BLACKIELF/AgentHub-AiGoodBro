//! A fixed own-Codex setup task followed by independent package verification.
//! None of the task's text or candidate JSON has authority to mark a tool ready.
use super::{
    launch::{self, Edition},
    LocalCliKind,
};
use crate::{
    accounts::{storage, DpapiProtector, SecretProtector},
    token_monitor::VerifiedNodeRuntime,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::File,
    io::{Read, Seek, SeekFrom},
    path::{Path, PathBuf},
    sync::Arc,
};
pub const VERIFIER: &[u8] = include_bytes!("dependency_verify.cjs");
const CONTEXT: &str = "AiGoodBro.Next.Windows.local-cli-runtime.v1";
pub struct PreparedTask {
    pub id: String,
    pub platform: LocalCliKind,
    pub directory: PathBuf,
    pub prompt: String,
}
pub fn supported(kind: LocalCliKind) -> bool {
    !matches!(kind, LocalCliKind::Codex | LocalCliKind::Mimo)
}
pub fn prepare(
    app_data: &Path,
    kind: LocalCliKind,
    edition: Option<Edition>,
) -> launch::Result<PreparedTask> {
    if !supported(kind) || edition.is_some() && kind != LocalCliKind::WorkBuddy {
        return Err(error("platform_not_supported"));
    }
    let id = hex(&launch::session_nonce()?);
    let directory = app_data.join("local-cli-setup").join(&id);
    storage::secure_directory(directory.parent().unwrap())
        .map_err(|_| error("dependency_storage_failed"))?;
    storage::create_private_directory(&directory)
        .map_err(|_| error("dependency_storage_failed"))?;
    let package = match kind {
        LocalCliKind::Grok => "@xai-official/grok",
        LocalCliKind::OpenCode => "opencode-ai",
        LocalCliKind::Kimi => "@moonshot-ai/kimi-code",
        LocalCliKind::Gemini => "@google/gemini-cli",
        LocalCliKind::WorkBuddy => "WorkBuddy 官方已装 bundle（不能用普通 CodeBuddy npm 包代替）",
        _ => "该工具官方 Windows 安装",
    };
    let prompt=format!("请在这台 Windows 为 AiGoodBro 准备 {}。使用当前这台机器已有的 Codex 与本次登录；不重新安装或切换 Codex/Claude，不复制其他电脑 auth/config。\n先检查已有 {}，可用则复用；必要时只从一手官方来源下载配置，优先本工作目录 tool 子目录或用户级安装，不更改全局代理/认证/安全设置，不停止其他进程。保留 Codex 本身审批；扫码/付费/系统批准由本人完成。\n对于 npm CLI，官方包名为 {}（WorkBuddy 除外）。保存精确 package-lock，优先 npm --prefix ./tool install --ignore-scripts --registry=https://registry.npmjs.org/ <精确官方包和版本>；必要安装步骤必须先从官方说明核实，不能擅自运行不明 lifecycle。包目录必须保留完整官方依赖；不要添加入口脚本或修改包文件。\n完成后在当前目录写 candidate.json：{{\"schema\":1,\"platform\":\"{}\",\"package_root\":\"实际 npm 包根绝对路径\",\"edition\":\"{}\"}}。这里是包根而不是 .cmd shim；已有安装可直接指向其真实根。原生/桌面或 WorkBuddy 也请记录官方来源与实际安装入口到 notes.md，若没有 npm 对应必须如实说明。\n验证 --version，并用合成配置目录检查隔离变量/落点；不发送任何第三方模型请求、不执行付费调用，不读取或记录token/完整邮箱。任务结束后输入 /quit 正常退出本次 Codex，AiGoodBro 将独立校验官方 registry tarball SHA512、实际文件、运行时与版本后启用。不要自行写 verified 或声称应用已全部就绪。",kind.display_name(),kind.display_name(),package,kind.id(),if edition==Some(Edition::International){"international"}else{"domestic"});
    storage::atomic_write(&directory.join("TASK.txt"), prompt.as_bytes())
        .map_err(|_| error("dependency_storage_failed"))?;
    Ok(PreparedTask {
        id,
        platform: kind,
        directory,
        prompt,
    })
}
pub fn valid_id(id: &str) -> bool {
    id.len() == 32
        && id
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}
fn error(code: &'static str) -> launch::Error {
    launch::Error { code }
}
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
pub fn verifier_file(task: &Path) -> launch::Result<(PathBuf, File)> {
    let path = task.join("verify.cjs");
    storage::atomic_write(&path, VERIFIER).map_err(|_| error("dependency_storage_failed"))?;
    let mut file = hold(&path)?;
    if read(&mut file, 256 * 1024)? != VERIFIER {
        return Err(error("verification_source_changed"));
    }
    Ok((path, file))
}
pub fn capture_file(task: &Path, name: &str) -> launch::Result<File> {
    if !matches!(name, "verification.json" | "version.txt") {
        return Err(error("dependency_storage_failed"));
    }
    let path = task.join(name);
    storage::ensure_no_links(&path).map_err(|_| error("dependency_storage_failed"))?;
    let mut options = std::fs::OpenOptions::new();
    options.read(true).write(true).create_new(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.share_mode(1);
    }
    options
        .open(path)
        .map_err(|_| error("dependency_storage_failed"))
}
pub fn captured(file: &mut File) -> launch::Result<Vec<u8>> {
    read(file, 8 * 1024 * 1024)
}
fn read(file: &mut File, max: u64) -> launch::Result<Vec<u8>> {
    file.seek(SeekFrom::Start(0))
        .map_err(|_| error("dependency_read_failed"))?;
    let mut b = Vec::new();
    file.take(max + 1)
        .read_to_end(&mut b)
        .map_err(|_| error("dependency_read_failed"))?;
    if b.len() as u64 > max {
        return Err(error("verification_report_large"));
    }
    Ok(b)
}
fn hold(path: &Path) -> launch::Result<File> {
    storage::ensure_no_links(path).map_err(|_| error("package_path_linked"))?;
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.share_mode(1);
    }
    let file = options
        .open(path)
        .map_err(|_| error("package_file_unavailable"))?;
    if !file
        .metadata()
        .map_err(|_| error("package_file_unavailable"))?
        .is_file()
    {
        return Err(error("package_file_invalid"));
    }
    Ok(file)
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Package {
    root: PathBuf,
    name: String,
    version: String,
    integrity: String,
    files: BTreeMap<String, String>,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Receipt {
    schema: u32,
    platform: String,
    version: String,
    entry: PathBuf,
    entry_type: String,
    product: Option<PathBuf>,
    packages: Vec<Package>,
    #[serde(default)]
    snapshot: Option<PathBuf>,
}
pub struct VerifiedRuntime {
    record: Receipt,
    executable: PathBuf,
    prefix: Vec<String>,
    _files: Vec<File>,
    _node: Arc<VerifiedNodeRuntime>,
}
impl VerifiedRuntime {
    pub fn executable(&self) -> &Path {
        &self.executable
    }
    pub fn prefix(&self) -> &[String] {
        &self.prefix
    }
    pub fn version(&self) -> &str {
        &self.record.version
    }
    pub fn executable_guard(&self) -> launch::Result<File> {
        hold(&self.executable)
    }
    pub fn product_config(&self) -> Option<&Path> {
        self.record.product.as_deref()
    }
    /// Copy only files authenticated by official tarballs. An unrelated package
    /// in the user's existing node_modules never becomes part of the runtime.
    pub fn stage(&self, app_data: &Path) -> launch::Result<Self> {
        let mut common = self.record.packages[0].root.clone();
        while !self
            .record
            .packages
            .iter()
            .all(|p| p.root.starts_with(&common))
        {
            if !common.pop() {
                return Err(error("package_path_invalid"));
            }
        }
        let parent = app_data.join("local-cli-runtimes/snapshots");
        storage::secure_directory(&parent).map_err(|_| error("dependency_storage_failed"))?;
        let root = parent.join(hex(&launch::session_nonce()?));
        storage::create_private_directory(&root).map_err(|_| error("dependency_storage_failed"))?;
        let mut record = self.record.clone();
        let relocate = |path: &Path| -> launch::Result<PathBuf> {
            Ok(root.join(
                path.strip_prefix(&common)
                    .map_err(|_| error("package_path_invalid"))?,
            ))
        };
        record.entry = relocate(&record.entry)?;
        record.product = record.product.as_ref().map(|p| relocate(p)).transpose()?;
        let mut written = BTreeSet::new();
        let mut total = 0u64;
        for package in &mut record.packages {
            let original = package.root.clone();
            package.root = relocate(&original)?;
            for (rel, digest) in &package.files {
                let dest = package.root.join(rel);
                if !written.insert(dest.clone()) {
                    continue;
                }
                let mut file = hold(&original.join(rel))?;
                let bytes = read(&mut file, 128 * 1024 * 1024)?;
                total += bytes.len() as u64;
                if total > 512 * 1024 * 1024 || hex(&Sha256::digest(&bytes)) != *digest {
                    return Err(error("package_files_changed"));
                }
                storage::secure_directory(
                    dest.parent().ok_or_else(|| error("package_path_invalid"))?,
                )
                .map_err(|_| error("dependency_storage_failed"))?;
                storage::atomic_write(&dest, &bytes)
                    .map_err(|_| error("dependency_storage_failed"))?;
            }
        }
        record.snapshot = Some(root);
        verify_record(
            LocalCliKind::parse(&record.platform).ok_or_else(|| error("platform_not_supported"))?,
            record,
            self._node.clone(),
        )
    }
    pub fn persist(&self, app_data: &Path) -> launch::Result<()> {
        if self.record.snapshot.is_none() {
            return Err(error("dependency_verification_failed"));
        }
        storage::secure_directory(&app_data.join("local-cli-runtimes"))
            .map_err(|_| error("dependency_storage_failed"))?;
        let b = serde_json::to_vec(&self.record).map_err(|_| error("verification_failed"))?;
        let sealed = DpapiProtector
            .seal(CONTEXT, &b)
            .map_err(|_| error("dependency_storage_failed"))?;
        storage::atomic_write(&receipt_path(app_data, &self.record.platform), &sealed)
            .map_err(|_| error("dependency_storage_failed"))
    }
}
fn receipt_path(app_data: &Path, platform: &str) -> PathBuf {
    app_data
        .join("local-cli-runtimes")
        .join(format!("{platform}.dpapi"))
}
pub fn accept_report(
    kind: LocalCliKind,
    bytes: &[u8],
    node: Arc<VerifiedNodeRuntime>,
) -> launch::Result<VerifiedRuntime> {
    if bytes.len() > 8 * 1024 * 1024 {
        return Err(error("verification_report_large"));
    }
    if let Ok(value) = serde_json::from_slice::<serde_json::Value>(bytes) {
        if let Some(code) = value.get("error").and_then(|v| v.as_str()) {
            return Err(error(match code {
                "workbuddy_product_unverified" => "workbuddy_product_unverified",
                "package_integrity_mismatch" => "package_integrity_mismatch",
                _ => "dependency_verification_failed",
            }));
        }
    }
    let record: Receipt =
        serde_json::from_slice(bytes).map_err(|_| error("verification_report_invalid"))?;
    verify_record(kind, record, node)
}
pub fn load_runtime(
    app_data: &Path,
    kind: LocalCliKind,
    node: Arc<VerifiedNodeRuntime>,
) -> launch::Result<VerifiedRuntime> {
    let bytes = storage::read_optional(&receipt_path(app_data, kind.id()), 16 * 1024 * 1024)
        .map_err(|_| error("dependency_read_failed"))?
        .ok_or_else(|| error("dependency_setup_needed"))?;
    let b = DpapiProtector
        .unseal(CONTEXT, &bytes)
        .map_err(|_| error("dependency_verification_failed"))?;
    let record: Receipt =
        serde_json::from_slice(&b).map_err(|_| error("verification_report_invalid"))?;
    if !record
        .snapshot
        .as_ref()
        .is_some_and(|p| p.starts_with(app_data.join("local-cli-runtimes/snapshots")))
    {
        return Err(error("dependency_verification_failed"));
    }
    verify_record(kind, record, node)
}
fn verify_record(
    kind: LocalCliKind,
    record: Receipt,
    node: Arc<VerifiedNodeRuntime>,
) -> launch::Result<VerifiedRuntime> {
    if record.schema != 1
        || record.platform != kind.id()
        || record.version.is_empty()
        || record.version.len() > 64
        || !record
            .version
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b".+-_".contains(&b))
        || record.packages.is_empty()
        || record.packages.len() > 256
    {
        return Err(error("verification_report_invalid"));
    }
    let expected = match kind {
        LocalCliKind::Grok => "@xai-official/grok",
        LocalCliKind::OpenCode => "opencode-ai",
        LocalCliKind::Kimi => "@moonshot-ai/kimi-code",
        LocalCliKind::Gemini => "@google/gemini-cli",
        LocalCliKind::WorkBuddy => "@tencent-ai/codebuddy-code",
        _ => return Err(error("platform_not_supported")),
    };
    if record.packages[0].name != expected || record.packages[0].version != record.version {
        return Err(error("package_identity_mismatch"));
    }
    let mut files = Vec::new();
    let mut paths = BTreeMap::new();
    let mut total = 0u64;
    for package in &record.packages {
        if !package.root.is_absolute()
            || package.files.is_empty()
            || !package.integrity.starts_with("sha512-")
        {
            return Err(error("verification_report_invalid"));
        }
        for (rel, digest) in &package.files {
            if rel.is_empty()
                || rel.contains(['\\', ':'])
                || rel.starts_with('/')
                || rel
                    .split('/')
                    .any(|s| s.is_empty() || s == "." || s == "..")
                || digest.len() != 64
            {
                return Err(error("verification_report_invalid"));
            }
            let path = package.root.join(rel);
            if let Some(prior) = paths.insert(path.clone(), digest.clone()) {
                if prior != *digest {
                    return Err(error("verification_report_invalid"));
                }
                continue;
            }
            let mut held = hold(&path)?;
            let bytes = read(&mut held, 128 * 1024 * 1024)?;
            total += bytes.len() as u64;
            if total > 512 * 1024 * 1024 {
                return Err(error("package_closure_large"));
            }
            if hex(&Sha256::digest(&bytes)) != *digest {
                return Err(error("package_files_changed"));
            }
            files.push(held);
            if files.len() > 40000 {
                return Err(error("package_closure_large"));
            }
        }
    }
    if !paths.contains_key(&record.entry)
        || record
            .product
            .as_ref()
            .is_some_and(|p| !paths.contains_key(p))
    {
        return Err(error("package_bin_invalid"));
    }
    if kind == LocalCliKind::WorkBuddy && record.product.is_none() {
        return Err(error("workbuddy_product_unverified"));
    }
    if let Some(root) = &record.snapshot {
        if !paths.keys().all(|p| p.starts_with(root)) {
            return Err(error("package_path_invalid"));
        }
        let mut count = 0;
        inventory(root, &paths, &mut files, &mut count)?;
        if count != paths.len() {
            return Err(error("package_files_changed"));
        }
    }
    let (executable, prefix) = match record.entry_type.as_str() {
        "script" => (
            node.path().to_owned(),
            vec![record.entry.to_string_lossy().into()],
        ),
        "native" => (record.entry.clone(), vec![]),
        _ => return Err(error("package_bin_invalid")),
    };
    Ok(VerifiedRuntime {
        record,
        executable,
        prefix,
        _files: files,
        _node: node,
    })
}
fn inventory(
    root: &Path,
    expected: &BTreeMap<PathBuf, String>,
    held: &mut Vec<File>,
    count: &mut usize,
) -> launch::Result<()> {
    storage::ensure_no_links(root).map_err(|_| error("package_path_linked"))?;
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.share_mode(1).custom_flags(0x02200000);
    }
    held.push(
        options
            .open(root)
            .map_err(|_| error("package_file_unavailable"))?,
    );
    for entry in std::fs::read_dir(root).map_err(|_| error("package_file_unavailable"))? {
        let entry = entry.map_err(|_| error("package_file_unavailable"))?;
        let path = entry.path();
        storage::ensure_no_links(&path).map_err(|_| error("package_path_linked"))?;
        if path.is_dir() {
            inventory(&path, expected, held, count)?;
        } else {
            if !expected.contains_key(&path) {
                return Err(error("package_files_changed"));
            }
            *count += 1;
            if *count > 40000 {
                return Err(error("package_closure_large"));
            }
        }
    }
    Ok(())
}
pub fn version_matches(expected: &str, actual: &[u8]) -> bool {
    actual.len() <= 4096
        && std::str::from_utf8(actual).is_ok_and(|s| {
            s.split_whitespace()
                .any(|word| word.strip_prefix('v').unwrap_or(word) == expected)
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn setup_task_is_fixed_bounded_and_reuses_this_codex_login() {
        let temp = tempfile::tempdir().unwrap();
        let task = prepare(temp.path(), LocalCliKind::Grok, None).unwrap();
        assert!(valid_id(&task.id));
        assert_eq!(
            task.directory.parent().unwrap(),
            temp.path().join("local-cli-setup")
        );
        assert!(task.prompt.chars().count() < 12000);
        assert!(task.prompt.contains("@xai-official/grok"));
        assert!(task.prompt.contains("--ignore-scripts"));
        assert!(task.prompt.contains("不重新安装或切换 Codex/Claude"));
        assert!(!task.prompt.contains("--yolo"));
        assert!(!task.prompt.contains("dangerously-bypass"));
        assert_eq!(
            std::fs::read(task.directory.join("TASK.txt")).unwrap(),
            task.prompt.as_bytes()
        );
        let next = prepare(temp.path(), LocalCliKind::Grok, None).unwrap();
        assert_ne!(task.id, next.id);
    }
    #[test]
    fn task_ids_and_platform_boundaries_reject_before_any_write() {
        let temp = tempfile::tempdir().unwrap();
        for kind in [LocalCliKind::Codex, LocalCliKind::Mimo] {
            assert!(prepare(temp.path(), kind, None).is_err());
        }
        assert!(prepare(temp.path(), LocalCliKind::Kimi, Some(Edition::Domestic)).is_err());
        assert_eq!(std::fs::read_dir(temp.path()).unwrap().count(), 0);
        for id in ["../x", "", "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "abc\0def"] {
            assert!(!valid_id(id));
        }
        assert!(valid_id("0123456789abcdef0123456789abcdef"));
    }
    #[test]
    fn capture_is_exclusive_and_source_is_embedded_bytes() {
        let temp = tempfile::tempdir().unwrap();
        // The runtime verifies inside a prepared private task, not the outer
        // temporary directory whose Windows owner may be an administrator group.
        let task = prepare(temp.path(), LocalCliKind::Grok, None).unwrap();
        let (path, mut guard) = verifier_file(&task.directory).unwrap();
        assert_eq!(read(&mut guard, 256 * 1024).unwrap(), VERIFIER);
        assert_eq!(path.file_name().unwrap(), "verify.cjs");
        let _capture = capture_file(&task.directory, "verification.json").unwrap();
        assert!(capture_file(&task.directory, "verification.json").is_err());
        assert!(capture_file(&task.directory, "../report").is_err());
    }
    #[test]
    fn version_probe_requires_exact_bounded_printed_version() {
        assert!(version_matches("1.2.3", b"grok-cli v1.2.3\r\n"));
        for value in [b"1.2.30".as_slice(), b"vv1.2.3", b"\xff1.2.3", b"success"] {
            assert!(!version_matches("1.2.3", value));
        }
        assert!(!version_matches("1.2.3", &vec![b' '; 4097]));
    }
    #[test]
    fn runtime_snapshot_rejects_unknown_files() {
        let temp = tempfile::tempdir().unwrap();
        let file = temp.path().join("cli.cjs");
        std::fs::write(&file, b"verified").unwrap();
        let expected = BTreeMap::from([(file.clone(), String::new())]);
        let mut held = vec![];
        let mut count = 0;
        inventory(temp.path(), &expected, &mut held, &mut count).unwrap();
        assert_eq!(count, 1);
        std::fs::write(temp.path().join("unknown.cjs"), b"extra").unwrap();
        assert!(inventory(temp.path(), &expected, &mut vec![], &mut 0).is_err());
    }
}
