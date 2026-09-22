//! The owned process joins a job while suspended, before it can spawn children.
use std::{fs::File, path::Path};

pub fn lock_executable(path: &Path) -> std::io::Result<File> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(windows)] {
        use std::os::windows::fs::OpenOptionsExt;
        options.share_mode(1); // FILE_SHARE_READ: reject replacement while probing/running.
    }
    options.open(path)
}

/// Windows C-runtime argv quoting, not shell escaping. Always quote each
/// argument and double trailing slashes so spaces/quotes remain literal.
#[cfg(any(windows, test))]
fn quote_argument(argument: &[u16]) -> Vec<u16> {
    let mut result = vec![b'"' as u16];
    let mut slashes = 0;
    for unit in argument {
        if *unit == b'\\' as u16 { slashes += 1; continue; }
        let count = if *unit == b'"' as u16 { slashes * 2 + 1 } else { slashes };
        result.extend(std::iter::repeat_n(b'\\' as u16, count));
        result.push(*unit);
        slashes = 0;
    }
    result.extend(std::iter::repeat_n(b'\\' as u16, slashes * 2));
    result.push(b'"' as u16);
    result
}

#[cfg(windows)]
mod native {
    use super::*;
    use std::{ffi::{c_void, OsStr, OsString}, os::windows::ffi::OsStrExt, time::{Duration, Instant}};
    type Handle = *mut c_void;
    #[repr(C)] #[derive(Default)]
    struct BasicLimits { process_time: i64, job_time: i64, flags: u32, min_working_set: usize, max_working_set: usize, active_processes: u32, affinity: usize, priority: u32, scheduling: u32 }
    #[repr(C)] #[derive(Default)]
    struct IoCounters { read_operations: u64, write_operations: u64, other_operations: u64, read_bytes: u64, write_bytes: u64, other_bytes: u64 }
    #[repr(C)] #[derive(Default)]
    struct ExtendedLimits { basic: BasicLimits, io: IoCounters, process_memory: usize, job_memory: usize, peak_process_memory: usize, peak_job_memory: usize }
    #[repr(C)] #[derive(Default)]
    struct Accounting { user_time: i64, kernel_time: i64, period_user: i64, period_kernel: i64, page_faults: u32, total: u32, active: u32, terminated: u32 }
    #[repr(C)]
    struct StartupInfo { size: u32, reserved: *mut u16, desktop: *mut u16, title: *mut u16, x: u32, y: u32, x_size: u32, y_size: u32, x_chars: u32, y_chars: u32, fill: u32, flags: u32, show: u16, reserved_size: u16, reserved_bytes: *mut u8, stdin: Handle, stdout: Handle, stderr: Handle }
    #[repr(C)]
    struct ProcessInfo { process: Handle, thread: Handle, process_id: u32, thread_id: u32 }
    #[link(name = "kernel32")]
    extern "system" {
        fn CreateJobObjectW(attributes: *const c_void, name: *const u16) -> Handle;
        fn SetInformationJobObject(job: Handle, class: i32, information: *const c_void, length: u32) -> i32;
        fn QueryInformationJobObject(job: Handle, class: i32, information: *mut c_void, length: u32, returned: *mut u32) -> i32;
        fn AssignProcessToJobObject(job: Handle, process: Handle) -> i32;
        fn TerminateJobObject(job: Handle, exit_code: u32) -> i32;
        fn WaitForSingleObject(handle: Handle, milliseconds: u32) -> u32;
        fn CloseHandle(handle: Handle) -> i32;
        fn CreateProcessW(application: *const u16, command_line: *mut u16, process_attributes: *const c_void, thread_attributes: *const c_void, inherit_handles: i32, creation_flags: u32, environment: *const c_void, directory: *const u16, startup: *mut StartupInfo, information: *mut ProcessInfo) -> i32;
        fn ResumeThread(thread: Handle) -> u32;
        fn TerminateProcess(process: Handle, code: u32) -> i32;
    }
    // Owned handles, never caller-supplied PIDs. Integers permit Send for the
    // job/process handles, whose Win32 APIs support calls from other threads.
    struct OwnedHandle(usize);
    impl OwnedHandle { fn raw(&self) -> Handle { self.0 as Handle } }
    impl Drop for OwnedHandle { fn drop(&mut self) { unsafe { CloseHandle(self.raw()); } } }
    struct Job(OwnedHandle);
    impl Job {
        fn create() -> std::io::Result<Self> {
            let handle = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
            if handle.is_null() { return Err(std::io::Error::last_os_error()); }
            let job = Self(OwnedHandle(handle as usize));
            let mut limits = ExtendedLimits::default();
            limits.basic.flags = 0x0000_2000; // KILL_ON_JOB_CLOSE: crash/forced-exit cleanup.
            let success = unsafe { SetInformationJobObject(handle, 9, &limits as *const _ as *const c_void, std::mem::size_of::<ExtendedLimits>() as u32) };
            if success == 0 { return Err(std::io::Error::last_os_error()); }
            Ok(job)
        }
        fn active_processes(&self) -> std::io::Result<u32> {
            let mut accounting = Accounting::default();
            let success = unsafe { QueryInformationJobObject(self.0.raw(), 1, &mut accounting as *mut _ as *mut c_void, std::mem::size_of::<Accounting>() as u32, std::ptr::null_mut()) };
            if success == 0 { return Err(std::io::Error::last_os_error()); }
            Ok(accounting.active)
        }
    }
    fn wide(value: &OsStr) -> std::io::Result<Vec<u16>> {
        let mut result: Vec<u16> = value.encode_wide().collect();
        if result.contains(&0) { return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "NUL in process argument")); }
        result.push(0);
        Ok(result)
    }
    fn environment(home: &Path) -> std::io::Result<Vec<u16>> {
        let mut entries: Vec<(OsString, OsString)> = std::env::vars_os().filter(|(key, _)| {
            !key.to_string_lossy().eq_ignore_ascii_case("CODEX_HOME")
                && !codexu_core::workflow::EXTERNAL_API_ENVIRONMENT.iter().any(|blocked| key.to_string_lossy().eq_ignore_ascii_case(blocked))
        }).collect();
        entries.push((OsString::from("CODEX_HOME"), home.as_os_str().to_owned()));
        entries.sort_by_key(|(key, _)| key.to_string_lossy().to_uppercase());
        let mut result = Vec::new();
        for (key, value) in entries {
            let mut item = key; item.push("="); item.push(value);
            result.extend(wide(&item)?);
        }
        result.push(0);
        if result.len() > 32767 { return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "Environment exceeds Windows limit")); }
        Ok(result)
    }
    pub struct OwnedConsole { process: OwnedHandle, job: Job, _executable: File }
    impl OwnedConsole {
        pub fn start(executable: &Path, home: &Path, workspace: &Path, args: &[String], guard: File) -> std::io::Result<Self> {
            let job = Job::create()?;
            let application = wide(executable.as_os_str())?;
            let directory = wide(workspace.as_os_str())?;
            let environment = environment(home)?;
            let mut command_line = quote_argument(&application[..application.len() - 1]);
            for argument in args {
                let argument = wide(OsStr::new(argument))?;
                command_line.push(b' ' as u16);
                command_line.extend(quote_argument(&argument[..argument.len() - 1]));
            }
            command_line.push(0);
            if command_line.len() > 32767 { return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "Command exceeds Windows limit")); }
            let mut title = wide(OsStr::new("AiGoodBro - Codex"))?;
            let mut startup: StartupInfo = unsafe { std::mem::zeroed() };
            startup.size = std::mem::size_of::<StartupInfo>() as u32;
            startup.title = title.as_mut_ptr();
            let mut information: ProcessInfo = unsafe { std::mem::zeroed() };
            // No inherited handles. New console supplies its own stdin/out.
            // CREATE_SUSPENDED | CREATE_NEW_CONSOLE | CREATE_UNICODE_ENVIRONMENT.
            let success = unsafe { CreateProcessW(application.as_ptr(), command_line.as_mut_ptr(), std::ptr::null(), std::ptr::null(), 0, 0x0000_0414, environment.as_ptr() as *const c_void, directory.as_ptr(), &mut startup, &mut information) };
            if success == 0 { return Err(std::io::Error::last_os_error()); }
            let process = OwnedHandle(information.process as usize);
            let thread = OwnedHandle(information.thread as usize);
            if unsafe { AssignProcessToJobObject(job.0.raw(), process.raw()) } == 0 {
                let error = std::io::Error::last_os_error();
                unsafe { TerminateProcess(process.raw(), 1); WaitForSingleObject(process.raw(), 2000); }
                return Err(error);
            }
            if unsafe { ResumeThread(thread.raw()) } != 1 {
                let error = std::io::Error::other("Could not resume owned terminal");
                unsafe { TerminateJobObject(job.0.raw(), 1); WaitForSingleObject(process.raw(), 2000); }
                return Err(error);
            }
            Ok(Self { process, job, _executable: guard })
        }
        pub fn has_exited(&mut self) -> std::io::Result<bool> {
            match unsafe { WaitForSingleObject(self.process.raw(), 0) } {
                0 => Ok(true), 258 => Ok(false), _ => Err(std::io::Error::last_os_error()),
            }
        }
        pub fn stop(&mut self) -> std::io::Result<()> {
            if unsafe { TerminateJobObject(self.job.0.raw(), 1) } == 0 { return Err(std::io::Error::last_os_error()); }
            let deadline = Instant::now() + Duration::from_secs(2);
            while self.job.active_processes()? != 0 {
                if Instant::now() >= deadline { return Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "Owned terminal has not exited")); }
                std::thread::sleep(Duration::from_millis(10));
            }
            Ok(())
        }
    }
}

#[cfg(windows)] pub use native::OwnedConsole;
#[cfg(not(windows))] pub struct OwnedConsole;
#[cfg(not(windows))]
impl OwnedConsole {
    pub fn start(_: &Path, _: &Path, _: &Path, _: &[String], _: File) -> std::io::Result<Self> { Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "Windows required")) }
    pub fn has_exited(&mut self) -> std::io::Result<bool> { Ok(true) }
    pub fn stop(&mut self) -> std::io::Result<()> { Ok(()) }
}

#[cfg(test)]
mod tests {
    use super::quote_argument;
    #[test]
    fn windows_arguments_keep_spaces_quotes_and_trailing_slashes_literal() {
        let quote = |value: &str| String::from_utf16(&quote_argument(&value.encode_utf16().collect::<Vec<_>>())).unwrap();
        assert_eq!(quote(""), "\"\"");
        assert_eq!(quote("two words"), "\"two words\"");
        assert_eq!(quote("a\"b"), "\"a\\\"b\"");
        assert_eq!(quote("tail\\"), "\"tail\\\\\"");
        assert_eq!(quote("x; & echo"), "\"x; & echo\"");
        assert_eq!(quote("目录"), "\"目录\"");
    }
}
