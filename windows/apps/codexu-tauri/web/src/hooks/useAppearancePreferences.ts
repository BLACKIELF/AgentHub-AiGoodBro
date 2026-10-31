import {useEffect, useRef, useState} from 'react';
import {APPEARANCE_EVENT, APPEARANCE_KEY, readAppearance, saveAppearance, type AppearancePatch, type AppearancePreference} from '../utils/appearancePreferences';
export function useAppearancePreferences() {
  const [value, setValue] = useState<AppearancePreference | null>(() => {try {return readAppearance();} catch {return null;}});
  const [error, setError] = useState(value === null), [busy, setBusy] = useState(false);
  const alive = useRef(false), saving = useRef(false);
  function read() {try {setValue(readAppearance()); setError(false);} catch {setError(true);}}
  useEffect(() => {
    alive.current = true;
    const storage = (event: StorageEvent) => {if (event.key === APPEARANCE_KEY || event.key === null) read();};
    window.addEventListener('storage', storage); window.addEventListener(APPEARANCE_EVENT, read);
    return () => {alive.current = false; window.removeEventListener('storage', storage); window.removeEventListener(APPEARANCE_EVENT, read);};
  }, []);
  async function save(patch: AppearancePatch) {
    if (saving.current) return false;
    saving.current = true; setBusy(true); setError(false);
    try {const next = await saveAppearance(patch); if (alive.current) setValue(next); return true;}
    catch {if (alive.current) setError(true); return false;}
    finally {saving.current = false; if (alive.current) setBusy(false);}
  }
  return {value, error, busy, read, save};
}
