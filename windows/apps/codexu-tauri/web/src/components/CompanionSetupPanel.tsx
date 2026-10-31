import {useEffect, useRef, useState} from 'react';
import {invoke} from '@tauri-apps/api/core';
import {listen} from '@tauri-apps/api/event';
import {useI18n} from '../i18n/I18nProvider';
import {parseCompanionSetup, type CompanionSetupSnapshot} from '../utils/companionSetup';

type Operation = 'inspect' | 'prepare' | 'confirm';
type Plan = {id: string; epoch: number};

/** Fixed native destination and pins. This view cannot authorize a task. */
export function CompanionSetupPanel() {
  const {language} = useI18n();
  const t = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const [view, setView] = useState<CompanionSetupSnapshot | null>(null);
  const [plan, setPlan] = useState<Plan | null>(null);
  const [busy, setBusy] = useState<Operation | null>(null);
  const [issue, setIssue] = useState<string | null>(null);
  const [confirmed, setConfirmed] = useState(false);
  const [needsCheck, setNeedsCheck] = useState(false);
  const [subscribed, setSubscribed] = useState(false);
  const alive = useRef(false), epoch = useRef(0), pending = useRef(false);
  const listening = useRef(false), queuedRead = useRef(false);
  const inspect = useRef<() => void>(() => {});

  function clear() {
    setView(null); setPlan(null); setConfirmed(false); setIssue(null);
  }
  async function act(operation: Operation, chosen?: Plan) {
    if (!alive.current || !listening.current || pending.current) return;
    if (operation === 'confirm' && (!chosen || chosen.epoch !== epoch.current)) return;
    pending.current = true;
    const own = ++epoch.current;
    clear(); setBusy(operation);
    // Once a mutation or inspection begins, old readiness is no longer evidence.
    setNeedsCheck(true);
    try {
      const command = operation === 'inspect' ? 'inspect_companion_setup'
        : operation === 'prepare' ? 'prepare_companion_setup' : 'confirm_companion_setup';
      const next = parseCompanionSetup(await invoke(command, operation === 'confirm' ? {planId: chosen!.id} : undefined));
      if (!alive.current || own !== epoch.current) return;
      if (operation === 'inspect' && next.planId !== null
          || operation === 'prepare' && next.state !== 'ready' && next.planId === null
          || operation === 'confirm' && next.state !== 'ready') throw Error('companion_response_invalid');
      setView(next);
      setPlan(operation === 'prepare' && next.planId ? {id: next.planId, epoch: own} : null);
      setConfirmed(operation === 'confirm'); setNeedsCheck(false);
    } catch (error) {
      if (alive.current && own === epoch.current) {
        const code = typeof error === 'string' ? error : '';
        setIssue(/^companion_[a-z_]{1,80}$/.test(code) ? code : 'companion_operation_unconfirmed');
      }
    } finally {
      pending.current = false;
      if (alive.current) {
        setBusy(null);
        if (queuedRead.current) { queuedRead.current = false; inspect.current(); }
      }
    }
  }
  inspect.current = () => { void act('inspect'); };
  useEffect(() => {
    alive.current = true;
    let dispose: (() => void) | undefined;
    const changed = () => {
      if (!alive.current) return;
      ++epoch.current; clear(); setNeedsCheck(true);
      // Finish the current native operation before checking. Its late reply may
      // neither restore Ready nor resurrect an obsolete confirmation plan.
      if (pending.current) queuedRead.current = true;
      else inspect.current();
    };
    void listen('companion-setup:changed', changed).then(unlisten => {
      if (!alive.current) { unlisten(); return; }
      dispose = unlisten; listening.current = true; setSubscribed(true); inspect.current();
    }).catch(() => {
      if (alive.current) { clear(); setIssue('companion_status_sync_unavailable'); }
    });
    return () => {
      alive.current = false; listening.current = false; ++epoch.current;
      queuedRead.current = false; dispose?.();
    };
  }, []);

  const code = issue ?? view?.issueCode;
  const detail = code === 'companion_confirmation_required'
    ? t('配套文件已匹配。请确认本次准备结果以恢复配套连接。', 'The companion files match. Confirm this prepared plan to restore the companion connection.')
    : code === 'companion_scope_required'
      ? t('请先在任务面板连接要使用的账号与项目，再重新检查。', 'Connect the intended account and project in Tasks, then check again.')
    : ['companion_cleanup_unconfirmed', 'companion_exit_in_progress'].includes(code ?? '')
      ? t('配套连接尚未恢复或停止结果未确认。请重新检查，当前不能确认就绪。', 'The companion connection has not resumed or its stop result is unconfirmed. Check again; readiness is not confirmed.')
    : ['companion_managed_section_conflict', 'companion_unrecognized_installation', 'companion_recovery_required', 'companion_rollback_conflict'].includes(code ?? '')
      ? t('现有文件需要核对，不能直接覆盖。已保留现场，请处理冲突后重新检查。', 'Existing files need review and cannot be overwritten directly. Evidence is retained; resolve the conflict and check again.')
    : code === 'companion_platform_adapter_unavailable' || code === 'companion_platform_unavailable'
      ? t('配套连接当前不可用。请先检查 Python 和任务连接；未确认安装就绪。', 'The companion connection is unavailable. Check Python and the Tasks connection first; installation readiness is not confirmed.')
    : code === 'companion_status_sync_unavailable'
      ? t('无法同步配套状态，请重新打开本页后检查。', 'Companion status updates are unavailable. Reopen this page and check again.')
    : code ? t('本次结果未确认，文件可能已经改变。请重新检查实际状态，再准备新计划；不会自动重复确认。', 'The result is unconfirmed; files may already have changed. Check the actual state before preparing a new plan. Confirmation is never retried automatically.') : null;
  const labels = {
    missing: t('尚未安装', 'Not installed'), outdated: t('有更新待确认', 'Update available'),
    conflict: t('现有文件需要核对', 'Existing files need review'),
    ready: t('已就绪', 'Ready'), unavailable: t('目前不可用', 'Unavailable'),
  };
  const button = 'rounded-lg border border-border px-3 py-1.5 text-sm disabled:opacity-50';
  const changes = view?.files.filter(file => file.status !== 'same') ?? [];
  function cancel() {
    if (pending.current) return;
    ++epoch.current; setPlan(null); setConfirmed(false);
    setView(value => value ? {...value, planId: null} : null);
  }
  return <section aria-label={t('配套 Skill', 'Companion Skill')} className="space-y-3">
    <h3 className="font-semibold">{t('配套 Skill', 'Companion Skill')}</h3>
    <p>{t('先检查配套文件，再准备差异并确认安装或更新。这里只配置工具连接，不运行任务。', 'Check companion files, prepare the differences, then confirm installation or update. This configures the tool connection without running a task.')}</p>
    <p role="status">{busy ? t('正在处理…', 'Working…') : view ? labels[view.state] : t('待检查', 'Not checked')}</p>
    <div className="flex flex-wrap gap-2">
      <button className={button} disabled={!subscribed || busy !== null} onClick={() => void act('inspect')}>{t('重新检查', 'Check again')}</button>
      <button className={button} disabled={!subscribed || busy !== null || needsCheck || !!plan || view?.state === 'conflict'} onClick={() => void act('prepare')}>{t('准备安装或更新', 'Prepare installation or update')}</button>
    </div>
    {detail && <p role="alert">{detail}</p>}
    {view && view.files.length > 0 && <details open={!!plan}>
      <summary>{t('文件比较', 'File comparison')} · {changes.length} {t('项差异', 'differences')}</summary>
      <ul className="mt-2 max-h-64 space-y-1 overflow-y-auto text-sm">
        {view.files.map(file => <li key={file.path} className="flex flex-wrap justify-between gap-2"><span className="break-all">{file.path}</span><span>{file.status === 'same' ? t('一致', 'Matches') : file.status === 'missing' ? t('缺少', 'Missing') : t('已变更', 'Changed')}</span></li>)}
      </ul>
    </details>}
    {plan && <div role="group" aria-label={t('确认配套安装', 'Confirm companion setup')} className="space-y-2 rounded-xl border border-border p-3">
      <p>{t('确认后会先备份将被替换的已有内容，再应用本次差异。自写正文和已有的两个旧策略配置保留不动。', 'Confirmation backs up existing content that will be replaced, then applies these differences. Your own text and the two existing legacy policy files remain unchanged.')}</p>
      <div className="flex flex-wrap gap-2"><button className={button} disabled={busy !== null} onClick={() => void act('confirm', plan)}>{t('确认安装或更新', 'Confirm installation or update')}</button><button className={button} disabled={busy !== null} onClick={cancel}>{t('取消', 'Cancel')}</button></div>
    </div>}
    {confirmed && view?.state === 'ready' && <p role="status">{t('配套文件与连接已检查就绪；此处未启动任务。', 'Companion files and connection are verified ready; no task was started here.')}</p>}
    {view?.backupAvailable && <p>{t('本次替换前的内容已有备份。', 'The content replaced in this operation has a backup.')}</p>}
    <p className="text-xs text-secondary">{t('使用现有 Python 与应用内账号、项目和调度设置。不会安装 Python、复制账号凭据或自动更改调度偏好。', 'Uses existing Python and the app’s account, project and dispatch settings. It does not install Python, copy account credentials or automatically change dispatch preferences.')}</p>
  </section>;
}
