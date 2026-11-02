//! Test-only isolation for restricted-token native launchers.
//!
//! A private desktop is created on a disposable thread because CreateDesktopW
//! assigns the calling thread to the new desktop. The returned handle and
//! explicit station\desktop name are owned by NativeDesktop until the caller
//! confirms its child Job is empty.

use std::{
    ffi::c_void,
    fmt, ptr,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Mutex, OnceLock,
    },
    thread,
};

type Handle = *mut c_void;

const ERROR_FILE_NOT_FOUND: u32 = 2;
const ERROR_INSUFFICIENT_BUFFER: u32 = 122;
const TOKEN_QUERY: u32 = 0x0008;
const TOKEN_USER_CLASS: u32 = 1;
const TOKEN_SESSION_ID_CLASS: u32 = 12;
const TOKEN_ELEVATION_CLASS: u32 = 20;
const TOKEN_INTEGRITY_LEVEL_CLASS: u32 = 25;
const SECURITY_IMPERSONATION: u32 = 2;
const TOKEN_IMPERSONATION: u32 = 2;
const UOI_NAME: u32 = 2;
const SE_WINDOW_OBJECT: i32 = 7;
const OWNER_SECURITY_INFORMATION: u32 = 0x0000_0001;
const GROUP_SECURITY_INFORMATION: u32 = 0x0000_0002;
const DACL_SECURITY_INFORMATION: u32 = 0x0000_0004;
const LABEL_SECURITY_INFORMATION: u32 = 0x0000_0010;
const SE_DACL_PROTECTED: u16 = 0x1000;
const ACCESS_ALLOWED_ACE_TYPE: u8 = 0;
const SYSTEM_MANDATORY_LABEL_ACE_TYPE: u8 = 0x11;
const SYSTEM_MANDATORY_LABEL_NO_WRITE_UP: u32 = 0x1;
const DESKTOP_READOBJECTS: u32 = 0x0001;
const DESKTOP_CREATEWINDOW: u32 = 0x0002;
const DESKTOP_CREATEMENU: u32 = 0x0004;
const DESKTOP_HOOKCONTROL: u32 = 0x0008;
const DESKTOP_JOURNALRECORD: u32 = 0x0010;
const DESKTOP_JOURNALPLAYBACK: u32 = 0x0020;
const DESKTOP_ENUMERATE: u32 = 0x0040;
const DESKTOP_WRITEOBJECTS: u32 = 0x0080;
const DESKTOP_SWITCHDESKTOP: u32 = 0x0100;
const READ_CONTROL: u32 = 0x0002_0000;
const WRITE_OWNER: u32 = 0x0008_0000;
const STANDARD_RIGHTS_REQUIRED: u32 = 0x000f_0000;
const WINSTA_ACCESSCLIPBOARD: u32 = 0x0004;
const WINSTA_CREATEDESKTOP: u32 = 0x0008;
const WINSTA_ACCESSGLOBALATOMS: u32 = 0x0020;
const WINSTA_ENUMDESKTOPS: u32 = 0x0001;
const WINSTA_READATTRIBUTES: u32 = 0x0002;

