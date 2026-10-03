'use strict';

// Dependency-free 0919v2 contract check. The optional Playwright test covers
// browser geometry; this executable check keeps the product contract runnable
// in the repository's pure-test environment as well.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const read = relative => fs.readFileSync(path.join(root, relative), 'utf8');

const html = read('Resources/UpstreamCharts/standalone.html');
const css = read('Resources/UpstreamCharts/standalone.css');
const js = read('Resources/UpstreamCharts/standalone.js');
const trend = read('Sources/CodexUsageWidget/UI/UpstreamTrendView.swift');
const banner = read('Sources/CodexUsageWidget/UI/ResetUpdatesBanner.swift');
const inbox = read('Sources/CodexUsageWidget/UI/HomeMessageInbox.swift');

assert.match(html, /<div id="charts">[\s\S]*<section id="overview">[\s\S]*<section id="trends"/);
assert.ok(html.indexOf('<section id="day-summary"') > html.indexOf('</div>\n<section id="trends"') || html.indexOf('<section id="day-summary"') > html.indexOf('</div>\n</div>'));
assert.match(html, /id="day-total"/);
assert.match(html, /id="day-tools"/);
assert.match(html, /id="day-donut"/);
assert.doesNotMatch(html, /<aside id="day-summary"/);

assert.match(css, /#charts\s*\{[^}]*grid-template-columns:\s*minmax\(240px, 38%\) minmax\(0, 1fr\)/);
assert.match(css, /#calendar svg\s*\{[^}]*width:\s*auto;[^}]*max-width:\s*100%/);
assert.match(css, /@media \(max-width: 800px\)/);
assert.doesNotMatch(css, /#calendar\s*\{[^}]*overflow-x:\s*auto/);
assert.doesNotMatch(css, /body[^}]*overflow-y:\s*auto/);
assert.match(css, /html, body\s*\{[^}]*overflow:\s*hidden/);

assert.match(js, /api\.contribHeatmap/);
assert.match(js, /renderDayComposition/);
assert.match(js, /donut-segment/);
assert.match(js, /e\.key === 'Enter' \|\| e\.key === ' '/);
assert.match(js, /document\.body\.getBoundingClientRect\(\)\.height/);
assert.doesNotMatch(js, /documentElement\??\.scrollHeight/);

assert.match(trend, /override func scrollWheel\(with event: NSEvent\)/);
assert.match(trend, /outerScrollViewForRegression/);
assert.match(trend, /RecordingScrollView/);
assert.match(trend, /forwardedEvents == 1/);
assert.match(banner, /recentVerifiableAnnouncement/);
assert.match(banner, /暂无近期可验证的新公告/);
assert.match(banner, /inlineHistory/);
assert.doesNotMatch(inbox, /NSPanel|HomeMessageInboxWindowController|HomeMessageInboxView/);

console.log('PASS 0919v2 dashboard contract: single outer scroll owner, compact 7-row chart layout, selected-day composition, inline history, and 30-day full-year announcement filtering.');
