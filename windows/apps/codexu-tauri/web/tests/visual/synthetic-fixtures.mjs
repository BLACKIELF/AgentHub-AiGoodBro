// Fully synthetic fixtures for the Windows dashboard visual assertions.
//
// Every value below is invented for the test run. No real account, workspace,
// project, thread, tool or token data is used, and no value is read from the
// machine running the test. Screenshots produced from these fixtures are the
// only ones that may be published (see docs/windows-port/README.md).

const DAY_MS = 24 * 60 * 60 * 1000;

/** Fixed instant so relative-time rendering ("3d ago", trend cutoffs) is stable. */
export const FIXED_NOW_ISO = '2026-09-16T03:30:00.000Z';
export const FIXED_NOW_MS = Date.parse(FIXED_NOW_ISO);

const daysAgo = (offset) => FIXED_NOW_MS - offset * DAY_MS;

const tokens = (input, cached, output, reasoning) => ({
  input_tokens: input,
  cached_input_tokens: cached,
  output_tokens: output,
  reasoning_output_tokens: reasoning,
  total_tokens: input + cached + output + reasoning,
});

const priced = (input, cached, output, reasoning, cost) => ({
  tokens: tokens(input, cached, output, reasoning),
  estimated_cost_usd: cost,
});

const dayBucket = (offset, input, cached, output, reasoning, cost) => ({
  id: `day-${offset}`,
  date: daysAgo(offset),
  usage: priced(input, cached, output, reasoning, cost),
  source_quality: 'detailed',
});

const DAY_BUCKETS = [
  dayBucket(6, 12000, 4000, 3000, 900, 1.12),
  dayBucket(5, 15000, 5200, 3600, 1100, 1.44),
  dayBucket(4, 9000, 3100, 2400, 700, 0.88),
  dayBucket(3, 18000, 6400, 4200, 1300, 1.71),
  dayBucket(2, 21000, 7600, 5100, 1500, 2.03),
  dayBucket(1, 16500, 5800, 3900, 1200, 1.58),
  dayBucket(0, 7400, 2600, 1900, 600, 0.72),
];

const HEATMAP_THRESHOLDS = [0, 5000, 12000, 20000, 30000];

// Eight weeks of synthetic activity; week 0 is the oldest.
const HEATMAP_WEEKS = Array.from({ length: 8 }, (_, week) =>
  Array.from({ length: 7 }, (_, weekday) => {
    const offset = (7 - week) * 7 - weekday;
    const isFuture = offset < 0;
    if (isFuture || offset % 3 === 0) {
      return { id: `heat-${week}-${weekday}`, date: daysAgo(offset), usage: null, is_future: isFuture };
    }
    const intensity = (offset % 4) + 1;
    return {
      id: `heat-${week}-${weekday}`,
      date: daysAgo(offset),
      usage: priced(intensity * 3200, intensity * 900, intensity * 700, intensity * 220, intensity * 0.31),
      is_future: false,
    };
  }),
);

const PROJECTS = [
  {
    id: 'project-atlas',
    name: 'Atlas',
    full_path: 'C:/synthetic/workspace/atlas',
    tokens: 184000,
    estimated_cost_usd: 12.4,
    thread_count: 14,
    last_active_at: daysAgo(0),
    source_quality: 'detailed',
  },
  {
    id: 'project-beacon',
    name: 'Beacon',
    full_path: 'C:/synthetic/workspace/beacon',
    tokens: 96000,
    estimated_cost_usd: 6.1,
    thread_count: 9,
    last_active_at: daysAgo(1),
    source_quality: 'detailed',
  },
  {
    id: 'project-cascade',
    name: 'Cascade',
    full_path: 'C:/synthetic/workspace/cascade',
    tokens: 41000,
    estimated_cost_usd: null,
    thread_count: 4,
    last_active_at: daysAgo(4),
    source_quality: 'approximate',
  },
];

