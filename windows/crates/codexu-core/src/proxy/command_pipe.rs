//! One bounded frame on the sole owned writer. Never leave a partial JSON line
//! available to the next command, and never wait for the helper to drain stdin.
use std::io::{PipeReader, PipeWriter};

pub(super) fn owned_pipe() -> std::io::Result<(PipeReader, PipeWriter)> {
    let (reader, writer) = std::io::pipe()?;
    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawHandle;
        use windows::Win32::{
            Foundation::HANDLE,
            System::Pipes::{SetNamedPipeHandleState, PIPE_NOWAIT},
        };
        // Configure the sole writer before a child can issue its first read.
        // Keep this mode for its lifetime: every write uses the bounded path.
        unsafe {
            SetNamedPipeHandleState(
                HANDLE(writer.as_raw_handle()),
                Some(&PIPE_NOWAIT),
                None,
                None,
            )
        }
        .map_err(|error| {
            #[cfg(test)]
            eprintln!("proxy_pipe_fixture prepare_hresult={}", error.code().0);
            std::io::Error::other(error)
        })?;
    }
    Ok((reader, writer))
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum FrameFailure {
    Unchanged,
    Poisoned,
}

fn valid_frame(bytes: &[u8]) -> bool {
    !bytes.is_empty()
        && bytes.len() <= 512
        && bytes.last() == Some(&b'\n')
        && !bytes[..bytes.len() - 1].contains(&b'\n')
}

pub(super) fn send(stdin: &mut Option<PipeWriter>, bytes: &[u8]) -> Result<(), FrameFailure> {
    if !valid_frame(bytes) {
        return Err(FrameFailure::Unchanged);
    }
    let writer = stdin.as_mut().ok_or(FrameFailure::Poisoned)?;
    let result = send_chunk(writer, bytes);
    if result == Err(FrameFailure::Poisoned) {
        // A partial frame can never be followed by a second command. Closing
        // the sole writer here makes that invariant independent of the caller.
        stdin.take();
    }
    result
}

#[cfg(windows)]
pub(super) fn send_chunk(stdin: &mut PipeWriter, bytes: &[u8]) -> Result<(), FrameFailure> {
    use std::os::windows::io::AsRawHandle;
    send_handle(
        windows::Win32::Foundation::HANDLE(stdin.as_raw_handle()),
        bytes,
    )
}

#[cfg(all(test, windows))]
pub(super) fn diagnostics(stdin: &PipeWriter) -> String {
    use std::os::windows::io::AsRawHandle;
    use windows::{
        Wdk::Storage::FileSystem::{
            FilePipeLocalInformation, NtQueryInformationFile, FILE_PIPE_LOCAL_INFORMATION,
        },
        Win32::{Foundation::HANDLE, System::IO::IO_STATUS_BLOCK},
    };
    let mut info = FILE_PIPE_LOCAL_INFORMATION::default();
    let mut status = IO_STATUS_BLOCK::default();
    let result = unsafe {
        NtQueryInformationFile(
            HANDLE(stdin.as_raw_handle()),
            &mut status,
            &mut info as *mut _ as _,
            std::mem::size_of_val(&info) as u32,
            FilePipeLocalInformation,
        )
    };
    format!("ntstatus={} info_bytes={} write_quota={} read_available={} inbound_quota={} outbound_quota={} pipe_state={} pipe_end={}", result.0, status.Information, info.WriteQuotaAvailable, info.ReadDataAvailable, info.InboundQuota, info.OutboundQuota, info.NamedPipeState, info.NamedPipeEnd)
}

#[cfg(all(test, not(windows)))]
pub(super) fn diagnostics(_: &PipeWriter) -> &'static str {
    "non_windows"
}

#[cfg(windows)]
fn no_write_progress(handle: windows::Win32::Foundation::HANDLE) -> Result<(), FrameFailure> {
    use windows::{
        Wdk::Storage::FileSystem::{
            FilePipeLocalInformation, NtQueryInformationFile, FILE_PIPE_CONNECTED_STATE,
            FILE_PIPE_LOCAL_INFORMATION,
        },
        Win32::System::IO::IO_STATUS_BLOCK,
    };
    // owned_pipe gives us a synchronous handle. Query only after a zero-byte
    // write; a connected full pipe may be retried, a closed reader may not.
    // Buffer quota is deliberately not used as an admission condition.
    let mut info = FILE_PIPE_LOCAL_INFORMATION::default();
    let mut status = IO_STATUS_BLOCK::default();
    let result = unsafe {
        NtQueryInformationFile(
            handle,
            &mut status,
            &mut info as *mut _ as _,
            std::mem::size_of_val(&info) as u32,
            FilePipeLocalInformation,
        )
    };
    if result.0 == 0
        && status.Information == std::mem::size_of_val(&info)
        && info.NamedPipeState == FILE_PIPE_CONNECTED_STATE
    {
        Err(FrameFailure::Unchanged)
    } else {
        Err(FrameFailure::Poisoned)
    }
}

