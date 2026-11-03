//! Privacy-safe local Codex task-board reader.
//!
//! The board deliberately reads only trusted state metadata from
//! `state_5.sqlite` and enabled automation metadata. It never opens session
//! JSONL files, previews, prompts, replies, tool arguments, or raw logs.

use std::collections::{hash_map::DefaultHasher, HashSet};
use std::fs;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};

use anyhow::Result;
use chrono::{DateTime, Datelike, Duration, Local, TimeZone, Utc};
use rusqlite::{Connection, OpenFlags};

use crate::models::{TaskBoard, TaskColumn, TaskItem};

const ACTIVE_WINDOW: Duration = Duration::hours(2);
const MAX_AUTOMATION_SCAN_DEPTH: usize = 3;

/// Reads only local Codex task state appropriate for presentation.
pub struct CodexTaskBoardReader {
    codex_root: PathBuf,
}

impl CodexTaskBoardReader {
    pub fn new(codex_root: impl AsRef<Path>) -> Self {
        Self {
            codex_root: codex_root.as_ref().to_path_buf(),
        }
    }

    /// Returns `None` only when no trustworthy task source is available.
    ///
    /// An available but empty state database returns a board with the four
    /// stable columns so the UI can distinguish "no records yet" from a
    /// source that cannot be read.
    pub async fn load(&self, now: DateTime<Utc>) -> Result<Option<TaskBoard>> {
        let codex_root = self.codex_root.clone();
        tokio::task::spawn_blocking(move || load_task_board(&codex_root, now)).await?
    }
}

#[derive(Debug)]
struct ThreadRecord {
    id: String,
    title: Option<String>,
    preview: Option<String>,
    cwd: Option<String>,
    activity_at: Option<DateTime<Utc>>,
    archived_at: Option<DateTime<Utc>>,
    archived: bool,
}

#[derive(Debug, Default)]
struct AutomationRecord {
    id: String,
    name: String,
    detail: String,
    chip: String,
}

fn load_task_board(codex_root: &Path, now: DateTime<Utc>) -> Result<Option<TaskBoard>> {
    let state_db = [
        codex_root.join("state_5.sqlite"),
        codex_root.join("sqlite").join("state_5.sqlite"),
    ]
    .into_iter()
    .find(|path| path.is_file());
    let automation_root = codex_root.join("automations");
    let has_automation_root = automation_root.is_dir();

    if state_db.is_none() && !has_automation_root {
        return Ok(None);
    }

    let records = match state_db {
        Some(path) => read_thread_records(&path, now)?,
        None => Vec::new(),
    };
    let automations = read_active_automations(&automation_root);
    Ok(Some(build_task_board(records, automations, now)))
}

fn read_thread_records(path: &Path, now: DateTime<Utc>) -> Result<Vec<ThreadRecord>> {
    let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let columns = table_columns(&connection, "threads")?;
    if !["id", "archived", "created_at", "updated_at"]
        .iter()
        .all(|column| columns.contains(*column))
    {
        return Ok(Vec::new());
    }

    let day_start = local_day_start(now).timestamp();
    let source_clause = if columns.contains("thread_source") {
        " AND COALESCE(LOWER(thread_source), '') <> 'subagent'"
    } else {
        ""
    };
    let recency_expr = if columns.contains("recency_at") {
        "recency_at"
    } else {
        "NULL"
    };
    let title_expr = if columns.contains("title") {
        "title"
    } else {
        "NULL"
    };
    let preview_expr = if columns.contains("preview") {
        "preview"
    } else {
        "NULL"
    };
    let cwd_expr = if columns.contains("cwd") {
        "cwd"
    } else {
        "NULL"
    };
    let archived_at_expr = if columns.contains("archived_at") {
        "archived_at"
    } else {
        "NULL"
    };

    let active_query = format!(
        "SELECT id, {title_expr}, {preview_expr}, {cwd_expr}, updated_at, {recency_expr}, created_at
         FROM threads
         WHERE COALESCE(archived, 0) = 0
           {source_clause}
           AND MAX(COALESCE(updated_at, 0), COALESCE({recency_expr}, 0), COALESCE(created_at, 0)) >= ?1
         ORDER BY MAX(COALESCE({recency_expr}, 0), COALESCE(updated_at, 0), COALESCE(created_at, 0)) DESC"
    );
    let archived_query = format!(
        "SELECT id, {title_expr}, {preview_expr}, {cwd_expr}, {archived_at_expr}, updated_at, created_at
         FROM threads
         WHERE COALESCE(archived, 0) = 1
           {source_clause}
           AND MAX(COALESCE({archived_at_expr}, 0), COALESCE(updated_at, 0), COALESCE(created_at, 0)) >= ?1
         ORDER BY MAX(COALESCE({archived_at_expr}, 0), COALESCE(updated_at, 0), COALESCE(created_at, 0)) DESC"
    );

    let mut records = Vec::new();
    let mut active_statement = connection.prepare(&active_query)?;
    let active_rows = active_statement.query_map([day_start], |row| {
        Ok(ThreadRecord {
            id: row.get(0)?,
            title: row.get(1)?,
            preview: row.get(2)?,
            cwd: row.get(3)?,
            activity_at: latest_timestamp([
                row.get::<_, Option<i64>>(4)?,
                row.get::<_, Option<i64>>(5)?,
                row.get::<_, Option<i64>>(6)?,
            ]),
            archived_at: None,
            archived: false,
        })
    })?;
    for row in active_rows {
        records.push(row?);
    }

    let mut archived_statement = connection.prepare(&archived_query)?;
    let archived_rows = archived_statement.query_map([day_start], |row| {
        let archived_at = latest_timestamp([
            row.get::<_, Option<i64>>(4)?,
            row.get::<_, Option<i64>>(5)?,
            row.get::<_, Option<i64>>(6)?,
        ]);
        Ok(ThreadRecord {
            id: row.get(0)?,
            title: row.get(1)?,
            preview: row.get(2)?,
            cwd: row.get(3)?,
            activity_at: archived_at,
            archived_at,
            archived: true,
        })
    })?;
    for row in archived_rows {
        records.push(row?);
    }

    Ok(records)
}

