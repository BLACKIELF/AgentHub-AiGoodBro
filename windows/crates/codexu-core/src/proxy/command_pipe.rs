//! One bounded frame on the sole owned writer. Never leave a partial JSON line
//! available to the next command, and never wait for the helper to drain stdin.
use std::io::PipeWriter;

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

#[cfg(windows)]
pub(super) fn send(stdin: &mut PipeWriter, bytes: &[u8]) -> Result<(), FrameFailure> {
    if !valid_frame(bytes) {
        return Err(FrameFailure::Unchanged);
    }
    send_chunk(stdin, bytes)
}

#[cfg(windows)]
pub(super) fn send_chunk(stdin: &mut PipeWriter, bytes: &[u8]) -> Result<(), FrameFailure> {
    use std::os::windows::io::AsRawHandle;
    send_handle(
        windows::Win32::Foundation::HANDLE(stdin.as_raw_handle()),
        bytes,
    )
}

#[cfg(windows)]
fn quota(handle: windows::Win32::Foundation::HANDLE) -> Result<u32, FrameFailure> {
    use windows::{
        Wdk::Storage::FileSystem::{
            FilePipeLocalInformation, NtQueryInformationFile, FILE_PIPE_LOCAL_INFORMATION,
        },
        Win32::System::IO::IO_STATUS_BLOCK,
    };
    let mut info = FILE_PIPE_LOCAL_INFORMATION::default();
    let mut status = IO_STATUS_BLOCK::default();
    // PipeWriter/CreatePipe are synchronous local pipe handles. This queries
    // kernel pipe state only; it never sends a request to the helper process.
    let result = unsafe {
        NtQueryInformationFile(
            handle,
            &mut status,
            &mut info as *mut _ as _,
            std::mem::size_of_val(&info) as u32,
            FilePipeLocalInformation,
        )
    };
    if result.0 != 0 || status.Information != std::mem::size_of_val(&info) {
        return Err(FrameFailure::Poisoned);
    }
    Ok(info.WriteQuotaAvailable)
}

#[cfg(windows)]
fn send_handle(
    handle: windows::Win32::Foundation::HANDLE,
    bytes: &[u8],
) -> Result<(), FrameFailure> {
    use windows::Win32::{
        Storage::FileSystem::WriteFile,
        System::Pipes::{SetNamedPipeHandleState, PIPE_NOWAIT, PIPE_WAIT},
    };
    if bytes.is_empty() || bytes.len() > 512 || quota(handle)? < bytes.len() as u32 {
        return Err(FrameFailure::Unchanged);
    }
    // SetNamedPipeHandleState explicitly supports CreatePipe handles. The
    // caller owns the only writer and serializes it with ServiceInner. Readers
    // can only increase free quota between this check and the one WriteFile.
    unsafe { SetNamedPipeHandleState(handle, Some(&PIPE_NOWAIT), None, None) }
        .map_err(|_| FrameFailure::Unchanged)?;
    let mut written = 0;
    let result = unsafe { WriteFile(handle, Some(bytes), Some(&mut written), None) };
    let restored = unsafe { SetNamedPipeHandleState(handle, Some(&PIPE_WAIT), None, None) };
    if restored.is_err() || written != 0 && written != bytes.len() as u32 {
        return Err(FrameFailure::Poisoned);
    }
    if result.is_err() {
        return Err(FrameFailure::Poisoned);
    }
    if written == bytes.len() as u32 {
        Ok(())
    } else {
        Err(FrameFailure::Unchanged)
    }
}

#[cfg(unix)]
pub(super) fn send(stdin: &mut PipeWriter, bytes: &[u8]) -> Result<(), FrameFailure> {
    if !valid_frame(bytes) {
        return Err(FrameFailure::Unchanged);
    }
    send_chunk(stdin, bytes)
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
    use std::io::{Read, Write};
    use std::time::{Duration, Instant};

    #[test]
    #[ignore = "child-only pipe fixture; invoked only with the exact test name"]
    fn blocked_pipe_child() {
        let Ok(role) = std::env::var("AIGOODBRO_PIPE_FIXTURE_ROLE") else {
            return;
        };
        if role == "hold" {
            std::thread::sleep(Duration::from_secs(5));
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
            let (input, mut writer) = std::io::pipe().unwrap();
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
            assert!(at.elapsed() < Duration::from_secs(2));
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
        let (mut read, mut write) = std::io::pipe().unwrap();
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
        // Even with some capacity, the next frame must not be split.
        let mut one = [0u8; 1];
        read.read_exact(&mut one).unwrap();
        assert_eq!(one[0], b'x');
        assert_eq!(send(&mut write, frame), Err(FrameFailure::Unchanged));
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
        write.flush().unwrap();
    }
}
