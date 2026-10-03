import { useCallback, useEffect, useRef, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import type { CodexDashboardSnapshot } from '../types/models';
import {
  isTauriRuntimeAvailable,
  requireTauriRuntime,
} from '../utils/tauri';

export function useUsage() {
  const [dashboard, setDashboard] = useState<CodexDashboardSnapshot | null | undefined>(undefined);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const generation = useRef(0);

  const load = useCallback(async (force = false) => {
    const epoch = ++generation.current;
    setLoading(true);
    setError(null);
    try {
      requireTauriRuntime();
      const result = await invoke<CodexDashboardSnapshot | null>(
        force ? 'refresh_usage' : 'get_local_usage'
      );
      if (epoch === generation.current) setDashboard(result);
    } catch (e) {
      if (epoch === generation.current) setError(String(e));
    } finally {
      if (epoch === generation.current) setLoading(false);
    }
  }, []);

  const changeSource = useCallback(() => {
    setDashboard(undefined);
    // Backend source keys invalidate the cache; ordinary reads coalesce across windows.
    void load();
  }, [load]);

  useEffect(() => {
    void load();
    let cancelled = false;
    const unlisteners: (() => void)[] = [];
    if (isTauriRuntimeAvailable()) {
      for (const [event, callback] of [
        ['usage:updated', () => { void load(); }],
        ['usage:source-changed', changeSource],
      ] as const) {
        void listen(event, callback).then(unlisten => {
          if (cancelled) unlisten(); else unlisteners.push(unlisten);
        }).catch(e => { if (!cancelled) setError(String(e)); });
      }
    }
    return () => {
      cancelled = true;
      generation.current++;
      unlisteners.forEach(unlisten => unlisten());
    };
  }, [load, changeSource]);

  return { dashboard, loading, error, refresh: () => load(true), changeSource };
}
