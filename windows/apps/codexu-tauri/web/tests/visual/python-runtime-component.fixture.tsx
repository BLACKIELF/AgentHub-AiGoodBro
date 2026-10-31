import React from 'react';import {createRoot} from 'react-dom/client';import {I18nProvider} from '../../src/i18n/I18nProvider';import {PythonRuntimeSetupPanel} from '../../src/components/PythonRuntimeSetupPanel';
export function mountPythonRuntime(element:HTMLElement){const root=createRoot(element);root.render(<I18nProvider><PythonRuntimeSetupPanel/></I18nProvider>);return()=>root.unmount();}
