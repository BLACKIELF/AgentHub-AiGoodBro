// Test-only mounting adapter; renders the actual production component/provider.
import React from 'react';
import { createRoot } from 'react-dom/client';
import { I18nProvider } from '../../src/i18n/I18nProvider';
import { ClaudeSwapImport } from '../../src/components/ClaudeSwapImport';

export function mountClaudeSwap(element: HTMLElement) {
  const root = createRoot(element);
  let generation = 0;
  const render = () => root.render(<I18nProvider><ClaudeSwapImport key={generation} disabled={false} onImported={async () => {}} /></I18nProvider>);
  render();
  return { remount() { generation++; render(); }, unmount() { root.unmount(); } };
}
