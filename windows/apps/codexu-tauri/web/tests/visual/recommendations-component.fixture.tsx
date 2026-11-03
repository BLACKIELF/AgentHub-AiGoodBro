import React from 'react';
import {createRoot} from 'react-dom/client';
import {I18nProvider} from '../../src/i18n/I18nProvider';
import {RecommendedSkills} from '../../src/components/RecommendedSkills';
export function mountRecommendations(node:HTMLElement){const root=createRoot(node);root.render(<I18nProvider><RecommendedSkills/></I18nProvider>);return()=>root.unmount();}
