//! Windows-only synthetic cases. The shared test runner must execute `cases`
//! under the same user's non-elevated token, with its original owned Job proof.
//! No production pipe, real App, account, browser or model request is used.
use super::*;
use tokio::net::windows::named_pipe::ClientOptions;

struct FixtureRoot(Option<tempfile::TempDir>);
impl FixtureRoot {
    fn path(&self) -> &Path {
        self.0.as_ref().unwrap().path()
    }
}
impl Drop for FixtureRoot {
    fn drop(&mut self) {
        if std::thread::panicking() {
            if let Some(root) = self.0.take() {
                let _ = root.keep();
            }
        }
    }
}

struct ReadOnlyBackend {
    runtime: String,
    mutations: AtomicBool,
}
impl Backend for ReadOnlyBackend {
    type Permit = ();
    fn now_ms(&self) -> u64 {
        1_000
    }
    fn capture(&self, _: &Selector, refresh: bool) -> Result<Scope> {
        assert!(!refresh, "native smoke must not verify a real account");
        Ok(Scope {
            fingerprint: hash(b"fixture-scope"),
            epoch: hash(b"fixture-session"),
            runtime_sha256: self.runtime.clone(),
            alias: "synthetic".into(),
            valid_until_ms: 40_000,
        })
    }
    fn reserve(&self, _: &Scope) -> Result<()> {
        panic!("native smoke must not reserve a real account")
    }
    fn adopt(&self, _: &str, _: &Scope, _: ()) -> Result<()> {
        panic!("native smoke must not adopt a real account")
    }
    fn create(&self, _: &str, _: &Scope, _: &str, _: &str) -> Result<Acknowledgement> {
        self.mutations.store(true, Ordering::SeqCst);
        panic!("no real tasks")
    }
    fn approve(&self, _: &str, _: &Scope, _: &str, _: &TaskBinding) -> Result<Acknowledgement> {
        self.mutations.store(true, Ordering::SeqCst);
        panic!("no real tasks")
    }
    fn lookup(
        &self,
        _: LookupAction,
        _: &str,
        _: &str,
        _: &str,
        _: &str,
    ) -> Result<Option<Acknowledgement>> {
        Ok(None)
    }
}
fn pin_self() -> PinnedExecutable {
    let (s, guard) = current_image().unwrap();
    PinnedExecutable {
        path: s.path,
        guard,
    }
}
fn root(parent: &Path, label: &str) -> PathBuf {
    let root = parent.join(label);
    storage::create_private_directory(&root).unwrap();
    bind_current_app(&root).unwrap();
    root
}
fn name() -> String {
    format!(
        r"\\.\pipe\AiGoodBro-companion-v1-{}",
        &nonce().unwrap()[..32]
    )
}
fn bridge(root: &Path, stamp: &Stamp) -> (Arc<Bridge<ReadOnlyBackend>>, Arc<ReadOnlyBackend>) {
    let b = Arc::new(ReadOnlyBackend {
        runtime: stamp.sha256.clone(),
        mutations: AtomicBool::new(false),
    });
    (
        Arc::new(Bridge::new(root.join("journal"), b.clone()).unwrap()),
        b,
    )
}
async fn request(pipe: &str, id: &str, method: Method) -> serde_json::Value {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut client = loop {
        match ClientOptions::new().open(pipe) {
            Ok(v) => break v,
            Err(e) if e.raw_os_error() == Some(231) && tokio::time::Instant::now() < deadline => {
                tokio::time::sleep(Duration::from_millis(10)).await
            }
            Err(e) => panic!("fixture pipe open failed: {e}"),
        }
    };
    let data = Request {
        abi: ABI,
        request_id: hash(id.as_bytes()),
        method,
    }
    .encode()
    .unwrap();
    tokio::time::timeout_at(deadline, client.write_all(&data))
        .await
        .unwrap()
        .unwrap();
    let mut n = [0; 4];
    tokio::time::timeout_at(deadline, client.read_exact(&mut n))
        .await
        .unwrap()
        .unwrap();
    let n = u32::from_le_bytes(n) as usize;
    assert!((1..=MAX_FRAME).contains(&n));
    let mut bytes = vec![0; n];
    tokio::time::timeout_at(deadline, client.read_exact(&mut bytes))
        .await
        .unwrap()
        .unwrap();
    let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(value["abi"], ABI);
    assert_eq!(value["requestId"], hash(id.as_bytes()));
    value
}
fn no_background(receiver: &mut Receiver) {
    receiver.stop().unwrap();
    assert!(!receiver.active());
}
/// Shared cfg(test) LUA runner calls this exact production receiver path. This
/// function intentionally is not a native-pass claim until that runner is wired
/// into a non-ignored test and the required CI log gate.
pub(crate) fn cases() {
    identity(unsafe { GetCurrentProcess() }, unsafe {
        GetCurrentProcessId()
    })
    .expect("fixture must run unelevated");
    let tmp = FixtureRoot(Some(
        tempfile::Builder::new()
            .prefix("companion-native-")
            .tempdir_in(std::env::temp_dir().canonicalize().unwrap())
            .unwrap(),
    ));
    let (stamp, _image) = current_image().unwrap();
    let first = root(tmp.path(), "first");
    let (host, backend) = bridge(&first, &stamp);
    let pipe = name();
    let mut receiver =
        Receiver::start_inner(first.clone(), pin_self(), host, Some(pipe.clone())).unwrap();
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();
    rt.block_on(async {
        let reply = request(
            &pipe,
            "preflight",
            Method::Preflight {
                selector: Selector {
                    profile_id: 1,
                    project: r"C:\synthetic\never-read".into(),
                },
            },
        )
        .await;
        assert_eq!(reply["result"]["state"], "ready");
        assert!(reply["issueCode"].is_null());
        let status = request(
            &pipe,
            "status",
            Method::Status {
                operation_id: hash(b"missing"),
            },
        )
        .await;
        assert_eq!(status["result"]["state"], "missing");
    });
    assert!(!backend.mutations.load(Ordering::SeqCst));

    // A separate private root does not bypass the real first-instance fence.
    let other = root(tmp.path(), "collision");
    let (host, _) = bridge(&other, &stamp);
    let error = Receiver::start_inner(other, pin_self(), host, Some(pipe.clone()))
        .err()
        .unwrap();
    assert_eq!(error.code, "companion_receiver_busy");
    rt.block_on(async {
        assert_eq!(
            request(
                &pipe,
                "still-owned",
                Method::Status {
                    operation_id: hash(b"none")
                }
            )
            .await["result"]["state"],
            "missing"
        );
    });
    no_background(&mut receiver);

    // Source and runtime locator schemas are not interchangeable, and unknown
    // source hashes are never learned from a discovered pipe.
    let mut source_doc: serde_json::Value = serde_json::from_slice(
        &storage::read_bound_optional(&first.join(SOURCE_FILE), 16 * 1024, true)
            .unwrap()
            .unwrap(),
    )
    .unwrap();
    source_doc["image"]["sha256"] = serde_json::Value::String(hash(b"wrong-installed-image"));
    write_private(&first.join(SOURCE_FILE), &source_doc).unwrap();
    let (host, _) = bridge(&first, &stamp);
    assert_eq!(
        Receiver::start_inner(first.clone(), pin_self(), host, Some(name()))
            .err()
            .unwrap()
            .code,
        "companion_source_changed"
    );
    source_doc["role"] = serde_json::Value::String("runtimeLocator".into());
    write_private(&first.join(SOURCE_FILE), &source_doc).unwrap();
    let (host, _) = bridge(&first, &stamp);
    assert_eq!(
        Receiver::start_inner(first.clone(), pin_self(), host, Some(name()))
            .err()
            .unwrap()
            .code,
        "companion_peer_untrusted"
    );
    bind_current_app(&first).unwrap();

    // Exact interpreter matching: a test client is not a separately selected
    // fixture PE, even with identical bytes. Never depend on System32 files
    // having a single link (Windows servicing may legitimately hard-link them).
    let command = tmp.path().join("other-interpreter-fixture.exe");
    std::fs::copy(&stamp.path, &command).unwrap();
    let command = command.canonicalize().unwrap();
    let mut file = hold_image(&command).unwrap();
    let other_stamp = super::stamp(&command, &mut file).unwrap();
    let wrong = root(tmp.path(), "wrong-interpreter");
    let (host, _) = bridge(&wrong, &other_stamp);
    let other_pipe = name();
    let mut rejected = Receiver::start_inner(
        wrong,
        PinnedExecutable {
            path: command,
            guard: file,
        },
        host,
        Some(other_pipe.clone()),
    )
    .unwrap();
    rt.block_on(async {
        let mut client = ClientOptions::new().open(&other_pipe).unwrap();
        client
            .write_all(
                &Request {
                    abi: ABI,
                    request_id: hash(b"wrong-client"),
                    method: Method::Status {
                        operation_id: hash(b"none"),
                    },
                }
                .encode()
                .unwrap(),
            )
            .await
            .unwrap();
        let mut bytes = [0; 4];
        let result = tokio::time::timeout(Duration::from_secs(5), client.read(&mut bytes))
            .await
            .unwrap();
        assert!(result.is_err() || matches!(result, Ok(0)));
    });
    no_background(&mut rejected);

    // Malformed/short frames never reach Backend; disconnect releases only the
    // test connection and the original server remains usable afterwards.
    let framing = root(tmp.path(), "framing");
    let (host, backend) = bridge(&framing, &stamp);
    let frame_pipe = name();
    let mut framing_receiver =
        Receiver::start_inner(framing.clone(), pin_self(), host, Some(frame_pipe.clone())).unwrap();
    rt.block_on(async {
        let mut client = ClientOptions::new().open(&frame_pipe).unwrap();
        client.write_all(&100u32.to_le_bytes()).await.unwrap();
        client.write_all(b"{").await.unwrap();
        drop(client);
        assert_eq!(
            request(
                &frame_pipe,
                "after-partial",
                Method::Status {
                    operation_id: hash(b"none")
                }
            )
            .await["result"]["state"],
            "missing"
        );
    });
    assert!(!backend.mutations.load(Ordering::SeqCst));
    no_background(&mut framing_receiver);
    // The same unique fixture pipe and owner fence are available only after a
    // successful stop/join; reopening never terminates or adopts another server.
    let (host, _) = bridge(&framing, &stamp);
    let mut reopened = Receiver::start_inner(framing, pin_self(), host, Some(frame_pipe)).unwrap();
    no_background(&mut reopened);

    // The receiver's policy is stricter than the unrelated Desktop owner
    // transport: even an outsider read ACE is not a private Companion pipe.
    rt.block_on(async {
        let (sid, _) = identity(unsafe { GetCurrentProcess() }, unsafe {
            GetCurrentProcessId()
        })
        .unwrap();
        let text = format!("O:{sid}D:P(A;;GA;;;{sid})(A;;GA;;;SY)(A;;GR;;;WD)\0")
            .encode_utf16()
            .collect::<Vec<_>>();
        let mut descriptor = ptr::null_mut();
        assert_ne!(
            unsafe {
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    text.as_ptr(),
                    1,
                    &mut descriptor,
                    ptr::null_mut(),
                )
            },
            0
        );
        let _descriptor = Local(descriptor as usize);
        let mut attrs = Attributes {
            size: std::mem::size_of::<Attributes>() as u32,
            descriptor,
            inherit: 0,
        };
        let server = unsafe {
            ServerOptions::new()
                .first_pipe_instance(true)
                .reject_remote_clients(true)
                .create_with_security_attributes_raw(name(), (&mut attrs as *mut Attributes).cast())
        }
        .unwrap();
        assert_eq!(
            private_pipe(server.as_raw_handle().cast())
                .unwrap_err()
                .code,
            "companion_peer_untrusted"
        );
    });

    // A connected partial sender makes stop uncertain until its own bounded
    // receive completes. The receiver owner fence must remain held meanwhile.
    let blocked = root(tmp.path(), "blocked");
    let (host, _) = bridge(&blocked, &stamp);
    let blocked_pipe = name();
    let mut blocked_receiver = Receiver::start_inner(
        blocked.clone(),
        pin_self(),
        host,
        Some(blocked_pipe.clone()),
    )
    .unwrap();
    rt.block_on(async {
        let mut client = ClientOptions::new().open(&blocked_pipe).unwrap();
        client.write_all(&[1]).await.unwrap();
        // Wait for this test's server connection admission, not a guessed sleep.
        let until = Instant::now() + Duration::from_secs(2);
        while !blocked_receiver.connected.load(Ordering::Acquire) && Instant::now() < until {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(blocked_receiver.connected.load(Ordering::Acquire));
        assert_eq!(
            blocked_receiver.stop().unwrap_err().code,
            "companion_cleanup_unconfirmed"
        );
        assert!(storage::StoreLock::acquire(&blocked.join("receiver-owner")).is_err());
        drop(client);
    });
    no_background(&mut blocked_receiver);
}
