//! Owner-private creation. An elevated process's default TokenOwner may be the
//! Administrators group; only its actual TokenUser is our storage identity.
//! Existing foreign-owned objects are rejected, never adopted or repaired.
use super::{fail, AccountResult};
use std::{
    ffi::c_void,
    fs::File,
    os::windows::{
        ffi::OsStrExt,
        io::{AsRawHandle, FromRawHandle},
    },
    path::Path,
};

#[repr(C)]
struct UnicodeString {
    length: u16,
    maximum_length: u16,
    buffer: *const u16,
}
#[repr(C)]
struct ObjectAttributes {
    length: u32,
    root: Handle,
    name: *const UnicodeString,
    attributes: u32,
    descriptor: *mut c_void,
    qos: *mut c_void,
}
#[repr(C)]
struct IoStatus {
    status: usize,
    information: usize,
}
#[repr(C)]
struct RenameInfo {
    replace: u8,
    root: Handle,
    length: u32,
    name: [u16; 1],
}
#[link(name = "ntdll")]
unsafe extern "system" {
    fn NtCreateFile(
        handle: *mut Handle,
        access: u32,
        attributes: *const ObjectAttributes,
        status: *mut IoStatus,
        allocation: *const i64,
        file_attributes: u32,
        share: u32,
        disposition: u32,
        options: u32,
        ea: *const c_void,
        ea_length: u32,
    ) -> i32;
    fn NtSetInformationFile(
        handle: Handle,
        status: *mut IoStatus,
        information: *const c_void,
        length: u32,
        class: u32,
    ) -> i32;
}

type Handle = *mut c_void;
#[repr(C)]
struct SecurityAttributes {
    size: u32,
    descriptor: *mut c_void,
    inherit: i32,
}
#[link(name = "advapi32")]
unsafe extern "system" {
    fn OpenProcessToken(process: Handle, access: u32, token: *mut Handle) -> i32;
    fn GetTokenInformation(
        token: Handle,
        class: u32,
        data: *mut c_void,
        size: u32,
        needed: *mut u32,
    ) -> i32;
    fn ConvertSidToStringSidW(sid: *const c_void, text: *mut *mut u16) -> i32;
    fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
        text: *const u16,
        revision: u32,
        descriptor: *mut *mut c_void,
        size: *mut u32,
    ) -> i32;
    fn GetSecurityInfo(
        handle: Handle,
        kind: u32,
        info: u32,
        owner: *mut *mut c_void,
        group: *mut *mut c_void,
        dacl: *mut *mut c_void,
        sacl: *mut *mut c_void,
        descriptor: *mut *mut c_void,
    ) -> u32;
    fn EqualSid(a: *const c_void, b: *const c_void) -> i32;
    fn GetSecurityDescriptorDacl(
        descriptor: *const c_void,
        present: *mut i32,
        dacl: *mut *mut c_void,
        defaulted: *mut i32,
    ) -> i32;
    fn SetSecurityInfo(
        handle: Handle,
        kind: u32,
        info: u32,
        owner: *const c_void,
        group: *const c_void,
        dacl: *const c_void,
        sacl: *const c_void,
    ) -> u32;
}
#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetCurrentProcess() -> Handle;
    fn CloseHandle(handle: Handle) -> i32;
    fn LocalFree(memory: *mut c_void) -> *mut c_void;
    fn CreateDirectoryW(path: *const u16, attributes: *const SecurityAttributes) -> i32;
    fn CreateFileW(
        path: *const u16,
        access: u32,
        share: u32,
        attributes: *const SecurityAttributes,
        creation: u32,
        flags: u32,
        template: Handle,
    ) -> Handle;
}
struct Local(*mut c_void);
impl Drop for Local {
    fn drop(&mut self) {
        unsafe {
            LocalFree(self.0);
        }
    }
}
struct Token(Handle);
impl Drop for Token {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}
fn error() -> crate::accounts::AccountError {
    fail("private_storage_unavailable")
}
fn wide(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain(Some(0)).collect()
}

