use super::*;
use codexu_core::profiles::normalize_root;

struct Fixture {
    _temp: tempfile::TempDir,
    state: Arc<AppState>,
    root: std::path::PathBuf,
}
impl Fixture {
    async fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().canonicalize().unwrap().join("linked");
        std::fs::create_dir(&root).unwrap();
        let token = "synthetic.eyJlbWFpbCI6ICJsaW5rZWRAZml4dHVyZS5pbnZhbGlkIiwgImFjY291bnRfaWQiOiAic3ludGhldGljLWxpbmtlZC1hY2NvdW50IiwgImV4cCI6IDF9.signature";
        let auth = serde_json::json!({"tokens":{"access_token":token,"id_token":token,"refresh_token":"synthetic-refresh","account_id":"synthetic-linked-account"}});
        std::fs::write(root.join("auth.json"), serde_json::to_vec(&auth).unwrap()).unwrap();
        let root = normalize_root(&root).unwrap();
        let state = Arc::new(AppState::new(temp.path().join("app-data")));
        state
            .config
            .write()
            .await
            .profiles
            .add(LocalCliKind::Codex, "Linked fixture".into(), root.clone())
            .unwrap();
        Self {
            _temp: temp,
            state,
            root,
        }
    }
}

#[tokio::test]
async fn linked_i_reads_real_local_identity_after_absent_managed_mapping_without_writes() {
    let f = Fixture::new().await;
    let before = std::fs::read(f.root.join("auth.json")).unwrap();
    let expected_root = f.root.clone();
    let dto = linked_details_with(&f.state, 1, |root| async move {
        assert_eq!(root, expected_root);
        Err("manual_action_registration_required".into())
    })
    .await
    .unwrap();
    assert_eq!(dto.profile_id, "1");
    assert_eq!(dto.email.as_deref(), Some("linked@fixture.invalid"));
    assert!(dto.linked_local);
    assert!(!dto.quota_fresh);
    assert_eq!(std::fs::read(f.root.join("auth.json")).unwrap(), before);
    assert_eq!(std::fs::read_dir(&f.root).unwrap().count(), 1);
    assert!(!f.state.app_data_dir.exists());
}

#[tokio::test]
async fn linked_i_does_not_hide_managed_failures_or_accept_removed_catalog_identity() {
    let f = Fixture::new().await;
    assert_eq!(
        linked_details_with(&f.state, 1, |_| async { Err("account_busy".into()) })
            .await
            .err()
            .as_deref(),
        Some("account_busy")
    );
    let state = f.state.clone();
    let result = linked_details_with(&f.state, 1, |_| async move {
        state.config.write().await.profiles.remove(1).unwrap();
        Err("manual_action_registration_required".into())
    })
    .await;
    assert_eq!(
        result.err().as_deref(),
        Some("manual_action_identity_changed")
    );
}

#[tokio::test]
async fn linked_i_preserves_managed_details_and_rejects_unknown_profile_before_read() {
    let f = Fixture::new().await;
    let dto = linked_details_with(&f.state, 1, |_| async {
        Ok(LocalDetails {
            profile_id: "native-managed-id".into(),
            email: Some("managed@fixture.invalid".into()),
            ..Default::default()
        })
    })
    .await
    .unwrap();
    assert_eq!(dto.profile_id, "1");
    assert_eq!(dto.email.as_deref(), Some("managed@fixture.invalid"));
    assert!(!dto.linked_local);
    let result = linked_details_with(&f.state, 999, |_| async {
        panic!("unknown profile must not reach reader")
    })
    .await;
    assert_eq!(
        result.err().as_deref(),
        Some("manual_action_identity_changed")
    );
}
