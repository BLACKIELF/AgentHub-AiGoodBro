import {useEffect} from 'react';
import {useAppearancePreferences} from '../hooks/useAppearancePreferences';
import {defaultAppearance} from '../utils/appearancePreferences';
import '../styles/appearance.css';
/** One per document, including compact windows. No native account or task action. */
export function AppearanceRuntime() {
  const {value} = useAppearancePreferences();
  useEffect(() => {
    const root = document.documentElement, current = value ?? defaultAppearance();
    root.dataset.workspaceAppearance = 'enabled';
    root.dataset.glassBackdrop = current.systemGlass ? 'system' : 'transparent';
    root.dataset.ringMotion = current.ringMotion;
    root.style.setProperty('--appearance-opacity', `${Math.max(current.systemGlass ? 0 : 5, current.opacity)}%`);
    root.style.setProperty('--appearance-line', `${10 + current.depth * .09}%`);
    root.style.setProperty('--appearance-control', `${3 + current.depth * .045}%`);
  }, [value]);
  useEffect(() => {
    const update = () => {document.documentElement.dataset.appearanceActive = String(!document.hidden && document.hasFocus());};
    update(); window.addEventListener('focus', update); window.addEventListener('blur', update); document.addEventListener('visibilitychange', update);
    return () => {window.removeEventListener('focus', update); window.removeEventListener('blur', update); document.removeEventListener('visibilitychange', update); document.documentElement.dataset.appearanceActive = 'false';};
  }, []);
  return null;
}