struct PrivateDescriptor {
    _user: Vec<u64>,
    sid: *const c_void,
    descriptor: Local,
}
impl PrivateDescriptor {
    fn current() -> AccountResult<Self> {
        let mut token = std::ptr::null_mut();
        if unsafe { OpenProcessToken(GetCurrentProcess(), 8, &mut token) } == 0 {
            return Err(error());
        }
        let token = Token(token);
        let mut needed = 0u32;
        unsafe {
            GetTokenInformation(token.0, 1, std::ptr::null_mut(), 0, &mut needed);
        }
        if needed < std::mem::size_of::<usize>() as u32 || needed > 65536 {
            return Err(error());
        }
        // TOKEN_USER starts with SID_AND_ATTRIBUTES; u64 storage is aligned on
        // both supported Windows targets and owns the SID for this lifetime.
        let mut user = vec![0u64; (needed as usize).div_ceil(8)];
        if unsafe { GetTokenInformation(token.0, 1, user.as_mut_ptr().cast(), needed, &mut needed) }
            == 0
        {
            return Err(error());
        }
        let sid = unsafe { *(user.as_ptr().cast::<*const c_void>()) };
        if sid.is_null() {
            return Err(error());
        }
        let mut text = std::ptr::null_mut();
        if unsafe { ConvertSidToStringSidW(sid, &mut text) } == 0 {
            return Err(error());
        }
        let allocation = Local(text.cast());
        let mut length = 0;
        while length < 184 && unsafe { *text.add(length) } != 0 {
            length += 1;
        }
        if length == 184 {
            return Err(error());
        }
        let user_text = String::from_utf16(unsafe { std::slice::from_raw_parts(text, length) })
            .map_err(|_| error())?;
        drop(allocation);
        let sddl = format!("O:{user_text}D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;{user_text})\0")
            .encode_utf16()
            .collect::<Vec<_>>();
        let mut descriptor = std::ptr::null_mut();
        if unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                1,
                &mut descriptor,
                std::ptr::null_mut(),
            )
        } == 0
        {
            return Err(error());
        }
        Ok(Self {
            _user: user,
            sid,
            descriptor: Local(descriptor),
        })
    }
    fn attributes(&self) -> SecurityAttributes {
        SecurityAttributes {
            size: std::mem::size_of::<SecurityAttributes>() as u32,
            descriptor: self.descriptor.0,
            inherit: 0,
        }
    }
    fn require_owner(&self, file: &File) -> AccountResult<()> {
        let mut owner = std::ptr::null_mut();
        let mut descriptor = std::ptr::null_mut();
        if unsafe {
            GetSecurityInfo(
                file.as_raw_handle().cast(),
                1,
                1,
                &mut owner,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut descriptor,
            )
        } != 0
        {
            return Err(error());
        }
        let _descriptor = Local(descriptor);
        if owner.is_null() || unsafe { EqualSid(owner, self.sid) } == 0 {
            return Err(fail("private_storage_owner_rejected"));
        }
        Ok(())
    }
}
fn opened(
    path: &Path,
    access: u32,
    share: u32,
    attributes: *const SecurityAttributes,
    creation: u32,
) -> std::io::Result<File> {
    let path = wide(path);
    let handle = unsafe {
        CreateFileW(
            path.as_ptr(),
            access,
            share,
            attributes,
            creation,
            0x0220_0080,
            std::ptr::null_mut(),
        )
    };
    if handle as isize == -1 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(unsafe { File::from_raw_handle(handle.cast()) })
}
pub(in crate::accounts) fn check_owner(path: &Path) -> AccountResult<()> {
    super::storage::ensure_no_links(path)?;
    let file = opened(path, 0x0002_0000, 1 | 2 | 4, std::ptr::null(), 3).map_err(|_| error())?;
    PrivateDescriptor::current()?.require_owner(&file)
}
pub(in crate::accounts) fn restrict_file(file: &File) -> AccountResult<()> {
    use std::os::windows::fs::MetadataExt;
    if file.metadata().map_err(|_| error())?.file_attributes() & 0x400 != 0 {
        return Err(fail("account_path_linked"));
    }
    let descriptor = PrivateDescriptor::current()?;
    descriptor.require_owner(file)?;
    // No OWNER_SECURITY_INFORMATION: an existing foreign owner cannot be
    // changed by this function, even when the caller is elevated.
    let mut present = 0;
    let mut defaulted = 0;
    let mut dacl = std::ptr::null_mut();
    if unsafe {
        GetSecurityDescriptorDacl(
            descriptor.descriptor.0,
            &mut present,
            &mut dacl,
            &mut defaulted,
        )
    } == 0
        || present == 0
        || dacl.is_null()
    {
        return Err(error());
    }
    if unsafe {
        SetSecurityInfo(
            file.as_raw_handle().cast(),
            1,
            0x8000_0004,
            std::ptr::null(),
            std::ptr::null(),
            dacl,
            std::ptr::null(),
        )
    } != 0
    {
        return Err(error());
    }
    descriptor.require_owner(file)
}
pub(in crate::accounts) fn restrict(path: &Path) -> AccountResult<()> {
    super::storage::ensure_no_links(path)?;
    let file = opened(path, 0x0006_0000, 1 | 2 | 4, std::ptr::null(), 3).map_err(|_| error())?;
    restrict_file(&file)
}
pub(in crate::accounts) fn create_directory(path: &Path) -> AccountResult<()> {
    super::storage::ensure_no_links(path)?;
    let descriptor = PrivateDescriptor::current()?;
    let attrs = descriptor.attributes();
    let path = wide(path);
    if unsafe { CreateDirectoryW(path.as_ptr(), &attrs) } == 0 {
        return Err(error());
    }
    Ok(())
}
pub(in crate::accounts) fn open_lock(path: &Path) -> AccountResult<File> {
    super::storage::ensure_no_links(path)?;
    let descriptor = PrivateDescriptor::current()?;
    let attrs = descriptor.attributes();
    let file = match opened(path, 0xc006_0000, 0, &attrs, 1) {
        Ok(file) => file,
        Err(e) if matches!(e.raw_os_error(), Some(80 | 183)) => {
            opened(path, 0xc006_0000, 0, std::ptr::null(), 3)
                .map_err(|_| fail("account_store_busy"))?
        }
        Err(_) => return Err(fail("account_store_busy")),
    };
    restrict_file(&file)?;
    Ok(file)
}

