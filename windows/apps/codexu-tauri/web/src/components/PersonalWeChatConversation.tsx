import { useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { RefreshCw } from 'lucide-react';
import { useI18n } from '../i18n/I18nProvider';
import { notificationError, notificationFailureText, type NotificationChannel } from '../utils/notificationChannels';
import { parsePersonalConversationState, type PersonalConversationState } from '../utils/personalWeChatConversation';
import { parseWorkbench, type WorkbenchSnapshot } from '../utils/taskWorkbench';

type Text = (zh: string, en: string) => string;

export function PersonalWeChatConversation({ channel, disabled }: { channel: NotificationChannel; disabled: boolean }) {
  const { language } = useI18n();
  const text: Text = (zh, en) => language === 'zh-Hans' ? zh : en;
  const [state, setState] = useState<PersonalConversationState | null>(null);
  const [workbench, setWorkbench] = useState<WorkbenchSnapshot | null>(null);
  const [selected, setSelected] = useState('');
  const [confirmed, setConfirmed] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const alive = useRef(false);
  const readSequence = useRef(0);
  const operation = useRef(false);

  async function readState() {
    if (operation.current) return;
    const sequence = ++readSequence.current;
    try {
      const value = parsePersonalConversationState(await invoke('get_personal_wechat_conversation_state'));
      if (!alive.current || sequence !== readSequence.current || operation.current) return;
      setState(value);
      setError(null);
    } catch (failure) {
      if (alive.current && sequence === readSequence.current) setError(notificationError(failure));
    }
  }

  async function loadChats() {
    if (operation.current || disabled) return;
    operation.current = true;
    ++readSequence.current;
    setConfirmed(false);
    setBusy(true); setError(null); setNotice(null);
    try {
      const value = parseWorkbench(await invoke('get_task_workbench'));
      if (!alive.current) return;
      setWorkbench(value);
      if (state?.binding && state.binding.expectedScopeId === value.scopeId) setSelected(state.binding.threadId);
      else setSelected('');
      if (value.sourceAvailable) setNotice(text('已读取本机聊天列表。选择一个原聊天后再确认。', 'Loaded the local chat list. Select an original chat before confirming.'));
    } catch (failure) {
      if (alive.current) setError(notificationError(failure));
    } finally {
      operation.current = false;
      if (alive.current) { setBusy(false); void readState(); }
    }
  }

  async function update(command: string, args: Record<string, unknown>) {
    if (operation.current || disabled) return;
    operation.current = true;
    ++readSequence.current;
    setBusy(true); setError(null); setNotice(null);
    try {
      const value = parsePersonalConversationState(await invoke(command, args));
      if (!alive.current) return;
      setState(value);
      setConfirmed(false);
      if (value.binding) setSelected(value.binding.threadId);
      setNotice(text('原聊天绑定状态已更新。', 'Original chat binding state updated.'));
    } catch (failure) {
      if (alive.current) setError(notificationError(failure));
    } finally {
      operation.current = false;
      if (alive.current) setBusy(false);
    }
  }

  useEffect(() => {
    alive.current = false;
    setConfirmed(false);
    if (channel.channel !== 'personal-wechat' || !channel.enabled) return;
    alive.current = true;
    void readState();
    let disposed = false;
    let release: (() => void) | undefined;
    void listen('notification-channels:changed', () => { if (!disposed) void readState(); })
      .then(unlisten => { if (disposed) unlisten(); else release = unlisten; })
      .catch(() => { if (!disposed) setError('notification_events_unavailable'); });
    return () => { disposed = true; alive.current = false; ++readSequence.current; release?.(); };
  }, [channel.enabled, channel.revision]);
  useEffect(() => { setConfirmed(false); }, [state?.revision]);

  if (channel.channel !== 'personal-wechat' || !channel.enabled) return null;
  const ready = channel.credentialPresent && channel.targetPresent && channel.phase !== 'session_expired';
  const entries = (workbench?.items ?? []).filter(item => !item.archived);
  const selectedItem = entries.find(item => item.threadId === selected);
  const boundItem = state?.binding && workbench?.scopeId === state.binding.expectedScopeId
    ? entries.find(item => item.threadId === state.binding?.threadId)
    : undefined;
  const canBind = ready && !busy && !disabled && !!state && !!workbench?.sourceAvailable && !!workbench && !!selectedItem && confirmed;
  const errorText = error ? notificationFailureText(error, text) : null;

  return <details className="notification-options" data-testid="personal-wechat-conversation">
    <summary>{text('自动接续到原 Codex 聊天', 'Continue in an original Codex chat')}</summary>
    <p className="notification-note">{text('仅处理发给已绑定机器人的新文本消息。内容会交给你选定的原聊天；只把该回合的最终回答发回微信。消息正文和会话令牌不会写入本机记录。', 'Only new text messages sent to the paired bot are handled. The selected original chat receives the message; only that turn’s final answer is sent back to WeChat. Message bodies and event context tokens are not written to the local journal.')}</p>
    {!ready && <p role="status" className="notification-note">{text('先完成个人微信扫码绑定并启用通知。', 'Pair personal WeChat with QR and enable its notification channel first.')}</p>}
    {state?.binding && <p className="notification-note" data-testid="personal-wechat-bound-thread">{text('当前原聊天', 'Bound original chat')}: {boundItem?.title ?? state.binding.threadId}</p>}
    {state?.needsConfirmation && <p role="alert" className="notification-note is-error">{text('微信凭据已变化。请重新选择并确认原聊天后才能继续。', 'The WeChat credentials changed. Select and confirm the original chat again before continuing.')}</p>}
    {workbench && !workbench.sourceAvailable && <p role="alert" className="notification-note is-error">{text('本机聊天来源暂不可验证。刷新聊天列表后重试。', 'The local chat source cannot be verified. Refresh the chat list and try again.')}</p>}
    {errorText && <p role="alert" className="notification-note is-error">{errorText}</p>}
    {notice && <p role="status" className="notification-note">{notice}</p>}
    <div className="notification-card-actions">
      <button type="button" className="glass-button notification-small-button" disabled={busy || disabled || !ready} onClick={() => void loadChats()}>
        <RefreshCw size={13} className={busy ? 'animate-spin' : ''}/>{text('读取本机聊天', 'Read local chats')}
      </button>
      {state?.binding && state.enabled && <button type="button" className="glass-button notification-small-button" disabled={busy || disabled} onClick={() => void update('set_personal_wechat_conversation_enabled', { expectedRevision: state.revision, enabled: false })}>{text('暂停自动接续', 'Pause auto replies')}</button>}
      {state?.binding && !state.enabled && !state.needsConfirmation && ready && <button type="button" className="glass-button notification-small-button" disabled={busy || disabled} onClick={() => void update('set_personal_wechat_conversation_enabled', { expectedRevision: state.revision, enabled: true })}>{text('恢复自动接续', 'Resume auto replies')}</button>}
      {state?.binding && <button type="button" className="glass-button notification-small-button" disabled={busy || disabled} onClick={() => void update('unbind_personal_wechat_conversation', { expectedRevision: state.revision })}>{text('移除原聊天绑定', 'Remove original chat binding')}</button>}
    </div>
    {workbench && workbench.sourceAvailable && <label className="notification-conversation-select">
      {text('选择原聊天', 'Select original chat')}
      <select aria-label={text('选择原聊天', 'Select original chat')} value={selected} disabled={busy || disabled || !ready} onChange={event => { setSelected(event.target.value); setConfirmed(false); }}>
        <option value="">{text('请选择…', 'Choose…')}</option>
        {entries.map(item => <option key={item.threadId} value={item.threadId}>{item.title} · {item.project} · {item.threadId}</option>)}
      </select>
    </label>}
    {workbench?.sourceAvailable && <label className="notification-conversation-consent">
      <input type="checkbox" checked={confirmed} disabled={busy || disabled || !ready || !selectedItem} onChange={event => setConfirmed(event.target.checked)}/>
      <span>{text('我确认把机器人收到的新消息发到此原聊天，并将该聊天的最终回答发送回微信。', 'I consent to forwarding new bot messages to this original chat and sending its final answer back to WeChat.')}</span>
    </label>}
    <div className="notification-card-actions">
      <button type="button" className="glass-button-solid notification-small-button" data-testid="personal-wechat-bind-original-chat" disabled={!canBind} onClick={() => void update('bind_personal_wechat_conversation', { expectedRevision: state!.revision, expectedScopeId: workbench!.scopeId, threadId: selected, confirmed: true })}>{state?.needsConfirmation ? text('重新确认绑定', 'Confirm binding again') : text('确认并启用', 'Confirm and enable')}</button>
    </div>
  </details>;
}
