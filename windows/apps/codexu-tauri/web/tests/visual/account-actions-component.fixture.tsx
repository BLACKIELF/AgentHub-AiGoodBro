// Mounts the real production components to exercise prop changes that card keys
// normally avoid. All IPC replies are supplied by the synthetic test harness.
import React from 'react';
import { createRoot } from 'react-dom/client';
import { I18nProvider } from '../../src/i18n/I18nProvider';
import { AccountActions } from '../../src/components/AccountActions';
import { AccountDetails } from '../../src/components/AccountDetails';
import { AccountWorkflow } from '../../src/components/AccountWorkflow';
export function mountAccountComponent(kind: 'actions' | 'details' | 'workflow', initialProfile: string) {
  const element = document.createElement('div'); element.dataset.testid = 'account-component-fixture'; document.body.append(element);
  const root = createRoot(element);
  function render(profileId: string) {
    root.render(<I18nProvider>{kind === 'actions' ? <AccountActions profileId={profileId} profileLabel={`Synthetic ${profileId}`} /> : kind === 'details' ? <AccountDetails profileId={profileId} profileLabel={`Synthetic ${profileId}`} details={null} current={false} onClose={() => root.unmount()} /> : <AccountWorkflow profileId={profileId} />}</I18nProvider>);
  }
  render(initialProfile);
  return { render, unmount: () => { root.unmount(); element.remove(); } };
}
