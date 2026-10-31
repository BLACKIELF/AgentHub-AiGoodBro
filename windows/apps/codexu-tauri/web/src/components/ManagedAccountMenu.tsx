import {normalizeAccountRemark, validAccountRemark} from '../utils/accountMetadata';
import { useEffect, useId, useRef, useState } from 'react';
import { MoreHorizontal, Pencil, Trash2, ListPlus } from 'lucide-react';
import { useI18n } from '../i18n/I18nProvider';

export function ManagedAccountMenu({ label, disabled, error, onRename, onRemove, onRegister, registrationPending = false, showRename = false }: {
  showRename?: boolean;
  onRegister?: () => Promise<boolean>; registrationPending?: boolean;
  label: string; disabled: boolean; error: string | null;
  onRename: (label: string) => Promise<boolean>; onRemove: () => Promise<boolean>;
}) {
  const { language } = useI18n(), text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const [mode, setMode] = useState<'rename' | 'remove' | null>(null), [draft, setDraft] = useState(label), [busy, setBusy] = useState(false), [failed, setFailed] = useState(false);
  const menu = useRef<HTMLDetailsElement>(null), summary = useRef<HTMLElement>(null), dialog = useRef<HTMLDialogElement>(null), alive = useRef(false), pending = useRef(false);
  const inputId = useId(), nextLabel = draft.trim();
  const valid = validAccountRemark(draft);
  useEffect(() => { alive.current = true; return () => { alive.current = false; }; }, []);
  useEffect(() => {
    const node = dialog.current, invoker = summary.current, panel = invoker?.closest('section.managed-accounts-panel');
    if (!mode || !node) return;
    node.showModal();
    return () => { node.close(); if (invoker?.isConnected) invoker.focus(); else panel?.querySelector<HTMLButtonElement>('button:not(:disabled)')?.focus(); };
  }, [mode]);
  const open = (next: 'rename' | 'remove') => { if (disabled) return; if (menu.current) menu.current.open = false; setDraft(label); setFailed(false); setMode(next); };
  const submit = async () => {
    if (pending.current || disabled || !mode || mode === 'rename' && (!valid || nextLabel === label)) return;
    pending.current = true; setBusy(true); setFailed(false);
    try { const success = mode === 'rename' ? await onRename(normalizeAccountRemark(draft)) : await onRemove(); if (alive.current) { if (success) setMode(null); else setFailed(true); } }
    finally { pending.current = false; if (alive.current) setBusy(false); }
  };
  return <>
    {showRename && <button type="button" className="glass-button proxy-action" disabled={disabled} onClick={() => open('rename')}><Pencil size={13} />{text('自定义名称', 'Customize name')}</button>}
    <details ref={menu} className="account-more" onKeyDown={event => { if (event.key === 'Escape') { event.preventDefault(); if (menu.current) menu.current.open = false; summary.current?.focus(); } }}>
      <summary ref={summary} className="icon-action" aria-label={text(`${label} 更多操作`, `More actions for ${label}`)} aria-disabled={disabled} onClick={event => { if (disabled) event.preventDefault(); }}><MoreHorizontal size={15} /></summary>
      <div className="account-more-content">{onRegister && <button type="button" disabled={disabled} onClick={() => { if (menu.current) menu.current.open = false; void onRegister(); }}><ListPlus size={13} />{registrationPending ? text('重试登记到主页与任务', 'Retry Home and Tasks registration') : text('登记到主页与任务', 'Register for Home and Tasks')}</button>}<button type="button" disabled={disabled} onClick={() => open('rename')}><Pencil size={13} />{text('重命名', 'Rename')}</button><button type="button" disabled={disabled} className="text-status-error" onClick={() => open('remove')}><Trash2 size={13} />{text('移除保存的账号', 'Remove saved account')}</button></div>
    </details>
    {mode && <dialog ref={dialog} className="managed-switch-dialog managed-account-editor" aria-label={mode === 'rename' ? text('重命名账号', 'Rename account') : text('移除保存的账号', 'Remove saved account')} onCancel={event => { event.preventDefault(); if (!pending.current) setMode(null); }}>
      <form onSubmit={event => { event.preventDefault(); void submit(); }}>
        <h2>{mode === 'rename' ? text('重命名账号', 'Rename account') : text('移除保存的账号', 'Remove saved account')}</h2>
        {mode === 'rename' ? <><label htmlFor={inputId}>{text('账号昵称', 'Account alias')}</label><input id={inputId} autoFocus maxLength={16384} value={draft} disabled={busy} onChange={event => { setDraft(event.target.value); setFailed(false); }} /><p>{text('最多 40 个字符，留空恢复原昵称。', 'Up to 40 characters. Leave empty to restore the original alias.')}</p></> : <><p>{text('移除此应用保存的账号 ', 'Remove the saved account ')}<strong>{label}</strong>?</p><p>{text('保留当前系统登录、Desktop 配置与历史记录。', 'Your current system sign-in, Desktop settings and history are retained.')}</p></>}
        {failed && <p role="alert" className="text-status-warn">{error ?? text('操作未完成，原记录已保留。请重试。', 'The operation did not complete. The saved record is retained. Try again.')}</p>}
        <div className="managed-editor-actions"><button type="button" className="glass-button proxy-action" disabled={busy} onClick={() => setMode(null)}>{text('取消', 'Cancel')}</button><button type="submit" className={`proxy-action ${mode === 'remove' ? 'glass-button is-danger' : 'glass-button-solid'}`} disabled={busy || disabled || mode === 'rename' && (!valid || nextLabel === label)}>{busy ? text('正在保存…', 'Saving…') : mode === 'rename' ? text('保存昵称', 'Save alias') : text('确认移除', 'Remove account')}</button></div>
      </form>
    </dialog>}
  </>;
}
