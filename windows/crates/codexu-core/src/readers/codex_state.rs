//! Codex state database reader.
//!
//! Reads `state_5.sqlite` to supplement JSONL transcript parsing with
//! thread-level metadata: title, cwd, model, archived flag, and timestamps.
//! This mirrors the macOS `LeadershipDataReader` SQLite queries.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use chrono::{DateTime, TimeZone, Utc};

/// Metadata for a single Codex thread from `state_5.sqlite`.
#[derive(Debug, Clone, PartialEq)]
pub struct CodexThreadMetadata {
    pub thread_id: String,
    pub rollout_path: String,
    pub title: Option<String>,
    pub cwd: Option<String>,
    pub model: Option<String>,
    pub archived: bool,
    pub created_at: Option<DateTime<Utc>>,
    pub updated_at: Option<DateTime<Utc>>,
    /// Runtime thread source (`main`, `subagent`, `automation`), if known.
    pub thread_source: Option<String>,
    /// Parent thread id from runtime spawn edges, if available.
    pub parent_thread_id: Option<String>,
    pub git_branch: Option<String>,
    pub git_origin_url: Option<String>,
}

/// Reads the Codex state database.
pub struct CodexStateReader {
    db_path: PathBuf,
}

impl CodexStateReader {
    pub fn new(db_path: impl AsRef<Path>) -> Self {
        Self {
            db_path: db_path.as_ref().to_path_buf(),
        }
    }

    /// Loads thread metadata indexed by normalized rollout filename.
    ///
    /// The key is the basename of `rollout_path` (e.g.
    /// `rollout-2026-03-26T20-53-36-019d2a35-18c6-7a91-a1af-ea3f821cd221.jsonl`)
    /// so it can be matched against transcript files discovered on disk.
    pub async fn load_metadata(&self) -> anyhow::Result<HashMap<String, CodexThreadMetadata>> {
        let db_path = self.db_path.clone();
        tokio::task::spawn_blocking(move || load_metadata_sync(&db_path)).await?
    }
}

fn load_metadata_sync(db_path: &Path) -> anyhow::Result<HashMap<String, CodexThreadMetadata>> {
    let conn = rusqlite::Connection::open(db_path)?;
    let mut has_thread_source = false;
    if let Ok(mut pragma) = conn.prepare("PRAGMA table_info(threads)") {
        let rows = pragma.query_map([], |row| row.get::<_, String>(1))?;
        for row in rows {
            if row? == "thread_source" {
                has_thread_source = true;
                break;
            }
        }
    }

    let mut query = String::from(
        "SELECT
            id,
            rollout_path,
            title,
            cwd,
            model,
            archived,
            created_at_ms,
            updated_at_ms,
            git_branch,
            git_origin_url
            ",
    );
    if has_thread_source {
        query.push_str(", thread_source");
    }
    query.push_str(
        "
        FROM threads
        WHERE rollout_path IS NOT NULL AND rollout_path != ''",
    );

    let mut stmt = conn.prepare(&query)?;

    let mut entries: HashMap<String, CodexThreadMetadata> = HashMap::new();
    let mut rows = stmt.query_map([], |row| {
        let thread_id: String = row.get::<_, String>(0)?;
        let rollout_path: String = row.get::<_, String>(1)?;
        let title: Option<String> = row.get::<_, Option<String>>(2)?;
        let cwd: Option<String> = row.get::<_, Option<String>>(3)?;
        let model: Option<String> = row.get::<_, Option<String>>(4)?;
        let archived: i64 = row.get::<_, i64>(5)?;
        let created_at_ms: Option<i64> = row.get::<_, Option<i64>>(6)?;
        let updated_at_ms: Option<i64> = row.get::<_, Option<i64>>(7)?;
        let git_branch: Option<String> = row.get::<_, Option<String>>(8)?;
        let git_origin_url: Option<String> = row.get::<_, Option<String>>(9)?;
        let thread_source: Option<String> = if has_thread_source {
            row.get::<_, Option<String>>(10)?
        } else {
            None
        };

        Ok((
            thread_id,
            rollout_path,
            title,
            cwd,
            model,
            archived,
            created_at_ms,
            updated_at_ms,
            git_branch,
            git_origin_url,
            thread_source,
        ))
    })?;

    let parent_edges = load_parent_edges(&conn)?;
    for row in rows.by_ref() {
        let (
            thread_id,
            rollout_path,
            title,
            cwd,
            model,
            archived,
            created_at_ms,
            updated_at_ms,
            git_branch,
            git_origin_url,
            thread_source,
        ) = row?;
        let parent_thread_id = parent_edges.get(&thread_id).cloned();
        entries.insert(
            normalize_rollout_key(&rollout_path),
            CodexThreadMetadata {
                thread_id,
                rollout_path: rollout_path.clone(),
                title: title.filter(|s| !s.trim().is_empty()),
                cwd: cwd.filter(|s| !s.trim().is_empty()),
                model: model.filter(|s| !s.trim().is_empty()),
                archived: archived != 0,
                created_at: created_at_ms.and_then(|ms| Utc.timestamp_millis_opt(ms).single()),
                updated_at: updated_at_ms.and_then(|ms| Utc.timestamp_millis_opt(ms).single()),
                thread_source: thread_source.filter(|s| !s.trim().is_empty()),
                parent_thread_id,
                git_branch,
                git_origin_url,
            },
        );
    }

    Ok(entries)
}

