import { useEffect, useRef, useState } from 'react';
import { ProviderMark, providerName } from './ProviderMark';
import { useI18n } from '../i18n/I18nProvider';
import { defaultNavigation, moveNavigation, PROVIDER_NAVIGATION_EVENT, PROVIDER_NAVIGATION_KEY, readNavigation, saveNavigation, type NavigationSnapshot } from '../utils/providerNavigation';

/** A provider rail, not the application's Home/Tasks/Usage page navigation. */
export function ProviderNavigation({ providers, selected, onSelect }: { providers: string[]; selected: string; onSelect: (id: string) => void }) {
  const { language } = useI18n(), text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const available = defaultNavigation(providers), availableKey = JSON.stringify(available);
  const [snapshot, setSnapshot] = useState<NavigationSnapshot>(() => { try { return readNavigation(localStorage, available); } catch { return { raw: null, ids: available, invalid: true }; } });
  const [draft, setDraft] = useState<string[] | null>(null), [base, setBase] = useState<NavigationSnapshot | null>(null), [error, setError] = useState(false);
  const [undo, setUndo] = useState<{ before: string[]; after: NavigationSnapshot } | null>(null);
  const dialog = useRef<HTMLDialogElement>(null), drag = useRef<{ id: string; token: string } | null>(null);
  const read = () => { try { setSnapshot(readNavigation(localStorage, available)); } catch { setError(true); } };
  useEffect(() => {
    read(); const changed = (event: Event) => { if (!(event instanceof StorageEvent) || event.key === PROVIDER_NAVIGATION_KEY || event.key === null) read(); };
    window.addEventListener('storage', changed); window.addEventListener(PROVIDER_NAVIGATION_EVENT, changed);
    return () => { window.removeEventListener('storage', changed); window.removeEventListener(PROVIDER_NAVIGATION_EVENT, changed); };
  }, [availableKey]);
  useEffect(() => { if (snapshot.raw !== null && selected !== 'all' && !snapshot.ids.includes(selected)) onSelect('all'); }, [snapshot.raw, selected, onSelect]);
  useEffect(() => { if (draft && dialog.current && !dialog.current.open) dialog.current.showModal(); else if (draft === null) dialog.current?.close(); }, [draft !== null]);
  const close = () => { setDraft(null); setBase(null); drag.current = null; };
  const open = () => { try { const value = readNavigation(localStorage, available); setSnapshot(value); setBase(value); setDraft([...value.ids]); setError(false); } catch { setError(true); } };
  const commit = (expected: NavigationSnapshot, ids: string[], isUndo = false) => {
    try {
      const next = saveNavigation(localStorage, expected, ids);
      setSnapshot(next); setUndo(isUndo ? null : { before: expected.ids, after: next }); setError(false); close();
      if (selected !== 'all' && !next.ids.includes(selected)) onSelect('all');
      window.dispatchEvent(new Event(PROVIDER_NAVIGATION_EVENT));
    } catch { setError(true); read(); }
  };
  const stale = base !== null && base.raw !== snapshot.raw;
  const move = (id: string, to: number) => { if (draft?.includes(id) && !stale && to >= 0 && to < draft.length) setDraft(moveNavigation(draft, id, to)); };
  return <div>
    <nav className="home-provider-rail" aria-label={text('账号平台', 'Account providers')}>
      <button type="button" aria-pressed={selected === 'all'} onClick={() => onSelect('all')}>{text('全部', 'All')}</button>
      {snapshot.ids.filter(id => available.includes(id)).map(id => <button key={id} type="button" aria-pressed={selected === id} onClick={() => onSelect(id)}><ProviderMark provider={id} size={20}/>{providerName(id)}</button>)}
      <button type="button" onClick={open}>{text('管理导航', 'Manage navigation')}</button>
      {undo && <button type="button" disabled={snapshot.raw !== undo.after.raw} onClick={() => commit(undo.after, undo.before, true)}>{text('撤销导航调整', 'Undo navigation change')}</button>}
    </nav>
    {error && <p role="alert">{text('导航未保存，或已在其他窗口更新。重新打开后再试。', 'Navigation was not saved or changed in another window. Reopen and retry.')}</p>}
    {draft && <dialog ref={dialog} className="installation-guide glass-panel" aria-label={text('管理导航', 'Manage navigation')} onCancel={event => { event.preventDefault(); close(); }}>
      <h2>{text('管理导航', 'Manage navigation')}</h2>
      <p>{text('仅调整导航入口；移除不会删除账号，添加不会安装或登录。', 'Only navigation changes. Removing does not delete accounts; adding does not install or sign in.')}</p>
      {(base?.invalid || snapshot.invalid) && <p role="status">{text('原导航设置无法读取；保存前将保留原始备份。', 'The saved navigation is unreadable; its original data will be backed up before saving.')}</p>}
      {stale && <p role="alert">{text('导航已变更，请关闭并重新打开。', 'Navigation changed. Close and reopen the editor.')}</p>}
      <ol>{draft.map((id, index) => <li key={id} className="flex items-center gap-2" draggable={!stale} onDragStart={event => { const token = crypto.randomUUID(); drag.current = { id, token }; event.dataTransfer.setData('application/x-aigoodbro-provider-navigation', token); }} onDragEnd={() => { drag.current = null; }} onDragOver={event => { if (drag.current && !stale) event.preventDefault(); }} onDrop={event => { event.preventDefault(); const source = drag.current; drag.current = null; if (source && source.token === event.dataTransfer.getData('application/x-aigoodbro-provider-navigation')) move(source.id, index); }}>
        <span>{available.includes(id) ? providerName(id) : text('暂不可用', 'Unavailable') + ` · ${id}`}</span>
        <button type="button" aria-label={`${text('上移', 'Move up')} · ${id}`} disabled={stale || index === 0} onClick={() => move(id, index - 1)}>↑</button>
        <button type="button" aria-label={`${text('下移', 'Move down')} · ${id}`} disabled={stale || index === draft.length - 1} onClick={() => move(id, index + 1)}>↓</button>
        <button type="button" disabled={stale} aria-label={`${text('从导航移除', 'Remove from navigation')} · ${id}`} onClick={() => setDraft(draft.filter(value => value !== id))}>{text('移除', 'Remove')}</button>
      </li>)}</ol>
      {!draft.length && <p>{text('导航已留空，全部账号入口仍可用。', 'No provider tabs selected. All accounts stays available.')}</p>}
      <fieldset disabled={stale}><legend>{text('可添加', 'Available')}</legend>{available.filter(id => !draft.includes(id)).map(id => <button type="button" className="glass-button" key={id} onClick={() => setDraft([...draft, id])}>{text('添加', 'Add')} {providerName(id)}</button>)}</fieldset>
      <footer><button type="button" className="glass-button" onClick={close}>{text('取消', 'Cancel')}</button><button type="button" className="glass-button" disabled={stale} onClick={() => setDraft([...available])}>{text('恢复默认', 'Restore defaults')}</button><button type="button" className="glass-button-solid" disabled={stale || !base} onClick={() => { if (base) commit(base, draft); }}>{text('保存导航', 'Save navigation')}</button></footer>
    </dialog>}
  </div>;
}