#[repr(C)]
struct SecurityAttributes {
    length: u32,
    security_descriptor: Handle,
    inherit_handle: i32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct SidAndAttributes {
    sid: Handle,
    attributes: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct SidHeader {
    revision: u8,
    sub_authority_count: u8,
    identifier_authority: [u8; 6],
}

#[repr(C)]
#[derive(Clone, Copy)]
struct AceWithMask {
    ace_type: u8,
    ace_flags: u8,
    ace_size: u16,
    mask: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct AceHeader {
    ace_type: u8,
    ace_flags: u8,
    ace_size: u16,
}

#[repr(C)]
#[derive(Default)]
struct AclSizeInformation {
    ace_count: u32,
    acl_bytes_in_use: u32,
    acl_bytes_free: u32,
}

#[repr(C)]
struct GenericMapping {
    generic_read: u32,
    generic_write: u32,
    generic_execute: u32,
    generic_all: u32,
}

#[repr(C)]
struct WellKnownSid {
    revision: u8,
    sub_authority_count: u8,
    identifier_authority: [u8; 6],
    sub_authority: [u32; 1],
}

#[link(name = "advapi32")]
unsafe extern "system" {
    fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
        text: *const u16,
        revision: u32,
        descriptor: *mut Handle,
        size: *mut u32,
    ) -> i32;
    fn ConvertSidToStringSidW(sid: Handle, text: *mut *mut u16) -> i32;
    fn GetTokenInformation(
        token: Handle,
        class: u32,
        buffer: Handle,
        size: u32,
        needed: *mut u32,
    ) -> i32;
    fn DuplicateTokenEx(
        existing: Handle,
        desired_access: u32,
        attributes: Handle,
        impersonation_level: u32,
        token_type: u32,
        duplicate: *mut Handle,
    ) -> i32;
    fn GetSecurityInfo(
        handle: Handle,
        object_type: i32,
        security_info: u32,
        owner: *mut Handle,
        group: *mut Handle,
        dacl: *mut Handle,
        sacl: *mut Handle,
        descriptor: *mut Handle,
    ) -> u32;
    fn GetSecurityDescriptorOwner(
        descriptor: Handle,
        owner: *mut Handle,
        defaulted: *mut i32,
    ) -> i32;
    fn GetSecurityDescriptorDacl(
        descriptor: Handle,
        present: *mut i32,
        dacl: *mut Handle,
        defaulted: *mut i32,
    ) -> i32;
    fn GetSecurityDescriptorSacl(
        descriptor: Handle,
        present: *mut i32,
        sacl: *mut Handle,
        defaulted: *mut i32,
    ) -> i32;
    fn GetSecurityDescriptorControl(
        descriptor: Handle,
        control: *mut u16,
        revision: *mut u32,
    ) -> i32;
    fn GetAclInformation(
        acl: Handle,
        information: Handle,
        information_length: u32,
        information_class: i32,
    ) -> i32;
    fn GetAce(acl: Handle, index: u32, ace: *mut Handle) -> i32;
    fn IsValidSid(sid: Handle) -> i32;
    fn GetLengthSid(sid: Handle) -> u32;
    fn EqualSid(left: Handle, right: Handle) -> i32;
    fn AccessCheck(
        descriptor: Handle,
        client_token: Handle,
        desired_access: u32,
        mapping: *const GenericMapping,
        privilege_set: Handle,
        privilege_set_length: *mut u32,
        granted_access: *mut u32,
        access_status: *mut i32,
    ) -> i32;
    fn MapGenericMask(access: *mut u32, mapping: *const GenericMapping);
}

#[link(name = "user32")]
unsafe extern "system" {
    fn GetProcessWindowStation() -> Handle;
    fn GetUserObjectInformationW(
        object: Handle,
        index: u32,
        information: Handle,
        length: u32,
        needed: *mut u32,
    ) -> i32;
    fn OpenDesktopW(name: *const u16, flags: u32, inherit: i32, desired_access: u32) -> Handle;
    fn CreateDesktopW(
        name: *const u16,
        device: *const u16,
        devmode: Handle,
        flags: u32,
        desired_access: u32,
        attributes: *mut SecurityAttributes,
    ) -> Handle;
    fn CloseDesktop(desktop: Handle) -> i32;
}

#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetLastError() -> u32;
    fn LocalFree(memory: Handle) -> Handle;
    fn CloseHandle(handle: Handle) -> i32;
}

#[link(name = "bcrypt")]
unsafe extern "system" {
    fn BCryptGenRandom(algorithm: Handle, buffer: *mut u8, length: u32, flags: u32) -> i32;
}

#[derive(Debug, Clone, Copy)]
pub struct NativeDesktopError {
    stage: &'static str,
    code: Option<u32>,
}

impl NativeDesktopError {
    fn new(stage: &'static str, code: Option<u32>) -> Self {
        Self { stage, code }
    }
}

impl fmt::Display for NativeDesktopError {
    fn fmt(&self, output: &mut fmt::Formatter<'_>) -> fmt::Result {
        if let Some(code) = self.code {
            write!(
                output,
                "native desktop {} failed (code=0x{code:08x})",
                self.stage
            )
        } else {
            write!(output, "native desktop {} failed", self.stage)
        }
    }
}

impl std::error::Error for NativeDesktopError {}

/// Owns an explicitly named desktop until the caller confirms its child Job is empty.
pub struct NativeDesktop {
    handle: Handle,
    desktop_name: String,
    lp_desktop: Vec<u16>,
}

static UNCONFIRMED_DESKTOP_HANDLES: OnceLock<Mutex<Vec<usize>>> = OnceLock::new();

fn retain_unclosed_desktop(handle: usize) {
    UNCONFIRMED_DESKTOP_HANDLES
        .get_or_init(|| Mutex::new(Vec::new()))
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .push(handle);
}

impl NativeDesktop {
    /// Create and validate a task-specific desktop for a same-user Medium child.
    ///
    /// The token handles must remain open for this call. They are never retained.
    pub fn create(
        parent_token: Handle,
        restricted_child_token: Handle,
    ) -> Result<Self, NativeDesktopError> {
        if parent_token.is_null() || restricted_child_token.is_null() {
            return Err(NativeDesktopError::new("token_handle", None));
        }

        let parent_identity = token_identity(parent_token)?;
        let child_identity = token_identity(restricted_child_token)?;
        if parent_identity.user_sid != child_identity.user_sid
            || parent_identity.session_id != child_identity.session_id
            || child_identity.elevated
            || child_identity.integrity_rid != 0x2000
        {
            return Err(NativeDesktopError::new("child_token_identity", None));
        }

        let station = unsafe { GetProcessWindowStation() };
        if station.is_null() {
            return Err(last_error("current_window_station"));
        }
        let station_name = user_object_name(station)?;
        let station_descriptor = security_descriptor(
            station,
            OWNER_SECURITY_INFORMATION | GROUP_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
        )?;
        let station_label_descriptor = security_descriptor(station, LABEL_SECURITY_INFORMATION)?;
        let station_label = integrity_label(station_label_descriptor.0)?;
        if station_label.is_some_and(|label| !matches!(label.rid, 0 | 0x1000 | 0x2000)) {
            return Err(NativeDesktopError::new("station_mic_denied", None));
        }

        let station_mapping = window_station_mapping(&station_name);
        if !access_check(
            station_descriptor.0,
            parent_token,
            WINSTA_CREATEDESKTOP,
            &station_mapping,
        )? {
            return Err(NativeDesktopError::new("station_creator_dacl_denied", None));
        }
        if !access_check(
            station_descriptor.0,
            restricted_child_token,
            station_mapping.generic_all,
            &station_mapping,
        )? {
            return Err(NativeDesktopError::new("station_child_dacl_denied", None));
        }

        let user_sid = child_identity.user_sid.clone();
        let sddl = format!("O:{user_sid}D:P(A;;GA;;;{user_sid})(A;;GA;;;SY)S:(ML;;NW;;;ME)");
        let sddl_wide: Vec<u16> = sddl.encode_utf16().chain(Some(0)).collect();
        let mut descriptor = ptr::null_mut();
        if unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl_wide.as_ptr(),
                1,
                &mut descriptor,
                ptr::null_mut(),
            )
        } == 0
        {
            return Err(last_error("desktop_security_descriptor"));
        }
        let descriptor = LocalSecurityDescriptor(descriptor);

