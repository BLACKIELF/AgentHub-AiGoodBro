//! Bundled editorial recommendations and bounded local installation presence.
//! No installation, model invocation, credential read or conversation mutation.
use crate::accounts::storage;
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
};

const CATALOG: &[u8] = include_bytes!("../../../../Resources/SkillLibrary/catalog.json");
const IDS: [&str; 6] = [
    "oracle",
    "handoff",
    "jev-use",
    "quicktoggle",
    "rea",
    "aihot",
];
const PACKAGES: [(&str, &[u8], &[u8]); 4] = [
    (
        "oracle",
        include_bytes!("../../../../Resources/SkillLibrary/oracle/SKILL.md"),
        include_bytes!("../../../../Resources/SkillLibrary/oracle/安装说明.md"),
    ),
    (
        "handoff",
        include_bytes!("../../../../Resources/SkillLibrary/handoff/SKILL.md"),
        include_bytes!("../../../../Resources/SkillLibrary/handoff/安装说明.md"),
    ),
    (
        "jev-cu",
        include_bytes!("../../../../Resources/SkillLibrary/jev-cu/SKILL.md"),
        include_bytes!("../../../../Resources/SkillLibrary/jev-cu/安装说明.md"),
    ),
    (
        "reverse-engineer-anything",
        include_bytes!("../../../../Resources/SkillLibrary/reverse-engineer-anything/SKILL.md"),
        include_bytes!("../../../../Resources/SkillLibrary/reverse-engineer-anything/安装说明.md"),
    ),
];
#[derive(Debug, thiserror::Error)]
#[error("{code}")]
pub struct Error {
    pub code: &'static str,
}
pub type Result<T> = std::result::Result<T, Error>;
fn fail(code: &'static str) -> Error {
    Error { code }
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Text {
    pub zh: String,
    pub en: String,
}
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Entry {
    id: String,
    kind: String,
    title: Text,
    purpose: Text,
    summary: Text,
    skill_directory: Option<String>,
    skill_names: Vec<String>,
    #[serde(rename = "sourceURL")]
    source_url: String,
    copy_text: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Catalog {
    schema_version: u8,
    items: Vec<Entry>,
}
#[derive(Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Debug)]
#[serde(rename_all = "camelCase")]
pub enum Presence {
    Installed,
    NotInstalled,
    Unknown,
    NotApplicable,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub id: String,
    pub kind: String,
    pub title: Text,
    pub purpose: Text,
    pub summary: Text,
    pub source_url: String,
    pub instructions: String,
    pub presence: Presence,
    pub hidden: bool,
    pub package_available: bool,
    pub can_install: bool,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub revision: u64,
    pub checked_at_ms: Option<i64>,
    pub items: Vec<Item>,
}
#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Saved {
    version: u8,
    revision: u64,
    hidden: BTreeSet<String>,
    states: BTreeMap<String, Presence>,
    checked_at_ms: Option<i64>,
}
impl Saved {
    fn fresh() -> Self {
        Self {
            version: 1,
            ..Self::default()
        }
    }
    fn validate(&self) -> Result<()> {
        if self.version != 1
            || self.revision > 9_007_199_254_740_991
            || self.hidden.iter().any(|id| !IDS.contains(&id.as_str()))
            || self.states.keys().any(|id| !IDS.contains(&id.as_str()))
            || self
                .checked_at_ms
                .is_some_and(|v| !(0..=253_402_300_799_000).contains(&v))
        {
            return Err(fail("recommendation_storage_invalid"));
        }
        Ok(())
    }
}
pub struct RecommendationStore {
    root: PathBuf,
    resources: PathBuf,
    home: PathBuf,
}
impl RecommendationStore {
    pub fn new(app_data: &Path, resources: &Path, home: &Path) -> Result<Self> {
        for path in [app_data, resources, home] {
            if !path.is_absolute()
                || path
                    .components()
                    .any(|c| matches!(c, std::path::Component::ParentDir))
            {
                return Err(fail("recommendation_path_invalid"));
            }
        }
        let root = app_data.join("recommendations-v1");
        storage::ensure_no_links(&root).map_err(|_| fail("recommendation_storage_unavailable"))?;
        Ok(Self {
            root,
            resources: resources.to_owned(),
            home: home.to_owned(),
        })
    }
    fn catalog(&self) -> Result<Vec<Entry>> {
        let bytes =
            storage::read_bound_optional(&self.resources.join("catalog.json"), 262_144, false)
                .map_err(|_| fail("recommendation_package_unavailable"))?
                .ok_or_else(|| fail("recommendation_package_unavailable"))?;
        if bytes != CATALOG {
            return Err(fail("recommendation_package_changed"));
        }
        let catalog: Catalog =
            serde_json::from_slice(&bytes).map_err(|_| fail("recommendation_package_changed"))?;
        if catalog.schema_version != 1
            || catalog
                .items
                .iter()
                .map(|e| e.id.as_str())
                .collect::<Vec<_>>()
                != IDS
        {
            return Err(fail("recommendation_package_changed"));
        }
        Ok(catalog.items)
    }
    fn entry(&self, id: &str) -> Result<Entry> {
        self.catalog()?
            .into_iter()
            .find(|e| e.id == id)
            .ok_or_else(|| fail("recommendation_unknown"))
    }
    fn read(&self) -> Result<Saved> {
        let value =
            match storage::read_bound_optional(&self.root.join("visibility.json"), 65_536, true)
                .map_err(|_| fail("recommendation_storage_unavailable"))?
            {
                None => Saved::fresh(),
                Some(bytes) => serde_json::from_slice(&bytes)
                    .map_err(|_| fail("recommendation_storage_invalid"))?,
            };
        value.validate()?;
        Ok(value)
    }
    fn write(&self, value: &mut Saved) -> Result<()> {
        value.revision = value
            .revision
            .checked_add(1)
            .ok_or_else(|| fail("recommendation_storage_invalid"))?;
        value.validate()?;
        let bytes =
            serde_json::to_vec(value).map_err(|_| fail("recommendation_storage_invalid"))?;
        storage::atomic_write(&self.root.join("visibility.json"), &bytes)
            .map_err(|_| fail("recommendation_save_failed"))?;
        if storage::read_bound_optional(&self.root.join("visibility.json"), 65_536, true)
            .map_err(|_| fail("recommendation_save_failed"))?
            .as_deref()
            != Some(bytes.as_slice())
        {
            return Err(fail("recommendation_save_failed"));
        }
        Ok(())
    }
    pub fn snapshot(&self) -> Result<Snapshot> {
        let saved = self.read()?;
        let items = self
            .catalog()?
            .into_iter()
            .map(|e| {
                let available = self.checked_package(&e).is_ok();
                Item {
                    hidden: saved.hidden.contains(&e.id),
                    presence: saved.states.get(&e.id).copied().unwrap_or(
                        if e.id == "quicktoggle" {
                            Presence::NotApplicable
                        } else {
                            Presence::Unknown
                        },
                    ),
                    can_install: e.kind == "skill" && available,
                    package_available: available,
                    id: e.id,
                    kind: e.kind,
                    title: e.title,
                    purpose: e.purpose,
                    summary: e.summary,
                    source_url: e.source_url,
                    instructions: e.copy_text,
                }
            })
            .collect();
        Ok(Snapshot {
            revision: saved.revision,
            checked_at_ms: saved.checked_at_ms,
            items,
        })
    }
    pub fn set_hidden(&self, id: &str, hidden: bool) -> Result<Snapshot> {
        self.entry(id)?;
        let _lock =
            storage::StoreLock::acquire(&self.root).map_err(|_| fail("recommendation_busy"))?;
        let mut saved = self.read()?;
        if hidden {
            saved.hidden.insert(id.to_owned());
        } else {
            saved.hidden.remove(id);
        }
        self.write(&mut saved)?;
        self.snapshot()
    }
    pub fn restore_hidden(&self) -> Result<Snapshot> {
        self.catalog()?;
        let _lock =
            storage::StoreLock::acquire(&self.root).map_err(|_| fail("recommendation_busy"))?;
        let mut saved = self.read()?;
        saved.hidden.clear();
        self.write(&mut saved)?;
        self.snapshot()
    }
    pub fn recheck(&self, now_ms: i64) -> Result<Snapshot> {
        let catalog = self.catalog()?;
        let _lock =
            storage::StoreLock::acquire(&self.root).map_err(|_| fail("recommendation_busy"))?;
        let mut saved = self.read()?;
        for entry in catalog {
            saved.states.insert(entry.id.clone(), self.detect(&entry));
        }
        saved.checked_at_ms = Some(now_ms);
        self.write(&mut saved)?;
        self.snapshot()
    }
    fn detect(&self, entry: &Entry) -> Presence {
        if entry.id == "quicktoggle" {
            return Presence::NotApplicable;
        }
        if entry.skill_names.is_empty() {
            return Presence::Unknown;
        }
        let mut unknown = false;
        for suffix in [".codex/skills", ".agents/skills"] {
            for name in &entry.skill_names {
                let folder = self.home.join(suffix).join(name);
                match storage::read_bound_optional(&folder.join("SKILL.md"), 262_144, false) {
                    Ok(Some(bytes)) => {
                        if std::str::from_utf8(&bytes)
                            .ok()
                            .and_then(frontmatter_name)
                            .is_some_and(|declared| {
                                entry.skill_names.iter().any(|name| name == &declared)
                            })
                        {
                            return Presence::Installed;
                        }
                        unknown = true;
                    }
                    Ok(None) => {
                        if folder.exists() {
                            unknown = true;
                        }
                    }
                    Err(_) => unknown = true,
                }
            }
        }
        if unknown {
            Presence::Unknown
        } else {
            Presence::NotInstalled
        }
    }
    fn checked_package(&self, entry: &Entry) -> Result<PathBuf> {
        let name = entry
            .skill_directory
            .as_deref()
            .ok_or_else(|| fail("recommendation_package_unavailable"))?;
        let (_, skill, instructions) = PACKAGES
            .iter()
            .find(|(n, _, _)| *n == name)
            .ok_or_else(|| fail("recommendation_package_unavailable"))?;
        let directory = crate::local_cli::launch::checked_directory(&self.resources.join(name))
            .map_err(|_| fail("recommendation_package_unavailable"))?;
        for (file, expected) in [("SKILL.md", *skill), ("安装说明.md", *instructions)] {
            let bytes = storage::read_bound_optional(&directory.join(file), 262_144, false)
                .map_err(|_| fail("recommendation_package_unavailable"))?
                .ok_or_else(|| fail("recommendation_package_unavailable"))?;
            if bytes != expected {
                return Err(fail("recommendation_package_changed"));
            }
        }
        Ok(directory)
    }
    /// Native-only path. IPC accepts an editorial ID, never a path supplied by WebView.
    pub fn package_directory(&self, id: &str) -> Result<PathBuf> {
        self.checked_package(&self.entry(id)?)
    }
    pub fn project_url(&self, id: &str) -> Result<String> {
        Ok(self.entry(id)?.source_url)
    }
    /// Prompt may contain the private resource path; it is only copied by native
    /// code or placed in the fixed Codex deep link, never serialized to WebView.
    pub fn install_prompt(&self, id: &str) -> Result<String> {
        let entry = self.entry(id)?;
        if entry.kind != "skill" {
            return Err(fail("recommendation_install_unsupported"));
        }
        let directory = self.checked_package(&entry)?;
        let path = directory
            .to_str()
            .filter(|p| !p.chars().any(char::is_control))
            .ok_or_else(|| fail("recommendation_path_invalid"))?;
        let boundary=match id {
            "oracle"=>"Oracle CLI 若未安装，只说明缺失与安装命令，等我确认。安装 Skill 本身不等于授权模型调用。",
            "handoff"=>"只安装 Skill，不创建交接文件；后续保存或读取交接仍按具体任务授权。",
            "jev-use"=>"识别已有 jev-use／jev-cu 并优先复用。Skill 依赖持久保存的公开 Jev-cu runner；先复用或获取经核验的仓库，再仅在新安装副本中解析 {{REPO_DIR}}，不运行会先删除同名目录的 installer，不调用 Jev API。",
            "rea"=>"只安装官方 Skill 与引用，不捆绑或安装引擎。复用已有 rea 6.4.0 与已连接工具；本次不写 MCP 登记、认证或全局运行配置，不获取不相关依赖，缺失能力如实说明。",
            _=>return Err(fail("recommendation_install_unsupported")),
        };
        Ok(format!("请读取 {path} 的 SKILL.md 和安装说明.md，按说明准备当前 Codex 用户级 Skill；先检查同名和近似项，已有可用安装优先复用，只在不同目标、身份或覆盖影响不明时询问，不静默覆盖。不修改认证或全局配置，不读取密钥、不调用模型或执行付费请求；{boundary}"))
    }
}
fn frontmatter_name(text: &str) -> Option<String> {
    let lines = text.lines().take(202).collect::<Vec<_>>();
    if lines.first().copied() != Some("---") {
        return None;
    }
    let end = lines
        .iter()
        .enumerate()
        .skip(1)
        .find(|(_, s)| **s == "---")?
        .0;
    if end > 200 {
        return None;
    }
    let names = lines[1..end]
        .iter()
        .filter_map(|s| s.strip_prefix("name:"))
        .collect::<Vec<_>>();
    if names.len() != 1 {
        return None;
    }
    let raw = names[0].trim();
    let name = if (raw.starts_with('\'') && raw.ends_with('\''))
        || (raw.starts_with('"') && raw.ends_with('"'))
    {
        raw.get(1..raw.len().checked_sub(1)?)?
    } else {
        raw
    };
    if name.is_empty()
        || name.len() > 100
        || !name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
    {
        return None;
    }
    Some(name.to_owned())
}
#[cfg(test)]
#[path = "recommendations_tests.rs"]
mod tests;