const TOOL_USAGES = [
  { id: 'tool-shell', name: 'shell', category: 'execution', call_count: 128, estimated_tokens: 24500, estimated_cost_usd: 1.82 },
  { id: 'tool-patch', name: 'apply_patch', category: 'editing', call_count: 74, estimated_tokens: 18900, estimated_cost_usd: 1.41 },
  { id: 'tool-search', name: 'search', category: 'retrieval', call_count: 61, estimated_tokens: 7300, estimated_cost_usd: 0.55 },
  { id: 'tool-plan', name: 'update_plan', category: 'planning', call_count: 22, estimated_tokens: null, estimated_cost_usd: null },
];

const SKILL_USAGES = [
  { id: 'skill-alpha', name: 'synthetic-skill-alpha', source_label: 'workspace', load_count: 12, thread_count: 5, last_loaded_at: daysAgo(1) },
  { id: 'skill-beta', name: 'synthetic-skill-beta', source_label: 'user', load_count: 7, thread_count: 3, last_loaded_at: daysAgo(3) },
];

const TASK_BOARD = {
  refreshed_at: FIXED_NOW_MS,
  columns: [
    {
      id: 'running',
      title: 'Running',
      count: 1,
      items: [
        {
          id: 'task-1',
          code: 'SYN-1',
          title: 'Synthetic running task with a deliberately long title to exercise truncation',
          detail: 'Synthetic detail line',
          chip: 'Running',
          updated_at: daysAgo(0),
          tokens: 4200,
          kind: 'task',
          thread_id: 'thread-1',
          runtime_state: 'running',
          source_kind: 'local',
          display_state: 'running',
          state_basis: 'transcript',
          raw_status: 'in_progress',
          next_run_at: null,
        },
      ],
    },
    {
      id: 'queued',
      title: 'Queued',
      count: 1,
      items: [
        {
          id: 'task-2',
          code: 'SYN-2',
          title: 'Synthetic queued task',
          detail: 'Synthetic detail line',
          chip: 'Queued',
          updated_at: daysAgo(1),
          tokens: null,
          kind: 'automation',
          thread_id: null,
          runtime_state: 'queued',
          source_kind: 'state',
          display_state: 'queued',
          state_basis: 'state_db',
          raw_status: null,
          next_run_at: daysAgo(-1),
        },
      ],
    },
    { id: 'done', title: 'Completed', count: 0, items: [] },
  ],
};

const LEADERSHIP_REPORT = {
  period: 'last_7_days',
  score: 68.4,
  core_score: 71.2,
  title: { level: 4, name: 'Synthetic Tier IV', english_name: 'Synthetic Tier IV', lower_bound: 60, upper_bound: 75 },
  dimensions: [
    { kind: 'span', score: 72, confidence: 0.82, summary_value: 18.5 },
    { kind: 'leverage', score: 64, confidence: 0.74, summary_value: 4.1 },
    { kind: 'orchestration', score: 70, confidence: 0.69, summary_value: 2.8 },
    { kind: 'autonomy', score: 61, confidence: 0.58, summary_value: 31.0 },
  ],
  maturity: 0.72,
  evidence_coverage: 0.81,
  active_day_count: 6,
  agent_count: 24,
  ai_hours: 41.5,
  autonomous_hours: 12.8,
  average_parallelism: 2.4,
  peak_concurrency: 5,
  project_count: 3,
  daily_points: Array.from({ length: 7 }, (_, index) => ({
    day: daysAgo(6 - index),
    agent_count: 2 + (index % 4),
    ai_hours: 3.5 + (index % 5) * 0.8,
    peak_concurrency: 1 + (index % 3),
  })),
  projects: PROJECTS.map((project, index) => ({
    project_id: project.id,
    project_name: project.name,
    agent_count: 6 + index * 2,
    ai_hours: 14.2 - index * 3.1,
    autonomous_hours: 4.6 - index * 1.2,
  })),
};