#[cfg(windows)]
fn send_handle(
    handle: windows::Win32::Foundation::HANDLE,
    bytes: &[u8],
) -> Result<(), FrameFailure> {
    use windows::Win32::{Foundation::ERROR_NO_DATA, Storage::FileSystem::WriteFile};
    if bytes.is_empty() || bytes.len() > 512 {
        return Err(FrameFailure::Unchanged);
    }
    // owned_pipe configures PIPE_NOWAIT before spawning the reader. The caller
    // owns the only writer and serializes complete command frames. Kernel
    // WriteQuotaAvailable can be zero while a pending reader accepts data;
    // only the actual nonblocking write decides whether bytes were accepted.
    let mut written = 0;
    let result = unsafe { WriteFile(handle, Some(bytes), Some(&mut written), None) };
    if written != 0 && written != bytes.len() as u32 {
        return Err(FrameFailure::Poisoned);
    }
    if let Err(_error) = result {
        if written == 0 && _error.code() == windows::core::HRESULT::from_win32(ERROR_NO_DATA.0) {
            return no_write_progress(handle);
        }
        #[cfg(test)]
        eprintln!(
            "proxy_pipe_fixture write_hresult={} written={}",
            _error.code().0,
            written
        );
        return Err(FrameFailure::Poisoned);
    }
    if written == bytes.len() as u32 {
        Ok(())
    } else {
        no_write_progress(handle)
    }
}

#[cfg(unix)]
pub(super) fn send_chunk(stdin: &mut PipeWriter, bytes: &[u8]) -> Result<(), FrameFailure> {
    use std::os::fd::AsRawFd;
    send_fd(stdin.as_raw_fd(), bytes)
}

