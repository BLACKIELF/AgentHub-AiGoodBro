use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Surface {
    Popover,
    EdgePeek,
    EdgeRail,
    EdgeCard,
}
impl Surface {
    pub const ALL: [Self; 4] = [
        Self::Popover,
        Self::EdgePeek,
        Self::EdgeRail,
        Self::EdgeCard,
    ];
    pub fn label(self) -> &'static str {
        match self {
            Self::Popover => "token-monitor-popover",
            Self::EdgePeek => "token-monitor-edge-peek",
            Self::EdgeRail => "token-monitor-edge-rail",
            Self::EdgeCard => "token-monitor-edge-card",
        }
    }
    pub fn from_label(value: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|surface| surface.label() == value)
    }
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum DockMode {
    AutoHide,
    Always,
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Side {
    Left,
    Right,
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum DockSize {
    Small,
    Medium,
    Large,
    Custom,
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum QuotaStyle {
    Ring,
    Fish,
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ItemKind {
    Limit,
    Stat,
    Proxy,
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Metric {
    Today,
    Week,
    Last7,
    Last30,
    Month,
    AllTime,
    LiveRate,
    Sessions,
}
impl Metric {
    pub fn id(self) -> &'static str {
        match self {
            Self::Today => "today",
            Self::Week => "week",
            Self::Last7 => "last7",
            Self::Last30 => "last30",
            Self::Month => "month",
            Self::AllTime => "allTime",
            Self::LiveRate => "liveRate",
            Self::Sessions => "sessions",
        }
    }
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum AccountMode {
    Active,
    Lowest,
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SessionGroup {
    None,
    Client,
}
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SessionDetail {
    Clients,
    Rate,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Item {
    pub id: String,
    pub r#type: ItemKind,
    pub provider_id: Option<String>,
    pub account_id: Option<String>,
    pub metric: Option<Metric>,
    pub hidden_account_ids: Vec<String>,
    pub show_usage: bool,
    pub show_sessions: bool,
    pub account_mode: AccountMode,
    pub running_only: bool,
    pub group_by: SessionGroup,
    pub cell_detail: SessionDetail,
}
impl Item {
    pub fn stat(metric: Metric) -> Self {
        Self {
            id: format!("stat:{}", metric.id()),
            r#type: ItemKind::Stat,
            provider_id: None,
            account_id: None,
            metric: Some(metric),
            hidden_account_ids: vec![],
            show_usage: true,
            show_sessions: true,
            account_mode: AccountMode::Lowest,
            running_only: false,
            group_by: SessionGroup::None,
            cell_detail: SessionDetail::Clients,
        }
    }
    pub fn limit(provider: &str) -> Self {
        let provider = canonical_provider(provider);
        Self {
            id: format!("limit:{provider}"),
            r#type: ItemKind::Limit,
            provider_id: Some(provider.clone()),
            metric: None,
            account_mode: if provider == "codex" {
                AccountMode::Active
            } else {
                AccountMode::Lowest
            },
            ..Self::stat(Metric::Today)
        }
    }
    pub fn proxy() -> Self {
        Self {
            id: "proxy".into(),
            r#type: ItemKind::Proxy,
            metric: None,
            show_usage: false,
            show_sessions: false,
            ..Self::stat(Metric::Today)
        }
    }
    pub fn derived_id(&self) -> Option<String> {
        match self.r#type {
            ItemKind::Proxy
                if self.provider_id.is_none()
                    && self.account_id.is_none()
                    && self.metric.is_none() =>
            {
                Some("proxy".into())
            }
            ItemKind::Stat if self.provider_id.is_none() && self.account_id.is_none() => {
                Some(format!("stat:{}", self.metric?.id()))
            }
            ItemKind::Limit if self.metric.is_none() => {
                let provider = self.provider_id.as_deref()?;
                if !safe_id(provider) {
                    return None;
                }
                Some(match &self.account_id {
                    Some(account) if safe_id(account) => {
                        format!("limit:{provider}:account:{account}")
                    }
                    Some(_) => return None,
                    None => format!("limit:{provider}"),
                })
            }
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Preferences {
    pub enabled: bool,
    pub mode: DockMode,
    pub side: Side,
    pub offset: f64,
    pub display_id: Option<String>,
    pub items: Option<Vec<Item>>,
    pub haptic_enabled: bool,
    pub warn_colors: bool,
    pub quota_style: QuotaStyle,
    pub refresh_enabled: bool,
    pub running_indicator_enabled: bool,
    pub size: DockSize,
    pub custom_scale: f64,
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            enabled: false,
            mode: DockMode::AutoHide,
            side: Side::Right,
            offset: 0.3,
            display_id: None,
            items: None,
            haptic_enabled: true,
            warn_colors: false,
            quota_style: QuotaStyle::Ring,
            refresh_enabled: false,
            running_indicator_enabled: true,
            size: DockSize::Medium,
            custom_scale: 1.0,
        }
    }
}
impl Preferences {
    pub fn scale(&self) -> f64 {
        match self.size {
            DockSize::Small => 0.85,
            DockSize::Medium => 1.,
            DockSize::Large => 1.25,
            DockSize::Custom => self.custom_scale,
        }
    }
    pub fn validate(&self) -> Result<(), &'static str> {
        if !self.offset.is_finite()
            || !(0. ..=1.).contains(&self.offset)
            || !self.custom_scale.is_finite()
            || !(0.75..=1.5).contains(&self.custom_scale)
            || (self.custom_scale * 20. - (self.custom_scale * 20.).round()).abs() > 0.000001
            || self.display_id.as_ref().is_some_and(|id| !safe_id(id))
        {
            return Err("compact_invalid_preferences");
        }
        if let Some(items) = &self.items {
            let mut ids = std::collections::BTreeSet::new();
            if items.len() > 24 {
                return Err("compact_invalid_preferences");
            }
            for item in items {
                if !safe_id(&item.id)
                    || item.derived_id().as_deref() != Some(item.id.as_str())
                    || !ids.insert(&item.id)
                    || item.hidden_account_ids.len() > 256
                    || item.hidden_account_ids.iter().any(|id| !safe_id(id))
                    || item
                        .hidden_account_ids
                        .iter()
                        .collect::<std::collections::BTreeSet<_>>()
                        .len()
                        != item.hidden_account_ids.len()
                {
                    return Err("compact_invalid_preferences");
                }
            }
        }
        Ok(())
    }
}
pub fn safe_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._:-".contains(&byte))
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowState {
    pub surface: Surface,
    pub visible: bool,
    pub pinned: bool,
    pub collapsed: bool,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Display {
    pub id: String,
    pub label: String,
    pub is_primary: bool,
    pub available: bool,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ShortcutStatus {
    Unregistered,
    Registered,
    Occupied,
    Failed,
    Unavailable,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CompactUiState {
    pub revision: u64,
    pub windows: Vec<WindowState>,
    pub selected_item_id: Option<String>,
    pub resolved_items: Vec<Item>,
    pub page_index: usize,
    pub page_count: usize,
    pub display_available: bool,
    pub side: Side,
    pub scale: f64,
    pub viewport_height: f64,
    pub preferences: Preferences,
    pub displays: Vec<Display>,
    pub failure_code: Option<&'static str>,
    pub shortcut_status: ShortcutStatus,
    pub cached_projection: super::cache::CachedProjection,
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn mac_defaults_scales_and_empty_items_are_preserved() {
        let mut prefs = Preferences::default();
        assert!(prefs.validate().is_ok());
        assert_eq!(prefs.scale(), 1.);
        assert!(prefs.items.is_none());
        prefs.items = Some(vec![]);
        assert!(prefs.validate().is_ok());
        prefs.size = DockSize::Small;
        assert_eq!(prefs.scale(), 0.85);
        prefs.size = DockSize::Large;
        assert_eq!(prefs.scale(), 1.25);
    }
    #[test]
    fn item_identity_and_unknown_fields_cannot_be_forged() {
        let mut item = Item::stat(Metric::LiveRate);
        assert_eq!(item.derived_id().as_deref(), Some("stat:liveRate"));
        item.id = "stat:allTime".into();
        let mut prefs = Preferences::default();
        prefs.items = Some(vec![item]);
        assert!(prefs.validate().is_err());
        let mut value = serde_json::to_value(Preferences::default()).unwrap();
        value["path"] = serde_json::json!("C:\\private");
        assert!(serde_json::from_value::<Preferences>(value).is_err());
    }
    #[test]
    fn finite_actions_reject_wrong_surfaces_and_unrelated_arguments() {
        assert!(validate_action(Surface::EdgePeek, "reveal", None).is_ok());
        assert!(validate_action(Surface::Popover, "reveal", None).is_err());
        assert!(validate_action(Surface::EdgeRail, "select_item", Some("stat:today")).is_ok());
        assert!(validate_action(Surface::Popover, "select_item", Some("stat:today")).is_err());
        assert!(validate_action(Surface::EdgeRail, "select_item", None).is_err());
        assert!(validate_action(Surface::Popover, "open_settings", None).is_ok());
        for action in ["close", "open_workspace", "open_running_tasks", "drag"] {
            assert!(validate_action(Surface::EdgeRail, action, Some("stat:today")).is_err());
        }
        assert!(validate_action(Surface::EdgeRail, "start_proxy", None).is_err());
        assert!(validate_action(Surface::EdgeRail, "select_item", Some("C:\\private")).is_err());
    }
    #[test]
    fn canonical_aliases_do_not_create_duplicate_automatic_provider_items() {
        assert_eq!(Item::limit(" Claude-Code ").id, "limit:claude");
        assert_eq!(Item::limit("Codex").account_mode, AccountMode::Active);
        assert_eq!(canonical_provider("OPEN_CODE"), "opencode");
    }
}

/// Native cache IDs remain unchanged; only comparisons/display order use the
/// actual LocalCliKind aliases already used by the Mac provider catalogue.
pub fn canonical_provider(value: &str) -> String {
    let value = value.trim().to_ascii_lowercase();
    match value.as_str() {
        "claude_code" | "claude-code" | "claudecode" => "claude",
        "open_code" => "opencode",
        "work_buddy" => "workbuddy",
        "zcode" => "zai",
        _ => &value,
    }
    .to_owned()
}

pub fn validate_action(
    surface: Surface,
    action: &str,
    item_id: Option<&str>,
) -> Result<(), &'static str> {
    if (action == "select_item") != item_id.is_some() || item_id.is_some_and(|id| !safe_id(id)) {
        return Err("compact_invalid_item");
    }
    let allowed = match action {
        "reveal" => matches!(surface, Surface::EdgePeek | Surface::EdgeRail),
        "drag" | "select_item" | "page_next" | "page_previous" => surface == Surface::EdgeRail,
        "pin" | "unpin" | "close" => surface != Surface::EdgePeek,
        "collapse" => matches!(surface, Surface::Popover | Surface::EdgeRail),
        "open_workspace" | "open_accounts" | "open_running_tasks" | "open_settings"
        | "open_proxy" => true,
        _ => false,
    };
    if allowed {
        Ok(())
    } else {
        Err("compact_action_unavailable")
    }
}