fn leaf(name: &std::ffi::OsStr) -> AccountResult<Vec<u16>> {
    let name = name.encode_wide().collect::<Vec<_>>();
    if name.is_empty()
        || name.len() > 255
        || name == [46]
        || name == [46, 46]
        || name.iter().any(|c| matches!(*c, 0 | 47 | 92 | 58))
    {
        return Err(fail("account_paths_invalid"));
    }
    Ok(name)
}
fn relative_file(
    parent: &File,
    name: &[u16],
    access: u32,
    disposition: u32,
    descriptor: *mut c_void,
) -> Result<File, i32> {
    let string = UnicodeString {
        length: (name.len() * 2) as u16,
        maximum_length: (name.len() * 2) as u16,
        buffer: name.as_ptr(),
    };
    let attributes = ObjectAttributes {
        length: std::mem::size_of::<ObjectAttributes>() as u32,
        root: parent.as_raw_handle().cast(),
        name: &string,
        attributes: 0x1040,
        descriptor,
        qos: std::ptr::null_mut(),
    };
    let mut handle = std::ptr::null_mut();
    let mut status = IoStatus {
        status: 0,
        information: 0,
    };
    let result = unsafe {
        NtCreateFile(
            &mut handle,
            access,
            &attributes,
            &mut status,
            std::ptr::null(),
            0x80,
            1 | 2 | 4,
            disposition,
            0x0020_0060,
            std::ptr::null(),
            0,
        )
    };
    if result != 0 {
        return Err(result);
    }
    Ok(unsafe { File::from_raw_handle(handle.cast()) })
}
fn existing_target_owner(
    parent: &File,
    name: &[u16],
    descriptor: &PrivateDescriptor,
) -> AccountResult<()> {
    match relative_file(parent, name, 0x0012_0080, 1, std::ptr::null_mut()) {
        Ok(file) => {
            use std::os::windows::fs::MetadataExt;
            let metadata = file.metadata().map_err(|_| error())?;
            if !metadata.is_file() || metadata.file_attributes() & 0x400 != 0 {
                return Err(fail("account_path_linked"));
            }
            descriptor.require_owner(&file)
        }
        Err(status) if status as u32 == 0xc000_0034 => Ok(()), // exact name not found; no adoption
        Err(_) => Err(error()),
    }
}
struct TemporaryFile {
    file: File,
    committed: bool,
}
impl Drop for TemporaryFile {
    fn drop(&mut self) {
        if !self.committed {
            // Delete only the exact new file held by this handle. A renamed
            // ancestor cannot redirect cleanup to a different pathname.
            let mut status = IoStatus {
                status: 0,
                information: 0,
            };
            let delete = 1u8;
            unsafe {
                NtSetInformationFile(
                    self.file.as_raw_handle().cast(),
                    &mut status,
                    (&delete as *const u8).cast(),
                    1,
                    13,
                );
            }
        }
    }
}
pub(in crate::accounts) fn atomic_write(path: &Path, bytes: &[u8]) -> AccountResult<()> {
    atomic_write_inner(path, bytes, |_| {})
}
fn atomic_write_inner(
    path: &Path,
    bytes: &[u8],
    after_pin: impl FnOnce(&File),
) -> AccountResult<()> {
    use std::io::Write;
    super::storage::ensure_no_links(path)?;
    let parent_path = path.parent().ok_or_else(|| fail("account_paths_invalid"))?;
    // No FILE_SHARE_DELETE: the immediate parent cannot be renamed/replaced
    // while this transaction is active. Creation AND rename are relative to
    // this held directory, so renaming an ancestor cannot retarget the write.
    let parent =
        opened(parent_path, 0x8012_0022, 1 | 2, std::ptr::null(), 3).map_err(|_| error())?;
    use std::os::windows::fs::MetadataExt;
    let metadata = parent.metadata().map_err(|_| error())?;
    if !metadata.is_dir() || metadata.file_attributes() & 0x400 != 0 {
        return Err(fail("account_path_linked"));
    }
    let descriptor = PrivateDescriptor::current()?;
    descriptor.require_owner(&parent)?;
    let target = leaf(
        path.file_name()
            .ok_or_else(|| fail("account_paths_invalid"))?,
    )?;
    existing_target_owner(&parent, &target, &descriptor)?;
    after_pin(&parent);
    let name = format!(".aigoodbro-{}.tmp", crate::accounts::nonce()?);
    let name = leaf(std::ffi::OsStr::new(&name))?;
    let file = relative_file(&parent, &name, 0xc017_0000, 2, descriptor.descriptor.0)
        .map_err(|_| error())?;
    let mut temporary = TemporaryFile {
        file,
        committed: false,
    };
    descriptor.require_owner(&temporary.file)?;
    temporary
        .file
        .write_all(bytes)
        .and_then(|_| temporary.file.sync_all())
        .map_err(|_| fail("account_save_failed"))?;
    // The read is also anchored. A foreign file that appeared since the first
    // check remains untouched; it cannot be made current-user owned here.
    existing_target_owner(&parent, &target, &descriptor)?;
    let offset = std::mem::offset_of!(RenameInfo, name);
    let size = (offset + target.len() * 2).max(std::mem::size_of::<RenameInfo>());
    let mut data = vec![0u64; size.div_ceil(8)];
    let info = data.as_mut_ptr().cast::<RenameInfo>();
    unsafe {
        (*info).replace = 1;
        (*info).root = parent.as_raw_handle().cast();
        (*info).length = (target.len() * 2) as u32;
        std::ptr::copy_nonoverlapping(
            target.as_ptr(),
            (info.cast::<u8>()).add(offset).cast(),
            target.len(),
        );
    }
    let mut status = IoStatus {
        status: 0,
        information: 0,
    };
    if unsafe {
        NtSetInformationFile(
            temporary.file.as_raw_handle().cast(),
            &mut status,
            info.cast(),
            size as u32,
            10,
        )
    } != 0
    {
        return Err(fail("account_save_failed"));
    }
    temporary.committed = true;
    descriptor.require_owner(&temporary.file)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::accounts::storage;
    #[link(name = "advapi32")]
    unsafe extern "system" {
        fn ConvertSecurityDescriptorToStringSecurityDescriptorW(
            descriptor: *const c_void,
            revision: u32,
            info: u32,
            text: *mut *mut u16,
            length: *mut u32,
        ) -> i32;
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn DeviceIoControl(
            handle: Handle,
            code: u32,
            input: *const c_void,
            input_length: u32,
            output: *mut c_void,
            output_length: u32,
            returned: *mut u32,
            overlapped: *mut c_void,
        ) -> i32;
    }
    fn descriptor(path: &Path) -> String {
        let file = opened(path, 0x0002_0000, 1 | 2 | 4, std::ptr::null(), 3).unwrap();
        let mut sd = std::ptr::null_mut();
        assert_eq!(
            unsafe {
                GetSecurityInfo(
                    file.as_raw_handle().cast(),
                    1,
                    5,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    &mut sd,
                )
            },
            0
        );
        let _sd = Local(sd);
        let mut text = std::ptr::null_mut();
        let mut size = 0;
        assert_ne!(
            unsafe {
                ConvertSecurityDescriptorToStringSecurityDescriptorW(sd, 1, 5, &mut text, &mut size)
            },
            0
        );
        let _text = Local(text.cast());
        let mut length = 0;
        while length < size as usize && unsafe { *text.add(length) } != 0 {
            length += 1;
        }
        String::from_utf16(unsafe { std::slice::from_raw_parts(text, length) }).unwrap()
    }
    fn private(path: &Path) {
        check_owner(path).unwrap();
        let sd = descriptor(path);
        assert!(sd.contains("D:P"), "DACL must be protected");
        assert_eq!(
            sd.matches("(A;").count(),
            2,
            "only actual user and SYSTEM may be granted access"
        );
        assert!(!sd.contains(";;;BA)") && !sd.contains(";;;WD)") && !sd.contains(";;;OW)"));
    }
    #[test]
    fn windows_private_creation_sets_token_user_owner_before_sensitive_write() {
        // The outer fixture can retain Windows' default group owner. We never
        // change it; every product-owned child is created with explicit owner.
        let fixture = tempfile::tempdir().unwrap();
        let root = fixture.path().join("synthetic-owned");
        storage::secure_directory(&root).unwrap();
        private(&root);
        storage::secure_directory(&root).unwrap();
        private(&root);
        let temporary = storage::private_tempdir(&root, "synthetic-login-").unwrap();
        private(temporary.path());
        let file = temporary.path().join("auth.json");
        storage::atomic_write(&file, b"synthetic-not-a-credential").unwrap();
        private(&file);
        storage::atomic_write(&file, b"synthetic-replacement").unwrap();
        private(&file);
        assert_eq!(std::fs::read(&file).unwrap(), b"synthetic-replacement");
        let lock = storage::StoreLock::acquire(&root).unwrap();
        assert!(storage::StoreLock::acquire(&root).is_err());
        drop(lock);
        private(&root.join("accounts.lock"));
        drop(storage::StoreLock::acquire(&root).unwrap());
        assert!(storage::create_private_directory(temporary.path()).is_err());
    }
    #[test]
    fn windows_private_atomic_write_pins_parent_and_anchors_ancestor_changes() {
        let fixture = tempfile::tempdir().unwrap();
        let scope = fixture.path().join("synthetic-scope");
        storage::secure_directory(&scope).unwrap();
        let home = scope.join("home");
        storage::secure_directory(&home).unwrap();
        let auth = home.join("auth.json");
        storage::atomic_write(&auth, b"synthetic-before").unwrap();
        let moved = fixture.path().join("synthetic-moved");
        let mut ancestor_moved = false;
        // The callback executes the attempted replacement during the actual
        // production transaction, after its handle pin and before creation.
        atomic_write_inner(&auth, b"synthetic-after", |_| {
            assert!(
                std::fs::rename(&home, scope.join("replaced-home")).is_err(),
                "held parent must deny rename"
            );
            if std::fs::rename(&scope, &moved).is_ok() {
                ancestor_moved = true;
                storage::create_private_directory(&scope).unwrap();
                storage::create_private_directory(&home).unwrap();
                storage::atomic_write(&auth, b"synthetic-decoy-preserved").unwrap();
            }
        })
        .unwrap();
        if ancestor_moved {
            assert_eq!(
                std::fs::read(moved.join("home/auth.json")).unwrap(),
                b"synthetic-after"
            );
            assert_eq!(std::fs::read(&auth).unwrap(), b"synthetic-decoy-preserved");
        } else {
            assert_eq!(std::fs::read(&auth).unwrap(), b"synthetic-after");
        }
    }
    fn junction(link: &Path, target: &Path) {
        storage::create_private_directory(link).unwrap();
        let file = opened(link, 0x4000_0000, 1 | 2 | 4, std::ptr::null(), 3).unwrap();
        let target = target.canonicalize().unwrap();
        let print = target
            .to_string_lossy()
            .trim_start_matches(r"\\?\")
            .to_owned();
        let substitute = format!(r"\??\{print}").encode_utf16().collect::<Vec<_>>();
        let print = print.encode_utf16().collect::<Vec<_>>();
        let mut paths = substitute.clone();
        paths.push(0);
        let print_offset = paths.len() * 2;
        paths.extend(&print);
        paths.push(0);
        let length = 8 + paths.len() * 2;
        let mut data = Vec::new();
        data.extend(0xa0000003u32.to_le_bytes());
        data.extend((length as u16).to_le_bytes());
        data.extend(0u16.to_le_bytes());
        for value in [
            0u16,
            (substitute.len() * 2) as u16,
            print_offset as u16,
            (print.len() * 2) as u16,
        ] {
            data.extend(value.to_le_bytes());
        }
        for value in paths {
            data.extend(value.to_le_bytes());
        }
        let mut returned = 0;
        assert_ne!(
            unsafe {
                DeviceIoControl(
                    file.as_raw_handle().cast(),
                    0x0009_00a4,
                    data.as_ptr().cast(),
                    data.len() as u32,
                    std::ptr::null_mut(),
                    0,
                    &mut returned,
                    std::ptr::null_mut(),
                )
            },
            0,
            "actual synthetic junction fixture must be created"
        );
    }
    fn foreign_attributes() -> (Local, SecurityAttributes) {
        // An administrator-group owner is deliberately foreign to TokenUser.
        // This opt-in fixture requires an elevated administrator test runner.
        let sddl = "O:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)\0"
            .encode_utf16()
            .collect::<Vec<_>>();
        let mut sd = std::ptr::null_mut();
        assert_ne!(
            unsafe {
                ConvertStringSecurityDescriptorToSecurityDescriptorW(
                    sddl.as_ptr(),
                    1,
                    &mut sd,
                    std::ptr::null_mut(),
                )
            },
            0
        );
        (
            Local(sd),
            SecurityAttributes {
                size: std::mem::size_of::<SecurityAttributes>() as u32,
                descriptor: sd,
                inherit: 0,
            },
        )
    }
    #[test]
    #[ignore = "requires explicit elevated Windows owner fixture; no user files are used"]
    fn windows_private_existing_administrators_owner_is_rejected_unchanged() {
        let fixture = tempfile::tempdir().unwrap();
        let root = fixture.path().join("synthetic-owned");
        storage::secure_directory(&root).unwrap();
        let (_sd, attributes) = foreign_attributes();
        let foreign = root.join("synthetic-foreign");
        assert_ne!(
            unsafe { CreateDirectoryW(wide(&foreign).as_ptr(), &attributes) },
            0,
            "administrator fixture capability is required"
        );
        let before = descriptor(&foreign);
        assert_eq!(
            storage::secure_directory(&foreign).unwrap_err().code,
            "private_storage_owner_rejected"
        );
        assert_eq!(descriptor(&foreign), before);
        let file_path = root.join("synthetic-foreign-auth.json");
        let mut file = opened(&file_path, 0xc006_0000, 1 | 2 | 4, &attributes, 1).unwrap();
        use std::io::Write;
        file.write_all(b"synthetic-preserved").unwrap();
        drop(file);
        let before = descriptor(&file_path);
        assert_eq!(
            restrict(&file_path).unwrap_err().code,
            "private_storage_owner_rejected"
        );
        assert_eq!(
            storage::atomic_write(&file_path, b"synthetic-must-not-replace")
                .unwrap_err()
                .code,
            "private_storage_owner_rejected"
        );
        assert_eq!(descriptor(&file_path), before);
        assert_eq!(std::fs::read(file_path).unwrap(), b"synthetic-preserved");
        let lock_path = root.join("accounts.lock");
        drop(opened(&lock_path, 0xc006_0000, 1 | 2 | 4, &attributes, 1).unwrap());
        let before = descriptor(&lock_path);
        assert!(storage::StoreLock::acquire(&root).is_err());
        assert_eq!(descriptor(&lock_path), before);
        let late = root.join("synthetic-late-foreign.json");
        assert_eq!(
            atomic_write_inner(&late, b"synthetic-must-not-write", |_| {
                let mut file = opened(&late, 0xc006_0000, 1 | 2 | 4, &attributes, 1).unwrap();
                file.write_all(b"synthetic-late-preserved").unwrap();
            })
            .unwrap_err()
            .code,
            "private_storage_owner_rejected"
        );
        assert_eq!(std::fs::read(&late).unwrap(), b"synthetic-late-preserved");
        let other = root.join("synthetic-other");
        storage::secure_directory(&other).unwrap();
        let other_auth = other.join("auth.json");
        storage::atomic_write(&other_auth, b"synthetic-other-preserved").unwrap();
        let redirect = root.join("synthetic-junction");
        junction(&redirect, &other);
        assert_eq!(
            storage::atomic_write(&redirect.join("auth.json"), b"synthetic-must-not-follow")
                .unwrap_err()
                .code,
            "account_path_linked"
        );
        let home = root.join("synthetic-held-home");
        storage::secure_directory(&home).unwrap();
        atomic_write_inner(&home.join("auth.json"), b"synthetic-owned", |_| {
            assert!(std::fs::rename(&home, root.join("synthetic-replaced-home")).is_err());
            assert!(std::fs::rename(&redirect, &home).is_err());
        })
        .unwrap();
        assert_eq!(
            std::fs::read(&other_auth).unwrap(),
            b"synthetic-other-preserved"
        );
    }
}
