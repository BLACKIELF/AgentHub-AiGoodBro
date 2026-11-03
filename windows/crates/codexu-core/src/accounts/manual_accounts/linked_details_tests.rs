use super::*;
use serde_json::json;

fn auth(email: &str, access_email: &str, expires: i64) -> Vec<u8> {
    let token = |email: &str| {
        format!("synthetic.{}.signature", URL_SAFE_NO_PAD.encode(serde_json::to_vec(&json!({
        "email": email, "account_id": "synthetic-linked-account", "exp": expires,
        "https://api.openai.com/auth": {"chatgpt_account_id":"synthetic-linked-account", "chatgpt_plan_type":"plus"}
    })).unwrap()))
    };
    serde_json::to_vec(
        &json!({"tokens": {"id_token": token(email), "access_token": token(access_email),
        "refresh_token":"synthetic-not-a-secret", "account_id":"synthetic-linked-account"}}),
    )
    .unwrap()
}

#[test]
fn linked_details_show_full_email_without_enrollment_or_fresh_quota_claims() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().canonicalize().unwrap();
    let bytes = auth(
        "Linked.Account@fixture.invalid",
        "linked.account@fixture.invalid",
        1,
    );
    std::fs::write(home.join("auth.json"), &bytes).unwrap();
    let dto = read_linked_local_details("7", &home).unwrap();
    assert_eq!(dto.email.as_deref(), Some("linked.account@fixture.invalid"));
    assert!(dto.linked_local);
    assert_eq!(dto.plan_type.as_deref(), Some("plus"));
    assert!(!dto.quota_fresh);
    assert!(dto.quota_windows.is_empty());
    assert_eq!(dto.participating, None);
    assert_eq!(dto.profile_fetched_at_ms, None);
    let value = serde_json::to_string(&dto).unwrap();
    for secret in [
        "synthetic-not-a-secret",
        "synthetic-linked-account",
        "id_token",
        "access_token",
        home.to_str().unwrap(),
    ] {
        assert!(!value.contains(secret));
    }
    assert_eq!(std::fs::read(home.join("auth.json")).unwrap(), bytes);
    assert_eq!(std::fs::read_dir(&home).unwrap().count(), 1);
}

#[test]
fn linked_details_reject_missing_malformed_conflicting_or_oversized_identity() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path().canonicalize().unwrap();
    assert_eq!(
        read_linked_local_details("7", &home).err().unwrap().code,
        "login_required"
    );
    for bytes in [
        b"not json".to_vec(),
        auth("one@fixture.invalid", "two@fixture.invalid", 4102444800),
        vec![b' '; 1024 * 1024 + 1],
    ] {
        std::fs::write(home.join("auth.json"), bytes).unwrap();
        assert!(read_linked_local_details("7", &home).is_err());
    }
    assert!(read_linked_local_details("7", Path::new("relative")).is_err());
}

#[cfg(unix)]
#[test]
fn linked_details_reject_symlinked_auth_and_home() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().canonicalize().unwrap();
    let home = root.join("home");
    std::fs::create_dir(&home).unwrap();
    let source = root.join("source.json");
    std::fs::write(
        &source,
        auth("one@fixture.invalid", "one@fixture.invalid", 4102444800),
    )
    .unwrap();
    std::os::unix::fs::symlink(&source, home.join("auth.json")).unwrap();
    assert!(read_linked_local_details("7", &home).is_err());
    std::os::unix::fs::symlink(&home, root.join("alias")).unwrap();
    assert!(read_linked_local_details("7", &root.join("alias")).is_err());
}
