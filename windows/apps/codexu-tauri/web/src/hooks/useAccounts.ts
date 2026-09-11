import { useCallback, useEffect, useState } from 'react';
import { invoke } from '@tauri-apps/api/core';
import type { AccountQuotaSnapshot, AccountsDto } from '../types/accounts';
import { isTauriRuntimeAvailable, requireTauriRuntime } from '../utils/tauri';

/**
 * Read the local account workbench data.
 *
 * The reader is read-only and never returns credential material, so a failure
 * here degrades to an empty panel with an explicit message instead of hiding the
 * rest of the dashboard.
 */
export function useAccounts() {
  const [accounts, setAccounts] = useState<AccountsDto | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!isTauriRuntimeAvailable()) return;

    setLoading(true);
    setError(null);
    try {
      requireTauriRuntime();
      const result = await invoke<AccountsDto>('list_accounts');
      setAccounts(result);
    } catch (cause) {
      setError(String(cause));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const refreshQuota = useCallback(async (accountId: string) => {
    if (!isTauriRuntimeAvailable()) return;
    try {
      requireTauriRuntime();
      const snapshot = await invoke<AccountQuotaSnapshot>('refresh_account_quota', {
        accountId,
      });
      setAccounts((current) => {
        if (!current) return current;
        return {
          ...current,
          quotas: { ...current.quotas, [accountId]: snapshot },
        };
      });
    } catch (cause) {
      setError(String(cause));
    }
  }, []);

  return { accounts, loading, error, refresh: load, refreshQuota };
}