fn load_parent_edges(conn: &rusqlite::Connection) -> anyhow::Result<HashMap<String, String>> {
    let query = conn.prepare("SELECT child_thread_id, parent_thread_id FROM thread_spawn_edges");
    let mut statement = match query {
        Ok(statement) => statement,
        Err(_) => return Ok(HashMap::new()),
    };

    let rows = statement.query_map([], |row| {
        let child: String = row.get(0)?;
        let parent: Option<String> = row.get(1)?;
        Ok((child, parent))
    })?;

    let mut map = HashMap::new();
    for row in rows {
        let (child, parent) = row?;
        if let Some(parent_thread_id) = parent {
            map.insert(child, parent_thread_id);
        }
    }
    Ok(map)
}

/// Returns the basename of a rollout path as the lookup key.
///
/// Splits on both `/` and `\` so the key is identical whether the path was
/// recorded on Windows or on a Unix host. Relying on the host path separator
/// made the result depend on which machine parsed the database.
fn normalize_rollout_key(path: &str) -> String {
    path.rsplit(['/', '\\'])
        .next()
        .filter(|segment| !segment.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| path.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_rollout_key_from_windows_path() {
        assert_eq!(
            normalize_rollout_key(r"C:\Users\ADMIN\.codex\sessions\2026\03\04\rollout-abc.jsonl"),
            "rollout-abc.jsonl"
        );
    }

    #[test]
    fn normalizes_rollout_key_from_unix_path() {
        assert_eq!(
            normalize_rollout_key("/home/admin/.codex/sessions/2026/03/04/rollout-abc.jsonl"),
            "rollout-abc.jsonl"
        );
    }

    #[tokio::test]
    async fn loads_thread_metadata_from_sqlite() {
        let temp = tempfile::tempdir().unwrap();
        let db_path = temp.path().join("state_5.sqlite");

        let conn = rusqlite::Connection::open(&db_path).unwrap();
        conn.execute(
            "CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                source TEXT NOT NULL,
                model_provider TEXT NOT NULL,
                cwd TEXT NOT NULL,
                title TEXT NOT NULL,
                sandbox_policy TEXT NOT NULL,
                approval_mode TEXT NOT NULL,
                tokens_used INTEGER NOT NULL DEFAULT 0,
                has_user_event INTEGER NOT NULL DEFAULT 0,
                archived INTEGER NOT NULL DEFAULT 0,
                archived_at INTEGER,
                git_sha TEXT,
                git_branch TEXT,
                git_origin_url TEXT,
                cli_version TEXT NOT NULL DEFAULT '',
                first_user_message TEXT NOT NULL DEFAULT '',
                agent_nickname TEXT,
                agent_role TEXT,
                memory_mode TEXT NOT NULL DEFAULT 'enabled',
                model TEXT,
                reasoning_effort TEXT,
                agent_path TEXT,
                created_at_ms INTEGER,
                updated_at_ms INTEGER,
                thread_source TEXT,
                preview TEXT NOT NULL DEFAULT '',
                recency_at INTEGER NOT NULL DEFAULT 0,
                recency_at_ms INTEGER NOT NULL DEFAULT 0,
                history_mode TEXT NOT NULL DEFAULT 'legacy',
                name TEXT
            )",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO threads (
                id, rollout_path, created_at, updated_at, source, model_provider,
                cwd, title, sandbox_policy, approval_mode, archived,
                model, created_at_ms, updated_at_ms
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
            rusqlite::params![
                "019d2a35-18c6-7a91-a1af-ea3f821cd221",
                r"C:\Users\ADMIN\.codex\sessions\2026\03\26\rollout-2026-03-26T20-53-36-019d2a35-18c6-7a91-a1af-ea3f821cd221.jsonl",
                0i64,
                0i64,
                "source",
                "openai",
                "h:\\project\\demo",
                "Demo thread",
                "sandbox",
                "approval",
                1i64,
                Some("gpt-5.4"),
                1711464816000i64,
                1711468416000i64,
            ],
        )
        .unwrap();
        drop(conn);

        let reader = CodexStateReader::new(&db_path);
        let metadata = reader.load_metadata().await.unwrap();

        assert_eq!(metadata.len(), 1);
        let meta = metadata
            .get("rollout-2026-03-26T20-53-36-019d2a35-18c6-7a91-a1af-ea3f821cd221.jsonl")
            .expect("key should be normalized rollout filename");
        assert_eq!(meta.thread_id, "019d2a35-18c6-7a91-a1af-ea3f821cd221");
        assert_eq!(meta.title.as_deref(), Some("Demo thread"));
        assert_eq!(meta.cwd.as_deref(), Some("h:\\project\\demo"));
        assert_eq!(meta.model.as_deref(), Some("gpt-5.4"));
        assert!(meta.archived);
        assert!(meta.created_at.is_some());
        assert!(meta.updated_at.is_some());
    }
}
