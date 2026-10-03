from pathlib import Path
import sys
exec(Path(__file__).with_name('extract-production-seams.py').read_text().split("root = ")[0])
root='Sources/CodexUsageWidget/'
parts=['import Foundation']
for name in ['RateWindow','CreditsInfo','ResetCreditDetail','AccountInfo']:
 parts.append(declaration(root+'Domain/UsageModels.swift','struct '+name+':'))
parts.append('final class CodexUsageReader {\n'+declaration(root+'Services/CodexUsageReader.swift','struct AppServerSnapshot {')+'\n'+declaration(root+'Services/CodexUsageReader.swift','func readQuotaSnapshot(')+'''\n
 func readAppServer(context: RuntimeLoadContext, messages: inout [String], quotaOnly: Bool,
 refreshingMembershipFor profile: CodexProfile? = nil, requestTimeout: TimeInterval? = nil,
 cancellation: TokenMonitorCancellation? = nil) -> AppServerSnapshot {
   Harness.events.append(profile == nil ? "rpc" : "membership")
   return Harness.rpc()
 }
}\n''')
parts.append('final class UsageStore {\nvar engineGeneration = TokenMonitorGeneration()\nvar engineCancellation: TokenMonitorCancellation?\nvar engineScanKey: String?\nvar engineQuotaCancellation: TokenMonitorCancellation?\nvar engineState = TokenMonitorEngineState()\n'+declaration(root+'Services/UsageStore.swift','func cancelStatisticsEngine()')+'\nvar profiles = [String]()\nvar accountManagerMessage: String?\nlet profileStore = SyntheticProfileStore()\n'+declaration(root+'Services/UsageStore.swift','func reorderProfiles(')+'\n}')
Path(sys.argv[1]).write_text('\n'.join(parts))
