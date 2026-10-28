use super::{fail, Result};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum ChannelKind {
    #[serde(rename = "feishu")]
    Feishu,
    #[serde(rename = "telegram")]
    Telegram,
    #[serde(rename = "wechat")]
    WeCom,
    #[serde(rename = "personal-wechat")]
    PersonalWeChat,
}
impl ChannelKind {
    pub const ALL: [Self; 4] = [
        Self::Feishu,
        Self::Telegram,
        Self::WeCom,
        Self::PersonalWeChat,
    ];
    pub fn id(self) -> &'static str {
        match self {
            Self::Feishu => "feishu",
            Self::Telegram => "telegram",
            Self::WeCom => "wechat",
            Self::PersonalWeChat => "personal-wechat",
        }
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MessageOptions {
    pub includes_agent_name: bool,
    pub includes_account_label: bool,
    pub includes_quotas: bool,
    pub includes_reset_times: bool,
    pub includes_reset_credits: bool,
    pub reset_expiry_detail: ResetExpiryDetail,
    pub notifies_five_hour_reset: bool,
    pub notifies_seven_day_reset: bool,
}
impl Default for MessageOptions {
    fn default() -> Self {
        Self {
            includes_agent_name: false,
            includes_account_label: true,
            includes_quotas: true,
            includes_reset_times: true,
            includes_reset_credits: true,
            reset_expiry_detail: ResetExpiryDetail::Nearest,
            notifies_five_hour_reset: true,
            notifies_seven_day_reset: true,
        }
    }
}
#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResetExpiryDetail {
    Nearest,
    All,
    None,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChannelState {
    pub channel: ChannelKind,
    pub enabled: bool,
    pub phase: &'static str,
    pub revision: u64,
    pub credential_present: bool,
    pub target_present: bool,
    pub last_accepted_at: Option<i64>,
    pub failure_code: Option<&'static str>,
    pub options: MessageOptions,
}
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeliveryReceipt {
    pub channel: ChannelKind,
    pub event_id: String,
    pub state: &'static str,
    pub checked_at: i64,
    pub remote_message_id: Option<String>,
    pub failure_code: Option<&'static str>,
}

#[derive(Clone, Copy)]
pub enum TaskState {
    Idle,
    Running,
    WaitingInput,
    Completed,
    Failed,
    Interrupted,
    Disconnected,
}
impl TaskState {
    fn label(self) -> &'static str {
        match self {
            Self::Idle => "空闲",
            Self::Running => "运行中",
            Self::WaitingInput => "等待输入",
            Self::Completed => "已完成",
            Self::Failed => "失败",
            Self::Interrupted => "已中断",
            Self::Disconnected => "已断开",
        }
    }
}
#[derive(Clone, Copy)]
pub enum SwitchFailure {
    NoEligibleAccount,
    AppBusy,
    ValidationFailed,
    RestartFailed,
    NetworkUnavailable,
    Unknown,
}
impl SwitchFailure {
    fn label(self) -> &'static str {
        match self {
            Self::NoEligibleAccount => "没有可用账号",
            Self::AppBusy => "应用正忙",
            Self::ValidationFailed => "身份核验失败",
            Self::RestartFailed => "重启失败",
            Self::NetworkUnavailable => "网络不可用",
            Self::Unknown => "原因未知",
        }
    }
}