fn build_task_board(
    records: Vec<ThreadRecord>,
    automations: Vec<AutomationRecord>,
    now: DateTime<Utc>,
) -> TaskBoard {
    let mut active = Vec::new();
    let mut pending = Vec::new();
    let mut done = Vec::new();

    for record in records {
        if record.archived {
            done.push(thread_task_item(record, "done", "archived", "archive"));
        } else if record
            .activity_at
            .is_some_and(|activity| activity >= now - ACTIVE_WINDOW)
        {
            active.push(thread_task_item(
                record,
                "active",
                "recentlyActive",
                "activityWindow",
            ));
        } else {
            pending.push(thread_task_item(
                record,
                "pending",
                "continueLater",
                "activityWindow",
            ));
        }
    }

    sort_task_items(&mut active);
    sort_task_items(&mut pending);
    sort_task_items(&mut done);

    let mut scheduled: Vec<TaskItem> = automations
        .into_iter()
        .map(|automation| TaskItem {
            id: opaque_task_id("automation", &automation.id),
            code: format!("AUTO-{}", short_task_token(&automation.id)[..4].to_string()),
            title: automation.name,
            detail: automation.detail,
            chip: automation.chip,
            updated_at: None,
            tokens: None,
            kind: "scheduled".to_string(),
            thread_id: None,
            runtime_state: "recorded".to_string(),
            source_kind: "codexAutomation".to_string(),
            display_state: "scheduled".to_string(),
            state_basis: "scheduleConfig".to_string(),
            raw_status: None,
            next_run_at: None,
        })
        .collect();
    scheduled.sort_by(|left, right| {
        left.title
            .cmp(&right.title)
            .then_with(|| left.id.cmp(&right.id))
    });

    TaskBoard {
        refreshed_at: now,
        columns: vec![
            task_column("active", "Recent activity", active),
            task_column("pending", "To continue", pending),
            task_column("scheduled", "Scheduled", scheduled),
            task_column("done", "Archived today", done),
        ],
    }
}

fn thread_task_item(
    record: ThreadRecord,
    kind: &str,
    display_state: &str,
    state_basis: &str,
) -> TaskItem {
    let factual_time = if record.archived_at.is_some() {
        record.archived_at
    } else {
        record.activity_at
    };
    TaskItem {
        id: opaque_task_id(kind, &record.id),
        code: "LOCAL-THREAD".to_string(),
        title: normalize_task_title(record.title.as_deref(), record.preview.as_deref()),
        detail: short_workspace_name(record.cwd.as_deref()),
        chip: display_state.to_string(),
        updated_at: factual_time,
        tokens: None,
        kind: kind.to_string(),
        thread_id: Some(record.id.clone()),
        runtime_state: "recorded".to_string(),
        source_kind: "codexThread".to_string(),
        display_state: display_state.to_string(),
        state_basis: state_basis.to_string(),
        raw_status: None,
        next_run_at: None,
    }
}

fn task_column(id: &str, title: &str, items: Vec<TaskItem>) -> TaskColumn {
    TaskColumn {
        id: id.to_string(),
        title: title.to_string(),
        count: items.len() as i64,
        items,
    }
}

