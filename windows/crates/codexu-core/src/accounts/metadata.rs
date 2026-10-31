//! Display metadata has one authority: the existing encrypted managed vault.
//! Linked Home rows project this metadata; no second label/order is persisted.
use super::*;
use unicode_segmentation::UnicodeSegmentation;

pub(crate) fn normalize_remark(value: &str) -> AccountResult<Option<String>> {
    if value.len() > 16384 {
        return Err(fail("invalid_label"));
    }
    let value = value.trim();
    if value.is_empty() {
        return Ok(None);
    }
    // Preserve the existing Windows non-secret alias policy, with Mac's
    // 40 extended-grapheme limit rather than bytes or UTF-16 code units.
    if value.chars().any(|c| c.is_control() || "@/\\:".contains(c)) {
        return Err(fail("invalid_label"));
    }
    Ok(Some(value.graphemes(true).take(40).collect()))
}
pub(crate) fn valid_remark(value: Option<&str>) -> bool {
    value.is_none_or(|s| normalize_remark(s).ok().flatten().as_deref() == Some(s))
}
pub fn valid_display_label(value: &str) -> bool {
    crate::profiles::validate_label(value).is_ok() || valid_remark(Some(value))
}
/// Native-only projection; deliberately not Serialize and never returned to Web.
#[derive(Clone, Debug)]
pub struct ManagedMetadata {
    pub id: String,
    pub label: String,
    pub home: Option<PathBuf>,
}
#[derive(Clone, Debug)]
pub struct ProfileMetadata {
    pub id: u64,
    pub label: String,
    pub managed_id: Option<String>,
}
impl AccountManager {
    pub fn project_profile_metadata(
        &self,
        catalog: &crate::profiles::ProfileCatalog,
    ) -> AccountResult<Vec<ProfileMetadata>> {
        catalog
            .validate()
            .map_err(|_| fail("account_catalog_invalid"))?;
        // An empty linked catalog has no managed metadata to project. Do not
        // make a fresh empty account list depend on an unrelated vault lock.
        if catalog.entries.is_empty() {
            return Ok(Vec::new());
        }
        let managed = self.managed_metadata()?;
        let mut projected = Vec::new();
        let mut seen_managed = std::collections::HashSet::new();
        for row in &catalog.entries {
            let mut matches = Vec::new();
            if row.kind == crate::local_cli::LocalCliKind::Codex {
                storage::ensure_no_links(&row.root)?;
                if let Ok(root) = row.root.canonicalize() {
                    matches = managed
                        .iter()
                        .filter(|m| {
                            m.home.as_ref().and_then(|h| h.canonicalize().ok()).as_ref()
                                == Some(&root)
                        })
                        .collect();
                }
            }
            if matches.len() > 1 {
                return Err(fail("account_catalog_ambiguous"));
            }
            if matches
                .first()
                .is_some_and(|m| !seen_managed.insert(m.id.clone()))
            {
                return Err(fail("account_catalog_ambiguous"));
            }
            projected.push(ProfileMetadata {
                id: row.id,
                label: matches
                    .first()
                    .map(|m| m.label.clone())
                    .unwrap_or_else(|| row.label.clone()),
                managed_id: matches.first().map(|m| m.id.clone()),
            });
        }
        // Only mapped managed slots move. Other providers and ordinary linked
        // directories retain their original slots and metadata.
        let mut ordered: Vec<_> = projected
            .iter()
            .filter(|p| p.managed_id.is_some())
            .cloned()
            .collect();
        ordered.sort_by_key(|p| {
            managed
                .iter()
                .position(|m| Some(&m.id) == p.managed_id.as_ref())
                .unwrap()
        });
        let mut ordered = ordered.into_iter();
        for slot in &mut projected {
            if slot.managed_id.is_some() {
                *slot = ordered.next().unwrap();
            }
        }
        Ok(projected)
    }
    pub fn move_projected_managed_profile(
        &self,
        catalog: &crate::profiles::ProfileCatalog,
        profile_id: u64,
        delta: i8,
    ) -> AccountResult<bool> {
        if !matches!(delta, -1 | 1) {
            return Err(fail("invalid_account_order"));
        }
        let projected = self.project_profile_metadata(catalog)?;
        let target = projected
            .iter()
            .find(|p| p.id == profile_id)
            .ok_or_else(|| fail("account_not_found"))?;
        let Some(id) = &target.managed_id else {
            return Ok(false);
        };
        let expected: Vec<_> = self.managed_metadata()?.into_iter().map(|m| m.id).collect();
        let mut visible: Vec<_> = projected
            .iter()
            .filter_map(|p| p.managed_id.clone())
            .collect();
        // Compare the projection to the current full order before deriving a move.
        let observed: Vec<_> = expected
            .iter()
            .filter(|id| visible.contains(id))
            .cloned()
            .collect();
        if observed != visible {
            return Err(fail("account_order_changed"));
        }
        let index = visible.iter().position(|x| x == id).unwrap();
        let destination = index as isize + delta as isize;
        if destination < 0 || destination >= visible.len() as isize {
            return Err(fail("invalid_account_order"));
        }
        visible.swap(index, destination as usize);
        let mut moved = visible.iter();
        let desired: Vec<_> = expected
            .iter()
            .map(|id| {
                if visible.contains(id) {
                    moved.next().unwrap().clone()
                } else {
                    id.clone()
                }
            })
            .collect();
        self.reorder_managed_accounts(&desired, &expected)?;
        Ok(true)
    }
    pub fn managed_metadata(&self) -> AccountResult<Vec<ManagedMetadata>> {
        let roots = self.managed_history_roots()?;
        let store = self.store()?;
        Ok(store
            .vault
            .accounts
            .iter()
            .map(|r| ManagedMetadata {
                id: r.id.clone(),
                label: r.display_label().to_owned(),
                home: roots
                    .iter()
                    .find(|(id, _)| id == &r.id)
                    .map(|(_, root)| root.clone()),
            })
            .collect())
    }
    pub fn reorder_managed_accounts(
        &self,
        ordered: &[String],
        expected: &[String],
    ) -> AccountResult<Vec<String>> {
        let _operation = self.mutation.try_lock().map_err(|_| fail("account_busy"))?;
        self.require_recovered()?;
        let mut store = self.store()?;
        let current: Vec<_> = store.vault.accounts.iter().map(|r| r.id.clone()).collect();
        if current != expected {
            return Err(fail("account_order_changed"));
        }
        let ids: std::collections::HashSet<_> = ordered.iter().collect();
        if ordered.len() != current.len()
            || ids.len() != current.len()
            || !current.iter().all(|id| ids.contains(id))
        {
            return Err(fail("invalid_account_order"));
        }
        if ordered != current {
            store.vault.accounts.sort_by_key(|r| {
                ordered
                    .iter()
                    .position(|id| id == &r.id)
                    .expect("validated full ID set")
            });
            self.require_accepting()?;
            store.save()?;
        }
        Ok(ordered.to_vec())
    }
}
#[cfg(test)]
#[path = "metadata_tests.rs"]
mod tests;