/// Constructed by native producers only. There is no Deserialize/IPC command
/// accepting event bodies or arbitrary message text from the WebView.
#[derive(Clone)]
pub struct NotificationEvent {
    pub(crate) key: String,
    pub(crate) keys: Vec<String>,
    pub(crate) expiry_items: Option<Vec<(String, i64)>>,
    pub(crate) at: i64,
    pub(crate) account: Option<String>,
    pub(crate) proof: Option<(String, i64)>,
    pub(crate) facts: Option<(Option<i64>, Option<i64>, Option<u32>)>,
    pub(crate) body: EventBody,
}
#[derive(Clone)]
pub(crate) enum EventBody {
    Test,
    LowQuota {
        five: Option<f64>,
        seven: Option<f64>,
    },
    QuotaReset {
        five: bool,
        seven: bool,
    },
    CardsChanged {
        previous: u32,
        available: u32,
        previous_at: i64,
    },
    CardsExpiring {
        batches: Vec<(i64, u32)>,
        available: u32,
        unknown_expiry: u32,
    },
    Switch {
        failure: Option<SwitchFailure>,
    },
    Task {
        task: String,
        state: TaskState,
    },
    PublicReset {
        banked: bool,
        text: String,
        announced_at: i64,
    },
}
pub(crate) fn safe_label(s: &str) -> bool {
    !s.is_empty()
        && s.trim() == s
        && s.chars().count() <= 64
        && s.chars()
            .all(|c| c.is_alphanumeric() || " .-_·()（）•*".contains(c))
}
impl NotificationEvent {
    pub fn task(
        event_id: &str,
        account: &str,
        task: &str,
        state: TaskState,
        at: i64,
    ) -> Result<Self> {
        if !safe_label(task) {
            return fail("invalid_notification");
        }
        Self::new(
            event_id,
            Some(account),
            EventBody::Task {
                task: task.into(),
                state,
            },
            at,
        )
    }
    pub fn account_switch(
        event_id: &str,
        account: &str,
        failure: Option<SwitchFailure>,
        at: i64,
    ) -> Result<Self> {
        Self::new(event_id, Some(account), EventBody::Switch { failure }, at)
    }
    /// Native feed producer must first validate the same official source as the
    /// Mac PublicResetAnnouncement. Destinations are stripped from public copy.
    pub fn public_reset(
        verified_id: &str,
        banked: bool,
        text: &str,
        announced_at: i64,
        at: i64,
    ) -> Result<Self> {
        if text.chars().count() > 240 || text.len() > 720 || text.chars().any(char::is_control) {
            return fail("invalid_notification");
        }
        let clean = text
            .split_whitespace()
            .filter(|s| !s.contains(['@', '/', '\\', ':', '.', '．', '｡', '。']))
            .collect::<Vec<_>>()
            .join(" ");
        if clean.is_empty() || announced_at <= 0 || announced_at > at {
            return fail("invalid_notification");
        }
        Self::new(
            verified_id,
            None,
            EventBody::PublicReset {
                banked,
                text: clean,
                announced_at,
            },
            at,
        )
    }
    pub(crate) fn new(key: &str, account: Option<&str>, body: EventBody, at: i64) -> Result<Self> {
        if key.is_empty()
            || key.len() > 512
            || key.chars().any(char::is_control)
            || at <= 0
            || account.is_some_and(|s| !safe_label(s))
        {
            return fail("invalid_notification");
        }
        let key = super::hash(key.as_bytes());
        Ok(Self {
            keys: vec![key.clone()],
            expiry_items: None,
            key,
            at,
            account: account.map(str::to_owned),
            proof: None,
            facts: None,
            body,
        })
    }
    pub(crate) fn current(&self, now: i64) -> bool {
        self.at > 0
            && now >= self.at
            && now - self.at <= 300
            && match &self.body {
                EventBody::CardsExpiring { batches, .. } => batches.iter().all(|(at, _)| *at > now),
                _ => true,
            }
    }
    pub(crate) fn content(&self, options: &MessageOptions) -> (String, &'static str, Vec<String>) {
        let (title, color) = match self.body {
            EventBody::Test => ("AiGoodBro 消息通道测试", "blue"),
            EventBody::LowQuota { .. } => ("低额度提醒", "orange"),
            EventBody::QuotaReset { .. } => ("额度已重置", "green"),
            EventBody::CardsChanged {
                previous,
                available,
                ..
            } => {
                if available > previous {
                    ("重置卡增加", "purple")
                } else {
                    ("重置卡数量变化", "purple")
                }
            }
            EventBody::CardsExpiring { .. } => ("重置卡将在24小时内到期", "orange"),
            EventBody::Switch { failure: None } => ("账号切换成功", "green"),
            EventBody::Switch { .. } => ("账号切换失败", "red"),
            EventBody::Task { .. } => ("任务状态变化", "blue"),
            EventBody::PublicReset { banked: true, .. } => ("公开重置公告 · 重置卡", "purple"),
            EventBody::PublicReset { .. } => ("公开重置公告 · 常规额度", "turquoise"),
        };
        let mut lines = Vec::new();
        if options.includes_agent_name {
            lines.push("Agent：Codex".into());
        }
        if options.includes_account_label {
            if let Some(a) = &self.account {
                lines.push(format!("账号：{a}"));
            }
        }
        match &self.body {
            EventBody::Test => lines.push("API 接受仅表示接口接收，不代表送达或已读。".into()),
            EventBody::LowQuota { five, seven } => {
                if options.includes_quotas {
                    for (label, v) in [("5小时", five), ("7天", seven)] {
                        if let Some(v) = v {
                            lines.push(format!("{label}剩余：{v:.1}%"));
                        }
                    }
                }
            }
            EventBody::QuotaReset { five, seven } => {
                if *five {
                    lines.push("5小时额度已恢复（官方读取）".into());
                }
                if *seven {
                    lines.push("7天额度已恢复（官方读取）".into());
                }
            }
            EventBody::CardsChanged {
                previous,
                available,
                previous_at,
            } => {
                if options.includes_reset_credits {
                    lines.push(format!(
                        "重置卡：{previous} → {available}（{:+}）",
                        i64::from(*available) - i64::from(*previous)
                    ));
                    lines.push(format!(
                        "上次：{}；本次：{}",
                        beijing(*previous_at),
                        beijing(self.at)
                    ));
                    if available < previous {
                        lines.push("减少原因未确认。".into());
                    }
                }
            }
            EventBody::CardsExpiring {
                batches,
                available,
                unknown_expiry,
            } => {
                if options.includes_reset_credits {
                    lines.push(format!("可用重置卡：{available}"));
                    let selected = match options.reset_expiry_detail {
                        ResetExpiryDetail::Nearest => &batches[..batches.len().min(1)],
                        ResetExpiryDetail::All => batches.as_slice(),
                        ResetExpiryDetail::None => &[],
                    };
                    for (at, count) in selected {
                        lines.push(format!("{} 到期：{count} 张", beijing(*at)));
                    }
                    if *unknown_expiry > 0 {
                        lines.push(format!("到期时间未知：{unknown_expiry} 张"));
                    }
                }
            }
            EventBody::Switch {
                failure: Some(reason),
            } => lines.push(format!("原因：{}", reason.label())),
            EventBody::Task { task, state } => {
                lines.push(format!("任务：{task}"));
                lines.push(format!("状态：{}", state.label()));
            }
            EventBody::PublicReset {
                text, announced_at, ..
            } => {
                lines.push(text.clone());
                lines.push(format!("公告时间（北京时间）：{}", beijing(*announced_at)));
                lines.push("个人额度与重置卡以账号页官方读取为准。".into());
            }
            _ => {}
        }
        if let Some((five, seven, available)) = self.facts {
            if options.includes_reset_times {
                if let Some(at) = five {
                    lines.push(format!("5小时重置（北京时间）：{}", beijing(at)));
                }
                if let Some(at) = seven {
                    lines.push(format!("7天重置（北京时间）：{}", beijing(at)));
                }
            }
            if options.includes_reset_credits
                && !matches!(
                    self.body,
                    EventBody::CardsChanged { .. } | EventBody::CardsExpiring { .. }
                )
            {
                if let Some(n) = available {
                    lines.push(format!("可用重置卡：{n}"));
                }
            }
        }
        (title.into(), color, lines)
    }
}
pub(crate) fn beijing(at: i64) -> String {
    chrono::DateTime::from_timestamp(at, 0)
        .map(|d| {
            d.with_timezone(&chrono::FixedOffset::east_opt(8 * 3600).unwrap())
                .format("%m/%d %H:%M")
                .to_string()
        })
        .unwrap_or_else(|| "未知".into())
}
