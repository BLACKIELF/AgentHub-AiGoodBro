import { useEffect } from 'react';
import { Minus, Pencil, X } from 'lucide-react';
import { useCompactUi } from '../hooks/useCompactUi';
import { useSettings } from '../hooks/useSettings';
import { useI18n } from '../i18n/I18nProvider';
import { applyAppTheme } from '../utils/appTheme';
import { DEFAULT_PALETTE_ID } from '../utils/paletteCatalog';
import { BubblePreferencesForm, BubblePreview } from '../components/FloatingBubbleSettings';

export function FloatingQuotaBubble({ editor = false }: { editor?: boolean }) {
  const ui = useCompactUi(), { settings } = useSettings(), { language } = useI18n();
  const text = (zh: string, en: string) => language === 'zh-Hans' ? zh : en;
  useEffect(() => { document.body.classList.add('compact-native-surface'); return () => document.body.classList.remove('compact-native-surface'); }, []);
  useEffect(() => { applyAppTheme(settings?.config.theme ?? 'dark', settings?.config.palette_id ?? DEFAULT_PALETTE_ID); }, [settings?.config.theme, settings?.config.palette_id]);
  if (editor) return <main className="floating-bubble-editor glass-panel"><header><h1>{text('悬浮额度', 'Floating quota')}</h1><button aria-label={text('关闭', 'Close')} onClick={() => void ui.action('close')} disabled={ui.busy}><X size={16} /></button></header><BubblePreferencesForm ui={ui} onCancel={() => void ui.action('close')} /></main>;
  const collapsed = ui.state?.windows.find(window => window.surface === 'floating_bubble')?.collapsed;
  if (collapsed) return <button className="floating-bubble-handle" aria-label={text('展开悬浮额度', 'Expand floating quota')} onClick={() => void ui.action('collapse')} disabled={ui.busy}>›</button>;
  return <main className="floating-quota-bubble glass-panel" data-testid="floating-quota-bubble">
    <header><button className="bubble-drag" aria-label={text('移动悬浮额度', 'Move floating quota')} onPointerDown={event => { if (event.button === 0) void ui.action('drag'); }}>•••</button><button aria-label={text('编辑悬浮额度', 'Edit floating quota')} disabled={ui.busy} onClick={() => void ui.action('edit_bubble')}><Pencil size={14} /></button><button aria-label={text('收起悬浮额度', 'Collapse floating quota')} disabled={ui.busy} onClick={() => void ui.action('collapse')}><Minus size={14} /></button><button aria-label={text('关闭悬浮额度', 'Close floating quota')} disabled={ui.busy} onClick={() => void ui.action('close')}><X size={14} /></button></header>
    {ui.state ? <BubblePreview preferences={ui.state.preferences.bubble} accounts={ui.state.cachedProjection.accounts} /> : <p>{text('正在读取…', 'Reading…')}</p>}
    {ui.error && <p role="alert">{text('窗口状态未确认，请重试。', 'Window state is unconfirmed. Retry.')}</p>}
  </main>;
}
