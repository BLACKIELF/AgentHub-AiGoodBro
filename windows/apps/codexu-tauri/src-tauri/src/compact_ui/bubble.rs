//! Standalone floating quota bubble; Mac geometry translated to Windows coordinates.
use super::{geometry::Rect, model::safe_id};
use serde::{Deserialize, Serialize};
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Preferences {
    pub enabled: bool,
    pub show_icon: bool,
    pub show_quota_bar: bool,
    pub show_percent: bool,
    pub show_reset_time: bool,
    pub show_cost: bool,
    pub custom_text: String,
    pub font_style: String,
    pub selected_provider_id: Option<String>,
    pub selected_profile_id: Option<String>,
    pub selected_metric_id: Option<String>,
    pub value_mode: String,
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            enabled: false,
            show_icon: true,
            show_quota_bar: true,
            show_percent: true,
            show_reset_time: true,
            show_cost: false,
            custom_text: String::new(),
            font_style: "menubar".into(),
            selected_provider_id: None,
            selected_profile_id: None,
            selected_metric_id: None,
            value_mode: "remaining".into(),
        }
    }
}
impl Preferences {
    pub fn check_base(&self, expected: Option<&serde_json::Value>) -> Result<(), &'static str> {
        let expected: Self =
            serde_json::from_value(expected.ok_or("compact_preferences_conflict")?.clone())
                .map_err(|_| "compact_invalid_preferences")?;
        expected.validate()?;
        if &expected != self {
            return Err("compact_preferences_conflict");
        }
        Ok(())
    }
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.custom_text.chars().count() > 80
            || self.custom_text.chars().any(char::is_control)
            || !["menubar", "normal", "condensed", "compactMono"]
                .contains(&self.font_style.as_str())
            || !["remaining", "used"].contains(&self.value_mode.as_str())
            || [
                &self.selected_provider_id,
                &self.selected_profile_id,
                &self.selected_metric_id,
            ]
            .into_iter()
            .any(|id| id.as_deref().is_some_and(|id| !safe_id(id)))
        {
            return Err("compact_invalid_preferences");
        }
        Ok(())
    }
}
pub fn clamp(bounds: Rect, area: Rect, margin: f64) -> Rect {
    let width = bounds.width.min((area.width - 2. * margin).max(1.));
    let height = bounds.height.min((area.height - 2. * margin).max(1.));
    Rect {
        x: bounds.x.clamp(
            area.x + margin,
            (area.right() - width - margin).max(area.x + margin),
        ),
        y: bounds.y.clamp(
            area.y + margin,
            (area.bottom() - height - margin).max(area.y + margin),
        ),
        width,
        height,
    }
}
pub fn collapsed(expanded: Rect, previous: Option<Rect>, display: Rect, dpi: f64) -> Rect {
    let width = 18. * dpi;
    let height = 34. * dpi;
    let old = previous.unwrap_or(Rect {
        x: if expanded.x + expanded.width / 2. <= display.x + display.width / 2. {
            expanded.x
        } else {
            expanded.right() - width
        },
        y: expanded.y + (expanded.height - height) / 2.,
        width,
        height,
    });
    clamp(
        Rect {
            width,
            height,
            ..old
        },
        display,
        0.,
    )
}
pub fn expanded(handle: Rect, previous: Rect, work: Rect, dpi: f64) -> Rect {
    let x = if handle.x + handle.width / 2. <= work.x + work.width / 2. {
        handle.x
    } else {
        handle.right() - previous.width
    };
    clamp(
        Rect {
            x,
            y: handle.y + (handle.height - previous.height) / 2.,
            ..previous
        },
        work,
        8. * dpi,
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stale_editor_cannot_reopen_or_overwrite_another_windows_selection() {
        let mut current = Preferences::default();
        current.enabled = true;
        let old = serde_json::to_value(&current).unwrap();
        assert!(current.check_base(Some(&old)).is_ok());
        current.enabled = false;
        assert_eq!(
            current.check_base(Some(&old)),
            Err("compact_preferences_conflict")
        );
        assert_eq!(
            current.check_base(None),
            Err("compact_preferences_conflict")
        );
        let closed = serde_json::to_value(&current).unwrap();
        current.selected_provider_id = Some("codex".into());
        assert_eq!(
            current.check_base(Some(&closed)),
            Err("compact_preferences_conflict")
        );
        assert!(current
            .check_base(Some(&serde_json::to_value(&current).unwrap()))
            .is_ok());
    }
    #[test]
    fn standalone_bubble_geometry_handles_negative_monitors_and_tiny_work_areas() {
        let work = Rect {
            x: -1920.,
            y: 40.,
            width: 1920.,
            height: 1040.,
        };
        let initial = clamp(
            Rect {
                x: -2000.,
                y: -100.,
                width: 304.,
                height: 260.,
            },
            work,
            8.,
        );
        assert_eq!(initial.x, -1912.);
        let handle = collapsed(initial, None, work, 1.);
        assert_eq!((handle.width, handle.height), (18., 34.));
        let restored = expanded(handle, initial, work, 1.);
        assert_eq!(restored, initial);
        let tiny = clamp(
            initial,
            Rect {
                x: 0.,
                y: 0.,
                width: 20.,
                height: 20.,
            },
            8.,
        );
        assert_eq!((tiny.width, tiny.height), (4., 4.));
    }
    #[test]
    fn bubble_text_and_selections_are_bounded() {
        let mut p = Preferences::default();
        assert!(p.validate().is_ok());
        p.custom_text = "a".repeat(81);
        assert!(p.validate().is_err());
        p.custom_text = "hello".into();
        p.selected_profile_id = Some("../../auth.json".into());
        assert!(p.validate().is_err());
    }
}
