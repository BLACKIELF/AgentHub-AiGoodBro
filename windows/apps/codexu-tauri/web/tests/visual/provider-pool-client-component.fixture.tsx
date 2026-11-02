import React from 'react';
import {createRoot} from 'react-dom/client';
import {flushSync} from 'react-dom';
import {I18nProvider} from '../../src/i18n/I18nProvider';
import {ProviderPoolClients} from '../../src/components/ProviderPoolClients';
import type {PoolProvider,PoolSnapshot} from '../../src/utils/providerPool';

export const clientSnapshot:PoolSnapshot={
 phase:'running',runId:'r'.repeat(43),port:18081,accounts:[],providers:['antigravity','claude'],
 providerModels:{antigravity:['gemini-3.1-pro','claude-3.7-sonnet'],claude:['claude-3.7-sonnet']},
 authorization:null,issueCode:null,
};
export function mountProviderPoolClient(element:HTMLElement){
 const root=createRoot(element);let provider:PoolProvider='antigravity',snapshot=clientSnapshot;
 const render=()=>root.render(<I18nProvider><ProviderPoolClients snapshot={snapshot} provider={provider} disabled={false}/></I18nProvider>);
 render();return{
  provider(value:PoolProvider){provider=value;flushSync(render);},
  snapshot(value:PoolSnapshot){snapshot=value;flushSync(render);},
  unmount(){root.unmount();},
 };
}
