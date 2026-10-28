import { useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { Download, ExternalLink, RefreshCw, X } from 'lucide-react';
import { useI18n } from '../i18n/I18nProvider';
import { parseAppUpdateState, type AppUpdateCommand, type AppUpdateState } from '../utils/appUpdate';

export function AppUpdatePanel() {
  const { language } = useI18n();
  const text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const [state, setState] = useState<AppUpdateState>({ phase: 'idle' });
  const [pending, setPending] = useState<AppUpdateCommand | null>(null);
  const alive = useRef(false), generation = useRef(0);
  const pendingOperation = useRef<{ command: AppUpdateCommand; token: object } | null>(null);
  const apply = (raw: unknown) => {
    try { setState(parseAppUpdateState(raw)); }
    catch { setState(previous => ({ phase: 'failed', info: previous.info, error_code: 'invalid_response' })); }
  };
  useEffect(() => {
    alive.current = true;
    const epoch = ++generation.current;
    let disposed = false;
    let unlisten: (() => void) | undefined;
    async function initialize() {
      try {
        const release = await listen('app-update:changed', event => {
          if (!disposed && alive.current) { generation.current++; apply(event.payload); }
        });
        if (disposed) { release(); return; }
        unlisten = release;
      } catch { /* The initial read and explicit commands can still report state. */ }
      if (disposed) return;
      try {
        const raw = await invoke('get_app_update_state');
        if (!disposed && alive.current && epoch === generation.current) apply(raw);
      } catch {
        if (!disposed && alive.current && epoch === generation.current) setState({ phase: 'failed', error_code: 'unavailable' });
      }
    }
    void initialize();
    return () => { disposed = true; alive.current = false; generation.current++; unlisten?.(); };
  }, []);

  async function run(command: AppUpdateCommand) {
    // Cancellation may interrupt an outstanding download command. Other actions
    // remain serialized, and an old completion cannot overwrite a newer event.
    if (pendingOperation.current && (command !== 'cancel_app_update' || pendingOperation.current.command === command)) return;
    const epoch = ++generation.current;
    const token = {};
    pendingOperation.current = { command, token }; setPending(command);
    try {
      const raw = await invoke(command);
      if (alive.current && epoch === generation.current) apply(raw);
    } catch {
      if (alive.current && epoch === generation.current) setState(previous => ({ phase: 'failed', info: previous.info, error_code: 'operation_failed' }));
    } finally {
      if (alive.current && pendingOperation.current?.token === token) { pendingOperation.current = null; setPending(null); }
    }
  }

  const info = state.info;
  const working = ['checking', 'downloading', 'verifying', 'opening'].includes(state.phase);
  const busy = working || pending !== null || state.phase === 'installer_opened';
  const messages = {
    idle: text('检查是否有可用更新。', 'Check for available updates.'),
    checking: text('正在检查更新…', 'Checking for updates…'),
    available: text('发现新版本。', 'A new version is available.'),
    up_to_date: text('当前版本已是最新。', 'This version is up to date.'),
    downloading: text('正在下载安装包…', 'Downloading the installer…'),
    verifying: text('正在校验安装包，请稍候…', 'Verifying the installer…'),
    downloaded: text('安装包已下载并通过校验。', 'The installer is downloaded and verified.'),
    cancelled: text('更新操作已取消。', 'The update operation was cancelled.'),
    failed: text('未能完成更新操作，请重试。', 'The update operation could not complete. Try again.'),
    opening: text('正在打开安装包…', 'Opening the installer…'),
    installer_opened: text('安装包已打开，请在 Windows 安装窗口中继续。', 'The installer was opened. Continue in the Windows installer window.'),
  };
  return <section className="app-update-panel border-t border-theme mt-4 pt-4 space-y-3" aria-label={text('应用更新', 'App updates')} data-update-phase={state.phase}>
    <div className="flex items-center justify-between gap-3">
      <h3 className="text-sm font-semibold text-primary">{text('应用更新', 'App updates')}</h3>
      <button type="button" className="icon-action" aria-label={text('检查更新', 'Check for updates')} title={text('检查更新', 'Check for updates')}
        disabled={busy} onClick={() => void run('check_app_update')}><RefreshCw size={14} aria-hidden="true" className={state.phase === 'checking' || pending === 'check_app_update' ? 'animate-spin' : ''} /></button>
    </div>
    {info && <p className="text-xs text-secondary">{text('当前版本 ', 'Current version ')}{info.current_version}
      {info.available_version && <> · {text('可用版本 ', 'Available version ')}{info.available_version}</>}
    </p>}
    <p role="status" className={`text-xs ${state.phase === 'failed' ? 'text-status-warn' : 'text-secondary'}`}>{pending === 'check_app_update' && state.phase !== 'checking' ? messages.checking : messages[state.phase]}</p>
    {info?.published_at && <p className="text-xs text-tertiary">{text('发布时间 ', 'Published ')}{new Date(info.published_at).toLocaleDateString(language === 'zh-Hans' ? 'zh-CN' : 'en-GB')}</p>}
    {info?.asset_name && <p className="text-xs text-tertiary break-words">{info.asset_name}{info.asset_size ? ` · ${(info.asset_size / 1024 / 1024).toFixed(1)} MB` : ''}</p>}
    {state.phase === 'available' && info && !info.can_download && <p className="text-xs text-secondary">{text('此版本没有适用于当前 Windows 平台的安装包。', 'This release has no installer available for this Windows platform.')}</p>}
    <div className="flex flex-wrap gap-2">
      {state.phase === 'available' && info?.can_download && <button type="button" className="glass-button-solid rounded-lg px-3 py-2 text-xs inline-flex items-center gap-2" disabled={busy} onClick={() => void run('download_app_update')}><Download size={14} />{text('下载更新', 'Download update')}</button>}
      {state.phase === 'downloaded' && <button type="button" className="glass-button-solid rounded-lg px-3 py-2 text-xs inline-flex items-center gap-2" disabled={busy} onClick={() => void run('open_app_update')}><ExternalLink size={14} />{text('打开安装包', 'Open installer')}</button>}
      {(['checking', 'downloading', 'verifying'].includes(state.phase) || pending === 'download_app_update' || pending === 'check_app_update') && <button type="button" className="glass-button rounded-lg px-3 py-2 text-xs inline-flex items-center gap-2" disabled={pending === 'cancel_app_update'} onClick={() => void run('cancel_app_update')}><X size={14} />{text('取消', 'Cancel')}</button>}
    </div>
    {info?.release_notes && <details className="text-xs text-secondary"><summary className="cursor-pointer">{text('更新内容', 'Release notes')}</summary><p className="whitespace-pre-wrap break-words mt-2 max-h-52 overflow-auto">{info.release_notes}</p></details>}
  </section>;
}
