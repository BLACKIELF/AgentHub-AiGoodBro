use super::*;
use serde::Deserialize;
use std::{
    io::{BufRead, BufReader, Read, Write},
    net::TcpListener,
    sync::atomic::{AtomicBool, Ordering},
    thread::{self, JoinHandle},
};
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Packet {
    schema_version: u32,
    key: String,
    proof: DesktopQuotaEvidence,
}
pub(super) struct EvidenceListener {
    pub endpoint: String,
    pub key: String,
    stop: Arc<AtomicBool>,
    _thread: Option<JoinHandle<()>>,
    claim: Arc<Mutex<DesktopWriterClaim>>,
}
impl EvidenceListener {
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Release);
    }
    pub fn start(
        gate: Arc<dyn ProxyAccountGate>,
        claim: DesktopWriterClaim,
    ) -> Result<Self, ProxyFailure> {
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
            .map_err(|_| ProxyFailure::Unavailable)?;
        listener
            .set_nonblocking(true)
            .map_err(|_| ProxyFailure::Unavailable)?;
        let endpoint = format!(
            "tcp:{}",
            listener
                .local_addr()
                .map_err(|_| ProxyFailure::Unavailable)?
        );
        let key = opaque_nonce()?;
        let wire_key = key.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let claim = Arc::new(Mutex::new(claim));
        let current_claim = claim.clone();
        let thread = thread::Builder::new()
            .name("agb-desktop-evidence".into())
            .spawn(move || {
                while !stopped.load(Ordering::Acquire) {
                    match listener.accept() {
                        Ok((mut stream, address)) => {
                            if !address.ip().is_loopback() {
                                continue;
                            }
                            if stream.set_nonblocking(false).is_err() {
                                continue;
                            }
                            let _ = stream.set_read_timeout(Some(Duration::from_secs(3)));
                            let _ = stream.set_write_timeout(Some(Duration::from_secs(3)));
                            let mut line = vec![];
                            let read = BufReader::new(&mut stream)
                                .take((2 << 20) + 1)
                                .read_until(b'\n', &mut line);
                            let packet =
                                if read.is_ok() && line.len() <= 2 << 20 && line.ends_with(b"\n") {
                                    serde_json::from_slice::<Packet>(&line).ok()
                                } else {
                                    None
                                };
                            let ok = packet.is_some_and(|p| {
                                let Ok(claim) = current_claim.lock().map(|c| c.clone()) else {
                                    return false;
                                };
                                p.schema_version == 1
                                    && key_equal(&p.key, &wire_key)
                                    && p.proof.writer_id == claim.writer_id
                                    && p.proof.proxy_run_id == claim.proxy_run_id
                                    && !stopped.load(Ordering::Acquire)
                                    && gate.recheck_desktop_writer(&claim).is_ok()
                                    && gate.accept_desktop_evidence(&claim, p.proof).is_ok()
                            });
                            let _ = stream.write_all(if ok {
                                b"{\"ok\":true}\n"
                            } else {
                                b"{\"ok\":false}\n"
                            });
                        }
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(10))
                        }
                        Err(_) => break,
                    }
                }
            })
            .map_err(|_| ProxyFailure::Unavailable)?;
        Ok(Self {
            endpoint,
            key,
            stop,
            _thread: Some(thread),
            claim,
        })
    }
    pub fn rebind(&self, claim: DesktopWriterClaim) -> Result<(), ProxyFailure> {
        *self.claim.lock().map_err(|_| ProxyFailure::Unavailable)? = claim;
        Ok(())
    }
}
impl Drop for EvidenceListener {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
    }
}
fn key_equal(a: &str, b: &str) -> bool {
    a.len() == b.len()
        && b.len() >= 24
        && a.bytes().zip(b.bytes()).fold(0u8, |v, (a, b)| v | (a ^ b)) == 0
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpStream;
    struct Gate {
        accepted: std::sync::atomic::AtomicUsize,
    }
    impl ProxyAccountGate for Gate {
        fn evidence(&self, _: &str) -> Result<AccountEvidence, ProxyFailure> {
            Err(ProxyFailure::Identity)
        }
        fn reserve(&self, _: &AdmissionRequest) -> Result<CredentialLease, ProxyFailure> {
            Err(ProxyFailure::Identity)
        }
        fn resolve(&self, _: &LeaseTuple) -> Result<AdmissionResolution, ProxyFailure> {
            Ok(AdmissionResolution::Unknown)
        }
        fn heartbeat(&self, _: &LeaseTuple) -> Result<(), ProxyFailure> {
            Err(ProxyFailure::Identity)
        }
        fn release(&self, _: &LeaseTuple) -> Result<(), ProxyFailure> {
            Err(ProxyFailure::Identity)
        }
        fn retire_run(&self, _: &str, _: bool) -> Result<(), ProxyFailure> {
            Err(ProxyFailure::Identity)
        }
        fn recheck_desktop_writer(&self, _: &DesktopWriterClaim) -> Result<(), ProxyFailure> {
            Ok(())
        }
        fn accept_desktop_evidence(
            &self,
            _: &DesktopWriterClaim,
            _: DesktopQuotaEvidence,
        ) -> Result<(), ProxyFailure> {
            self.accepted.fetch_add(1, Ordering::AcqRel);
            Ok(())
        }
    }
    #[test]
    fn writer_evidence_channel_authenticates_role_and_rejects_old_run() {
        let gate = Arc::new(Gate {
            accepted: std::sync::atomic::AtomicUsize::new(0),
        });
        let mut claim = DesktopWriterClaim {
            writer_id: "fixture-writer".into(),
            profile_id: "fixture-profile".into(),
            proxy_run_id: "run-one".into(),
            identity_hash: "a".repeat(64),
            initial_generation: "fixture-generation".into(),
        };
        let listener = EvidenceListener::start(gate.clone(), claim.clone()).unwrap();
        let send = |key: &str, run: &str| {
            let mut stream =
                TcpStream::connect(listener.endpoint.strip_prefix("tcp:").unwrap()).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let packet = serde_json::json!({"schemaVersion":1,"key":key,"proof":{"writerID":"fixture-writer","proxyRunID":run,"backendID":"fixture-backend","observedAt":1.0,"authDigest":"a".repeat(64),"account":{},"rateLimits":{}}});
            let mut bytes = serde_json::to_vec(&packet).unwrap();
            bytes.push(b'\n');
            // The listener is nonblocking, but an accepted connection must
            // wait for bounded fragmented JSON instead of treating WouldBlock
            // after the first fragment as an invalid or unknown proof.
            let split = bytes.len() / 2;
            stream.write_all(&bytes[..split]).unwrap();
            std::thread::sleep(Duration::from_millis(5));
            stream.write_all(&bytes[split..]).unwrap();
            let mut line = String::new();
            BufReader::new(stream).read_line(&mut line).unwrap();
            serde_json::from_str::<serde_json::Value>(&line).unwrap()["ok"]
                .as_bool()
                .unwrap()
        };
        assert!(!send("wrong", "run-one"));
        assert!(send(&listener.key, "run-one"));
        claim.proxy_run_id = "run-two".into();
        listener.rebind(claim).unwrap();
        assert!(!send(&listener.key, "run-one"));
        assert!(send(&listener.key, "run-two"));
        assert_eq!(gate.accepted.load(Ordering::Acquire), 2);
    }
}
