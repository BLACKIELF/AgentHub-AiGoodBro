'use strict';
// The upstream renderer receives only the validated usage snapshot. No Electron,
// filesystem, network, account or process API is exposed to this web view.
window.AiGoodBroDashboard = {
  input: null, snapshotID: null, end: null, preferences: {}, settings: {},
  ready: false, resolveSettings: null, rawDaily: new Map()
};
// The upstream scheduler captures its render callback at construction. Route
// that callback through the host layout so later control clicks keep both panes.
const upstreamCreateScheduler = window.TokenMonitorStatsRenderScheduler.createStatsRenderScheduler;
window.TokenMonitorStatsRenderScheduler.createStatsRenderScheduler = options =>
  upstreamCreateScheduler({...options, render: () => window.AiGoodBroDashboard.render?.()});
window.tokenMonitor = {
  getSettings: () => new Promise(resolve => { window.AiGoodBroDashboard.resolveSettings = resolve; }),
  getDashboardHistory: async () => window.AiGoodBroDashboard.history,
  updateSettings: patch => window.AiGoodBroDashboard.save?.(patch),
  dashboard: {ready() {}, minimize() {}, close() {}}
};
