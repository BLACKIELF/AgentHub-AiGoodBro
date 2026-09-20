import { useCallback, useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { open } from '@tauri-apps/plugin-dialog';
import { useI18n } from '../i18n/I18nProvider';

type Profile = { id: string; label: string; selected: boolean };

export function ProfilesPanel({ onSourceChange }: { onSourceChange: () => void }) {
  const { language } = useI18n();
  const text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const [profiles, setProfiles] = useState<Profile[]>([]);
  const [busy, setBusy] = useState(false);
  const inFlight = useRef(false);
  const request = useRef(0);
  const [error, setError] = useState(false);
  const [editing, setEditing] = useState<string | null>(null);
  const [label, setLabel] = useState('');
  const [removing, setRemoving] = useState<string | null>(null);
  const reload = useCallback(async () => {
    const epoch = ++request.current;
    try {
      const rows = await invoke<Profile[]>('list_profiles');
      if (epoch === request.current) { setProfiles(rows); setError(false); }
    } catch { if (epoch === request.current) setError(true); }
  }, []);
  useEffect(() => {
    void reload();
    let cancelled = false;
    let unlisten: (() => void) | undefined;
    void listen('profiles:changed', () => { void reload(); }).then(fn => {
      if (cancelled) fn(); else unlisten = fn;
    }).catch(() => setError(true));
    return () => { cancelled = true; request.current++; unlisten?.(); };
  }, [reload]);

  async function perform(action: Record<string, unknown>) {
    if (inFlight.current) return;
    inFlight.current = true;
    setBusy(true); setError(false); request.current++;
    try {
      let actual = action;
      if (action.kind === 'link') {
        const root = await open({ directory: true, multiple: false });
        if (!root) return;
        actual = { ...action, root };
      }
      await invoke<Profile[]>('update_profile', { action: actual });
      // Do not clear drafts or close confirmation on failure.
      setEditing(null); setRemoving(null); setLabel('');
      await reload();
      if (action.kind === 'view') onSourceChange();
    } catch { setError(true); }
    finally { inFlight.current = false; setBusy(false); }
  }

  return (
    <section className="glass-panel p-4 space-y-3" aria-label={text('账号目录', 'Account directories')}>
      <header className="flex items-center justify-between gap-3">
        <h2 className="text-sm font-semibold text-primary">{text('账号目录', 'Account directories')}</h2>
        <button className="glass-button px-3 py-1.5 text-sm" disabled={busy} onClick={() => { setEditing('new'); setLabel(''); setRemoving(null); }}>
          {text('关联已有目录', 'Link existing directory')}
        </button>
      </header>
      <p className="text-xs text-secondary">{text('切换查看不同目录的用量，不切换 Codex 登录身份；目录存在不代表身份已验证。', 'View usage from different directories; does not switch Codex login. A linked folder is not a verified identity.')}</p>
      {profiles.length === 0 && <p className="text-sm text-tertiary">{text('尚未关联账号目录，仍显示设置中的数据来源。', 'No linked directories. The configured data source is still displayed.')}</p>}
      <ul className="space-y-2">
        {profiles.map((profile, index) => (
          <li key={profile.id} data-testid={'profile-' + profile.id} className="flex flex-wrap items-center gap-2 border border-theme rounded-xl p-2">
            <span className="flex-1 text-sm text-primary">{profile.label}</span>
            <button className="glass-button px-2 py-1 text-xs" disabled={busy || profile.selected} onClick={() => void perform({ kind: 'view', id: profile.id })}>{profile.selected ? text('正在查看', 'Viewing') : text('查看用量', 'View usage')}</button>
            <button className="glass-button px-2 py-1 text-xs" disabled={busy} onClick={() => { setEditing(profile.id); setLabel(profile.label); setRemoving(null); }}>{text('备注', 'Rename')}</button>
            <button className="glass-button px-2 py-1 text-xs" aria-label={text('上移', 'Move up')} disabled={busy || index === 0} onClick={() => void perform({ kind: 'move', id: profile.id, delta: -1 })}>↑</button>
            <button className="glass-button px-2 py-1 text-xs" aria-label={text('下移', 'Move down')} disabled={busy || index === profiles.length - 1} onClick={() => void perform({ kind: 'move', id: profile.id, delta: 1 })}>↓</button>
            <button className="glass-button px-2 py-1 text-xs" disabled={busy} onClick={() => { setRemoving(profile.id); setEditing(null); }}>{text('移除', 'Remove')}</button>
          </li>
        ))}
      </ul>
      {editing !== null && <form className="flex flex-wrap gap-2" onSubmit={event => { event.preventDefault(); void perform(editing === 'new' ? { kind: 'link', label: label.trim() } : { kind: 'rename', id: editing, label: label.trim() }); }}>
        <input className="rounded-lg border border-theme bg-surface-inset px-3 py-2 text-sm text-primary" aria-label={text('账号备注（不填邮箱）', 'Alias (not email)')} placeholder={text('账号备注（不填邮箱）', 'Alias (not email)')} value={label} maxLength={64} disabled={busy} onChange={e => setLabel(e.target.value)} />
        <button className="glass-button-solid px-3 py-2 text-sm" disabled={busy || !label.trim() || /[@/\\:\x00-\x1f]/.test(label)} type="submit">{editing === 'new' ? text('选择目录并关联', 'Choose directory and link') : text('保存', 'Save')}</button>
        <button className="glass-button px-3 py-2 text-sm" type="button" disabled={busy} onClick={() => setEditing(null)}>{text('取消', 'Cancel')}</button>
      </form>}
      {removing && <div role="group" aria-label={text('确认移除', 'Confirm removal')} className="flex flex-wrap items-center gap-2 text-sm">
        <span>{text('只移除这条关联，不删除目录或凭据，也不注销登录。', 'Remove the link only. Keep files, credentials and login unchanged.')}</span>
        <button className="glass-button px-3 py-1" disabled={busy} onClick={() => void perform({ kind: 'remove', id: removing })}>{text('确认移除', 'Confirm removal')}</button>
        <button className="glass-button px-3 py-1" disabled={busy} onClick={() => setRemoving(null)}>{text('取消', 'Cancel')}</button>
      </div>}
      {error && <div role="alert" className="text-xs text-status-error">{text('操作失败，未确认保存。请检查重复目录、备注或目录可用性后重试。', 'Operation failed; save not confirmed. Check duplicate folders, alias or availability and retry.')} <button className="underline" onClick={() => void reload()} disabled={busy}>{text('重新读取', 'Reload')}</button></div>}
    </section>
  );
}