        for _ in 0..8 {
            let desktop_leaf = random_desktop_name()?;
            let desktop_name: Vec<u16> = desktop_leaf.encode_utf16().chain(Some(0)).collect();
            match preflight_desktop(&desktop_name)? {
                Preflight::ExistsOrInaccessible => continue,
                Preflight::Absent => {}
            }

            let raw_handle = create_on_disposable_thread(&desktop_name, descriptor.0)?;
            let lp_desktop = format!("{station_name}\\{desktop_leaf}")
                .encode_utf16()
                .chain(Some(0))
                .collect();
            let desktop = Self {
                handle: raw_handle,
                desktop_name: desktop_leaf,
                lp_desktop,
            };
            desktop.validate(&child_identity.user_sid, restricted_child_token)?;
            eprintln!(
                "native desktop diagnostics: station_dacl=allowed station_label={} desktop_dacl=allowed desktop_label=medium_nw name=redacted",
                station_label_name(station_label)
            );
            return Ok(desktop);
        }

        Err(NativeDesktopError::new(
            "desktop_name_collision_limit",
            None,
        ))
    }

    /// A pointer suitable for STARTUPINFO.lpDesktop, valid while `self` is alive.
    pub fn lp_desktop(&self) -> *mut u16 {
        self.lp_desktop.as_ptr().cast_mut()
    }

    /// Transfer the open handle to an unconfirmed-Job retention list.
    pub fn into_raw_handle(mut self) -> usize {
        let handle = self.handle as usize;
        self.handle = ptr::null_mut();
        handle
    }

    fn validate(
        &self,
        expected_owner_sid: &str,
        restricted_child_token: Handle,
    ) -> Result<(), NativeDesktopError> {
        let leaf_name = user_object_name(self.handle)?;
        if !leaf_name.eq_ignore_ascii_case(&self.desktop_name) {
            return Err(NativeDesktopError::new("desktop_name_validation", None));
        }

        let descriptor = security_descriptor(
            self.handle,
            OWNER_SECURITY_INFORMATION | GROUP_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
        )?;
        if !owner_matches(descriptor.0, expected_owner_sid)?
            || !protected_exact_user_system_dacl(descriptor.0, expected_owner_sid)?
        {
            return Err(NativeDesktopError::new("desktop_dacl_validation", None));
        }
        if !access_check(
            descriptor.0,
            restricted_child_token,
            desktop_all_access(),
            &desktop_mapping(),
        )? {
            return Err(NativeDesktopError::new("desktop_child_dacl_denied", None));
        }

        let label_descriptor = security_descriptor(self.handle, LABEL_SECURITY_INFORMATION)?;
        match integrity_label(label_descriptor.0)? {
            Some(label)
                if label.rid == 0x2000 && label.policy == SYSTEM_MANDATORY_LABEL_NO_WRITE_UP => {}
            _ => {
                return Err(NativeDesktopError::new(
                    "desktop_medium_nw_label_validation",
                    None,
                ))
            }
        }
        Ok(())
    }

    /// Close the desktop after the caller has confirmed its child Job is empty.
    pub fn close(mut self) -> Result<(), NativeDesktopError> {
        if self.handle.is_null() {
            return Ok(());
        }
        if unsafe { CloseDesktop(self.handle) } == 0 {
            return Err(last_error("desktop_close"));
        }
        self.handle = ptr::null_mut();
        Ok(())
    }
}

