/**
 * Account workbench types.
 *
 * These mirror the Rust DTOs in `crates/codexu-core/src/models/` and the Tauri
 * command payloads in `apps/codexu-tauri/src-tauri/src/commands/accounts.rs`.
 * Field names stay snake_case so the JSON crosses the IPC boundary unchanged.
 */

export type CodexModelId =
  | 'gpt-6-astra'
  | 'gpt-5.6-sol'
  | 'gpt-5.6-terra'
  | 'gpt-5.6-luna'
  | 'gpt-5.5'
  | 'gpt-5.2';

export type ReasoningEffortId = 'low' | 'medium' | 'high' | 'xhigh' | 'max' | 'ultra';

/** `standard` serialises as `default` on the wire. */
export type ServiceTierId = 'default' | 'fast';

export type SubagentModeId = 'standard' | 'sol_luna' | 'luna_direct';

export interface CustomPreset {
  name: string | null;
  use_saved_model: boolean;
  model: CodexModelId;
  reasoning_effort: ReasoningEffortId;
  subagents_enabled: boolean;
  subagent_model: CodexModelId;
  subagent_reasoning_effort: ReasoningEffortId;
}

export interface ExecutionPreference {
  model: CodexModelId;
  reasoning_effort: ReasoningEffortId;
  service_tier: ServiceTierId;
  subagent_mode: SubagentModeId;
  custom_presets?: Record<string, CustomPreset>;
}

export interface AccountIdentity {
  id: string;
  label: string;
  masked_email: string | null;
  plan_label: string | null;
  is_signed_in: boolean;
}

export interface AccountRecord {
  identity: AccountIdentity;
  home_dir_label: string;
  preference: ExecutionPreference;
  participates_in_dispatch: boolean;
  order: number;
  pinned_first: boolean;
  /** The system login is read-only: it never stores a preference. */
  is_system_profile: boolean;
}

export interface AccountsDto {
  accounts: AccountRecord[];
  /**
   * Official quota keyed by account id. A missing key means the value has not
   * been read yet, which renders as unknown rather than as zero.
   *
   * Optional so an older backend that predates this field stays readable.
   */
  quotas?: Record<string, AccountQuotaSnapshot>;
  /** Basename of the managed profile root. The absolute path is never sent. */
  profiles_root_label: string;
  messages: string[];
}

/** Official quota window, expressed the way the source reports it. */
export interface QuotaWindowSnapshot {
  /** Percent already consumed, as reported by the source. */
  used_percent: number;
  window_duration_mins: number | null;
  resets_at: number | null;
}

export type QuotaSourceQuality = 'official' | 'stale' | 'local_only' | 'unknown';

export interface AccountQuotaSnapshot {
  account_id: string;
  limit_id: string | null;
  limit_name: string | null;
  five_hour: QuotaWindowSnapshot | null;
  seven_day: QuotaWindowSnapshot | null;
  monthly: QuotaWindowSnapshot | null;
  available_reset_credits: number | null;
  reset_credit_expiries: number[] | null;
  credit_balance: string | null;
  credit_balance_unlimited: boolean | null;
  fetched_at: number;
  app_server_version: string | null;
  quota_read_succeeded: boolean | null;
  quality: QuotaSourceQuality;
}
