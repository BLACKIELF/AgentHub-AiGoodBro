//! Owned Windows compact presentation. It projects existing state only: no
//! transcript scan, quota refresh, login, process control or statistics timer.
pub mod cache;
mod geometry;
mod hotkey;
pub mod model;
mod storage;
mod windowing;

use geometry::Rect;
use model::*;
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::Instant,
};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition};

pub struct CompactAppState(pub Arc<CompactService>);
pub struct CompactService {
    inner: Mutex<Inner>,
    operation: Mutex<()>,
    store: storage::Store,
    app: AppHandle,
    hover_running: AtomicBool,
    exiting: AtomicBool,
    shortcut: Mutex<Option<hotkey::Owner>>,
}
struct Inner {
    public: CompactUiState,
    anchor: Option<(f64, f64)>,
    layout: Option<Layout>,
    edge_started: Option<Instant>,
    hover_started: Option<Instant>,
    hovered: Option<String>,
    outside_started: Option<Instant>,
    dragging: bool,
    edge_hidden: bool,
}
#[derive(Clone)]
struct Layout {
    rail: Rect,
    card: Rect,
    peek: Rect,
    dpi: f64,
    capacity: usize,
}
fn failure<T>(code: &'static str) -> Result<T, String> {
    Err(code.into())
}
impl Inner {
    fn window(&self, surface: Surface) -> &WindowState {
        self.public
            .windows
            .iter()
            .find(|value| value.surface == surface)
            .expect("fixed compact surface")
    }
    fn window_mut(&mut self, surface: Surface) -> &mut WindowState {
        self.public
            .windows
            .iter_mut()
            .find(|value| value.surface == surface)
            .expect("fixed compact surface")
    }
    fn bump(&mut self) -> Result<(), String> {
        self.public.revision = self
            .public
            .revision
            .checked_add(1)
            .ok_or("compact_unavailable")?;
        Ok(())
    }
    fn dismiss(&mut self, surface: Surface) {
        self.window_mut(surface).visible = false;
        self.hover_started = None;
        self.outside_started = None;
        if surface == Surface::EdgeRail {
            self.edge_hidden = true;
            self.window_mut(surface).pinned = false;
            self.window_mut(Surface::EdgeCard).visible = false;
            self.window_mut(Surface::EdgeCard).pinned = false;
            self.public.selected_item_id = None;
        } else if surface == Surface::EdgeCard {
            self.window_mut(surface).pinned = false;
            self.public.selected_item_id = None;
        }
    }
    fn shortcut_should_enable(&self) -> bool {
        !(self.public.preferences.enabled && self.window(Surface::EdgeRail).visible)
    }
    fn apply_shortcut(&mut self, preferences: Preferences) {
        self.edge_hidden = false;
        self.public.selected_item_id = None;
        self.hovered = None;
        self.hover_started = None;
        self.outside_started = None;
        self.edge_started = None;
        for surface in [Surface::EdgePeek, Surface::EdgeRail, Surface::EdgeCard] {
            let window = self.window_mut(surface);
            window.visible = preferences.enabled && surface == Surface::EdgeRail;
            window.pinned = window.visible;
        }
        self.public.preferences = preferences;
    }
    fn items(&self) -> Vec<Item> {
        if let Some(items) = &self.public.preferences.items {
            return items.clone();
        }
        const ORDER: &[&str] = &[
            "claude",
            "codex",
            "opencode",
            "cursor",
            "antigravity",
            "cline",
            "factory",
            "kimi",
            "grok",
            "copilot",
            "zed",
            "commandcode",
            "mimo",
            "zai",
            "zaiteam",
            "kiro",
            "workbuddy",
            "qoder",
            "deepseek",
            "devin",
            "typesafe",
            "openrouter",
            "minimax",
            "volcengine",
            "ollama",
            "trae",
            "alibaba",
            "thirdparty",
        ];
        let mut providers = self
            .public
            .cached_projection
            .accounts
            .iter()
            .filter(|account| {
                account.logged_in
                    && account.available
                    && (account.credits_usd.is_some()
                        || account
                            .windows
                            .iter()
                            .any(|window| window.used_percent.is_some()))
            })
            .map(|account| account.provider_id.clone())
            .collect::<Vec<_>>();
        providers.sort_by_key(|id| {
            (
                ORDER
                    .iter()
                    .position(|value| *value == canonical_provider(id))
                    .unwrap_or(usize::MAX),
                id.clone(),
            )
        });
        providers.dedup_by(|a, b| canonical_provider(a) == canonical_provider(b));
        let mut items = vec![Item::proxy(), Item::stat(Metric::Today)];
        items.extend(providers.iter().take(3).map(|id| Item::limit(id)));
        items.push(Item::stat(Metric::LiveRate));
        items
    }
}
pub fn install(app: &AppHandle, app_data_root: PathBuf) -> Result<(), String> {
    if app.try_state::<CompactAppState>().is_some() {
        return Ok(());
    }
    let store = storage::Store::new(&app_data_root).map_err(str::to_owned)?;
    let (preferences, error) = match store.load() {
        Ok(value) => (value, None),
        Err(code) => (Preferences::default(), Some(code)),
    };
    let public = CompactUiState {
        revision: 0,
        windows: Surface::ALL
            .into_iter()
            .map(|surface| WindowState {
                surface,
                visible: false,
                pinned: false,
                collapsed: false,
            })
            .collect(),
        selected_item_id: None,
        resolved_items: vec![],
        page_index: 0,
        page_count: 1,
        display_available: false,
        side: preferences.side,
        scale: preferences.scale(),
        viewport_height: 0.,
        preferences,
        displays: vec![],
        failure_code: error,
        shortcut_status: if cfg!(windows) {
            ShortcutStatus::Unregistered
        } else {
            ShortcutStatus::Unavailable
        },
        cached_projection: cache::CachedProjection::default(),
    };
    let service = Arc::new(CompactService {
        inner: Mutex::new(Inner {
            public,
            anchor: None,
            layout: None,
            edge_started: None,
            hover_started: None,
            hovered: None,
            outside_started: None,
            dragging: false,
            edge_hidden: false,
        }),
        operation: Mutex::new(()),
        store,
        app: app.clone(),
        hover_running: AtomicBool::new(false),
        exiting: AtomicBool::new(false),
        shortcut: Mutex::new(None),
    });
    app.manage(CompactAppState(service.clone()));
    let current = service.clone();
    tauri::async_runtime::spawn_blocking(move || {
        current.install_shortcut();
        let _ = current.reconcile();
    });
    Ok(())
}
pub async fn toggle_popover(
    app: AppHandle,
    anchor: Option<PhysicalPosition<f64>>,
) -> Result<(), String> {
    let service = app
        .try_state::<CompactAppState>()
        .ok_or("compact_unavailable")?
        .0
        .clone();
    tauri::async_runtime::spawn_blocking(move || {
        let _operation = service
            .operation
            .lock()
            .map_err(|_| "compact_unavailable")?;
        {
            let mut inner = service.inner.lock().map_err(|_| "compact_unavailable")?;
            if let Some(anchor) = anchor {
                inner.anchor = Some((anchor.x, anchor.y));
            }
            let window = inner.window_mut(Surface::Popover);
            window.visible = !window.visible;
            inner.bump()?;
        }
        service.apply_locked()?;
        Ok(())
    })
    .await
    .map_err(|_| "compact_unavailable".to_owned())?
}
pub fn shutdown(app: &AppHandle) {
    let Some(state) = app.try_state::<CompactAppState>() else {
        return;
    };
    state.0.exiting.store(true, Ordering::Release);
    let clean = state
        .0
        .shortcut
        .lock()
        .map(|owner| owner.as_ref().is_none_or(|owner| owner.shutdown()))
        .unwrap_or(false);
    if let Ok(mut inner) = state.0.inner.lock() {
        inner.public.shortcut_status = if clean {
            ShortcutStatus::Unavailable
        } else {
            ShortcutStatus::Failed
        };
    }
    for surface in Surface::ALL {
        if let Some(window) = app.get_webview_window(surface.label()) {
            let _ = window.hide();
        }
    }
}
pub fn replace_cached_projection(
    app: &AppHandle,
    value: cache::CachedProjection,
) -> Result<(), String> {
    value.validate().map_err(str::to_owned)?;
    let service = app
        .try_state::<CompactAppState>()
        .ok_or("compact_unavailable")?
        .0
        .clone();
    {
        let _operation = service
            .operation
            .lock()
            .map_err(|_| "compact_unavailable")?;
        let mut inner = service.inner.lock().map_err(|_| "compact_unavailable")?;
        if inner.public.cached_projection == value {
            return Ok(());
        }
        inner.public.cached_projection = value;
        inner.bump()?;
    }
    service.reconcile()
}
impl CompactService {
    fn shortcut_status(&self, status: ShortcutStatus) {
        if self.exiting.load(Ordering::Acquire) {
            return;
        }
        if let Ok(mut inner) = self.inner.lock() {
            if inner.public.shortcut_status == status {
                return;
            }
            inner.public.shortcut_status = status;
            let _ = inner.bump();
        }
        self.emit();
    }
    fn install_shortcut(self: &Arc<Self>) {
        if self.exiting.load(Ordering::Acquire) {
            return;
        }
        let Ok(mut owned) = self.shortcut.lock() else {
            self.shortcut_status(ShortcutStatus::Failed);
            return;
        };
        if owned.is_some() {
            return;
        }
        let action_owner = Arc::downgrade(self);
        let status_owner = Arc::downgrade(self);
        let result = hotkey::Owner::start(
            Arc::new(move || {
                if let Some(service) = action_owner.upgrade() {
                    if !service.exiting.load(Ordering::Acquire) {
                        tauri::async_runtime::spawn_blocking(move || {
                            let _ = service.toggle_from_shortcut();
                        });
                    }
                }
            }),
            Arc::new(move |status| {
                if let Some(service) = status_owner.upgrade() {
                    service.shortcut_status(status);
                }
            }),
        );
        match result {
            Ok(owner) => *owned = Some(owner),
            Err("windows_required") => self.shortcut_status(ShortcutStatus::Unavailable),
            Err(_) => self.shortcut_status(ShortcutStatus::Failed),
        }
    }
    pub fn retry_shortcut(self: &Arc<Self>) -> Result<CompactUiState, String> {
        if self.exiting.load(Ordering::Acquire) {
            return failure("compact_stopped");
        }
        self.install_shortcut();
        let status = self
            .shortcut
            .lock()
            .map_err(|_| "compact_shortcut_unavailable")?
            .as_ref()
            .ok_or("compact_shortcut_unavailable")?
            .retry()
            .map_err(str::to_owned)?;
        self.shortcut_status(status);
        self.state()
    }
    fn toggle_from_shortcut(self: &Arc<Self>) -> Result<(), String> {
        let _operation = self.operation.lock().map_err(|_| "compact_unavailable")?;
        if self.exiting.load(Ordering::Acquire) {
            return failure("compact_stopped");
        }
        let preferences = {
            let inner = self.inner.lock().map_err(|_| "compact_unavailable")?;
            let mut preferences = inner.public.preferences.clone();
            preferences.enabled = inner.shortcut_should_enable();
            preferences
        };
        self.store.save(&preferences).map_err(|code| {
            self.mark_failure(code);
            code.to_owned()
        })?;
        {
            let mut inner = self.inner.lock().map_err(|_| "compact_unavailable")?;
            inner.apply_shortcut(preferences);
            inner.bump()?;
        }
        self.apply_locked()
    }
    pub fn state(&self) -> Result<CompactUiState, String> {
        self.inner
            .lock()
            .map(|inner| inner.public.clone())
            .map_err(|_| "compact_unavailable".into())
    }
    fn emit(&self) {
        if self.exiting.load(Ordering::Acquire) {
            return;
        }
        if let Ok(value) = self.state() {
            let _ = self.app.emit("compact-ui:changed", value);
        }
    }
    fn mark_failure(&self, code: &'static str) {
        // A failed show/place must never leave the requested visibility
        // masquerading as an acknowledged owned window.
        let actual = Surface::ALL
            .into_iter()
            .map(|surface| {
                let visible = self
                    .app
                    .get_webview_window(surface.label())
                    .map(|window| window.is_visible().ok())
                    .unwrap_or(Some(false));
                (surface, visible)
            })
            .collect::<Vec<_>>();
        if let Ok(mut inner) = self.inner.lock() {
            for (surface, visible) in actual {
                if let Some(visible) = visible {
                    inner.window_mut(surface).visible = visible;
                }
            }
            inner.public.failure_code = Some(code);
            let _ = inner.bump();
        }
        self.emit();
    }
    pub fn reconcile(self: &Arc<Self>) -> Result<(), String> {
        let _operation = self.operation.lock().map_err(|_| "compact_unavailable")?;
        self.apply_locked()
    }
    pub fn save(self: &Arc<Self>, patch: serde_json::Value) -> Result<CompactUiState, String> {
        let _operation = self.operation.lock().map_err(|_| "compact_unavailable")?;
        if self.exiting.load(Ordering::Acquire) {
            return failure("compact_stopped");
        }
        let (old, cache) = {
            let inner = self.inner.lock().map_err(|_| "compact_unavailable")?;
            (
                inner.public.preferences.clone(),
                inner.public.cached_projection.clone(),
            )
        };
        let mut value = serde_json::to_value(&old).map_err(|_| "compact_invalid_preferences")?;
        let patches = patch.as_object().ok_or("compact_invalid_preferences")?;
        for (key, field) in patches {
            if !value
                .as_object()
                .is_some_and(|object| object.contains_key(key))
            {
                return failure("compact_invalid_preferences");
            }
            value[key] = field.clone();
        }
        let prefs: Preferences =
            serde_json::from_value(value).map_err(|_| "compact_invalid_preferences")?;
        prefs.validate().map_err(str::to_owned)?;
        if let Some(items) = &prefs.items {
            for item in items.iter().filter(|item| item.r#type == ItemKind::Limit) {
                let provider = item.provider_id.as_deref().unwrap_or("");
                if !cache.accounts.iter().any(|account| {
                    canonical_provider(&account.provider_id) == canonical_provider(provider)
                        && item.account_id.as_ref().is_none_or(|id| account.id == *id)
                }) {
                    return failure("compact_account_unavailable");
                }
                if item.hidden_account_ids.iter().any(|id| {
                    !cache.accounts.iter().any(|account| {
                        &account.id == id
                            && canonical_provider(&account.provider_id)
                                == canonical_provider(provider)
                    })
                }) {
                    return failure("compact_account_unavailable");
                }
            }
        }
        if prefs != old {
            self.store.save(&prefs).map_err(str::to_owned)?;
            {
                let mut inner = self.inner.lock().map_err(|_| "compact_unavailable")?;
                inner.public.preferences = prefs;
                inner.public.side = inner.public.preferences.side;
                inner.public.failure_code = None;
                inner.edge_hidden = false;
                if !inner.public.preferences.enabled {
                    for surface in [Surface::EdgePeek, Surface::EdgeRail, Surface::EdgeCard] {
                        inner.window_mut(surface).visible = false;
                        inner.window_mut(surface).pinned = false;
                    }
                    inner.public.selected_item_id = None;
                    inner.hovered = None;
                    inner.hover_started = None;
                    inner.outside_started = None;
                    inner.edge_started = None;
                }
                inner.bump()?;
            }
            self.apply_locked()?;
        }
        self.state()
    }
    fn apply_locked(self: &Arc<Self>) -> Result<(), String> {
        let result = self.apply_plan_locked();
        if let Err(error) = &result {
            if !self.exiting.load(Ordering::Acquire) {
                let code = match error.as_str() {
                    "compact_display_unavailable" => "compact_display_unavailable",
                    "compact_display_identity_unknown" => "compact_display_identity_unknown",
                    "compact_pin_unconfirmed" => "compact_pin_unconfirmed",
                    "compact_visibility_unconfirmed" => "compact_visibility_unconfirmed",
                    "compact_geometry_invalid" => "compact_geometry_invalid",
                    "compact_geometry_unconfirmed" => "compact_geometry_unconfirmed",
                    "compact_display_events_unavailable" => "compact_display_events_unavailable",
                    _ => "compact_window_unavailable",
                };
                self.mark_failure(code);
            }
        }
        result
    }
    fn apply_plan_locked(self: &Arc<Self>) -> Result<(), String> {
        if self.exiting.load(Ordering::Acquire) {
            return failure("compact_stopped");
        }
        let screens = match windowing::screens(&self.app) {
            Ok(screens) => screens,
            Err(code) => {
                for surface in Surface::ALL {
                    if let Some(window) = self.app.get_webview_window(surface.label()) {
                        let _ = window.hide();
                    }
                }
                if let Ok(mut inner) = self.inner.lock() {
                    inner.layout = None;
                    inner.public.display_available = false;
                }
                return failure(code);
            }
        };
        let cursor = self
            .app
            .cursor_position()
            .ok()
            .map(|point| (point.x, point.y));
        let (rectangles, visible) = {
            let mut inner = self.inner.lock().map_err(|_| "compact_unavailable")?;
            inner.public.displays = screens
                .iter()
                .map(|screen| screen.display.clone())
                .collect();
            let selected = inner
                .public
                .preferences
                .display_id
                .as_ref()
                .and_then(|id| screens.iter().find(|screen| &screen.display.id == id));
            let follow = inner
                .anchor
                .or(cursor)
                .and_then(|(x, y)| screens.iter().find(|screen| screen.bounds.contains(x, y)))
                .or_else(|| screens.iter().find(|screen| screen.display.is_primary))
                .or_else(|| screens.first());
            let target = if inner.public.preferences.display_id.is_some() {
                selected
            } else {
                follow
            };
            inner.public.display_available = target.is_some();
            if target.is_some()
                && matches!(
                    inner.public.failure_code,
                    Some("compact_display_unavailable" | "compact_display_identity_unknown")
                )
            {
                inner.public.failure_code = None;
            }
            inner.public.resolved_items = inner.items();
            if !inner
                .public
                .resolved_items
                .iter()
                .any(|item| Some(&item.id) == inner.public.selected_item_id.as_ref())
            {
                inner.public.selected_item_id = None;
                inner.window_mut(Surface::EdgeCard).visible = false;
            }
            let mut rectangles = vec![];
            if let Some(screen) = target {
                let natural = 64. + inner.public.resolved_items.len() as f64 * 56.;
                let scale = geometry::fitting_scale(
                    inner.public.preferences.scale(),
                    natural,
                    (screen.work.height / screen.dpi - 16.).max(1.),
                );
                let height = (natural * scale * screen.dpi)
                    .min((screen.work.height - 16. * screen.dpi).max(1.));
                let capacity =
                    (((height / (scale * screen.dpi) - 64.).max(0.) / 56.).floor() as usize).max(1);
                inner.public.page_count =
                    inner.public.resolved_items.len().div_ceil(capacity).max(1);
                inner.public.page_index = inner.public.page_index.min(inner.public.page_count - 1);
                inner.public.scale = scale;
                inner.public.viewport_height = height / (scale * screen.dpi);
                inner.public.side = inner.public.preferences.side;
                let rail = geometry::rail(
                    screen.work,
                    inner.public.side,
                    inner.public.preferences.offset,
                    height,
                    scale,
                    screen.dpi,
                );
                let peek = geometry::peek(rail, screen.work, inner.public.side, scale, screen.dpi);
                let index = inner
                    .public
                    .selected_item_id
                    .as_ref()
                    .and_then(|id| {
                        inner
                            .public
                            .resolved_items
                            .iter()
                            .position(|item| &item.id == id)
                    })
                    .unwrap_or(inner.public.page_index * capacity);
                let local = index.saturating_sub(inner.public.page_index * capacity);
                let center = rail.y + (32. + local as f64 * 56. + 28.) * scale * screen.dpi;
                let card = geometry::card(
                    rail,
                    center,
                    440. * scale * screen.dpi,
                    screen.work,
                    inner.public.side,
                    scale,
                    screen.dpi,
                );
                inner.layout = Some(Layout {
                    rail,
                    peek,
                    card,
                    dpi: screen.dpi,
                    capacity,
                });
                if inner.public.preferences.enabled {
                    let expanded = !inner.edge_hidden
                        && (inner.window(Surface::EdgeRail).visible
                            || inner.public.preferences.mode == DockMode::Always);
                    inner.window_mut(Surface::EdgeRail).visible = expanded;
                    inner.window_mut(Surface::EdgePeek).visible = !expanded;
                    inner.window_mut(Surface::EdgeCard).visible =
                        expanded && inner.public.selected_item_id.is_some();
                }
                rectangles.extend([
                    (Surface::EdgePeek, peek),
                    (Surface::EdgeRail, rail),
                    (Surface::EdgeCard, card),
                ]);
            } else {
                inner.layout = None;
                for surface in [Surface::EdgePeek, Surface::EdgeRail, Surface::EdgeCard] {
                    inner.window_mut(surface).visible = false;
                }
                if inner.public.preferences.enabled {
                    inner.public.failure_code = Some("compact_display_unavailable");
                }
            }
            if let Some(screen) = follow {
                let anchor = inner
                    .anchor
                    .or(cursor)
                    .unwrap_or((screen.work.right(), screen.work.bottom()));
                let rect = geometry::popover(
                    screen.work,
                    anchor,
                    inner.window(Surface::Popover).collapsed,
                    screen.dpi,
                );
                rectangles.push((Surface::Popover, rect));
            } else {
                inner.window_mut(Surface::Popover).visible = false;
            }
            (rectangles, inner.public.windows.clone())
        };
        for state in visible {
            let existing = self.app.get_webview_window(state.surface.label());
            let watches_display = state.surface == Surface::EdgePeek
                && self
                    .inner
                    .lock()
                    .map(|inner| inner.public.preferences.enabled)
                    .unwrap_or(false);
            if existing.is_none() && !state.visible && !watches_display {
                continue;
            }
            let (window, created) =
                windowing::ensure(&self.app, state.surface).map_err(|code| {
                    self.mark_failure(code);
                    code.to_owned()
                })?;
            if created {
                self.bind_window(&window, state.surface);
            }
            if let Some((_, rect)) = rectangles
                .iter()
                .find(|(surface, _)| *surface == state.surface)
            {
                windowing::place(&window, *rect).map_err(str::to_owned)?;
            }
            let top = state.surface != Surface::Popover || state.pinned;
            window
                .set_always_on_top(top)
                .map_err(|_| "compact_window_unavailable")?;
            if window
                .is_always_on_top()
                .map_err(|_| "compact_window_unavailable")?
                != top
            {
                self.mark_failure("compact_pin_unconfirmed");
                return failure("compact_pin_unconfirmed");
            }
            let was_visible = window
                .is_visible()
                .map_err(|_| "compact_window_unavailable")?;
            let actual = windowing::set_visible(&window, state.visible).map_err(|code| {
                self.mark_failure(code);
                code.to_owned()
            })?;
            self.inner
                .lock()
                .map_err(|_| "compact_unavailable")?
                .window_mut(state.surface)
                .visible = actual;
            if state.surface == Surface::Popover && actual && !was_visible {
                window
                    .set_focus()
                    .map_err(|_| "compact_window_unavailable")?;
            }
        }
        {
            let mut inner = self.inner.lock().map_err(|_| "compact_unavailable")?;
            if matches!(
                inner.public.failure_code,
                Some(
                    "compact_window_unavailable"
                        | "compact_pin_unconfirmed"
                        | "compact_visibility_unconfirmed"
                        | "compact_geometry_invalid"
                        | "compact_geometry_unconfirmed"
                )
            ) {
                inner.public.failure_code = None;
            }
            inner.bump()?;
        }
        self.emit();
        self.ensure_hover();
        Ok(())
    }
    fn bind_window(self: &Arc<Self>, window: &tauri::WebviewWindow, surface: Surface) {
        let weak = Arc::downgrade(self);
        window.on_window_event(move |event| {
            let Some(service) = weak.upgrade() else {
                return;
            };
            let close = matches!(event, tauri::WindowEvent::CloseRequested { .. });
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
            }
            let defocus =
                surface == Surface::Popover && matches!(event, tauri::WindowEvent::Focused(false));
            if close || defocus {
                tauri::async_runtime::spawn_blocking(move || {
                    if defocus
                        && service
                            .app
                            .get_webview_window(surface.label())
                            .is_some_and(|window| window.is_focused().unwrap_or(false))
                    {
                        return;
                    }
                    let Ok(_operation) = service.operation.lock() else {
                        return;
                    };
                    {
                        let Ok(mut inner) = service.inner.lock() else {
                            return;
                        };
                        if defocus && inner.window(surface).pinned {
                            return;
                        }
                        inner.dismiss(surface);
                        let _ = inner.bump();
                    }
                    let _ = service.apply_locked();
                });
            }
        });
        let weak = Arc::downgrade(self);
        let callback = Arc::new(move || {
            let Some(service) = weak.upgrade() else {
                return;
            };
            tauri::async_runtime::spawn_blocking(move || {
                let _ = service.reconcile();
            });
        });
        if let Err(code) = windowing::install_display_listener(window, callback) {
            self.mark_failure(code);
        }
    }
    pub fn action(
        self: &Arc<Self>,
        surface: Surface,
        action: &str,
        item_id: Option<&str>,
    ) -> Result<CompactUiState, String> {
        let _operation = self.operation.lock().map_err(|_| "compact_unavailable")?;
        if self.exiting.load(Ordering::Acquire) {
            return failure("compact_stopped");
        }
        validate_action(surface, action, item_id).map_err(str::to_owned)?;
        let before = self.state()?;
        if action == "drag" {
            if !self
                .inner
                .lock()
                .map_err(|_| "compact_unavailable")?
                .window(surface)
                .visible
            {
                return failure("compact_action_unavailable");
            }
            let window = self
                .app
                .get_webview_window(surface.label())
                .ok_or("compact_window_unavailable")?;
            self.inner
                .lock()
                .map_err(|_| "compact_unavailable")?
                .dragging = true;
            if window.start_dragging().is_err() {
                self.inner
                    .lock()
                    .map_err(|_| "compact_unavailable")?
                    .dragging = false;
                return failure("compact_drag_unavailable");
            }
            self.ensure_hover();
            return self.state();
        }
        let mut navigate = None;
        {
            let mut inner = self.inner.lock().map_err(|_| "compact_unavailable")?;
            match action {
                "reveal" => {
                    if !inner.public.preferences.enabled || !inner.public.display_available {
                        return failure("compact_action_unavailable");
                    }
                    inner.edge_hidden = false;
                    inner.window_mut(Surface::EdgeRail).visible = true;
                    inner.edge_started = None;
                }
                "collapse" => {
                    if surface == Surface::Popover {
                        let window = inner.window_mut(surface);
                        window.collapsed = !window.collapsed;
                    } else {
                        inner.dismiss(Surface::EdgeRail);
                    }
                }
                "pin" | "unpin" => {
                    if !inner.window(surface).visible {
                        return failure("compact_action_unavailable");
                    }
                    inner.window_mut(surface).pinned = action == "pin";
                    inner.outside_started = None;
                }
                "close" => {
                    inner.dismiss(surface);
                }
                "select_item" => {
                    let id = item_id.ok_or("compact_invalid_item")?;
                    let item = inner
                        .public
                        .resolved_items
                        .iter()
                        .find(|item| item.id == id)
                        .cloned()
                        .ok_or("compact_invalid_item")?;
                    if !inner.window(Surface::EdgeRail).visible {
                        return failure("compact_action_unavailable");
                    }
                    inner.hovered = Some(id.into());
                    inner.hover_started = None;
                    inner.outside_started = None;
                    if item.r#type == ItemKind::Proxy {
                        navigate = Some("proxy");
                        inner.public.selected_item_id = None;
                    } else if item.metric == Some(Metric::Today) {
                        navigate = Some("home");
                        inner.public.selected_item_id = None;
                    } else if item.r#type == ItemKind::Limit
                        && item
                            .provider_id
                            .as_deref()
                            .map(canonical_provider)
                            .as_deref()
                            == Some("codex")
                    {
                        navigate = Some("accounts");
                        inner.public.selected_item_id = None;
                    } else {
                        if inner.public.selected_item_id.as_deref() != Some(id) {
                            inner.window_mut(Surface::EdgeCard).pinned = false;
                        }
                        inner.public.selected_item_id = Some(id.into());
                        inner.window_mut(Surface::EdgeRail).visible = true;
                        inner.window_mut(Surface::EdgeRail).pinned = true;
                    }
                }
                "page_next" => {
                    inner.public.page_index = (inner.public.page_index + 1)
                        .min(inner.public.page_count.saturating_sub(1));
                    inner.public.selected_item_id = None;
                    inner.window_mut(Surface::EdgeCard).pinned = false;
                    inner.hover_started = None;
                    inner.hovered = None;
                }
                "page_previous" => {
                    inner.public.page_index = inner.public.page_index.saturating_sub(1);
                    inner.public.selected_item_id = None;
                    inner.window_mut(Surface::EdgeCard).pinned = false;
                    inner.hover_started = None;
                    inner.hovered = None;
                }
                "open_workspace" => navigate = Some("home"),
                "open_accounts" => navigate = Some("accounts"),
                "open_running_tasks" => navigate = Some("tools"),
                "open_proxy" => navigate = Some("proxy"),
                "open_settings" => {}
                _ => return failure("compact_action_unavailable"),
            }
            inner.bump()?;
        }
        if navigate.is_some() {
            let mut inner = self.inner.lock().map_err(|_| "compact_unavailable")?;
            inner.window_mut(Surface::EdgeCard).pinned = false;
        }
        if let Err(error) = self.apply_locked() {
            // Failed native commands cannot acknowledge the requested pin or
            // collapse. Keep the prior interaction state and read visibility.
            if let Ok(mut inner) = self.inner.lock() {
                inner.public.windows = before.windows;
                inner.public.selected_item_id = before.selected_item_id;
                let _ = inner.bump();
            }
            // Restore an already-established layout when part of a multi-window
            // action failed; no preference or account data is mutated here.
            let _ = self.apply_plan_locked();
            self.mark_failure("compact_window_unavailable");
            return Err(error);
        }
        if let Some(page) = navigate {
            let main = self
                .app
                .get_webview_window("main")
                .ok_or("compact_workspace_unavailable")?;
            main.show()
                .and_then(|_| main.set_focus())
                .map_err(|_| "compact_workspace_unavailable")?;
            if !main
                .is_visible()
                .map_err(|_| "compact_workspace_unavailable")?
            {
                return failure("compact_workspace_unavailable");
            }
            self.app
                .emit_to(
                    "main",
                    "workspace:navigate",
                    if action == "open_running_tasks" {
                        serde_json::json!({"page":page,"toolTab":"tasks"})
                    } else {
                        serde_json::json!({"page":page})
                    },
                )
                .map_err(|_| "compact_workspace_unavailable")?;
        }
        if action == "open_settings" {
            tauri::async_runtime::block_on(crate::commands::settings::open_settings_window(
                self.app.clone(),
            ))
            .map_err(|_| "compact_settings_unavailable")?;
            if !self
                .app
                .get_webview_window("settings")
                .is_some_and(|window| window.is_visible().unwrap_or(false))
            {
                return failure("compact_settings_unavailable");
            }
        }
        self.state()
    }
    fn ensure_hover(self: &Arc<Self>) {
        if self.exiting.load(Ordering::Acquire)
            || self
                .hover_running
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .is_err()
        {
            return;
        }
        let needed = self
            .inner
            .lock()
            .map(|inner| {
                inner.public.preferences.enabled
                    && inner
                        .public
                        .windows
                        .iter()
                        .any(|window| window.surface != Surface::Popover && window.visible)
            })
            .unwrap_or(false);
        if !needed {
            self.hover_running.store(false, Ordering::Release);
            return;
        }
        let weak = Arc::downgrade(self);
        let result = std::thread::Builder::new()
            .name("compact-owned-hover".into())
            .spawn(move || loop {
                let Some(service) = weak.upgrade() else {
                    return;
                };
                if service.exiting.load(Ordering::Acquire) {
                    service.hover_running.store(false, Ordering::Release);
                    return;
                }
                let needed =
                    service
                        .inner
                        .lock()
                        .map(|inner| {
                            inner.public.preferences.enabled
                                && inner.layout.is_some()
                                && inner.public.windows.iter().any(|window| {
                                    window.surface != Surface::Popover && window.visible
                                })
                        })
                        .unwrap_or(false);
                if !needed {
                    service.hover_running.store(false, Ordering::Release);
                    if service
                        .inner
                        .lock()
                        .map(|inner| {
                            inner.public.preferences.enabled
                                && inner.public.windows.iter().any(|window| {
                                    window.surface != Surface::Popover && window.visible
                                })
                        })
                        .unwrap_or(false)
                    {
                        service.ensure_hover();
                    }
                    return;
                }
                let busy = service.hover_tick();
                drop(service);
                std::thread::sleep(std::time::Duration::from_millis(if busy {
                    50
                } else {
                    200
                }));
            });
        if result.is_err() {
            self.hover_running.store(false, Ordering::Release);
            self.mark_failure("compact_hover_unavailable");
        }
    }
    fn hover_tick(self: &Arc<Self>) -> bool {
        let Ok(_operation) = self.operation.try_lock() else {
            return true;
        };
        let Ok(point) = self.app.cursor_position() else {
            return false;
        };
        let now = Instant::now();
        let mut changed = false;
        let mut save_drag = None;
        let busy = {
            let Ok(mut inner) = self.inner.lock() else {
                return false;
            };
            let Some(layout) = inner.layout.clone() else {
                return false;
            };
            if inner.dragging {
                if windowing::left_button_down() {
                    return true;
                }
                if let Some(window) = self.app.get_webview_window(Surface::EdgeRail.label()) {
                    if let (Ok(position), Ok(size)) = (window.outer_position(), window.outer_size())
                    {
                        let current = Rect {
                            x: position.x as f64,
                            y: position.y as f64,
                            width: size.width as f64,
                            height: size.height as f64,
                        };
                        if let Ok(screens) = windowing::screens(&self.app) {
                            let center = (
                                current.x + current.width / 2.,
                                current.y + current.height / 2.,
                            );
                            if let Some(screen) = screens.iter().min_by(|a, b| {
                                a.bounds
                                    .distance_squared(center.0, center.1)
                                    .total_cmp(&b.bounds.distance_squared(center.0, center.1))
                            }) {
                                let (side, offset) = geometry::placement_after_drag(
                                    current,
                                    screen.work,
                                    screen.dpi,
                                );
                                let mut prefs = inner.public.preferences.clone();
                                prefs.side = side;
                                prefs.offset = offset;
                                prefs.display_id = Some(screen.display.id.clone());
                                save_drag = Some(prefs);
                            }
                        }
                    }
                }
                inner.dragging = false;
                changed = true;
            }
            if !inner.window(Surface::EdgeRail).visible {
                let side = inner.public.side;
                let zone = Rect {
                    x: if side == Side::Right {
                        layout.peek.right() - 24. * layout.dpi
                    } else {
                        layout.peek.x
                    },
                    width: 24. * layout.dpi,
                    ..layout.peek
                };
                if zone.contains(point.x, point.y) {
                    let started = *inner.edge_started.get_or_insert(now);
                    if now.duration_since(started).as_millis() >= 140 {
                        inner.edge_hidden = false;
                        inner.window_mut(Surface::EdgeRail).visible = true;
                        inner.edge_started = None;
                        changed = true;
                    }
                } else {
                    inner.edge_started = None;
                }
            } else {
                let over_rail = layout.rail.contains(point.x, point.y);
                let card_visible = inner.window(Surface::EdgeCard).visible;
                let over_card = card_visible && layout.card.contains(point.x, point.y);
                let crossing = card_visible
                    && geometry::corridor_contains(
                        point.x,
                        point.y,
                        layout.rail,
                        layout.card,
                        layout.dpi,
                    );
                if over_rail {
                    let cell =
                        ((point.y - layout.rail.y) / (inner.public.scale * layout.dpi) - 32.) / 56.;
                    let index = (cell >= 0.)
                        .then_some(cell.floor() as usize)
                        .filter(|index| *index < layout.capacity)
                        .map(|index| index + inner.public.page_index * layout.capacity);
                    let hovered = index
                        .and_then(|index| inner.public.resolved_items.get(index))
                        .map(|item| item.id.clone());
                    if hovered != inner.hovered {
                        inner.hovered = hovered;
                        inner.hover_started = inner.hovered.as_ref().map(|_| now);
                    }
                    if !inner.window(Surface::EdgeCard).pinned
                        && inner
                            .hover_started
                            .is_some_and(|started| now.duration_since(started).as_millis() >= 70)
                        && inner.public.selected_item_id != inner.hovered
                    {
                        inner.public.selected_item_id = inner.hovered.clone();
                        changed = true;
                    }
                } else {
                    inner.hovered = None;
                    inner.hover_started = None;
                }
                if over_rail || over_card || crossing {
                    inner.outside_started = None;
                } else if !inner.window(Surface::EdgeCard).pinned
                    && (card_visible
                        || (inner.public.preferences.mode == DockMode::AutoHide
                            && !inner.window(Surface::EdgeRail).pinned))
                {
                    let started = *inner.outside_started.get_or_insert(now);
                    if now.duration_since(started).as_millis() >= 320 {
                        inner.public.selected_item_id = None;
                        inner.window_mut(Surface::EdgeCard).visible = false;
                        if inner.public.preferences.mode == DockMode::AutoHide
                            && !inner.window(Surface::EdgeRail).pinned
                        {
                            inner.window_mut(Surface::EdgeRail).visible = false;
                        }
                        inner.outside_started = None;
                        changed = true;
                    }
                } else {
                    inner.outside_started = None;
                }
            }
            inner.edge_started.is_some()
                || inner.hover_started.is_some()
                || inner.outside_started.is_some()
                || inner.dragging
        };
        if let Some(prefs) = save_drag {
            match self.store.save(&prefs) {
                Ok(()) => {
                    if let Ok(mut inner) = self.inner.lock() {
                        inner.public.preferences = prefs;
                    }
                }
                Err(code) => self.mark_failure(code),
            }
        }
        if changed {
            if let Ok(mut inner) = self.inner.lock() {
                let _ = inner.bump();
            }
            let _ = self.apply_locked();
        }
        busy
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn inner() -> Inner {
        Inner {
            public: CompactUiState {
                revision: 0,
                windows: Surface::ALL
                    .into_iter()
                    .map(|surface| WindowState {
                        surface,
                        visible: false,
                        pinned: false,
                        collapsed: false,
                    })
                    .collect(),
                selected_item_id: None,
                resolved_items: vec![],
                page_index: 0,
                page_count: 1,
                display_available: true,
                side: Side::Right,
                scale: 1.,
                viewport_height: 640.,
                preferences: Preferences::default(),
                displays: vec![],
                failure_code: None,
                shortcut_status: ShortcutStatus::Unavailable,
                cached_projection: cache::CachedProjection::default(),
            },
            anchor: None,
            layout: None,
            edge_started: None,
            hover_started: None,
            hovered: None,
            outside_started: None,
            dragging: false,
            edge_hidden: false,
        }
    }
    fn account(id: &str, provider: &str, available: bool) -> cache::Account {
        cache::Account {
            id: id.into(),
            provider_id: provider.into(),
            label: "Synthetic account".into(),
            logged_in: true,
            active: None,
            observed_at: Some(1),
            available,
            reason_code: None,
            plan_type: None,
            windows: vec![cache::QuotaWindow {
                id: "window".into(),
                label: "Window".into(),
                used_percent: Some(10.),
                resets_at: None,
            }],
            credits_usd: None,
            credit_points: None,
            reset_cards: None,
        }
    }
    #[test]
    fn automatic_order_uses_only_available_known_accounts_and_keeps_three_providers() {
        let mut inner = inner();
        inner.public.cached_projection.accounts = vec![
            account("1", "kimi", true),
            account("2", "codex", true),
            account("3", "claude_code", true),
            account("4", "claude-code", true),
            account("5", "grok", true),
            account("6", "opencode", false),
        ];
        assert_eq!(
            inner
                .items()
                .iter()
                .map(|item| item.id.as_str())
                .collect::<Vec<_>>(),
            vec![
                "proxy",
                "stat:today",
                "limit:claude",
                "limit:codex",
                "limit:kimi",
                "stat:liveRate"
            ]
        );
        inner.public.preferences.items = Some(vec![]);
        assert!(inner.items().is_empty());
        inner.public.preferences.items = Some(vec![Item::stat(Metric::AllTime), Item::proxy()]);
        assert_eq!(
            inner
                .items()
                .iter()
                .map(|item| item.id.as_str())
                .collect::<Vec<_>>(),
            vec!["stat:allTime", "proxy"]
        );
    }
    #[test]
    fn dismissing_an_always_visible_rail_keeps_preference_but_releases_its_detail_latch() {
        let mut inner = inner();
        inner.public.preferences.enabled = true;
        inner.public.preferences.mode = DockMode::Always;
        for surface in [Surface::EdgeRail, Surface::EdgeCard] {
            inner.window_mut(surface).visible = true;
            inner.window_mut(surface).pinned = true;
        }
        inner.public.selected_item_id = Some("stat:month".into());
        inner.hover_started = Some(Instant::now());
        inner.dismiss(Surface::EdgeRail);
        assert!(inner.edge_hidden);
        assert!(inner.public.preferences.enabled);
        assert_eq!(inner.public.preferences.mode, DockMode::Always);
        assert!(!inner.window(Surface::EdgeRail).visible);
        assert!(!inner.window(Surface::EdgeCard).visible);
        assert!(!inner.window(Surface::EdgeCard).pinned);
        assert!(inner.public.selected_item_id.is_none());
        assert!(inner.hover_started.is_none());
    }
    #[test]
    fn automatic_items_accept_a_verified_literal_balance_without_inventing_a_percentage() {
        let mut inner = inner();
        let mut claude = account("claude-balance", "claude", true);
        claude.windows.clear();
        claude.credits_usd = Some(0.);
        inner.public.cached_projection.accounts = vec![claude];
        assert!(inner.items().iter().any(|item| item.id == "limit:claude"));
        inner.public.cached_projection.accounts[0].credits_usd = None;
        assert!(!inner.items().iter().any(|item| item.id == "limit:claude"));
        inner.public.cached_projection.accounts[0].credits_usd = Some(12.5);
        inner.public.cached_projection.accounts[0].available = false;
        assert!(!inner.items().iter().any(|item| item.id == "limit:claude"));
    }
    #[test]
    fn shortcut_reveals_and_pins_a_hidden_dock_then_disables_only_a_visible_dock() {
        let mut inner = inner();
        inner.public.preferences.items = Some(vec![Item::stat(Metric::Month)]);
        for enabled in [false, true] {
            inner.public.preferences.enabled = enabled;
            inner.window_mut(Surface::EdgeRail).visible = false;
            assert!(inner.shortcut_should_enable());
        }
        let mut preferences = inner.public.preferences.clone();
        preferences.enabled = inner.shortcut_should_enable();
        inner.apply_shortcut(preferences);
        assert!(inner.window(Surface::EdgeRail).visible);
        assert!(inner.window(Surface::EdgeRail).pinned);
        assert!(!inner.shortcut_should_enable());
        let mut preferences = inner.public.preferences.clone();
        preferences.enabled = inner.shortcut_should_enable();
        inner.apply_shortcut(preferences);
        assert!(!inner.public.preferences.enabled);
        assert!(!inner.window(Surface::EdgeRail).visible);
        assert!(!inner.window(Surface::EdgeRail).pinned);
        assert_eq!(
            inner.public.preferences.items.as_ref().unwrap()[0].id,
            "stat:month"
        );
    }
}