fn short_task_token(source_id: &str) -> String {
    let hash = source_id.bytes().fold(0x811c9dc5_u32, |hash, byte| {
        (hash ^ u32::from(byte)).wrapping_mul(0x01000193)
    });
    format!("{:06X}", hash & 0x00FF_FFFF)
}

fn normalize_task_title(title: Option<&str>, fallback: Option<&str>) -> String {
    let raw = [title, fallback]
        .into_iter()
        .flatten()
        .map(str::trim)
        .find(|value| !value.is_empty())
        .unwrap_or("Untitled");
    let normalized = raw.split_whitespace().collect::<Vec<_>>().join(" ");
    if normalized.chars().count() <= 48 {
        return normalized;
    }
    format!("{}...", normalized.chars().take(45).collect::<String>())
}

fn short_workspace_name(path: Option<&str>) -> String {
    path.unwrap_or("")
        .trim()
        .rsplit(['\\', '/'])
        .find(|part| !part.is_empty())
        .unwrap_or("")
        .to_string()
}

fn sort_task_items(items: &mut [TaskItem]) {
    items.sort_by(|left, right| {
        right
            .updated_at
            .cmp(&left.updated_at)
            .then_with(|| left.id.cmp(&right.id))
    });
}

fn read_active_automations(root: &Path) -> Vec<AutomationRecord> {
    let mut files = Vec::new();
    find_automation_files(root, 0, &mut files);
    files
        .into_iter()
        .filter_map(|path| fs::read_to_string(path).ok())
        .filter_map(|contents| parse_active_automation(&contents))
        .collect()
}

fn find_automation_files(directory: &Path, depth: usize, files: &mut Vec<PathBuf>) {
    if depth > MAX_AUTOMATION_SCAN_DEPTH {
        return;
    }
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_file()
            && path
                .file_name()
                .is_some_and(|name| name == "automation.toml")
        {
            files.push(path);
        } else if path.is_dir() {
            find_automation_files(&path, depth + 1, files);
        }
    }
}

fn parse_active_automation(contents: &str) -> Option<AutomationRecord> {
    let mut id = None;
    let mut name = None;
    let mut status = None;
    let mut kind = None;
    let mut rrule = None;

    for line in contents.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (key, value) = line.split_once('=')?;
        let value = value.trim().trim_matches('"').trim_matches('\'').trim();
        match key.trim() {
            "id" => id = non_empty(value),
            "name" => name = non_empty(value),
            "status" => status = non_empty(value),
            "kind" => kind = non_empty(value),
            "rrule" => rrule = non_empty(value),
            _ => {}
        }
    }

    if !status.is_some_and(|value| value.eq_ignore_ascii_case("ACTIVE")) {
        return None;
    }
    let kind = kind.unwrap_or("cron");
    let is_heartbeat = kind.eq_ignore_ascii_case("heartbeat");
    let schedule = rrule.filter(|rule| valid_rrule(rule));
    if !is_heartbeat && schedule.is_none() {
        return None;
    }

    let id = id.map(str::to_owned).unwrap_or_else(|| "local".to_string());
    Some(AutomationRecord {
        name: name.map(str::to_owned).unwrap_or_else(|| id.clone()),
        id,
        detail: if is_heartbeat {
            "Active heartbeat".to_string()
        } else {
            schedule_summary(schedule.as_deref().unwrap_or_default())
        },
        chip: if is_heartbeat {
            "Heartbeat".to_string()
        } else {
            "Scheduled".to_string()
        },
    })
}

fn valid_rrule(rule: &str) -> bool {
    let normalized = rule.to_ascii_uppercase();
    ["DAILY", "WEEKLY", "HOURLY", "MINUTELY"]
        .iter()
        .any(|frequency| normalized.contains(&format!("FREQ={frequency}")))
}

fn schedule_summary(rule: &str) -> String {
    let normalized = rule.to_ascii_uppercase();
    if normalized.contains("FREQ=DAILY") {
        "Every day".to_string()
    } else if normalized.contains("FREQ=WEEKLY") {
        "Every week".to_string()
    } else if normalized.contains("FREQ=HOURLY") {
        "Every hour".to_string()
    } else {
        "Every minute".to_string()
    }
}

fn non_empty(value: &str) -> Option<&str> {
    (!value.is_empty()).then_some(value)
}

fn opaque_task_id(kind: &str, source_id: &str) -> String {
    let mut hasher = DefaultHasher::new();
    kind.hash(&mut hasher);
    source_id.hash(&mut hasher);
    format!("{kind}-{:016x}", hasher.finish())
}

