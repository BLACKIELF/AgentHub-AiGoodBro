// Test-only mounting adapter for the actual production order editor.
import React from 'react'; import { createRoot } from 'react-dom/client'; import { flushSync } from 'react-dom';
import { I18nProvider } from '../../src/i18n/I18nProvider'; import { ManagedAccountOrder } from '../../src/components/ManagedAccountOrder';
export function mountAccountOrder(element: HTMLElement, initial: {id:string;label:string}[]) {
 const root=createRoot(element);let rows=initial;const render=()=>root.render(<I18nProvider><ManagedAccountOrder accounts={rows} disabled={false} onChanged={()=>{}}/></I18nProvider>);render();
 return {update(next:typeof rows){rows=next;flushSync(render);},unmount(){root.unmount();}};
}
