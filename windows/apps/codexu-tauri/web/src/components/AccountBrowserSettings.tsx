import { useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { Globe } from 'lucide-react';
import { useI18n } from '../i18n/I18nProvider';
import { parseBrowserSettings, type BrowserMode, type BrowserSettings } from '../utils/accountBrowser';
import './AccountActions.css';

function BrowserDialog({ profileId, profileLabel, onClose, onChanged }: { profileId: string; profileLabel: string; onClose: () => void; onChanged?: (settings: BrowserSettings) => void }) {
  const { language } = useI18n(), text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const [settings, setSettings] = useState<BrowserSettings | null>(null), [mode, setMode] = useState<BrowserMode>('systemDefault'), [directory, setDirectory] = useState(''), [busy, setBusy] = useState(false), [error, setError] = useState(''), [saved, setSaved] = useState(false);
  const dialog = useRef<HTMLDialogElement>(null), alive = useRef(false), pending = useRef(false);
  const apply = (value: BrowserSettings) => { setSettings(value); setMode(value.mode); setDirectory(value.profileDirectory ?? ''); };
  async function run(save: boolean) {
    if (pending.current) return; pending.current = true; setBusy(true); setError(''); setSaved(false);
    try {
      const result = parseBrowserSettings(await invoke(save ? 'set_account_browser_settings' : 'get_account_browser_settings', { profileId, ...(save ? { mode, profileDirectory: mode === 'existingChrome' ? directory : null } : {}) }), profileId);
      if (alive.current) { apply(result); if (save) { setSaved(true); onChanged?.(result); } }
    } catch (failure) { if (alive.current) { const code = typeof failure === 'string' ? failure : ''; setError(code === 'browser_chrome_unavailable' ? text('未找到 Chrome，请安装后重新读取。', 'Chrome was not found. Install it, then read again.') : code === 'browser_profile_unavailable' ? text('所选 Chrome 个人资料已不可用，请重新读取。', 'The selected Chrome profile is unavailable. Read it again.') : text('浏览器设置未完成，原设置已保留。', 'Browser settings did not complete. The previous setting is retained.')); } }
    finally { pending.current = false; if (alive.current) setBusy(false); }
  }
  useEffect(() => { alive.current = true; const previous = document.activeElement; dialog.current?.showModal(); void run(false); return () => { alive.current = false; dialog.current?.close(); if (previous instanceof HTMLElement && previous.isConnected) previous.focus(); }; }, []);
  const valid = !!settings && (mode === 'systemDefault' || settings.chromeAvailable) && (mode !== 'existingChrome' || settings.profiles.some(row => row.directoryName === directory));
  return <dialog ref={dialog} className="managed-switch-dialog account-action-dialog" aria-label={text('账号浏览器', 'Account browser')} onCancel={event => { event.preventDefault(); if (!busy) onClose(); }}>
    <header><h2>{text('账号浏览器', 'Account browser')} · {profileLabel}</h2><button type="button" className="glass-button proxy-action" disabled={busy} onClick={onClose}>{text('关闭', 'Close')}</button></header>
    {settings && <><label className="block space-y-1">{text('登录页打开方式', 'Open login page with')}<select aria-label={text('登录页打开方式', 'Open login page with')} className="w-full rounded-lg border border-theme bg-surface-inset p-2 text-primary" disabled={busy} value={mode} onChange={event => { setMode(event.target.value as BrowserMode); setSaved(false); }}><option value="systemDefault">{text('系统默认浏览器', 'System default browser')}</option><option value="dedicatedChrome">{text('此账号专用 Chrome', 'Dedicated Chrome for this account')}</option><option value="existingChrome">{text('已有 Chrome 个人资料', 'Existing Chrome profile')}</option></select></label>
      {mode === 'existingChrome' && <label className="block space-y-1">{text('Chrome 个人资料', 'Chrome profile')}<select aria-label={text('Chrome 个人资料', 'Chrome profile')} className="w-full rounded-lg border border-theme bg-surface-inset p-2 text-primary" disabled={busy} value={directory} onChange={event => { setDirectory(event.target.value); setSaved(false); }}><option value="">{text('选择个人资料', 'Choose a profile')}</option>{directory && !settings.profiles.some(row => row.directoryName === directory) && <option value={directory}>{directory} · {text('当前不可用', 'Unavailable')}</option>}{settings.profiles.map(row => <option key={row.directoryName} value={row.directoryName}>{row.displayName} · {row.directoryName}</option>)}</select></label>}
      <p className="text-xs text-secondary">{mode === 'dedicatedChrome' ? text('首次打开登录页时创建此账号独立的 Chrome 资料，不复制其他浏览器登录状态。', 'Creates a separate Chrome profile for this account when you open the login page. Other browser sessions are not copied.') : mode === 'existingChrome' ? text('使用你选择的现有 Chrome 资料打开官方登录页；账号身份仍以登录验证结果为准。', 'Uses your chosen Chrome profile for the official login page. The verified sign-in determines the account identity.') : text('使用系统默认浏览器打开官方登录页。', 'Opens the official login page in your system default browser.')}</p>
      {settings.profileScanIssue && <p role="status" className="text-status-warn">{text('现有 Chrome 个人资料读取失败，可改用系统默认或账号专用 Chrome。', 'Existing Chrome profiles could not be read. You can use the system default or dedicated Chrome.')}</p>}
      {!settings.chromeAvailable && mode !== 'systemDefault' && <p role="status" className="text-status-warn">{text('未找到 Chrome。安装后重新读取即可选择。', 'Chrome was not found. Read again after installing it.')}</p>}
    </>}
    {error && <p role="alert" className="text-status-warn">{error}</p>}{saved && <p role="status">{text('已保存，下次打开登录页时使用。', 'Saved for the next time you open the login page.')}</p>}
    <div className="flex gap-2"><button type="button" className="glass-button proxy-action" disabled={busy} onClick={() => void run(false)}>{text('重新读取', 'Read again')}</button><button type="button" className="glass-button-solid proxy-action" disabled={busy || !valid} onClick={() => void run(true)}>{text('保存浏览器设置', 'Save browser settings')}</button></div>
  </dialog>;
}
function AccountBrowserContent(props: { profileId: string; profileLabel: string; onChanged?: (settings: BrowserSettings) => void }) {
  const { language } = useI18n(), [open, setOpen] = useState(false);
  return <><button type="button" className="glass-button proxy-action" onClick={() => setOpen(true)}><Globe size={14} />{language === 'zh-Hans' ? '浏览器设置' : 'Browser settings'}</button>{open && <BrowserDialog {...props} onClose={() => setOpen(false)} />}</>;
}
export function AccountBrowserSettings(props: { profileId: string; profileLabel: string; onChanged?: (settings: BrowserSettings) => void }) { return <AccountBrowserContent key={props.profileId} {...props} />; }