fn latest_timestamp(values: [Option<i64>; 3]) -> Option<DateTime<Utc>> {
    values
        .into_iter()
        .flatten()
        .filter(|timestamp| *timestamp > 0)
        .max()
        .and_then(|timestamp| Utc.timestamp_opt(timestamp, 0).single())
}

fn table_columns(connection: &Connection, table: &str) -> Result<HashSet<String>> {
    let mut statement = connection.prepare(&format!("PRAGMA table_info({table})"))?;
    let columns = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<std::result::Result<HashSet<_>, _>>()?;
    Ok(columns)
}

fn local_day_start(now: DateTime<Utc>) -> DateTime<Utc> {
    let local = now.with_timezone(&Local);
    Local
        .with_ymd_and_hms(local.year(), local.month(), local.day(), 0, 0, 0)
        .earliest()
        .map(|value| value.with_timezone(&Utc))
        .unwrap_or(now)
}

/// Bounded, all-date metadata for the separate workbench. The existing daily
/// board above is intentionally unchanged. No preview, rollout path, prompt,
/// response, automation body or transcript is selected by this query.
#[derive(Clone)]
pub struct WorkbenchThreadMetadata {
    pub thread_id: String,
    pub title: String,
    pub project: String,
    pub updated_at_ms: Option<i64>,
    pub archived: bool,
}
pub struct WorkbenchMetadata {
    pub source_available: bool,
    pub truncated: bool,
    pub threads: Vec<WorkbenchThreadMetadata>,
}

pub fn read_workbench_metadata(codex_root: &Path) -> Result<WorkbenchMetadata> {
    crate::accounts::storage::ensure_no_links(codex_root)?;
    anyhow::ensure!(
        codex_root.canonicalize()? == codex_root,
        "Invalid source root"
    );
    let mut selected = None;
    for path in [
        codex_root.join("state_5.sqlite"),
        codex_root.join("sqlite/state_5.sqlite"),
    ] {
        crate::accounts::storage::ensure_no_links(&path)?;
        match std::fs::symlink_metadata(&path) {
            Ok(meta) => {
                anyhow::ensure!(meta.is_file(), "Invalid metadata source");
                selected = Some(path);
                break;
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
            Err(e) => return Err(e.into()),
        }
    }
    let Some(path) = selected else {
        return Ok(WorkbenchMetadata {
            source_available: false,
            truncated: false,
            threads: vec![],
        });
    };
    let connection = Connection::open_with_flags(&path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    connection.busy_timeout(std::time::Duration::from_millis(250))?;
    connection.execute_batch("PRAGMA query_only=ON;")?;
    let columns = table_columns(&connection, "threads")?;
    anyhow::ensure!(
        columns.contains("id") && columns.contains("archived"),
        "Unrecognized metadata schema"
    );
    let title = if columns.contains("title") {
        "substr(title,1,512)"
    } else {
        "NULL"
    };
    let cwd = if columns.contains("cwd") {
        "substr(cwd,1,4096)"
    } else {
        "NULL"
    };
    // Both official timestamp generations are supported without guessing units.
    let time = if columns.contains("updated_at_ms") {
        "updated_at_ms"
    } else if columns.contains("updated_at") {
        "updated_at * 1000"
    } else if columns.contains("created_at_ms") {
        "created_at_ms"
    } else if columns.contains("created_at") {
        "created_at * 1000"
    } else {
        "NULL"
    };
    let parent = if columns.contains("thread_source") {
        "WHERE COALESCE(LOWER(thread_source),'') <> 'subagent'"
    } else {
        ""
    };
    let query = format!("SELECT substr(id,1,128), {title}, {cwd}, {time}, archived FROM threads {parent} ORDER BY {time} DESC, id ASC LIMIT 1001");
    let mut statement = connection.prepare(&query)?;
    let records = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, Option<String>>(1)?,
            row.get::<_, Option<String>>(2)?,
            row.get::<_, Option<i64>>(3)?,
            row.get::<_, Option<i64>>(4)?,
        ))
    })?;
    let mut threads = Vec::new();
    let mut count = 0;
    for record in records {
        let (thread_id, title, cwd, updated, archived) = record?;
        count += 1;
        if count > 1000 {
            break;
        }
        threads.push(WorkbenchThreadMetadata {
            thread_id,
            title: normalize_task_title(title.as_deref(), None),
            project: short_workspace_name(cwd.as_deref()),
            updated_at_ms: updated.filter(|v| *v > 0 && *v <= 8_640_000_000_000_000),
            archived: archived == Some(1),
        });
    }
    crate::accounts::storage::ensure_no_links(&path)?;
    anyhow::ensure!(codex_root.canonicalize()? == codex_root, "Source changed");
    Ok(WorkbenchMetadata {
        source_available: true,
        truncated: count > 1000,
        threads,
    })
}
