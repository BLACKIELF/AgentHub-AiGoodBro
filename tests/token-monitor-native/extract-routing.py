from pathlib import Path
import sys
exec(Path(__file__).with_name('extract-production-seams.py').read_text().split("root = ")[0])
root='Sources/CodexUsageWidget/'
parts=['import Foundation', 'import CoreFoundation']
for name in ['RateWindow','CreditsInfo','ResetCreditDetail','AccountInfo']:
 parts.append(declaration(root+'Domain/UsageModels.swift','struct '+name+':'))
parts.append(Path(root+'Domain/CodexRateLimitNormalizer.swift').read_text())
reader=root+'Services/CodexUsageReader.swift'
for marker in ['private func resetExactInt64(', 'private func resetValidField(', 'private func resetExpiry(',
               'private func intValue(', 'private func doubleValue(', 'private func stringValue(']:
 parts.append(declaration(reader,marker))
parser='\n'.join(declaration(reader,marker).replace('private func','func',1) for marker in [
 'private func parseRateLimits(', 'private func parseResetCreditSummary(', 'private func parseRateWindow(', 'private func rateLimitDiagnostics('])
parts.append('final class CodexUsageReader {\n'+declaration(reader,'struct AppServerSnapshot {')+'\n'+parser+'\n'+declaration(reader,'func readQuotaSnapshot(')+'''\n
 func readAppServer(context: RuntimeLoadContext, messages: inout [String], quotaOnly: Bool,
 refreshingMembershipFor profile: CodexProfile? = nil, requestTimeout: TimeInterval? = nil,
 cancellation: TokenMonitorCancellation? = nil) -> AppServerSnapshot {
   Harness.events.append(profile == nil ? "rpc" : "membership")
   return Harness.rpc()
 }
}\n''')
# Keep this routing seam focused on independent cancellation. The full production
# scan-key/cache contract is exercised by scripts/test-statistics-engine-cache.py.
parts.append('final class UsageStore {\ntypealias StatisticsEngineScanKey = String\nvar engineGeneration = TokenMonitorGeneration()\nvar engineCancellation: TokenMonitorCancellation?\nvar engineScanKey: StatisticsEngineScanKey?\nvar engineLastGoodScanKey: StatisticsEngineScanKey?\nfunc currentStatisticsEngineScanKey() -> StatisticsEngineScanKey { \"synthetic-routing-scope\" }\nvar engineQuotaCancellation: TokenMonitorCancellation?\nvar engineState = TokenMonitorEngineState()\n'+declaration(root+'Services/UsageStore.swift','func cancelStatisticsEngine(')+'\nvar profiles = [String]()\nvar accountManagerMessage: String?\nlet profileStore = SyntheticProfileStore()\n'+declaration(root+'Services/UsageStore.swift','func reorderProfiles(')+'\n}')
Path(sys.argv[1]).write_text('\n'.join(parts))