impl Drop for NativeDesktop {
    fn drop(&mut self) {
        if !self.handle.is_null() {
            if unsafe { CloseDesktop(self.handle) } == 0 {
                let error = unsafe { GetLastError() };
                retain_unclosed_desktop(self.handle as usize);
                eprintln!("native desktop cleanup failed (code=0x{error:08x})");
                self.handle = ptr::null_mut();
            }
        }
    }
}

struct LocalSecurityDescriptor(Handle);

impl Drop for LocalSecurityDescriptor {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { LocalFree(self.0) };
        }
    }
}

struct OwnedHandle(Handle);

impl Drop for OwnedHandle {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { CloseHandle(self.0) };
        }
    }
}

struct TokenIdentity {
    user_sid: String,
    session_id: u32,
    elevated: bool,
    integrity_rid: u32,
}

#[derive(Clone, Copy)]
struct IntegrityLabel {
    rid: u32,
    policy: u32,
}

enum Preflight {
    ExistsOrInaccessible,
    Absent,
}

fn token_identity(token: Handle) -> Result<TokenIdentity, NativeDesktopError> {
    let user_information = token_information(
        token,
        TOKEN_USER_CLASS,
        "token_user",
        std::mem::size_of::<SidAndAttributes>(),
    )?;
    let user = unsafe { ptr::read_unaligned(user_information.as_ptr().cast::<SidAndAttributes>()) };
    if user.sid.is_null() || unsafe { IsValidSid(user.sid) } == 0 {
        return Err(NativeDesktopError::new("token_user_sid", None));
    }
    let user_sid = sid_to_string(user.sid)?;
    let session = token_information(token, TOKEN_SESSION_ID_CLASS, "token_session", 4)?;
    let elevation = token_information(token, TOKEN_ELEVATION_CLASS, "token_elevation", 4)?;
    let elevated = unsafe { ptr::read_unaligned(elevation.as_ptr().cast::<u32>()) != 0 };
    let integrity_information = token_information(
        token,
        TOKEN_INTEGRITY_LEVEL_CLASS,
        "token_integrity",
        std::mem::size_of::<SidAndAttributes>(),
    )?;
    let integrity =
        unsafe { ptr::read_unaligned(integrity_information.as_ptr().cast::<SidAndAttributes>()) };
    if integrity.attributes & 0x20 == 0 {
        return Err(NativeDesktopError::new(
            "token_integrity_sid_disabled",
            None,
        ));
    }
    let integrity_rid = sid_integrity_rid(integrity.sid)?;
    Ok(TokenIdentity {
        user_sid,
        session_id: unsafe { ptr::read_unaligned(session.as_ptr().cast::<u32>()) },
        elevated,
        integrity_rid,
    })
}

fn token_information(
    token: Handle,
    class: u32,
    stage: &'static str,
    minimum_size: usize,
) -> Result<Vec<u64>, NativeDesktopError> {
    let mut needed = 0u32;
    let first = unsafe { GetTokenInformation(token, class, ptr::null_mut(), 0, &mut needed) };
    if first != 0 || unsafe { GetLastError() } != ERROR_INSUFFICIENT_BUFFER {
        return Err(last_error(stage));
    }
    if (needed as usize) < minimum_size || needed > 1024 * 1024 {
        return Err(NativeDesktopError::new(stage, None));
    }
    let units = (needed as usize).div_ceil(std::mem::size_of::<u64>());
    let mut buffer = vec![0u64; units];
    let mut returned = 0u32;
    if unsafe {
        GetTokenInformation(
            token,
            class,
            buffer.as_mut_ptr().cast(),
            needed,
            &mut returned,
        )
    } == 0
        || (returned as usize) < minimum_size
        || returned as usize > buffer.len() * std::mem::size_of::<u64>()
    {
        return Err(last_error(stage));
    }
    Ok(buffer)
}

fn sid_integrity_rid(sid: Handle) -> Result<u32, NativeDesktopError> {
    if sid.is_null() || unsafe { IsValidSid(sid) } == 0 {
        return Err(NativeDesktopError::new("token_integrity_sid", None));
    }
    let header = unsafe { ptr::read_unaligned(sid.cast::<SidHeader>()) };
    if header.identifier_authority != [0, 0, 0, 0, 0, 16] || header.sub_authority_count == 0 {
        return Err(NativeDesktopError::new("token_integrity_sid", None));
    }
    let last_sub_authority = unsafe {
        sid.cast::<u8>()
            .add(std::mem::size_of::<SidHeader>() + (header.sub_authority_count as usize - 1) * 4)
            .cast::<u32>()
    };
    Ok(unsafe { ptr::read_unaligned(last_sub_authority) })
}