#[cfg(unix)]
fn send_fd(fd: std::os::fd::RawFd, bytes: &[u8]) -> Result<(), FrameFailure> {
    use std::ffi::{c_int, c_void};
    unsafe extern "C" {
        fn fcntl(fd: c_int, command: c_int, ...) -> c_int;
        fn write(fd: c_int, bytes: *const c_void, size: usize) -> isize;
    }
    #[cfg(target_os = "macos")]
    const NONBLOCK: c_int = 4;
    #[cfg(not(target_os = "macos"))]
    const NONBLOCK: c_int = 2048;
    if bytes.is_empty() || bytes.len() > 512 {
        return Err(FrameFailure::Unchanged);
    }
    let flags = unsafe { fcntl(fd, 3) };
    if flags < 0 || unsafe { fcntl(fd, 4, flags | NONBLOCK) } < 0 {
        return Err(FrameFailure::Unchanged);
    }
    // <=512 is within POSIX's minimum PIPE_BUF: a nonblocking write is all or
    // nothing. Do not write_all or flush/retry a partially emitted frame.
    let written = unsafe { write(fd, bytes.as_ptr().cast(), bytes.len()) };
    let write_error = (written < 0).then(std::io::Error::last_os_error);
    let restored = unsafe { fcntl(fd, 4, flags) };
    if restored < 0 || written > 0 && written as usize != bytes.len() {
        return Err(FrameFailure::Poisoned);
    }
    if write_error.is_some_and(|error| error.kind() != std::io::ErrorKind::WouldBlock) {
        return Err(FrameFailure::Poisoned);
    }
    if written as usize == bytes.len() {
        Ok(())
    } else {
        Err(FrameFailure::Unchanged)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Read;
    #[cfg(not(windows))]
    use std::io::Write;
    use std::time::{Duration, Instant};

    #[test]
    #[ignore = "child-only pipe fixture; invoked only with the exact test name"]
    fn blocked_pipe_child() {
        let Ok(role) = std::env::var("AIGOODBRO_PIPE_FIXTURE_ROLE") else {
            return;
        };
        if role == "hold" {
            std::thread::sleep(Duration::from_secs(5));
        } else if role == "consume" || role == "slow_consume" {
            use std::io::BufRead;
            let mut frame = Vec::new();
            if role == "consume" {
                std::io::stdin()
                    .lock()
                    .read_until(b'\n', &mut frame)
                    .unwrap();
            } else {
                let mut input = std::io::stdin().lock();
                while frame.last() != Some(&b'\n') {
                    let mut buffer = [0; 4096];
                    let n = input.read(&mut buffer).unwrap();
                    if n == 0 {
                        break;
                    }
                    frame.extend_from_slice(&buffer[..n]);
                    std::thread::sleep(Duration::from_millis(5));
                }
            }
            assert_eq!(frame.len(), 65537);
            assert_eq!(frame.last(), Some(&b'\n'));
            assert!(frame[..65536].iter().all(|byte| *byte == b'x'));
            println!("synthetic_startup_frame_complete");
        }
    }

    #[test]
    #[ignore = "explicit native helper contract; same synchronous pipe with a consuming child"]
    fn actual_helper_startup_pipe_reader_accepts_complete_large_frame() {
        use std::process::{Command, Stdio};
        use std::sync::atomic::AtomicUsize;
        for role in ["consume", "slow_consume"] {
            let (input, mut writer) = owned_pipe().unwrap();
            let mut command = Command::new(std::env::current_exe().unwrap());
            command
                .args([
                    "--exact",
                    "proxy::process::command_pipe::tests::blocked_pipe_child",
                    "--ignored",
                    "--nocapture",
                ])
                .env("AIGOODBRO_PIPE_FIXTURE_ROLE", role)
                .stdin(Stdio::from(input))
                .stdout(Stdio::piped())
                .stderr(Stdio::null());
            let mut child = command.spawn().unwrap();
            drop(command);
            let at = Instant::now();
            let mut frame = vec![b'x'; 65536];
            frame.push(b'\n');
            let write = super::super::write_startup(
                &mut writer,
                &frame,
                &AtomicUsize::new(1),
                1,
                None,
                at + Duration::from_secs(3),
            );
            #[cfg(windows)]
            if write.is_err() {
                // Diagnostic only, against this synthetic consuming child.
                // Never turn a failed startup into a pass or continue its line.
                use std::os::windows::io::AsRawHandle;
                let mut written = 0;
                let result = unsafe {
                    windows::Win32::Storage::FileSystem::WriteFile(
                        windows::Win32::Foundation::HANDLE(writer.as_raw_handle()),
                        Some(&[b'x'; 512]),
                        Some(&mut written),
                        None,
                    )
                };
                eprintln!(
                    "proxy_pipe_fixture post_failure_direct_write_hresult={} written={}",
                    result.err().map(|error| error.code().0).unwrap_or(0),
                    written
                );
            }
            drop(writer);
            let exit = loop {
                if let Some(exit) = child.try_wait().unwrap() {
                    break Some(exit);
                }
                if write.is_err() || at.elapsed() >= Duration::from_secs(5) {
                    let _ = child.kill();
                    let _ = child.wait();
                    break None;
                }
                std::thread::sleep(Duration::from_millis(5));
            };
            let mut output = String::new();
            child
                .stdout
                .take()
                .unwrap()
                .read_to_string(&mut output)
                .unwrap();
            assert_eq!(write, Ok(()));
            assert!(exit.is_some_and(|exit| exit.success()));
            assert!(output.contains("synthetic_startup_frame_complete"));
        }
    }

    #[test]
    #[ignore = "explicit native helper contract; no real account or service"]
    fn actual_helper_startup_unread_pipe_is_cancellable_and_dead_reader_fails_bounded() {
        use std::process::{Command, Stdio};
        use std::sync::{
            atomic::{AtomicUsize, Ordering},
            Arc,
        };
        for role in ["hold", "timeout", "exit"] {
            let (input, mut writer) = owned_pipe().unwrap();
            let mut command = Command::new(std::env::current_exe().unwrap());
            command
                .args([
                    "--exact",
                    "proxy::process::command_pipe::tests::blocked_pipe_child",
                    "--ignored",
                    "--nocapture",
                ])
                .env(
                    "AIGOODBRO_PIPE_FIXTURE_ROLE",
                    if role == "exit" { "exit" } else { "hold" },
                )
                .stdin(Stdio::from(input))
                .stdout(Stdio::null())
                .stderr(Stdio::null());
            let mut child = command.spawn().unwrap();
            drop(command);
            let generation = Arc::new(AtomicUsize::new(1));
            let stop = generation.clone();
            if role != "exit" {
                let mut filled = 0;
                while send_chunk(&mut writer, &[b'x'; 512]) == Ok(()) {
                    filled += 512;
                    assert!(filled < 4 * 1024 * 1024);
                }
                assert!(filled >= 512);
            }
            let cancel = if role == "hold" {
                Some(std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_millis(50));
                    stop.store(2, Ordering::Release);
                }))
            } else {
                None
            };
            let at = Instant::now();
            let result = super::super::write_startup(
                &mut writer,
                &vec![b'x'; 1 << 20],
                &generation,
                1,
                None,
                at + if role == "timeout" {
                    Duration::from_millis(100)
                } else {
                    Duration::from_secs(10)
                },
            );
            drop(writer);
            let _ = child.kill();
            let _ = child.wait();
            if let Some(cancel) = cancel {
                cancel.join().unwrap();
            }
            assert!(at.elapsed() < Duration::from_secs(2), "role={role}");
            assert_eq!(
                result,
                Err(if role == "hold" {
                    super::super::ProxyFailure::Stopping
                } else {
                    super::super::ProxyFailure::StartupFailed
                })
            );
        }
    }

    #[test]
    #[ignore = "explicit native helper contract uses the same owned synchronous pipe type"]
    fn actual_helper_command_pipe_full_rejects_whole_frame_without_blocking_or_corruption() {
        let (mut read, write) = owned_pipe().unwrap();
        let mut write = Some(write);
        let frame = b"{\"command\":\"fixture\"}\n";
        let mut fill = vec![b'x'; 512];
        fill[511] = b'\n';
        let mut count = 0;
        while send(&mut write, &fill) == Ok(()) {
            count += 512;
            assert!(count < 4 * 1024 * 1024);
        }
        assert!(count >= 512);
        let at = Instant::now();
        assert_eq!(send(&mut write, frame), Err(FrameFailure::Unchanged));
        assert!(at.elapsed() < Duration::from_secs(1));
        #[cfg(windows)]
        {
            // Draining one byte from a 512-byte queued write does not release
            // that entry's storage. Drain the complete entry, then refill all
            // but one byte to exercise an actual partial write.
            let mut first = [0u8; 512];
            read.read_exact(&mut first).unwrap();
            assert_eq!(first.as_slice(), fill.as_slice());
            let mut refill = vec![b'y'; 511];
            refill[510] = b'\n';
            send(&mut write, &refill).unwrap();
            eprintln!(
                "proxy_pipe_fixture one_byte_room {}",
                diagnostics(write.as_ref().unwrap())
            );
            let result = send(&mut write, frame);
            assert_eq!(result, Err(FrameFailure::Poisoned));
            assert!(write.is_none());
            assert_eq!(send(&mut write, frame), Err(FrameFailure::Poisoned));
            let mut remaining = Vec::new();
            read.read_to_end(&mut remaining).unwrap();
            let mut expected: Vec<u8> = fill.iter().cycle().take(count - 512).copied().collect();
            expected.extend_from_slice(&refill);
            expected.push(frame[0]);
            assert_eq!(remaining, expected);
            // No newline/complete command or later command followed the prefix.
            return;
        }
        #[cfg(not(windows))]
        {
            // POSIX rejects the small frame atomically with one byte free.
            let mut one = [0u8; 1];
            read.read_exact(&mut one).unwrap();
            assert_eq!(one[0], b'x');
            let result = send(&mut write, frame);
            assert_eq!(result, Err(FrameFailure::Unchanged));
            let mut remaining = vec![0; count - 1];
            read.read_exact(&mut remaining).unwrap();
            let expected: Vec<u8> = fill
                .iter()
                .cycle()
                .skip(1)
                .take(count - 1)
                .copied()
                .collect();
            assert_eq!(remaining, expected);
            send(&mut write, frame).unwrap();
            let mut received = vec![0; frame.len()];
            read.read_exact(&mut received).unwrap();
            assert_eq!(received, frame);
            assert_eq!(
                send(&mut write, b"bad\nframe\n"),
                Err(FrameFailure::Unchanged)
            );
            write.as_mut().unwrap().flush().unwrap();
        }
    }
}
