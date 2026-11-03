import { useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { useI18n } from '../i18n/I18nProvider';
import { parseAccountOrder } from '../utils/accountMetadata';
type Row = { id: string; label: string };
export function ManagedAccountOrder({ accounts, disabled, onChanged }: { accounts: Row[]; disabled: boolean; onChanged: () => void | Promise<void> }) {
  const { language } = useI18n(), text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const [draft, setDraft] = useState<string[] | null>(null), [expected, setExpected] = useState<string[]>([]), [busy, setBusy] = useState(false), [error, setError] = useState(false);
  const dialog = useRef<HTMLDialogElement>(null), active = useRef(false), alive = useRef(false), drag = useRef<{ token: string; id: string; order: string } | null>(null);
  const signature = JSON.stringify(accounts.map(a => a.id)), stale = draft !== null && signature !== JSON.stringify(expected);
  useEffect(() => { alive.current = true; return () => { alive.current = false; }; }, []);
  useEffect(() => { if (draft !== null && !dialog.current?.open) dialog.current?.showModal(); }, [draft]);
  const cancel = () => { if (active.current) return; dialog.current?.close(); setDraft(null); drag.current = null; };
  const move = (id: string, destination: number) => {
    if (!draft || busy || disabled || stale || !Number.isInteger(destination) || destination < 0 || destination >= draft.length) return;
    const next = draft.filter(value => value !== id); next.splice(destination, 0, id); setDraft(next); drag.current = null; setError(false);
  };
  async function save() {
    if (!draft || active.current || disabled || stale || JSON.stringify(draft) === JSON.stringify(expected)) return;
    active.current = true; setBusy(true); setError(false); const order = [...draft], before = [...expected];
    try {
      parseAccountOrder(await invoke('reorder_managed_accounts', { orderedIds: order, expectedOrder: before }), order);
      if (alive.current) { dialog.current?.close(); setDraft(null); }
      await onChanged();
    } catch { if (alive.current) setError(true); }
    finally { active.current = false; if (alive.current) setBusy(false); }
  }
  return <><button type="button" className="glass-button proxy-action" disabled={disabled || accounts.length < 2} onClick={() => { if (active.current) return; const ids = accounts.map(a => a.id); setExpected(ids); setDraft(ids); setError(false); }}>{text('账号排序', 'Reorder accounts')}</button>
    {draft && <dialog ref={dialog} className="managed-switch-dialog" aria-label={text('调整 Codex 账号顺序', 'Reorder Codex accounts')} onCancel={event => { event.preventDefault(); cancel(); }}>
      <h2>{text('调整 Codex 账号顺序', 'Reorder Codex accounts')}</h2><p>{text('拖动、输入序号或使用箭头调整。只改变展示顺序，不改变反代或调度优先。', 'Drag, enter a position, or use the arrows. This changes display order only, not proxy or dispatch priority.')}</p>
      <ol>{draft.map((id, index) => <li key={id} draggable={!busy && !disabled && !stale} onDragStart={event => { const token = crypto.randomUUID(); drag.current = { token, id, order: JSON.stringify(draft) }; event.dataTransfer.setData('application/x-aigoodbro-account-order', token); }} onDragEnd={() => { drag.current = null; }} onDragOver={event => { if (drag.current) event.preventDefault(); }} onDrop={event => { const value = drag.current; if (!value || value.order !== JSON.stringify(draft) || event.dataTransfer.getData('application/x-aigoodbro-account-order') !== value.token) return; event.preventDefault(); move(value.id, index); }}>
        <span>{accounts.find(a => a.id === id)?.label ?? text('账号已变化', 'Account changed')}</span>
        <input type="number" min={1} max={draft.length} aria-label={text('目标序号', 'Target position') + ' · ' + (accounts.find(a => a.id === id)?.label ?? id)} value={index + 1} disabled={busy || disabled || stale} onChange={event => { const n = Number(event.target.value); if (event.target.value) move(id, n - 1); }} />
        <button type="button" aria-label={text('上移', 'Move up') + ' · ' + (accounts.find(a => a.id === id)?.label ?? id)} disabled={busy || disabled || stale || index === 0} onClick={() => move(id, index - 1)}>↑</button><button type="button" aria-label={text('下移', 'Move down') + ' · ' + (accounts.find(a => a.id === id)?.label ?? id)} disabled={busy || disabled || stale || index === draft.length - 1} onClick={() => move(id, index + 1)}>↓</button>
      </li>)}</ol>
      {(error || stale) && <p role="alert">{text('未保存。列表可能已变化或暂时无法写入；草稿保留，请重新读取后再试。', 'Not saved. The list may have changed or saving is unavailable. The draft is retained; reload before trying again.')}</p>}
      <div className="managed-editor-actions"><button type="button" className="glass-button proxy-action" disabled={busy} onClick={cancel}>{text('取消', 'Cancel')}</button><button type="button" className="glass-button-solid proxy-action" disabled={busy || disabled || stale || JSON.stringify(draft) === JSON.stringify(expected)} onClick={() => void save()}>{busy ? text('正在保存…', 'Saving…') : text('保存顺序', 'Save order')}</button></div>
    </dialog>}
  </>;
}
