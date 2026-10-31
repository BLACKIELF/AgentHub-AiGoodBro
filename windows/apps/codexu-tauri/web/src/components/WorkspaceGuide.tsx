import { useEffect, useRef, useState } from 'react';
import { useI18n } from '../i18n/I18nProvider';
import { RuntimeSetupPanel } from './RuntimeSetupPanel';

export type GuideDestination = 'accounts' | 'tools' | 'proxy' | 'settings';
const steps = ['runtime', 'accounts', 'features', 'notifications', 'updates', 'ready'] as const;
type Step = typeof steps[number];
/** Explicit help is independent of the installation-event outcome. Viewing or
 * closing it cannot mark a runtime ready or reset completed/deferred onboarding. */
export function WorkspaceGuide({ onOpen }: { onOpen: (section: GuideDestination) => void | Promise<void> }) {
  const { language } = useI18n(), text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const [opened, setOpened] = useState(false), [step, setStep] = useState<Step>('accounts'), [busy, setBusy] = useState(false), [error, setError] = useState(false);
  const dialog = useRef<HTMLDialogElement>(null), alive = useRef(true), pending = useRef(false);
  useEffect(() => { alive.current = true; return () => { alive.current = false; }; }, []);
  useEffect(() => { if (opened && dialog.current && !dialog.current.open) dialog.current.showModal(); else if (!opened) dialog.current?.close(); }, [opened]);
  const titles: Record<Step, string> = { runtime: text('工具', 'Tools'), accounts: text('账号', 'Accounts'), features: text('功能', 'Features'), notifications: text('通知', 'Notifications'), updates: text('更新', 'Updates'), ready: text('完成', 'Finish') };
  const go = async (section: GuideDestination) => {
    if (pending.current) return; pending.current = true; setBusy(true); setError(false);
    try { await onOpen(section); if (alive.current) setOpened(false); }
    catch { if (alive.current) setError(true); }
    finally { pending.current = false; if (alive.current) setBusy(false); }
  };
  const index = steps.indexOf(step);
  return <>
    <button type="button" className="glass-button m-2 self-start" onClick={() => { setStep('accounts'); setError(false); setOpened(true); }}>{text('使用引导', 'Getting started')}</button>
    {opened && <dialog ref={dialog} className="installation-guide glass-panel" aria-label={text('使用引导', 'Getting started')} onCancel={event => { event.preventDefault(); if (!pending.current) setOpened(false); }}>
      <h2>{text('使用引导', 'Getting started')}</h2>
      <nav aria-label={text('引导步骤', 'Guide steps')}>{steps.map(id => <button key={id} type="button" aria-current={id === step ? 'step' : undefined} disabled={busy} onClick={() => { setStep(id); setError(false); }}>{titles[id]}</button>)}</nav>
      <h3>{titles[step]}</h3>
      {step === 'runtime' && <RuntimeSetupPanel onOpenTasks={() => go('tools')} />}
      {step === 'accounts' && <><p>{text('在账号页添加账号或关联已有目录。只有身份核验和额度读取成功后，才能使用相应能力；打开引导不会切换账号。', 'Add an account or link an existing directory in Accounts. Identity and quota must be verified for the relevant features; opening this guide does not switch accounts.')}</p><button type="button" disabled={busy} onClick={() => void go('accounts')}>{text('打开账号页', 'Open Accounts')}</button></>}
      {step === 'features' && <><p>{text('反代参与、额度保留和任务审批都由各自页面明确设置。查看引导不会开启反代或派发任务。', 'Proxy participation, quota reserves and task approvals are explicit controls on their own pages. Viewing the guide does not enable proxying or dispatch tasks.')}</p><button type="button" disabled={busy} onClick={() => void go('proxy')}>{text('打开反代设置', 'Open proxy settings')}</button></>}
      {step === 'notifications' && <><p>{text('在设置里连接并启用通知渠道。只有明确发送或已启用的通知规则才会投递；本步骤不会发送测试消息。', 'Connect and enable notification channels in Settings. Only explicit sends or enabled notification rules deliver messages; this step sends no test message.')}</p><button type="button" disabled={busy} onClick={() => void go('settings')}>{text('打开通知设置', 'Open notification settings')}</button></>}
      {step === 'updates' && <><p>{text('在设置里查看更新。检查、下载和安装是独立操作，查看引导不会下载或覆盖应用。', 'Review updates in Settings. Checking, downloading and installing are separate actions; viewing the guide does not download or replace the app.')}</p><button type="button" disabled={busy} onClick={() => void go('settings')}>{text('打开更新设置', 'Open update settings')}</button></>}
      {step === 'ready' && <p>{text('可随时从“使用引导”重新查看。关闭此页只结束本次查看，不更改账号、工具或首次安装进度。', 'Reopen Getting started at any time. Closing only ends this review; it does not change accounts, tools or installation progress.')}</p>}
      {error && <p role="alert">{text('页面未打开，请重试。', 'The page did not open. Retry.')}</p>}
      <footer><button type="button" className="glass-button" disabled={busy} onClick={() => setOpened(false)}>{text('以后再说', 'Not now')}</button><span>{index + 1} / {steps.length}</span><button type="button" className="glass-button" disabled={busy || index === 0} onClick={() => setStep(steps[index - 1])}>{text('上一步', 'Back')}</button><button type="button" className="glass-button-solid" disabled={busy} onClick={() => { if (index + 1 === steps.length) setOpened(false); else setStep(steps[index + 1]); }}>{index + 1 === steps.length ? text('完成查看', 'Finish review') : text('下一步', 'Continue')}</button></footer>
    </dialog>}
  </>;
}
