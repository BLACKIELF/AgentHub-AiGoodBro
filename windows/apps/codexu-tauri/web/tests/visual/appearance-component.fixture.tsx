import React from 'react';
import {createRoot} from 'react-dom/client';
import {I18nProvider} from '../../src/i18n/I18nProvider';
import {AppearanceControls} from '../../src/components/AppearanceControls';
import {AppearanceRuntime} from '../../src/components/AppearanceRuntime';
import {QuotaRing} from '../../src/components/QuotaRing';
export function mountAppearance(node:HTMLElement){const root=createRoot(node);root.render(<I18nProvider><AppearanceRuntime/><div className="glass-panel p-5"><AppearanceControls/><div className="flex gap-5 mt-4"><QuotaRing label="5h" remaining={80} description="Synthetic quota"/><QuotaRing label="unknown" remaining={null} description="Unknown quota"/></div></div></I18nProvider>);return()=>root.unmount();}