fn sid_to_string(sid: Handle) -> Result<String, NativeDesktopError> {
    let mut text = ptr::null_mut();
    if unsafe { ConvertSidToStringSidW(sid, &mut text) } == 0 {
        return Err(last_error("sid_conversion"));
    }
    let result = unsafe { wide_string(text) };
    unsafe { LocalFree(text.cast()) };
    Ok(result)
}

unsafe fn wide_string(text: *const u16) -> String {
    let mut length = 0usize;
    while unsafe { *text.add(length) } != 0 {
        length += 1;
        assert!(length < 1024);
    }
    String::from_utf16(unsafe { std::slice::from_raw_parts(text, length) }).unwrap_or_default()
}

fn user_object_name(object: Handle) -> Result<String, NativeDesktopError> {
    let mut needed = 0u32;
    let first =
        unsafe { GetUserObjectInformationW(object, UOI_NAME, ptr::null_mut(), 0, &mut needed) };
    if first != 0 || unsafe { GetLastError() } != ERROR_INSUFFICIENT_BUFFER {
        return Err(last_error("object_name_query"));
    }
    if needed < 2 || needed > 8192 {
        return Err(NativeDesktopError::new("object_name_size", None));
    }
    let mut wide = vec![0u16; (needed as usize).div_ceil(2)];
    if unsafe {
        GetUserObjectInformationW(
            object,
            UOI_NAME,
            wide.as_mut_ptr().cast(),
            needed,
            &mut needed,
        )
    } == 0
    {
        return Err(last_error("object_name_query"));
    }
    let end = wide
        .iter()
        .position(|unit| *unit == 0)
        .unwrap_or(wide.len());
    String::from_utf16(&wide[..end]).map_err(|_| NativeDesktopError::new("object_name_utf16", None))
}

fn security_descriptor(
    object: Handle,
    information: u32,
) -> Result<LocalSecurityDescriptor, NativeDesktopError> {
    let mut descriptor = ptr::null_mut();
    let status = unsafe {
        GetSecurityInfo(
            object,
            SE_WINDOW_OBJECT,
            information,
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            &mut descriptor,
        )
    };
    if status != 0 || descriptor.is_null() {
        return Err(NativeDesktopError::new(
            "security_descriptor_query",
            Some(status),
        ));
    }
    Ok(LocalSecurityDescriptor(descriptor))
}

fn access_check(
    descriptor: Handle,
    primary_token: Handle,
    requested: u32,
    mapping: &GenericMapping,
) -> Result<bool, NativeDesktopError> {
    let mut impersonation = ptr::null_mut();
    if unsafe {
        DuplicateTokenEx(
            primary_token,
            TOKEN_QUERY,
            ptr::null_mut(),
            SECURITY_IMPERSONATION,
            TOKEN_IMPERSONATION,
            &mut impersonation,
        )
    } == 0
    {
        return Err(last_error("access_check_token"));
    }
    let impersonation = OwnedHandle(impersonation);
    let mut desired_access = requested;
    unsafe { MapGenericMask(&mut desired_access, mapping) };
    let mut privilege_set = [0u64; 128];
    let mut privilege_set_length = std::mem::size_of_val(&privilege_set) as u32;
    let mut granted_access = 0u32;
    let mut access_status = 0i32;
    if unsafe {
        AccessCheck(
            descriptor,
            impersonation.0,
            desired_access,
            mapping,
            privilege_set.as_mut_ptr().cast(),
            &mut privilege_set_length,
            &mut granted_access,
            &mut access_status,
        )
    } == 0
    {
        return Err(last_error("access_check"));
    }
    Ok(access_status != 0)
}

fn window_station_mapping(name: &str) -> GenericMapping {
    let interactive = name.eq_ignore_ascii_case("WinSta0");
    let generic_read = 0x0002_0000 | WINSTA_ENUMDESKTOPS | WINSTA_READATTRIBUTES | 0x0100;
    let generic_write = 0x0002_0000 | WINSTA_ACCESSCLIPBOARD | WINSTA_CREATEDESKTOP;
    let generic_execute = 0x0002_0000 | WINSTA_ACCESSGLOBALATOMS | 0x0040;
    let generic_all = STANDARD_RIGHTS_REQUIRED
        | WINSTA_ACCESSCLIPBOARD
        | WINSTA_CREATEDESKTOP
        | WINSTA_ACCESSGLOBALATOMS
        | WINSTA_ENUMDESKTOPS
        | WINSTA_READATTRIBUTES
        | 0x0100
        | 0x0040
        | if interactive { 0x0200 | 0x0010 } else { 0 };
    GenericMapping {
        generic_read: generic_read | if interactive { 0x0200 } else { 0 },
        generic_write: generic_write | if interactive { 0x0010 } else { 0 },
        generic_execute,
        generic_all,
    }
}

