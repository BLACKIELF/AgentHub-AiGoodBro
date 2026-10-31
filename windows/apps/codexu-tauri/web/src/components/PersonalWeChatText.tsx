import { useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { useI18n } from '../i18n/I18nProvider';
import { notificationCanTest, notificationError, notificationFailureText, type NotificationChannel } from '../utils/notificationChannels';
import { parsePersonalTextReceipt, personalTextBytes, validPersonalText, type PersonalTextReceipt } from '../utils/personalWeChatText';

export function PersonalWeChatText({ channel, disabled, onChanged }: { channel: NotificationChannel; disabled: boolean; onChanged: () => void | Promise<void> }) {
  const { language } = useI18n();
  const text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const [draft, setDraft] = useState(''), [pending, setPending] = useState(false), [error, setError] = useState<string | null>(null);
  const [receipt, setReceipt] = useState<PersonalTextReceipt | null>(null), [unknown, setUnknown] = useState<string | null>(null);
  const alive = useRef(false), generation = useRef(0), active = useRef<object | null>(null);
  const binding = `${channel.revision}:${channel.enabled}`;
  const currentBinding = useRef(binding); currentBinding.current = binding;
  useEffect(() => { alive.current = true; return () => { alive.current = false; generation.current++; }; }, []);
  useEffect(() => { generation.current++; setReceipt(null); setError(null); }, [binding]);
  const allowed = channel.channel === 'personal-wechat' && notificationCanTest(channel) && !disabled;
  async function send() {
    if (!allowed || active.current || !validPersonalText(draft) || unknown === draft) return;
    const submitted = draft, revision = channel.revision, epoch = generation.current, submittedBinding = binding, token = {};
    const requestId = crypto.randomUUID().replace(/-/g, '');
    active.current = token; setPending(true); setError(null); setReceipt(null); setUnknown(submitted);
    try {
      const next = parsePersonalTextReceipt(await invoke('send_personal_wechat_text', { requestId, expectedRevision: revision, text: submitted, confirmed: true }), requestId, revision);
      if (!alive.current || epoch !== generation.current || currentBinding.current !== submittedBinding) return;
      setReceipt(next);
      if (next.state === 'accepted') { setUnknown(null); setDraft(current => current === submitted ? '' : current); }
      else if (next.state === 'uncertain') setUnknown(submitted);
      else setUnknown(null);
      void Promise.resolve(onChanged()).catch(() => undefined);
    } catch (failure) {
      if (alive.current && epoch === generation.current && currentBinding.current === submittedBinding) { setError(notificationError(failure)); setUnknown(submitted); }
    } finally { if (active.current === token) { active.current = null; if (alive.current) setPending(false); } }
  }
  if (channel.channel !== 'personal-wechat' || !channel.enabled) return null;
  return <details className="notification-personal-text"><summary>{text('发送微信文本', 'Send WeChat text')}</summary>
    <label>{text('微信发送内容', 'WeChat message text')}<textarea aria-label={text('微信发送内容', 'WeChat message text')} rows={4} value={draft} maxLength={4096} disabled={pending || disabled} onChange={event => { setDraft(event.target.value); setError(null); setReceipt(null); }} /></label>
    <p className="notification-note">{text('正文与来源标记合计', 'Text and source footer')}: {personalTextBytes(draft)} / 4096 bytes</p>
    <button type="button" className="glass-button notification-small-button" disabled={!allowed || pending || !validPersonalText(draft) || unknown === draft} onClick={() => void send()}>{pending ? text('正在发送…', 'Sending…') : text('发送到已绑定的微信', 'Send to paired WeChat')}</button>
    {error && <p role="alert" className="notification-note is-error">{notificationFailureText(error, text)}</p>}
    {!pending && (receipt || unknown !== null) && <p role="status" className="notification-note">{receipt?.state === 'accepted' ? text('个人微信 API 已接收文本；不代表收到或已读。', 'Personal WeChat API accepted the text; receipt and reading are unconfirmed.') : receipt?.state === 'rejected' || receipt?.state === 'not_sent' ? text('本次未被接口接受，草稿已保留。', 'This submission was not accepted. The draft is retained.') : text('发送结果未确认，未自动重发。请先在微信核对。', 'The send outcome is unconfirmed. No automatic retry was made. Check WeChat first.')}</p>}
  </details>;
}
