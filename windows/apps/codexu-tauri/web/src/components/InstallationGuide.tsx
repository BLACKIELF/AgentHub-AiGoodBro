import { useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { useI18n } from '../i18n/I18nProvider';
import { parseSetupContext, type SetupContext } from '../utils/setupContext';
import { WorkspaceGuide, type GuideDestination } from './WorkspaceGuide';

export function InstallationGuide({ onAccounts, onOpenSection }: { onAccounts: () => void; onOpenSection?: (section: Exclude<GuideDestination, 'accounts'>) => void | Promise<void> }) {
  const { language } = useI18n(), text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const [state, setState] = useState<SetupContext | null>(null), [audience, setAudience] = useState<'new' | 'returning' | null>(null), [busy, setBusy] = useState(false), [error, setError] = useState(false);
  const alive = useRef(false), serial = useRef(0), pending = useRef(false), dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    alive.current = true; let release: (() => void) | undefined;
    const read = async () => { const id = ++serial.current; try { const next = parseSetupContext(await invoke('get_setup_context')); if (alive.current && id === serial.current && !pending.current) { setState(next); setAudience(next.audience); setError(false); } } catch { /* An unknown installation event cannot trigger onboarding. */ } };
    void listen('setup-context:changed', () => { if (!pending.current) void read(); }).then(fn => { if (alive.current) release = fn; else fn(); }).catch(() => {}); void read();
    return () => { alive.current = false; serial.current++; release?.(); };
  }, []);
  useEffect(() => { if (state?.shouldPresent && dialog.current && !dialog.current.open) dialog.current.showModal(); else if (!state?.shouldPresent) dialog.current?.close(); }, [state?.shouldPresent]);
  const finish = async (outcome: 'completed' | 'deferred') => {
    if (!state?.eventId || pending.current || outcome === 'completed' && !audience) return;
    pending.current = true; serial.current++; setBusy(true); setError(false);
    try { const next = parseSetupContext(await invoke('update_setup_onboarding', { eventId: state.eventId, audience, outcome })); if (alive.current) { setState(next); if (outcome === 'completed') onAccounts(); } }
    catch { if (alive.current) setError(true); }
    finally { pending.current = false; if (alive.current) setBusy(false); }
  };
  if (!state?.shouldPresent) return <WorkspaceGuide onOpen={async section => { if (section === 'accounts') onAccounts(); else if (onOpenSection) await onOpenSection(section); else if (section === 'settings') await invoke('open_settings_window'); else throw Error('guide_navigation_unavailable'); }} />;
  return <dialog ref={dialog} className="installation-guide glass-panel" aria-label={text('欢迎使用 AiGoodBro', 'Welcome to AiGoodBro')} onCancel={event => { event.preventDefault(); if (!busy) void finish('deferred'); }}>
    <h1>{text('欢迎使用 AiGoodBro', 'Welcome to AiGoodBro')}</h1><p>{text('在这里连接已有账号、查看额度与用量。', 'Connect existing accounts and view quota and usage here.')}</p>
    <fieldset disabled={busy || state.audience !== null}><legend>{text('选择适合你的开始方式', 'Choose how to begin')}</legend><label><input type="radio" name="setup-audience" checked={audience === 'new'} onChange={() => setAudience('new')} />{text('第一次使用', 'New user')}</label><label><input type="radio" name="setup-audience" checked={audience === 'returning'} onChange={() => setAudience('returning')} />{text('已有账号与配置', 'Returning user')}</label></fieldset>
    {audience && <p>{audience === 'new' ? text('前往账号页，使用“添加账号指引”或关联已有目录。连接后再读取额度；未读取的用量会保留为未知。', 'Open Accounts and use Add account guide or link an existing directory. Read quota after connecting; unread values remain unknown.') : text('前往账号页核对已有账号。可以继续使用已安装的 Codex、Claude 与现有目录；打开应用不会自动切换登录身份。', 'Review existing accounts in Accounts. Reuse your installed Codex, Claude and existing directories; opening the app does not switch identities.')}</p>}
    {error && <p role="alert">{text('引导进度未保存，请重试。', 'Guide progress could not be saved. Retry.')}</p>}
    <footer><button className="glass-button" disabled={busy} onClick={() => void finish('deferred')}>{text('稍后设置', 'Set up later')}</button><button className="glass-button-solid" disabled={busy || !audience} onClick={() => void finish('completed')}>{text('进入账号页', 'Open Accounts')}</button></footer>
  </dialog>;
}
