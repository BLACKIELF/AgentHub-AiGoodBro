import { useEffect, useRef, useState, type ReactNode } from 'react';
import './AccountActions.css';
import { invoke } from '@tauri-apps/api/core';
import { RotateCcw, UserPlus } from 'lucide-react';
import { useI18n } from '../i18n/I18nProvider';
import { parseReferralBatch, parseReferralPage, parseReferralReview, parseRecipients, parseResetReceipt, parseResetReview, type ReferralBatch, type ReferralPage, type ReferralPeriod, type ReferralReview, type ResetOutcome, type ResetReview } from '../utils/accountActions';

type Text = (zh: string, en: string) => string;
function failureText(error: unknown, text: Text) {
  const raw = typeof error === 'string' ? error : error instanceof Error ? error.message : '';
  const code = raw.startsWith('referral_') ? raw.slice(9) : raw === 'manual_action_identity_changed' ? 'identity_changed' : raw;
  const messages: Record<string, [string, string]> = {
    identity_changed: ['账号身份已变化，请关闭后重新读取。', 'The account identity changed. Close and read it again.'],
    review_expired: ['本次确认已过期，请重新读取。', 'This review expired. Read it again.'],
    manual_action_registration_required: ['此目录尚未关联已验证的托管账号。请先在平台账号中完成登录登记。', 'This directory is not linked to a verified managed account. Complete registration in Accounts first.'],
    login_required: ['请先登录此账号。', 'Sign in to this account first.'],
    no_reset_credit: ['官方未提供可用重置卡。', 'No reset card is available from the provider.'],
    manual_action_busy: ['此账号的手动操作正在进行，请稍后重试。', 'A manual action for this account is in progress. Try again shortly.'],
    reset_outcome_unknown: ['上次使用结果尚未返回，请先刷新官方记录；不会自动重复使用。', 'The previous result is pending. Refresh official records; the card will not be consumed again automatically.'],
    delivery_uncertain: ['发送结果待确认，请先核对邀请记录，避免重复发送。', 'Delivery is unconfirmed. Check invitation records before sending again.'],
    offer_changed: ['官方邀请条件已变化，请刷新后重新确认。', 'The official offer changed. Refresh and confirm it again.'],
    reconciliation_required: ['请核对官方邀请记录；本次发送记录仍保留，不能自动重发。', 'Check official invitation history. The send record is retained and cannot be resent automatically.'],
    capacity_reached: ['本次邀请超过官方可用名额，请刷新。', 'The request exceeds the available invitation capacity. Refresh the offer.'],
    consent_required: ['请先确认已获得好友同意。', 'Confirm that the recipients have consented first.'],
    rate_limited: ['官方暂时限制请求，请稍后重试。', 'The provider is limiting requests. Try again later.'],
  };
  return messages[code] ? text(...messages[code]) : text('读取或操作未完成，请刷新状态后重试。', 'The read or action did not complete. Refresh the state and try again.');
}
function ActionDialog({ title, busy, onClose, children }: { title: string; busy: boolean; onClose: () => void; children: ReactNode }) {
  const { language } = useI18n();
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => { const node = dialog.current, previous = document.activeElement; node?.showModal(); return () => { node?.close(); if (previous instanceof HTMLElement && previous.isConnected) previous.focus(); }; }, []);
  return <dialog ref={dialog} aria-label={title} className="managed-switch-dialog account-action-dialog" onCancel={event => { event.preventDefault(); if (!busy) onClose(); }}>
    <header className="flex items-center justify-between gap-3"><h2>{title}</h2><button type="button" className="glass-button proxy-action" disabled={busy} onClick={onClose}>{language === 'zh-Hans' ? '关闭' : 'Close'}</button></header>{children}
  </dialog>;
}
function ResetAction({ profileId, profileLabel, onChanged }: { profileId: string; profileLabel: string; onChanged?: () => void }) {
  const { language } = useI18n(), text: Text = (zh, en) => language === 'zh-Hans' ? zh : en;
  const [review, setReview] = useState<ResetReview | null>(null), [step, setStep] = useState<1 | 2>(1), [busy, setBusy] = useState(false), [error, setError] = useState(''), [outcome, setOutcome] = useState<ResetOutcome | null>(null), [now, setNow] = useState(Date.now);
  const [outcomeIssue, setOutcomeIssue] = useState<'notification_receipt_save_failed' | null>(null);
  const surface = useRef<HTMLDivElement>(null);
  const alive = useRef(false), pending = useRef(false), activeReview = useRef<ResetReview | null>(null);
  useEffect(() => { alive.current = true; return () => { alive.current = false; const current = activeReview.current; if (current) void invoke('cancel_manual_reset_review', { profileId, reviewId: current.reviewId }).catch(() => undefined); }; }, [profileId]);
  useEffect(() => { if (!review) return; const timer = window.setInterval(() => setNow(Date.now()), 500); return () => window.clearInterval(timer); }, [review]);
  async function perform(action: 'begin' | 'confirm' | 'consume' | 'cancel') {
    if (pending.current) return;
    const current = activeReview.current;
    if (action !== 'begin' && !current || (action === 'confirm' || action === 'consume') && current && current.expiresAtMs <= Date.now()) return;
    pending.current = true; setBusy(true); setError('');
    try {
      if (action === 'cancel') { await invoke('cancel_manual_reset_review', { profileId, reviewId: current!.reviewId }); activeReview.current = null; if (alive.current) setReview(null); }
      else if (action === 'consume') {
        // No optimistic success, no automatic retry after an ambiguous consume.
        const result = parseResetReceipt(await invoke('consume_manual_reset_credit', { profileId, reviewId: current!.reviewId }), profileId);
        activeReview.current = null;
        if (alive.current) { setReview(null); setOutcome(result.outcome); setOutcomeIssue(result.issueCode); if (result.outcome !== 'unknown') onChanged?.(); }
      } else {
        const next = parseResetReview(await invoke(action === 'begin' ? 'begin_manual_reset_review' : 'confirm_manual_reset_review', { profileId, ...(current && action === 'confirm' ? { reviewId: current.reviewId } : {}) }), profileId);
        if (action === 'confirm' && next.reviewId !== current!.reviewId) throw Error('invalid_response');
        if (!alive.current || !surface.current?.getClientRects().length || surface.current.closest('[hidden]')) { void invoke('cancel_manual_reset_review', { profileId, reviewId: next.reviewId }).catch(() => undefined); return; }
        activeReview.current = next; setReview(next); setStep(action === 'begin' ? 1 : 2); setOutcome(null); setOutcomeIssue(null); setNow(Date.now());
      }
    } catch (failure) { if (alive.current) { if (action === 'consume') { setOutcome('unknown'); setReview(null); activeReview.current = null; } setError(failureText(failure, text)); } }
    finally { pending.current = false; if (alive.current) setBusy(false); }
  }
  const notices: Record<ResetOutcome, string> = { reset: text('重置已确认 · 手动使用 1 张重置卡。', 'Reset confirmed · Manually used 1 reset card.'), nothingToReset: text('当前额度无需重置。', 'The current allowance does not need a reset.'), noCredit: text('没有可用的重置卡。', 'No reset card is available.'), alreadyRedeemed: text('这张重置卡已使用。', 'This reset card was already used.'), unknown: text('使用结果待确认，请先刷新官方记录；不会自动重复使用。', 'The result is unconfirmed. Refresh official records; no automatic repeat will occur.') };
  const expired = !!review && review.expiresAtMs <= now;
  return <div ref={surface} className="space-y-2"><button type="button" className="glass-button proxy-action" disabled={busy || !!review || outcome === 'unknown' || outcomeIssue !== null} onClick={() => void perform('begin')}><RotateCcw size={14} />{text('使用重置卡', 'Use reset card')}</button>
    {!review && error && <p role="alert" className="proxy-feedback is-error">{error}</p>}{outcome && <p role="status" className="proxy-feedback">{outcomeIssue ? text('重置成功，通知记录保存失败。', 'Reset succeeded; the notification record could not be saved.') : notices[outcome]}</p>}
    {review && <ActionDialog title={step === 1 ? text('第一次确认：核对账号与重置卡', 'Confirmation 1: verify account and reset card') : text('第二次确认：使用一张重置卡', 'Confirmation 2: consume one reset card')} busy={busy} onClose={() => void perform('cancel')}>
      <p><strong>{profileLabel}</strong></p><p>{text('卡片：1 张可用的 Codex 额度重置卡', 'Card: 1 available Codex rate-limit reset card')}</p><p>{text('到期：', 'Expiry: ')}{review.cardExpiresAtMs === null ? text('无到期时间', 'No expiry') : new Date(review.cardExpiresAtMs).toLocaleString(language === 'zh-Hans' ? 'zh-CN' : 'en-GB')}</p>
      {step === 2 && <p>{text('符合条件的额度窗口将重置，每周额度的下次重置时间会改变。此操作无法撤销。', 'Eligible limit windows will reset, and the next weekly reset time will change. This cannot be undone.')}</p>}
      {expired && <p role="alert" className="text-status-warn">{text('确认已过期，请关闭后重新读取。', 'The review expired. Close and read it again.')}</p>}{error && <p role="alert" className="proxy-feedback is-error">{error}</p>}
      <div className="flex flex-wrap gap-2"><button type="button" className="glass-button proxy-action" disabled={busy} onClick={() => void perform('cancel')}>{text('取消', 'Cancel')}</button><button type="button" className={step === 1 ? 'glass-button-solid proxy-action' : 'glass-button proxy-action is-danger'} disabled={busy || expired || review.availableCount < 1} onClick={() => void perform(step === 1 ? 'confirm' : 'consume')}>{busy ? text('处理中…', 'Working…') : step === 1 ? text('我已核对账号与卡片', 'I verified the account and card') : text('使用这张重置卡', 'Consume this reset card')}</button></div>
    </ActionDialog>}
  </div>;
}
function ReferralAction({ profileId, profileLabel }: { profileId: string; profileLabel: string }) {
  const { language } = useI18n(), text: Text = (zh, en) => language === 'zh-Hans' ? zh : en;
  const [open, setOpen] = useState(false), [busy, setBusy] = useState(false), [review, setReview] = useState<ReferralReview | null>(null), [input, setInput] = useState(''), [consent, setConsent] = useState(false), [error, setError] = useState(''), [batch, setBatch] = useState<ReferralBatch | null>(null), [submitted, setSubmitted] = useState<string[]>([]), [history, setHistory] = useState<ReferralPage | null>(null), [period, setPeriod] = useState<ReferralPeriod>('past_90_days');
  const alive = useRef(false), pending = useRef(false), cursors = useRef(new Set<string>());
  useEffect(() => { alive.current = true; return () => { alive.current = false; }; }, [profileId]);
  const recipients = parseRecipients(input), uncertain = !!batch?.uncertain.length;
  async function perform(action: 'offer' | 'send' | 'check' | 'history', nextPeriod = period, more = false) {
    if (pending.current) return;
    pending.current = true; setBusy(true); setError('');
    try {
      if (action === 'offer') { const result = parseReferralReview(await invoke('get_account_referral_eligibility', { profileId, language: language === 'zh-Hans' ? 'zh' : 'en' }), profileId); if (alive.current) { setReview(result); setConsent(false); } }
      else if (action === 'history') {
        const cursor = more ? history?.cursor : null;
        const result = parseReferralPage(await invoke('get_account_referral_tracking', { profileId, period: nextPeriod, cursor, language: language === 'zh-Hans' ? 'zh' : 'en' }), profileId);
        if (result.cursor && (result.cursor === cursor || more && cursors.current.has(result.cursor))) throw Error('invalid_response');
        if (alive.current) { if (!more) cursors.current.clear(); if (result.cursor) cursors.current.add(result.cursor); setHistory(previous => ({ ...result, items: more ? [...(previous?.items ?? []).filter(x => !result.items.some(next => next.id === x.id)), ...result.items] : result.items })); setPeriod(nextPeriod); }
      } else {
        if (!review) return;
        const emails = action === 'check' ? submitted : recipients.emails;
        if (action === 'send' && (!canSend || uncertain)) return;
        let result: ReferralBatch;
        if (action === 'send') {
          // Hold the exact submitted list through failures. Never infer delivery from a timeout.
          setSubmitted(emails);
          try { result = parseReferralBatch(await invoke('send_account_referral_invites', { profileId, reviewId: review.reviewId, emails, consent, language: language === 'zh-Hans' ? 'zh' : 'en' }), profileId, emails.length); }
          catch (failure) { if (alive.current) { const code = typeof failure === 'string' ? failure : failure instanceof Error ? failure.message : ''; if (['referral_review_expired', 'referral_offer_changed', 'referral_capacity_reached', 'referral_consent_required', 'referral_invalid_email'].includes(code)) { setReview(null); setConsent(false); } else setBatch({ profileId, sent: [], failed: [], uncertain: emails.map((_, index) => index) }); } throw failure; }
        } else result = parseReferralBatch(await invoke('check_account_referral_outcome', { profileId, reviewId: review.reviewId, language: language === 'zh-Hans' ? 'zh' : 'en' }), profileId, emails.length);
        if (alive.current) { setBatch(result); if (result.uncertain.length === 0) { setInput(result.failed.map(index => emails[index]).join('\n')); setReview(null); setConsent(false); } }
      }
    } catch (failure) { if (alive.current) setError(failureText(failure, text)); }
    finally { pending.current = false; if (alive.current) setBusy(false); }
  }
  const canSend = !!review?.shouldShow && review.expiresAtMs > Date.now() && recipients.emails.length > 0 && recipients.emails.length <= review.invitationCapacity && !recipients.tooLong && recipients.invalid === 0 && (!review.requiresExplicitConfirmation || consent) && !uncertain;
  const status = { pending: text('待接受', 'Pending'), redeemed: text('已接受', 'Accepted'), expired: text('已过期', 'Expired'), unknown: text('状态待确认', 'Status pending') };
  return <div><button type="button" className="glass-button proxy-action" onClick={() => { setOpen(true); if (!review && !uncertain) void perform('offer'); }}><UserPlus size={14} />{text('邀请好友', 'Invite friends')}</button>
    {open && <ActionDialog title={text('邀请好友', 'Invite friends')} busy={busy} onClose={() => setOpen(false)}>
      <p><strong>{profileLabel}</strong></p><div className="flex flex-wrap gap-2"><button type="button" className="glass-button proxy-action" disabled={busy || uncertain} onClick={() => void perform('offer')}>{text('刷新邀请资格', 'Refresh eligibility')}</button><button type="button" className="glass-button proxy-action" disabled={busy} onClick={() => void perform('history')}>{text('查看邀请记录', 'View invitations')}</button></div>
      {busy && <p role="status">{text('正在读取或处理…', 'Reading or working…')}</p>}{error && <p role="alert" className="proxy-feedback is-error">{error}</p>}
      {review && <section className="space-y-2" aria-label={text('官方邀请条件', 'Official invitation offer')}><h3>{!review.shouldShow ? text('暂未开放邀请奖励', 'Referral rewards are not available now') : review.creditAmount === null ? text('官方未显示邀请点数', 'The official offer does not show invitation credits') : text(`每次符合条件的邀请：${review.creditAmount} 点`, `${review.creditAmount} credits per qualifying invitation`)}</h3>{review.title && <p>{review.title}</p>}{review.description && <p>{review.description}</p>}<p>{text('剩余发送 ', 'Send capacity ')}{review.remainingSendCapacity ?? '—'} · {text('奖励名额 ', 'Reward capacity ')}{review.remainingRewardCapacity ?? '—'} · {text('本次最多 ', 'Up to ')}{review.invitationCapacity}</p>{review.rules.length > 0 && <ul className="list-disc pl-5">{review.rules.map((rule, index) => <li key={index}>{rule}</li>)}</ul>}</section>}
      <label className="block space-y-1">{text('好友邮箱', "Friends' email addresses")}<textarea className="w-full rounded-lg border border-theme bg-surface-inset p-2 text-primary" rows={3} value={input} disabled={busy || uncertain} onChange={event => setInput(event.target.value)} aria-label={text('好友邮箱，可一次输入多个', 'Recipient emails; multiple addresses supported')} /></label>
      <p>{text('每行一个，或用逗号、分号、空格分隔；最多 5 个，重复邮箱自动合并。', 'Separate with new lines, commas, semicolons or spaces. Up to 5 addresses; duplicates are merged.')}</p>
      {(recipients.invalid > 0 || recipients.tooLong || recipients.emails.length > (review?.invitationCapacity ?? 5)) && <p role="status" className="text-status-warn">{text('请检查邮箱格式、长度和官方可用名额。', 'Check address format, length and available capacity.')}</p>}
      {review?.requiresExplicitConfirmation && <label className="flex items-center gap-2"><input type="checkbox" checked={consent} disabled={busy || uncertain} onChange={event => setConsent(event.target.checked)} />{text('我已征得以上好友同意发送邀请', 'I have consent from all recipients')}</label>}
      <button type="button" className="glass-button-solid proxy-action" disabled={busy || !canSend} onClick={() => void perform('send')}>{text('发送邀请', 'Send invitations')}</button>
      {batch && <section className="space-y-2" aria-label={text('本次邀请结果', 'Invitation results')}>{(['sent', 'failed', 'uncertain'] as const).flatMap(kind => batch[kind].map(index => <p key={index}>{submitted[index]} · {kind === 'sent' ? text('邀请已发送，等待好友接受', 'Invitation sent; awaiting acceptance') : kind === 'failed' ? text('未发送', 'Not sent') : text('结果待确认', 'Result unconfirmed')}</p>))}<p>{text('接受状态以官方记录为准；已接受不代表奖励已到账。', 'Acceptance comes from official records; acceptance does not establish that rewards were credited.')}</p></section>}
      {uncertain && <button type="button" className="glass-button proxy-action" disabled={busy} onClick={() => void perform('check')}>{text('核对邀请记录', 'Check invitation records')}</button>}
      {history && <section className="space-y-2 border-t border-theme pt-3" aria-label={text('邀请记录', 'Invitation history')}><label>{text('时间范围', 'Period')}<select className="ml-2 rounded-lg bg-surface-inset p-1" value={period} disabled={busy} onChange={event => void perform('history', event.target.value as ReferralPeriod)}><option value="past_90_days">{text('过去 90 天', 'Past 90 days')}</option><option value="this_month">{text('本月', 'This month')}</option></select></label>{history.items.map(item => <p key={item.id} className="flex justify-between gap-3"><span>{item.maskedEmail ?? text('邮箱未提供', 'Email unavailable')}</span><span>{status[item.status]}</span></p>)}{history.items.length === 0 && <p>{text('此时间范围内暂无邀请', 'No invitations in this period')}</p>}{history.cursor && <button type="button" className="glass-button proxy-action" disabled={busy} onClick={() => void perform('history', period, true)}>{text('加载更多', 'Load more')}</button>}<p>{text(`已加载 ${history.items.length} 条`, `${history.items.length} loaded`)}</p></section>}
    </ActionDialog>}
  </div>;
}
/** Row-local commands intentionally do not inherit proxy or unrelated task busy state. */
export function AccountActions(props: { profileId: string; profileLabel: string; onChanged?: () => void }) {
  return <div className="account-manual-actions flex flex-wrap gap-2" data-testid={`account-actions-${props.profileId}`}><ResetAction key={`reset-${props.profileId}`} {...props} /><ReferralAction key={`referral-${props.profileId}`} {...props} /></div>;
}