fn desktop_mapping() -> GenericMapping {
    GenericMapping {
        generic_read: 0x0002_0000 | DESKTOP_ENUMERATE | DESKTOP_READOBJECTS,
        generic_write: 0x0002_0000
            | DESKTOP_CREATEMENU
            | DESKTOP_CREATEWINDOW
            | DESKTOP_HOOKCONTROL
            | DESKTOP_JOURNALPLAYBACK
            | DESKTOP_JOURNALRECORD
            | DESKTOP_WRITEOBJECTS,
        generic_execute: 0x0002_0000 | DESKTOP_SWITCHDESKTOP,
        generic_all: STANDARD_RIGHTS_REQUIRED
            | DESKTOP_CREATEMENU
            | DESKTOP_CREATEWINDOW
            | DESKTOP_HOOKCONTROL
            | DESKTOP_JOURNALPLAYBACK
            | DESKTOP_JOURNALRECORD
            | DESKTOP_ENUMERATE
            | DESKTOP_READOBJECTS
            | DESKTOP_WRITEOBJECTS
            | DESKTOP_SWITCHDESKTOP,
    }
}

fn desktop_all_access() -> u32 {
    desktop_mapping().generic_all
}

fn owner_matches(descriptor: Handle, expected_owner_sid: &str) -> Result<bool, NativeDesktopError> {
    let mut owner = ptr::null_mut();
    let mut owner_defaulted = 0;
    if unsafe { GetSecurityDescriptorOwner(descriptor, &mut owner, &mut owner_defaulted) } == 0
        || owner.is_null()
    {
        return Err(NativeDesktopError::new("desktop_owner_query", None));
    }
    Ok(sid_to_string(owner)? == expected_owner_sid)
}

fn protected_exact_user_system_dacl(
    descriptor: Handle,
    expected_user_sid: &str,
) -> Result<bool, NativeDesktopError> {
    let mut dacl_present = 0;
    let mut dacl = ptr::null_mut();
    let mut dacl_defaulted = 0;
    if unsafe {
        GetSecurityDescriptorDacl(
            descriptor,
            &mut dacl_present,
            &mut dacl,
            &mut dacl_defaulted,
        )
    } == 0
        || dacl_present == 0
        || dacl.is_null()
    {
        return Ok(false);
    }
    let mut control = 0u16;
    let mut revision = 0u32;
    if unsafe { GetSecurityDescriptorControl(descriptor, &mut control, &mut revision) } == 0
        || control & SE_DACL_PROTECTED == 0
    {
        return Ok(false);
    }
    let mut acl_information = AclSizeInformation::default();
    if unsafe {
        GetAclInformation(
            dacl,
            (&mut acl_information as *mut AclSizeInformation).cast(),
            std::mem::size_of::<AclSizeInformation>() as u32,
            2,
        )
    } == 0
        || acl_information.ace_count != 2
    {
        return Ok(false);
    }

    let system_sid = WellKnownSid {
        revision: 1,
        sub_authority_count: 1,
        identifier_authority: [0, 0, 0, 0, 0, 5],
        sub_authority: [18],
    };
    let system_sid = (&system_sid as *const WellKnownSid).cast_mut().cast();
    let mut saw_user = false;
    let mut saw_system = false;
    for index in 0..2 {
        let mut ace = ptr::null_mut();
        if unsafe { GetAce(dacl, index, &mut ace) } == 0 || ace.is_null() {
            return Ok(false);
        }
        let ace_header = unsafe { ptr::read_unaligned(ace.cast::<AceHeader>()) };
        if ace_header.ace_type != ACCESS_ALLOWED_ACE_TYPE
            || ace_header.ace_flags != 0
            || (ace_header.ace_size as usize) < std::mem::size_of::<AceHeader>() + 4
        {
            return Ok(false);
        }
        let sid = unsafe {
            ace.cast::<u8>()
                .add(std::mem::size_of::<AceHeader>() + 4)
                .cast()
        };
        let mut mask = unsafe {
            ptr::read_unaligned(
                ace.cast::<u8>()
                    .add(std::mem::size_of::<AceHeader>())
                    .cast::<u32>(),
            )
        };
        unsafe { MapGenericMask(&mut mask, &desktop_mapping()) };
        if mask != desktop_all_access() {
            return Ok(false);
        }
        if unsafe { IsValidSid(sid) } == 0
            || ace_header.ace_size as usize
                != std::mem::size_of::<AceHeader>() + 4 + unsafe { GetLengthSid(sid) as usize }
        {
            return Ok(false);
        }
        let sid_text = sid_to_string(sid)?;
        if sid_text == expected_user_sid && !saw_user {
            saw_user = true;
        } else if unsafe { EqualSid(sid, system_sid) } != 0 && !saw_system {
            saw_system = true;
        } else {
            return Ok(false);
        }
    }
    Ok(saw_user && saw_system)
}

