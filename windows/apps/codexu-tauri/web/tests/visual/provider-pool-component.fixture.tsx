import React from 'react';
import {createRoot} from 'react-dom/client';
import {flushSync} from 'react-dom';
import {I18nProvider} from '../../src/i18n/I18nProvider';
import {ProviderAccountPoolPanel} from '../../src/components/ProviderAccountPoolPanel';
export function mountProviderPool(element:HTMLElement,initial=true){const root=createRoot(element);let active=initial;const render=()=>root.render(<I18nProvider><ProviderAccountPoolPanel active={active}/></I18nProvider>);render();return{active(value:boolean){active=value;flushSync(render);},unmount(){root.unmount();}};}
