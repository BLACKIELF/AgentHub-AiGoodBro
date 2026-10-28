//! Recover only a cryptographically bound, originally owned Windows Job.
//! Missing legacy evidence remains unknown; no name/PID-only cleanup exists.
use super::*;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    io::{Read, Write},
    path::{Path, PathBuf},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DesktopRecoveryKind {
    Prepared,
    Exited,
}
pub struct DesktopRecoveryProof {
    claim: DesktopWriterClaim,
    kind: DesktopRecoveryKind,
    digest: String,
    owner: Owner,
}
impl DesktopRecoveryProof {
    pub fn claim(&self) -> &DesktopWriterClaim {
        &self.claim
    }
    pub fn kind(&self) -> DesktopRecoveryKind {
        self.kind
    }
    pub fn receipt_digest(&self) -> &str {
        &self.digest
    }
    pub fn owner_pid(&self) -> u32 {
        self.owner.pid
    }
    pub fn owner_created_at(&self) -> u64 {
        self.owner.created
    }
    #[cfg(test)]
    pub(crate) fn synthetic(claim: DesktopWriterClaim, kind: DesktopRecoveryKind) -> Self {
        Self {
            claim,
            kind,
            digest: "a".repeat(64),
            owner: Owner {
                pid: 11,
                created: 22,
                sid: "synthetic".into(),
                image_hash: "b".repeat(64),
                session: 0,
            },
        }
    }
}
pub struct ProxyHelperRecoveryProof {
    run: String,
    digest: String,
    owner: Owner,
}
impl ProxyHelperRecoveryProof {
    pub fn run_id(&self) -> &str {
        &self.run
    }
    pub fn receipt_digest(&self) -> &str {
        &self.digest
    }
    pub fn owner_pid(&self) -> u32 {
        self.owner.pid
    }
    pub fn owner_created_at(&self) -> u64 {
        self.owner.created
    }
    #[cfg(test)]
    pub(crate) fn synthetic(run: String) -> Self {
        Self {
            run,
            digest: "a".repeat(64),
            owner: Owner {
                pid: 11,
                created: 22,
                sid: "synthetic".into(),
                image_hash: "b".repeat(64),
                session: 0,
            },
        }
    }
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Owner {
    pid: u32,
    created: u64,
    sid: String,
    image_hash: String,
    session: u32,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Stage {
    Prepared,
    Launching,
    Armed,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Receipt {
    schema: u32,
    kind: String,
    id: String,
    run: String,
    profile: Option<String>,
    identity: Option<String>,
    generation: Option<String>,
    owner: Owner,
    stage: Stage,
    job: Option<String>,
    nonce: Option<String>,
    child_pid: Option<u32>,
    child_created: Option<u64>,
}
impl Receipt {
    fn validate(&self) -> Result<(), ProxyFailure> {
        if self.schema != 1
            || !policy::valid_id(&self.id)
            || !policy::valid_id(&self.run)
            || !matches!(self.kind.as_str(), "desktop" | "helper")
            || self.owner.pid < 2
            || self.owner.created == 0
            || !policy::valid_hash(&self.owner.image_hash)
            || self.owner.sid.is_empty()
        {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        if self.kind == "desktop"
            && (!self.profile.as_deref().is_some_and(policy::valid_id)
                || !self.identity.as_deref().is_some_and(policy::valid_hash)
                || !self.generation.as_ref().is_some_and(|v| !v.is_empty()))
        {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        if matches!(self.stage, Stage::Armed)
            && (!self.nonce.as_deref().is_some_and(policy::valid_id)
                || self.job.as_ref().is_none_or(|name| {
                    name != &job_name(&self.kind, &self.id, self.nonce.as_deref().unwrap_or(""))
                })
                || self.child_pid.is_none_or(|p| p < 2)
                || self.child_created.is_none_or(|p| p == 0))
        {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        Ok(())
    }
    fn claim(&self) -> Result<DesktopWriterClaim, ProxyFailure> {
        self.validate()?;
        if self.kind != "desktop" {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
        Ok(DesktopWriterClaim {
            writer_id: self.id.clone(),
            profile_id: self.profile.clone().unwrap(),
            proxy_run_id: self.run.clone(),
            identity_hash: self.identity.clone().unwrap(),
            initial_generation: self.generation.clone().unwrap(),
        })
    }
}
const CONTEXT: &str = "AiGoodBro.Next.Windows.owned-job.v1";
fn receipt_path(root: &Path, kind: &str, id: &str) -> Result<PathBuf, ProxyFailure> {
    if !policy::valid_id(id)
        || !matches!(kind, "desktop" | "helper")
        || !crate::updates::safe_download_directory(root)
    {
        return Err(ProxyFailure::CleanupUnconfirmed);
    }
    Ok(root.join(format!("owner-{kind}-{id}.dpapi")))
}
fn read(root: &Path, kind: &str, id: &str) -> Result<(Receipt, String), ProxyFailure> {
    use crate::accounts::SecretProtector;
    let path = receipt_path(root, kind, id)?;
    let meta = std::fs::symlink_metadata(&path).map_err(|_| ProxyFailure::CleanupUnconfirmed)?;
    if !meta.is_file() || meta.file_type().is_symlink() || meta.len() > 65536 {
        return Err(ProxyFailure::CleanupUnconfirmed);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if meta.file_attributes() & 0x400 != 0 {
            return Err(ProxyFailure::CleanupUnconfirmed);
        }
    }
    let mut bytes = vec![];
    std::fs::File::open(&path)
        .and_then(|f| f.take(65537).read_to_end(&mut bytes))
        .map_err(|_| ProxyFailure::CleanupUnconfirmed)?;
    if bytes.len() > 65536 {
        return Err(ProxyFailure::CleanupUnconfirmed);
    }
    let plain = crate::accounts::DpapiProtector
        .unseal(CONTEXT, &bytes)
        .map_err(|_| ProxyFailure::CleanupUnconfirmed)?;
    let receipt: Receipt =
        serde_json::from_slice(&plain).map_err(|_| ProxyFailure::CleanupUnconfirmed)?;
    receipt.validate()?;
    if receipt.kind != kind || receipt.id != id {
        return Err(ProxyFailure::CleanupUnconfirmed);
    }
    Ok((receipt, format!("{:x}", Sha256::digest(&bytes))))
}
fn write(root: &Path, receipt: &Receipt) -> Result<(), ProxyFailure> {
    use crate::accounts::SecretProtector;
    receipt.validate()?;
    let path = receipt_path(root, &receipt.kind, &receipt.id)?;
    std::fs::create_dir_all(root).map_err(|_| ProxyFailure::Unavailable)?;
    if std::fs::symlink_metadata(&path).is_ok_and(|m| !m.is_file() || m.file_type().is_symlink()) {
        return Err(ProxyFailure::CleanupUnconfirmed);
    }
    let plain = serde_json::to_vec(receipt).map_err(|_| ProxyFailure::Unavailable)?;
    let sealed = crate::accounts::DpapiProtector
        .seal(CONTEXT, &plain)
        .map_err(|_| ProxyFailure::Unavailable)?;
    let mut temp = tempfile::NamedTempFile::new_in(root).map_err(|_| ProxyFailure::Unavailable)?;
    temp.write_all(&sealed)
        .and_then(|_| temp.as_file().sync_all())
        .map_err(|_| ProxyFailure::Unavailable)?;
    temp.persist(path).map_err(|_| ProxyFailure::Unavailable)?;
    Ok(())
}
pub(crate) fn job_name(kind: &str, id: &str, nonce: &str) -> String {
    format!("Local\\AiGoodBro.Next.{kind}.{id}.{nonce}")
}
#[cfg(windows)]
pub(crate) fn nonce() -> Result<String, ProxyFailure> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).map_err(|_| ProxyFailure::Unavailable)?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}
#[cfg(windows)]
pub(crate) fn process_created(handle: isize) -> Result<u64, ProxyFailure> {
    native::process_created(handle)
}
#[cfg(windows)]
pub(crate) fn create_private_job(name: &str) -> Result<isize, ProxyFailure> {
    native::create_private_job(name)
}
pub(crate) fn prepare_desktop(root: &Path, claim: &DesktopWriterClaim) -> Result<(), ProxyFailure> {
    if receipt_path(root, "desktop", &claim.writer_id)?.exists() {
        return Err(ProxyFailure::CleanupUnconfirmed);
    }
    let owner = native::current_owner()?;
    let receipt = Receipt {
        schema: 1,
        kind: "desktop".into(),
        id: claim.writer_id.clone(),
        run: claim.proxy_run_id.clone(),
        profile: Some(claim.profile_id.clone()),
        identity: Some(claim.identity_hash.clone()),
        generation: Some(claim.initial_generation.clone()),
        owner,
        stage: Stage::Prepared,
        job: None,
        nonce: None,
        child_pid: None,
        child_created: None,
    };
    write(root, &receipt)
}
#[cfg(windows)]
pub(crate) fn launching(root: &Path, kind: &str, id: &str) -> Result<(), ProxyFailure> {
    let (mut r, _) = read(root, kind, id)?;
    if !native::same_owner(&r.owner)? || !matches!(r.stage, Stage::Prepared) {
        return Err(ProxyFailure::CleanupUnconfirmed);
    }
    r.stage = Stage::Launching;
    write(root, &r)
}
#[cfg(windows)]
pub(crate) fn arm(
    root: &Path,
    kind: &str,
    id: &str,
    job: String,
    nonce: String,
    pid: u32,
    created: u64,
) -> Result<(), ProxyFailure> {
    let (mut r, _) = read(root, kind, id)?;
    if !native::same_owner(&r.owner)? || !matches!(r.stage, Stage::Launching) {
        return Err(ProxyFailure::CleanupUnconfirmed);
    }
    r.stage = Stage::Armed;
    r.job = Some(job);
    r.nonce = Some(nonce);
    r.child_pid = Some(pid);
    r.child_created = Some(created);
    write(root, &r)
}
#[cfg(windows)]
pub(crate) fn prepare_helper(root: &Path, run: &str) -> Result<(), ProxyFailure> {
    if receipt_path(root, "helper", run)?.exists() {
        return Err(ProxyFailure::CleanupUnconfirmed);
    }
    let r = Receipt {
        schema: 1,
        kind: "helper".into(),
        id: run.into(),
        run: run.into(),
        profile: None,
        identity: None,
        generation: None,
        owner: native::current_owner()?,
        stage: Stage::Prepared,
        job: None,
        nonce: None,
        child_pid: None,
        child_created: None,
    };
    write(root, &r)
}
pub(crate) fn verify_desktop(
    root: &Path,
    claim: &DesktopWriterClaim,
) -> Result<DesktopRecoveryProof, ProxyFailure> {
    let (r, digest) = read(root, "desktop", &claim.writer_id)?;
    let from = r.claim()?;
    if from.writer_id != claim.writer_id
        || from.profile_id != claim.profile_id
        || from.identity_hash != claim.identity_hash
        || from.initial_generation != claim.initial_generation
    {
        return Err(ProxyFailure::CleanupUnconfirmed);
    }
    native::verify_exit(&r)?;
    // The sealed receipt retains its original run across a controlled rebind.
    // The registry, which durably records that original run, must authenticate
    // this receipt's exact run before granting the current writer claim.
    let kind = if matches!(r.stage, Stage::Prepared) {
        DesktopRecoveryKind::Prepared
    } else {
        DesktopRecoveryKind::Exited
    };
    Ok(DesktopRecoveryProof {
        claim: from,
        kind,
        digest,
        owner: r.owner,
    })
}
pub(crate) fn verify_helper(
    root: &Path,
    run: &str,
) -> Result<ProxyHelperRecoveryProof, ProxyFailure> {
    let (r, digest) = read(root, "helper", run)?;
    if r.run != run {
        return Err(ProxyFailure::CleanupUnconfirmed);
    }
    native::verify_exit(&r)?;
    Ok(ProxyHelperRecoveryProof {
        run: run.into(),
        digest,
        owner: r.owner,
    })
}

#[cfg(windows)]
mod native;
#[cfg(all(test, windows))]
mod tests;
#[cfg(not(windows))]
mod native {
    use super::*;
    pub(super) fn current_owner() -> Result<Owner, ProxyFailure> {
        Err(ProxyFailure::Unavailable)
    }
    pub(super) fn verify_exit(_: &Receipt) -> Result<(), ProxyFailure> {
        Err(ProxyFailure::CleanupUnconfirmed)
    }
}