fn integrity_label(descriptor: Handle) -> Result<Option<IntegrityLabel>, NativeDesktopError> {
    let mut present = 0;
    let mut sacl = ptr::null_mut();
    let mut sacl_defaulted = 0;
    if unsafe {
        GetSecurityDescriptorSacl(descriptor, &mut present, &mut sacl, &mut sacl_defaulted)
    } == 0
    {
        return Err(NativeDesktopError::new("integrity_label_query", None));
    }
    if present == 0 || sacl.is_null() {
        return Ok(None);
    }
    let mut acl_information = AclSizeInformation::default();
    if unsafe {
        GetAclInformation(
            sacl,
            (&mut acl_information as *mut AclSizeInformation).cast(),
            std::mem::size_of::<AclSizeInformation>() as u32,
            2,
        )
    } == 0
    {
        return Err(last_error("integrity_label_acl"));
    }
    let mut label = None;
    for index in 0..acl_information.ace_count {
        let mut ace = ptr::null_mut();
        if unsafe { GetAce(sacl, index, &mut ace) } == 0 || ace.is_null() {
            return Err(last_error("integrity_label_ace"));
        }
        let header = unsafe { ptr::read_unaligned(ace.cast::<AceHeader>()) };
        if header.ace_type != SYSTEM_MANDATORY_LABEL_ACE_TYPE {
            continue;
        }
        if label.is_some() || (header.ace_size as usize) < std::mem::size_of::<AceWithMask>() + 8 {
            return Err(NativeDesktopError::new("integrity_label_ambiguous", None));
        }
        let mandatory = unsafe { ptr::read_unaligned(ace.cast::<AceWithMask>()) };
        let sid = unsafe {
            ace.cast::<u8>()
                .add(std::mem::size_of::<AceHeader>() + 4)
                .cast()
        };
        if unsafe { IsValidSid(sid) } == 0
            || mandatory.ace_size as usize
                != std::mem::size_of::<AceHeader>() + 4 + unsafe { GetLengthSid(sid) as usize }
        {
            return Err(NativeDesktopError::new("integrity_label_sid", None));
        }
        let rid = sid_integrity_rid(sid)?;
        label = Some(IntegrityLabel {
            rid,
            policy: mandatory.mask,
        });
    }
    Ok(label)
}

fn station_label_name(label: Option<IntegrityLabel>) -> &'static str {
    match label.map(|label| label.rid) {
        None => "missing_effective_medium",
        Some(0) => "untrusted",
        Some(0x1000) => "low",
        Some(0x2000) => "medium",
        Some(_) => "higher_or_unknown",
    }
}

fn random_desktop_name() -> Result<String, NativeDesktopError> {
    let mut bytes = [0u8; 16];
    let status = unsafe { BCryptGenRandom(ptr::null_mut(), bytes.as_mut_ptr(), 16, 2) };
    if status != 0 {
        return Err(NativeDesktopError::new("random_name", Some(status as u32)));
    }
    let mut name = String::from("AiGoodBro-Test-");
    for byte in bytes {
        use fmt::Write as _;
        let _ = write!(&mut name, "{byte:02x}");
    }
    Ok(name)
}

fn preflight_desktop(name: &[u16]) -> Result<Preflight, NativeDesktopError> {
    let desktop = unsafe { OpenDesktopW(name.as_ptr(), 0, 0, 0) };
    if !desktop.is_null() {
        if unsafe { CloseDesktop(desktop) } == 0 {
            return Err(last_error("collision_handle_close"));
        }
        return Ok(Preflight::ExistsOrInaccessible);
    }
    let error = unsafe { GetLastError() };
    if error == ERROR_FILE_NOT_FOUND {
        Ok(Preflight::Absent)
    } else {
        Ok(Preflight::ExistsOrInaccessible)
    }
}

fn create_on_disposable_thread(
    name: &[u16],
    descriptor: Handle,
) -> Result<Handle, NativeDesktopError> {
    let name = name.to_vec();
    let descriptor = descriptor as usize;
    let created_handle = Arc::new(AtomicUsize::new(0));
    let worker_created_handle = Arc::clone(&created_handle);
    let worker = thread::Builder::new()
        .name("native-test-desktop".to_owned())
        .spawn(move || {
            let mut attributes = SecurityAttributes {
                length: std::mem::size_of::<SecurityAttributes>() as u32,
                security_descriptor: descriptor as Handle,
                inherit_handle: 0,
            };
            let handle = unsafe {
                CreateDesktopW(
                    name.as_ptr(),
                    ptr::null(),
                    ptr::null_mut(),
                    0,
                    READ_CONTROL
                        | WRITE_OWNER
                        | DESKTOP_CREATEWINDOW
                        | DESKTOP_READOBJECTS
                        | DESKTOP_WRITEOBJECTS,
                    &mut attributes,
                )
            };
            let error = if handle.is_null() {
                unsafe { GetLastError() }
            } else {
                worker_created_handle.store(handle as usize, Ordering::Release);
                0
            };
            (handle as usize, error)
        })
        .map_err(|_| NativeDesktopError::new("creator_thread_start", None))?;

    match worker.join() {
        Ok((handle, _error)) if handle != 0 => Ok(handle as Handle),
        Ok((_, error)) => Err(NativeDesktopError::new("desktop_create", Some(error))),
        Err(_) => {
            let handle = created_handle.load(Ordering::Acquire);
            if handle != 0 && unsafe { CloseDesktop(handle as Handle) } == 0 {
                let close_error = unsafe { GetLastError() };
                retain_unclosed_desktop(handle);
                eprintln!("native desktop worker cleanup failed (code=0x{close_error:08x})");
            }
            Err(NativeDesktopError::new("creator_thread_join", None))
        }
    }
}

