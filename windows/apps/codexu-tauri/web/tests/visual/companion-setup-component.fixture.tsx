import React from 'react';
import {createRoot} from 'react-dom/client';
import {I18nProvider} from '../../src/i18n/I18nProvider';
import {CompanionSetupPanel} from '../../src/components/CompanionSetupPanel';
export function mountCompanionSetup(element: HTMLElement) {
  const root = createRoot(element);
  root.render(<I18nProvider><CompanionSetupPanel/></I18nProvider>);
  return () => root.unmount();
}
