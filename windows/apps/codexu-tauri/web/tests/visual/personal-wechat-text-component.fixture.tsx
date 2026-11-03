// Test-only adapter mounts the actual production component/provider.
import React from 'react';
import { createRoot } from 'react-dom/client';
import { flushSync } from 'react-dom';
import { I18nProvider } from '../../src/i18n/I18nProvider';
import { PersonalWeChatText } from '../../src/components/PersonalWeChatText';
import type { NotificationChannel } from '../../src/utils/notificationChannels';
export function mountPersonalText(element: HTMLElement, initial: NotificationChannel) {
  const root = createRoot(element); let channel = initial; let disabled = false;
  const render = () => root.render(<I18nProvider><PersonalWeChatText channel={channel} disabled={disabled} onChanged={() => {}} /></I18nProvider>);
  render(); return { update(next: Partial<NotificationChannel>, blocked = false) { channel = { ...channel, ...next }; disabled = blocked; flushSync(render); }, unmount() { root.unmount(); } };
}