fn last_error(stage: &'static str) -> NativeDesktopError {
    NativeDesktopError::new(stage, Some(unsafe { GetLastError() }))
}

#[cfg(all(test, windows))]
mod native_desktop_smoke {
    use super::*;

    const TOKEN_SMOKE_ACCESS: u32 = 0x008b;
    const CREATE_RESTRICTED_TOKEN_FLAGS: u32 = 5;

    #[repr(C)]
    struct TokenMandatoryLabel {
        label: SidAndAttributes,
        integrity_sid: WellKnownSid,
    }

    #[link(name = "advapi32")]
    unsafe extern "system" {
        fn OpenProcessToken(process: Handle, desired_access: u32, token: *mut Handle) -> i32;
        fn CreateRestrictedToken(
            token: Handle,
            flags: u32,
            disable_count: u32,
            disable: *const c_void,
            delete_count: u32,
            delete: *const c_void,
            restrict_count: u32,
            restrict: *const c_void,
            restricted_token: *mut Handle,
        ) -> i32;
        fn SetTokenInformation(
            token: Handle,
            class: u32,
            information: *const c_void,
            information_length: u32,
        ) -> i32;
    }

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetCurrentProcess() -> Handle;
    }

    fn restricted_medium_token(parent_token: Handle) -> OwnedHandle {
        let mut restricted = ptr::null_mut();
        let created = unsafe {
            CreateRestrictedToken(
                parent_token,
                CREATE_RESTRICTED_TOKEN_FLAGS,
                0,
                ptr::null(),
                0,
                ptr::null(),
                0,
                ptr::null(),
                &mut restricted,
            )
        };
        let create_error = if created == 0 {
            unsafe { GetLastError() }
        } else {
            0
        };
        assert_ne!(
            created, 0,
            "create restricted desktop smoke token failed (code=0x{create_error:08x})"
        );
        let restricted = OwnedHandle(restricted);

        let mut integrity = TokenMandatoryLabel {
            label: SidAndAttributes {
                sid: ptr::null_mut(),
                attributes: 0x20,
            },
            integrity_sid: WellKnownSid {
                revision: 1,
                sub_authority_count: 1,
                identifier_authority: [0, 0, 0, 0, 0, 16],
                sub_authority: [0x2000],
            },
        };
        integrity.label.sid = (&mut integrity.integrity_sid as *mut WellKnownSid).cast();
        let information_length = (std::mem::size_of::<SidAndAttributes>()
            + unsafe { GetLengthSid(integrity.label.sid) as usize })
            as u32;
        let updated = unsafe {
            SetTokenInformation(
                restricted.0,
                TOKEN_INTEGRITY_LEVEL_CLASS,
                (&integrity as *const TokenMandatoryLabel).cast(),
                information_length,
            )
        };
        let update_error = if updated == 0 {
            unsafe { GetLastError() }
        } else {
            0
        };
        assert_ne!(
            updated, 0,
            "set desktop smoke token integrity to Medium failed (code=0x{update_error:08x})"
        );
        restricted
    }

    #[test]
    fn create_validate_and_close_medium_child_desktop() {
        let mut raw_parent = ptr::null_mut();
        let opened =
            unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_SMOKE_ACCESS, &mut raw_parent) };
        let open_error = if opened == 0 {
            unsafe { GetLastError() }
        } else {
            0
        };
        assert_ne!(
            opened, 0,
            "open desktop smoke primary token failed (code=0x{open_error:08x})"
        );
        let parent = OwnedHandle(raw_parent);
        let token_type =
            token_information(parent.0, 8, "token_type", 4).expect("read desktop smoke token type");
        assert_eq!(
            unsafe { ptr::read_unaligned(token_type.as_ptr().cast::<u32>()) },
            1,
            "desktop smoke requires the current process primary token"
        );
        let parent_identity = token_identity(parent.0).expect("read desktop smoke parent token");
        let restricted = parent_identity
            .elevated
            .then(|| restricted_medium_token(parent.0));
        let child_token = restricted.as_ref().map_or(parent.0, |token| token.0);

        // create() enforces the same-user, same-session, non-elevated Medium contract.
        let desktop = NativeDesktop::create(parent.0, child_token)
            .expect("create and validate restricted-child desktop");
        desktop.close().expect("close validated child desktop");
    }
}