const LOCAL_USAGE = {
  lifetime_tokens: 321000,
  today_tokens: 9900,
  seven_day_tokens: 98500,
  thread_count: 27,
  last_updated_at: FIXED_NOW_MS,
  daily_buckets: DAY_BUCKETS.map((bucket) => ({ id: bucket.id, label: bucket.id, tokens: bucket.usage.tokens.total_tokens })),
  recent_threads: [
    { id: 'thread-1', title: 'Synthetic thread one', tokens: 12400, updated_at: daysAgo(0), model: 'gpt-5-codex', cwd: 'C:/synthetic/workspace/atlas', archived: false },
    { id: 'thread-2', title: 'Synthetic thread two with a longer descriptive title', tokens: 8100, updated_at: daysAgo(1), model: 'gpt-5-codex', cwd: 'C:/synthetic/workspace/beacon', archived: false },
    { id: 'thread-3', title: 'Synthetic thread three', tokens: 5200, updated_at: daysAgo(2), model: null, cwd: 'C:/synthetic/workspace/cascade', archived: true },
  ],
  detailed_usage: {
    today: priced(5200, 1900, 1400, 400, 0.68),
    seven_day: priced(48500, 16800, 12400, 3800, 6.12),
    month: priced(142000, 49000, 36000, 11000, 18.4),
    lifetime: priced(198000, 68000, 51000, 15000, 25.6),
    parsed_file_count: 42,
    token_event_count: 318,
  },
  usage_trend: {
    day_buckets: DAY_BUCKETS,
    heatmap_weeks: HEATMAP_WEEKS,
    heatmap_thresholds: HEATMAP_THRESHOLDS,
    summary: {
      seven_day: priced(48500, 16800, 12400, 3800, 6.12),
      daily_average_tokens: 14071,
      peak_day: DAY_BUCKETS[4],
      change_percent: 12.5,
      is_new_activity: false,
    },
    model_trends: [
      {
        id: 'model-gpt-5-codex',
        model: 'gpt-5-codex',
        day_buckets: DAY_BUCKETS,
        summary: {
          seven_day: priced(48500, 16800, 12400, 3800, 6.12),
          daily_average_tokens: 14071,
          peak_day: DAY_BUCKETS[4],
          change_percent: 12.5,
          is_new_activity: false,
        },
        active_day_count: 7,
      },
    ],
    month: priced(142000, 49000, 36000, 11000, 18.4),
    projected_month_cost_usd: 34.2,
    active_day_count: 7,
    source_quality: 'detailed',
  },
  project_board: { recent_projects: PROJECTS.slice(0, 2), all_projects: PROJECTS },
  tool_usages: TOOL_USAGES,
  skill_usages: SKILL_USAGES,
};

const USAGE_SNAPSHOT = {
  refreshed_at: FIXED_NOW_MS,
  account: { type: 'synthetic', plan_type: 'synthetic-plan', email_present: true },
  limit_id: 'synthetic-limit',
  limit_name: 'Synthetic Limit',
  quota_read_succeeded: true,
  five_hour_quota: { used_percent: 42, window_duration_mins: 300, resets_at: daysAgo(-1) },
  seven_day_quota: { used_percent: 63, window_duration_mins: 10080, resets_at: daysAgo(-3) },
  monthly_quota: { used_percent: 28, window_duration_mins: 43200, resets_at: daysAgo(-12) },
  local: LOCAL_USAGE,
  task_board: TASK_BOARD,
  messages: [],
};

export const SYNTHETIC_DASHBOARD = {
  codex: {
    scope: 'codex',
    snapshot: USAGE_SNAPSHOT,
    status: 'available',
    quota_source_label: 'Synthetic official quota',
    usage_source_label: 'Synthetic local transcripts',
  },
  leadership: {
    score: LEADERSHIP_REPORT.score,
    evidence_coverage: LEADERSHIP_REPORT.evidence_coverage,
    active_day_count: LEADERSHIP_REPORT.active_day_count,
    period: LEADERSHIP_REPORT.period,
    model_version: 'synthetic-leadership-v1',
    report: { model_version: 'synthetic-leadership-v1', refreshed_at: FIXED_NOW_MS, reports: [LEADERSHIP_REPORT] },
  },
  refreshed_at: FIXED_NOW_MS,
  messages: [],
};

export const SYNTHETIC_SETTINGS = {
  codex_root_configured: true,
  cache_dir_configured: false,
  theme: 'dark',
  refresh_interval_secs: 300,
  tray_density: 'classic',
  language: 'en',
  palette_id: 'codexu.default',
};
