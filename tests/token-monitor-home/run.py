#!/usr/bin/env python3
from pathlib import Path
import subprocess, json, hashlib, difflib, re, argparse, tempfile, atexit
parser = argparse.ArgumentParser(description='Offline actual home projection regression; no GUI or accounts.')
parser.add_argument('--repo-root', type=Path, default=Path(__file__).resolve().parents[2])
args = parser.parse_args()
root=args.repo_root.resolve()/'Sources/CodexUsageWidget'
if not (root/'UI/CodexAccountManagerView.swift').is_file(): parser.error('repository Sources tree is required')
temporary = tempfile.TemporaryDirectory(prefix='token-monitor-home-tests-')
atexit.register(temporary.cleanup)
q=Path(temporary.name)
ui=root/'UI/CodexAccountManagerView.swift' 
s=ui.read_text()
def read(p): return (root/p).read_text()
projection=s[s.index('enum HomeEngineProjection {'):s.index('private struct UpstreamHomeStatistics:')]
token_range='''
enum TokenUsageHomeRange: String, CaseIterable, Identifiable {
    case sevenDays, thirtyDays, ninetyDays, all, custom
    var id: String { rawValue }
}
'''
announcement=read('Services/PublicResetAnnouncements.swift').split('struct PublicResetAnnouncement:',1)[1].split('    enum CodingKeys:',1)[0]
channel=read('Domain/MessageChannel.swift')
result=channel[channel.index('struct PublicResetChannelResult:'):channel.index('    var statusText:')]+ '}\n'
kind=channel[channel.index('enum MessageChannelKind:'):channel.index('    func displayName')]+ '}\n'
chart=read('UI/UpstreamTrendView.swift'); annotation=chart[chart.index('    struct ResetAnnotation:'):chart.index('    enum RenderFailure:')]
# SwiftUI chart namespace is a fixture shell; production Models and Engine declarations remain actual source.
prefix='''import Foundation
'''
source=prefix+read('Domain/TokenMonitorEngineModels.swift')+'\n'+read('Services/TokenMonitorEngine.swift')+'\n'+read('Domain/StatisticsTimeZone.swift').split('enum StatisticsTimeZoneSelfTest')[0]+'\n'
source+='struct PublicResetAnnouncement:'+announcement+'}\n'+kind+result
source+='enum UpstreamTrendView {\n'+annotation+'}\n'+token_range+projection
source+='''
func check(_ condition: Bool, _ label: String) { precondition(condition, label); print("PASS " + label) }
var r = TokenMonitorResponse(schemaVersion: 1, requestId: "fixture", operation: .collectUsage,
 engine: .init(repository: "fixture", commit: "fixture", version: "fixture"), collectedAt: "2026-09-12T12:00:00Z",
 timezone: "UTC", status: .ok, sources: [], payload: .object(["aggregate": .object(["allTime": .object(["totalTokens": .number(0)])])]),
 coverage: .init(entries: [], days: [], cost: .unknown), errors: [])
check(HomeEngineProjection.total(r) == nil, "empty aggregate zero unknown")
r.sources = [.init(id: "a", providerId: "tool-one", status: .ok, coverage: .known)]
r.coverage.entries = [.init(sourceId: "a", providerId: "tool-one", date: "2026-09-12", metric: "tokens", status: .known)]
check(HomeEngineProjection.total(r) == 0, "successful evidenced zero")
var costOnlyPartial = r
costOnlyPartial.status = .partial
check(!HomeEngineProjection.partial(costOnlyPartial), "unknown cost does not downgrade complete token coverage")

r.sources.append(.init(id: "b", providerId: "tool-two", status: .unavailable, coverage: .unknown))
check(HomeEngineProjection.partial(r), "known A missing B partial")
check(HomeEngineProjection.total(r) == 0 && r.coverage.cost == .unknown, "unknown cost retains known tokens")
for value in ["1.5", "-1", "9223372036854775808"] {
 check(HomeEngineProjection.exactTokens(.number(Decimal(string: value)!)) == nil, "reject " + value)
}
check(HomeEngineProjection.exactTokens(.number(Decimal(Int64.max))) == Int64.max, "exact Int64 max")
r.sources[0].status = .excluded
check(HomeEngineProjection.total(r) == nil, "all excluded or unavailable zero unknown")
r.sources[0].status = .ok
let stale = TokenMonitorEngineState(phase: .failed, lastGood: r, failureCode: .processFailed)
check(HomeEngineProjection.cachedAt(stale) == r.collectedAt && HomeEngineProjection.total(stale.lastGood) == 0, "failed lastGood cached with actual timestamp")
let event = PublicResetAnnouncement(id: "fixture", resetType: .banked,
 announcedAt: ISO8601DateFormatter().date(from: "2026-09-12T23:30:00Z")!, text: "Original public notice", source: .init(type: "fixture", author: nil, url: nil))
let utc = StatisticsContext(preference: .init(selection: .utc, fixedIdentifier: "UTC"), now: event.announcedAt)
let east = StatisticsContext(preference: .init(selection: .fixed, fixedIdentifier: "Asia/Shanghai"), now: event.announcedAt)
check(HomeEngineProjection.annotations([event], context: utc)[0].date == "2026-09-12", "UTC annotation boundary")
let annotations = HomeEngineProjection.annotations([event], context: east)
check(annotations[0].date == "2026-09-13" && annotations[0].kind == .banked && annotations[0].text == event.text, "selected timezone original banked annotation")
let regular = PublicResetAnnouncement(id: "regular", resetType: .regular, announcedAt: event.announcedAt, text: "Regular original", source: event.source)
check(HomeEngineProjection.annotations([regular], context: east)[0].kind == .regular, "regular type retained")
check(HomeEngineProjection.annotations([], context: east).isEmpty, "no fabricated history")
let sameDay = HomeEngineProjection.annotations([regular, event], context: east)
check(sameDay.count == 2 && Set(sameDay.map(\.text)) == Set([regular.text, event.text]), "multiple public events on one day are retained")
let events53 = (0..<53).map { n in PublicResetAnnouncement(id: String(format: "event-%02d", n), resetType: n % 2 == 0 ? .regular : .banked, announcedAt: event.announcedAt.addingTimeInterval(Double(n)), text: "Public fixture \(n)", source: event.source) }
check(HomeEngineProjection.annotations(events53.reversed(), context: east).map(\.text) == events53.map(\.text), "all 53 validated-page events remain in stable chronological order")
let older = PublicResetChannelResult(channel: .telegram, state: .failed, checkedAt: Date(timeIntervalSince1970: 1), errorCategory: .transport)
let newest = PublicResetChannelResult(channel: .weChat, state: .uncertain, checkedAt: Date(timeIntervalSince1970: 2), errorCategory: .response)
let tied = PublicResetChannelResult(channel: .telegram, state: .accepted, checkedAt: newest.checkedAt, errorCategory: nil)
check(HomeEngineProjection.outcomes([older, newest, tied]) == [tied, newest, older], "actual outcome DTO newest then channel; states retained")
let payload = #"{"aggregate":{"allTime":{"totalTokens":9223372036854775807}},"usage":{"tool-x":{"account-a":{"arbitrary/model-v-next":123}},"tool-y":{"account-b":{"different-model":456}}},"history":[],"extra":{"preserved":true}}"#
r.payload = try JSONDecoder().decode(TokenMonitorJSON.self, from: Data(payload.utf8))
let encoded = try JSONEncoder().encode(r)
let decoded = try JSONDecoder().decode(TokenMonitorResponse.self, from: encoded)
check(decoded.payload == r.payload && decoded.sources.count == 2 && decoded.coverage.entries.count == 1, "real F DTO full envelope roundtrip two tools/accounts arbitrary models")
let periodNow = ISO8601DateFormatter().date(from: "2026-03-09T00:30:00Z")!
r.timezone = "America/Los_Angeles"
r.payload = .object(["aggregate": .object(["history": .object(["daily": .array([
 .object(["date": .string("2026-03-02"), "tokens": .number(5)]),
 .object(["date": .string("2026-03-07"), "tokens": .number(0)]),
 .object(["date": .string("2026-03-08"), "tokens": .number(7)]),
 .object(["date": .string("2026-03-09"), "tokens": .number(1000)])
])])])])
let periods = HomeEngineProjection.recentPeriods(r, now: periodNow)
check(periods[0].tokens == 7 && periods[0].recordedDays == 1, "today follows statistics time zone")
check(periods[1].tokens == 12 && periods[1].recordedDays == 3 && periods[1].calendarDays == 7, "seven calendar days across DST retain zero and omit future bucket")
check(periods[2].tokens == 12 && periods[2].calendarDays == 8, "month-to-date observed total")
let canonicalPayload = r.payload
let collectedHistory = canonicalPayload["aggregate"]?["history"]!
r.payload = .object(["aggregate": .object([:]), "history": collectedHistory!])
check(HomeEngineProjection.recentPeriods(r, now: periodNow) == periods, "collector top-level history matches chart totals")
r.payload = .object(["usage": .object(["history": collectedHistory!])])
check(HomeEngineProjection.recentPeriods(r, now: periodNow) == periods, "usage history follows chart fallback")
r.payload = canonicalPayload
check(HomeEngineProjection.recentPeriods(nil, now: periodNow).allSatisfy { $0.tokens == nil }, "missing days stay unknown")
r.payload = .object(["aggregate": .object(["history": .object(["daily": .array([
 .object(["date": .string("2026-03-08"), "tokens": .number(0)]),
 .object(["date": .string("2026-03-08"), "tokens": .number(7)])
])])])])
check(HomeEngineProjection.recentPeriods(r, now: periodNow).allSatisfy { $0.tokens == nil }, "duplicate canonical day cannot double count")
r.payload = .object(["aggregate": .object(["history": .object(["daily": .array([
 .object(["date": .string("2026-03-07"), "tokens": .number(Decimal(Int64.max))]),
 .object(["date": .string("2026-03-08"), "tokens": .number(1)])
])])])])
check(HomeEngineProjection.recentPeriods(r, now: periodNow)[1].tokens == nil, "period overflow is unavailable")
r.payload = canonicalPayload
let thirty = HomeEngineProjection.window(r, range: .thirtyDays, customStart: periodNow, now: periodNow)
check(thirty.calendarDays == 30 && thirty.recordedDays == 3 && thirty.tokens == 12, "thirty-day window uses canonical days")
let chart30 = HomeEngineProjection.chartWindow(r, range: .thirtyDays, customStart: periodNow, now: periodNow)
check(chart30?.from == "2026-02-07" && chart30?.to == "2026-03-08", "chart window follows statistics timezone")
let lifetime = HomeEngineProjection.window(r, range: .all, customStart: periodNow, now: periodNow)
check(lifetime.calendarDays == 0 && thirty.calendarDays == 30, "all-time is not a 30-day window")
r.sources = [.init(id: "a", providerId: "tool-one", status: .ok, coverage: .known)]
r.coverage.entries = [.init(sourceId: "a", providerId: "tool-one", date: "2026-09-17", metric: "tokens", status: .known)]
r.timezone = "Asia/Shanghai"
let windowNow = ISO8601DateFormatter().date(from: "2026-09-17T04:00:00Z")!
r.payload = .object(["aggregate": .object(["allTime": .object(["totalTokens": .number(100)]), "history": .object(["daily": .array([
 .object(["date": .string("2026-08-08"), "tokens": .number(70)]),
 .object(["date": .string("2026-09-15"), "tokens": .number(0)]),
 .object(["date": .string("2026-09-16"), "tokens": .number(20)]),
 .object(["date": .string("2026-09-17"), "tokens": .number(10)])
])])])])
let oracleThirty = HomeEngineProjection.window(r, range: .thirtyDays, customStart: windowNow, now: windowNow)
let oracleAll = HomeEngineProjection.window(r, range: .all, customStart: windowNow, now: windowNow)
let oracleChart = HomeEngineProjection.chartWindow(r, range: .thirtyDays, customStart: windowNow, now: windowNow)
check(oracleThirty.tokens == 30 && oracleThirty.recordedDays == 3, "thirty-day window is 10+20 plus recorded zero")
check(oracleAll.tokens == 100, "all-time total stays 100 outside the window")
check(oracleChart?.from == "2026-08-19" && oracleChart?.to == "2026-09-17", "chart window excludes the 40-day-old bucket")
'''
(q/'consumer-fixture-0913v5.swift').write_text(source)
with (q/'consumer-tests-0913v5.log').open('w') as log:
 for cmd in [['xcrun','swiftc','-module-cache-path',str(q/'module-cache'),str(q/'consumer-fixture-0913v5.swift'),'-o',str(q/'consumer-fixture-0913v5')],[str(q/'consumer-fixture-0913v5')]]:
  p=subprocess.run(cmd,stdout=log,stderr=log)
  if p.returncode:
   log.flush(); print((q/'consumer-tests-0913v5.log').read_text(), end=''); raise SystemExit(p.returncode)
print((q/'consumer-tests-0913v5.log').read_text(), end='')
