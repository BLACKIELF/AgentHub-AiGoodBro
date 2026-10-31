import { useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { useI18n } from '../i18n/I18nProvider';
import { parseClaudeSwapCandidates, type ClaudeSwapCandidate } from '../utils/claudeSwap';
import { parseManagedAccount } from '../utils/managedAccounts';

export function ClaudeSwapImport({ disabled, onImported }: { disabled: boolean; onImported: () => Promise<void> }) {
  const { language } = useI18n();
  const text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const [candidates, setCandidates] = useState<ClaudeSwapCandidate[] | null>(null);
  const [pending, setPending] = useState<string | null>(null), [error, setError] = useState<string | null>(null);
  const alive = useRef(false), busy = useRef(false), generation = useRef(0);
  useEffect(() => { alive.current = true; return () => { alive.current = false; generation.current++; }; }, []);
  const errorText = (failure: unknown) => {
    const code = typeof failure === 'string' ? failure : failure instanceof Error ? failure.message : '';
    if (code === 'duplicate_identity') return text('此订阅已经添加，请重新扫描。', 'This subscription is already added. Scan again.');
    if (code === 'claude_swap_busy') return text('claude-swap 正在使用或恢复此订阅，已保留原槽位。', 'claude-swap is using or recovering this subscription. The source slot is retained.');
    if (code === 'claude_swap_changed' || code === 'claude_swap_identity_changed') return text('候选来源已变化，请重新扫描。', 'The candidate source changed. Scan again.');
    if (code === 'duplicate_label') return text('此昵称已存在，请先重命名已保存的订阅。', 'That alias already exists. Rename the saved subscription first.');
    return text('未能完成，请检查 claude-swap 来源后重新扫描。', 'Could not complete. Check the claude-swap source and scan again.');
  };
  async function action(id: string | null) {
    if (disabled || busy.current) return;
    const epoch = ++generation.current;
    busy.current = true; setPending(id ?? 'scan'); setError(null);
    try {
      if (id !== null) {
        const saved = parseManagedAccount(await invoke('import_claude_swap_candidate', { candidateId: id }));
        if (saved.platform !== 'claude') throw Error('invalid_response');
        if (!alive.current || epoch !== generation.current) return;
        setCandidates(rows => rows?.map(row => row.candidate_id === id ? { ...row, already_imported: true } : row) ?? null);
        await onImported();
      } else {
        const rows = parseClaudeSwapCandidates(await invoke('scan_claude_swap_candidates'));
        if (alive.current && epoch === generation.current) setCandidates(rows);
      }
    } catch (failure) { if (alive.current && epoch === generation.current) setError(errorText(failure)); }
    finally { if (alive.current && epoch === generation.current) { busy.current = false; setPending(null); } }
  }
  return <section className="claude-swap-import" aria-label={text('从 claude-swap 添加', 'Add from claude-swap')}>
    <button type="button" className="glass-button proxy-action" disabled={disabled || pending !== null} onClick={() => void action(null)}>{pending === 'scan' ? text('正在扫描…', 'Scanning…') : candidates === null ? text('扫描 claude-swap', 'Scan claude-swap') : text('重新扫描 claude-swap', 'Rescan claude-swap')}</button>
    {error && <p role="alert" className="proxy-feedback is-error">{error}</p>}
    {candidates?.length === 0 && <p className="proxy-note">{text('未发现可添加的本机槽位。', 'No local slots found.')}</p>}
    {candidates && candidates.length > 0 && <><p className="proxy-note">{text('逐条添加来源引用；保留 claude-swap 的原槽位。', 'Add each source reference individually. Original claude-swap slots are retained.')}</p><ul>{candidates.map(row => <li key={row.candidate_id}><span>{row.label} · {row.masked_identity ?? text('身份未知', 'Identity unknown')}</span> <button type="button" className="glass-button proxy-action" disabled={disabled || pending !== null || row.already_imported} onClick={() => void action(row.candidate_id)}>{row.already_imported ? text('已添加', 'Added') : pending === row.candidate_id ? text('正在添加…', 'Adding…') : text('添加', 'Add')}</button></li>)}</ul></>}
  </section>;
}
