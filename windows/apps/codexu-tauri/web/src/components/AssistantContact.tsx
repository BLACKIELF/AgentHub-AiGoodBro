import { useEffect, useRef, useState } from 'react';
import { useI18n } from '../i18n/I18nProvider';

export function AssistantContact() {
  const { language } = useI18n();
  const text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  const dialog = useRef<HTMLDialogElement>(null);
  const timer = useRef<ReturnType<typeof setTimeout>>();
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState(false);
  useEffect(() => () => clearTimeout(timer.current), []);
  async function copy() {
    try {
      await navigator.clipboard.writeText('AiGoodBro');
      setCopied(true); setError(false);
      clearTimeout(timer.current); timer.current = setTimeout(() => setCopied(false), 2000);
    } catch { setCopied(false); setError(true); }
  }
  return <section className="glass-panel p-5 space-y-3" aria-label={text('关于 AiGoodBro', 'About AiGoodBro')}>
    <h2 className="text-lg font-semibold text-primary">AiGoodBro</h2>
    <div className="flex flex-wrap items-center gap-5">
      <div className="space-y-2 flex-1 min-w-48">
        <h3 className="font-medium text-primary">{text('联系小助理', 'Contact the assistant')}</h3>
        <p className="text-sm text-secondary">{text('微信号：', 'WeChat: ')}<span className="select-text font-medium">AiGoodBro</span></p>
        <button type="button" className="glass-button px-3 py-2 text-sm" onClick={() => void copy()}>{copied ? text('已复制', 'Copied') : text('复制微信号', 'Copy WeChat ID')}</button>
        <p role="status" className="text-xs text-secondary">{error ? text('复制失败，请选中微信号手动复制。', 'Copy failed. Select the ID and copy it manually.') : text('扫描二维码添加，点击可放大。', 'Scan to add; select the image to enlarge.')}</p>
      </div>
      <button type="button" className="rounded-xl overflow-hidden" aria-label={text('放大微信二维码', 'Enlarge WeChat QR code')} onClick={() => dialog.current?.showModal()}>
        <img src="/assistant-wechat.jpg" alt={text('小助理微信二维码', 'Assistant WeChat QR code')} className="w-32 h-auto" />
      </button>
    </div>
    <dialog ref={dialog} className="rounded-2xl p-5 bg-surface text-primary max-w-[90vw] max-h-[90vh] overflow-auto backdrop:bg-black/60">
      <div className="flex items-center justify-between gap-5 mb-3"><h3>{text('微信扫码添加小助理', 'Add the assistant on WeChat')}</h3><button type="button" className="glass-button px-3 py-1.5" onClick={() => dialog.current?.close()}>{text('关闭', 'Close')}</button></div>
      <img src="/assistant-wechat.jpg" alt={text('小助理微信二维码', 'Assistant WeChat QR code')} className="w-80 max-w-full h-auto" />
    </dialog>
  </section>;
}
