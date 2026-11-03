import { useCallback, useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { currentLiveTasks, LIVE_TASK_MAX_AGE_MS, parseLiveTasks, unavailableLiveTasks, type LiveTaskState } from '../utils/liveTasks';

export function useLiveTasks() {
  const [state, setState] = useState<LiveTaskState>(unavailableLiveTasks), [busy, setBusy] = useState(false);
  const alive = useRef(false), epoch = useRef(0), pending = useRef(false), reconnecting = useRef(false), again = useRef(false), request = useRef<() => Promise<void>>(async () => {});
  const read = useCallback(async () => {
    if (!alive.current) return;
    if (pending.current) { again.current = true; return; }
    pending.current = true; const generation = ++epoch.current;
    try { const value = parseLiveTasks(await invoke('get_live_task_state')); if (alive.current && generation === epoch.current) setState(currentLiveTasks(value)); }
    catch { if (alive.current && generation === epoch.current) setState(unavailableLiveTasks()); }
    finally { pending.current = false; if (again.current && alive.current) { again.current = false; queueMicrotask(() => void request.current()); } }
  }, []);
  request.current = read;
  useEffect(() => {
    alive.current = true; let disposed = false, release: (() => void) | undefined;
    void listen('live-tasks:changed', () => {
      if (disposed) return;
      epoch.current++; setState(unavailableLiveTasks()); void read();
    }).then(unlisten => { if (disposed) unlisten(); else { release = unlisten; void read(); } }).catch(() => { if (!disposed) setState(unavailableLiveTasks()); });
    return () => { disposed = true; alive.current = false; epoch.current++; release?.(); };
  }, [read]);
  useEffect(() => {
    if (state.phase !== 'live' || state.observedAtMs === null) return;
    const timer = setTimeout(() => setState(previous => currentLiveTasks(previous)), Math.max(0, state.observedAtMs + LIVE_TASK_MAX_AGE_MS + 1 - Date.now()));
    return () => clearTimeout(timer);
  }, [state]);
  const reconnect = async () => {
    if (reconnecting.current || !alive.current) return;
    reconnecting.current = true;
    const generation = ++epoch.current; setState(unavailableLiveTasks()); setBusy(true);
    try { const value = parseLiveTasks(await invoke('reconnect_live_tasks')); if (alive.current && generation === epoch.current) setState(currentLiveTasks(value)); }
    catch { if (alive.current && generation === epoch.current) setState(unavailableLiveTasks()); }
    finally { reconnecting.current = false; if (alive.current) setBusy(false); void read(); }
  };
  return { state, busy, read, reconnect };
}
