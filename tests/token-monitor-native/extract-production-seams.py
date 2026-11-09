from pathlib import Path
import sys

def declaration(path, marker):
    text = Path(path).read_text()
    start = text.index(marker)
    opening = text.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        if text[end] == '{': depth += 1
        if text[end] == '}': depth -= 1
        end += 1
    return text[start:end]

root = 'Sources/CodexUsageWidget/'
domain = root + 'Domain/UsageModels.swift'
parts = ['import Foundation', 'import CoreFoundation']
for name in ['RateWindow', 'CreditsInfo', 'ResetCreditDetail', 'AccountInfo']:
    parts.append(declaration(domain, 'struct ' + name + ':'))
parts.append(declaration(root + 'Services/CCSwitchUsageReader.swift', 'enum CustomTokenSourceStore {'))
parts.append(Path(root + 'Domain/CodexRateLimitNormalizer.swift').read_text())
reader = root + 'Services/CodexUsageReader.swift'
for marker in ['private func resetExactInt64(', 'private func resetValidField(', 'private func resetExpiry(',
               'private func intValue(', 'private func doubleValue(', 'private func stringValue(']:
    parts.append(declaration(reader, marker))
parser = '\n'.join(declaration(reader, marker).replace('private func', 'func', 1) for marker in [
    'private func parseRateLimits(', 'private func parseResetCreditSummary(', 'private func parseRateWindow(', 'private func rateLimitDiagnostics('])
parts.append('struct CodexUsageReader {\n' + declaration(reader, 'struct AppServerSnapshot {') + '\n' + parser + '\n}')
Path(sys.argv[1]).write_text('\n'.join(parts))
