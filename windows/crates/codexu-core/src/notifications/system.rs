//! Local Windows notifications use the same native producer and durable ledger
//! as remote channels. A successful Show is submission, never visible delivery.
use super::{fail, Result};
use serde::Serialize;
use std::sync::atomic::AtomicBool;
#[cfg(any(windows, test))]
const APP_ID: &str = "com.blackielf.codex-account-manager-next.windows";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SystemNotificationPermission {
    Enabled,
    DisabledApp,
    DisabledUser,
    DisabledPolicy,
    DisabledManifest,
    Unavailable,
}
pub(super) fn permission() -> SystemNotificationPermission {
    #[cfg(windows)]
    {
        native::permission().unwrap_or(SystemNotificationPermission::Unavailable)
    }
    #[cfg(not(windows))]
    {
        SystemNotificationPermission::Unavailable
    }
}
pub(super) fn send(title: &str, body: &str, cancelled: &AtomicBool) -> Result<()> {
    let xml = payload(title, body)?;
    #[cfg(windows)]
    {
        native::send(&xml, cancelled)
    }
    #[cfg(not(windows))]
    {
        let _ = (xml, cancelled);
        fail("system_notifications_unavailable")
    }
}
fn payload(title: &str, body: &str) -> Result<String> {
    if title.trim().is_empty()
        || title.chars().count() > 128
        || body.chars().count() > 4096
        || title
            .chars()
            .chain(body.chars())
            .any(|c| c.is_control() && c != '\n')
    {
        return fail("invalid_system_notification");
    }
    fn escaped(value: &str) -> String {
        value
            .replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
            .replace('"', "&quot;")
            .replace('\'', "&apos;")
    }
    Ok(format!(
        "<toast><visual><binding template=\"ToastGeneric\"><text>{}</text><text>{}</text></binding></visual><audio silent=\"true\"/></toast>",
        escaped(title), escaped(body)
    ))
}

#[cfg(windows)]
mod native {
    use super::*;
    use std::sync::atomic::Ordering;
    use windows::{
        core::HSTRING,
        Data::Xml::Dom::XmlDocument,
        UI::Notifications::{NotificationSetting, ToastNotification, ToastNotificationManager},
    };
    #[link(name = "combase")]
    unsafe extern "system" {
        fn RoInitialize(kind: u32) -> i32;
        fn RoUninitialize();
    }
    struct Apartment(bool);
    impl Apartment {
        fn enter() -> Result<Self> {
            let hr = unsafe { RoInitialize(1) };
            if hr < 0 && hr as u32 != 0x80010106 {
                return fail("system_notifications_unavailable");
            }
            Ok(Self(hr >= 0))
        }
    }
    impl Drop for Apartment {
        fn drop(&mut self) {
            if self.0 {
                unsafe { RoUninitialize() };
            }
        }
    }
    fn map(value: NotificationSetting) -> SystemNotificationPermission {
        match value {
            NotificationSetting::Enabled => SystemNotificationPermission::Enabled,
            NotificationSetting::DisabledForApplication => {
                SystemNotificationPermission::DisabledApp
            }
            NotificationSetting::DisabledForUser => SystemNotificationPermission::DisabledUser,
            NotificationSetting::DisabledByGroupPolicy => {
                SystemNotificationPermission::DisabledPolicy
            }
            NotificationSetting::DisabledByManifest => {
                SystemNotificationPermission::DisabledManifest
            }
            _ => SystemNotificationPermission::Unavailable,
        }
    }
    pub(super) fn permission() -> Result<SystemNotificationPermission> {
        let _apartment = Apartment::enter()?;
        let notifier = ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(APP_ID))
            .map_err(|_| super::super::Failure("system_notifications_unavailable"))?;
        notifier
            .Setting()
            .map(map)
            .map_err(|_| super::super::Failure("system_notifications_unavailable"))
    }
    pub(super) fn send(xml: &str, cancelled: &AtomicBool) -> Result<()> {
        let _apartment = Apartment::enter()?;
        let notifier = ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(APP_ID))
            .map_err(|_| super::super::Failure("system_notifications_unavailable"))?;
        let permission = notifier
            .Setting()
            .map_err(|_| super::super::Failure("system_notifications_unavailable"))?;
        if map(permission) != SystemNotificationPermission::Enabled {
            return fail("system_notifications_disabled");
        }
        let document = XmlDocument::new()
            .map_err(|_| super::super::Failure("system_notifications_unavailable"))?;
        document
            .LoadXml(&HSTRING::from(xml))
            .map_err(|_| super::super::Failure("invalid_system_notification"))?;
        let toast = ToastNotification::CreateToastNotification(&document)
            .map_err(|_| super::super::Failure("system_notifications_unavailable"))?;
        if cancelled.load(Ordering::Acquire) {
            return fail("cancelled");
        }
        notifier
            .Show(&toast)
            .map_err(|_| super::super::Failure("system_notification_submission_failed"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn local_notification_escapes_markup_and_rejects_invalid_text() {
        let xml = payload("A < B", "x & y\n<action>evil</action>").unwrap();
        assert!(xml.contains("A &lt; B"));
        assert!(xml.contains("x &amp; y\n&lt;action&gt;"));
        assert!(!xml.contains("<action>"));
        assert!(payload("", "valid").is_err());
        assert!(payload("valid", "hidden\0text").is_err());
    }
    #[test]
    fn application_id_matches_the_real_installer_identity() {
        let config: serde_json::Value = serde_json::from_slice(include_bytes!(
            "../../../../apps/codexu-tauri/src-tauri/tauri.conf.json"
        ))
        .unwrap();
        assert_eq!(config["identifier"], APP_ID);
    }
}
