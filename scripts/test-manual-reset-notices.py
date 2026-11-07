#!/usr/bin/env python3
"""Actual manual notice callback/queue/transport admission, synthetic dependencies only."""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'Sources/CodexUsageWidget'

def declaration(source, needle):
    start = source.index(needle)
    depth = 0
    for index in range(source.index('{', start), len(source)):
        depth += (source[index] == '{') - (source[index] == '}')
        if depth == 0:
            return source[start:index + 1]
    raise ValueError(needle)

paths = [BASE / p for p in ['Services/UsageStore.swift', 'Services/FeishuWebhookService.swift',
    'Domain/CodexResetNotice.swift', 'Domain/UsageModels.swift', 'Domain/MessageChannel.swift',
    'Services/CodexResetNoticeDeliveryStore.swift']] + [ROOT / 'tests/ManualResetNoticeFixture.swift']
frozen = {p: p.read_text() for p in paths}
usage = frozen[BASE / 'Services/UsageStore.swift']
feishu = frozen[BASE / 'Services/FeishuWebhookService.swift']
channel = frozen[BASE / 'Domain/MessageChannel.swift']
methods = '\n'.join(declaration(usage, n) for n in ['    func recordManualResetConfirmed(',
    '    private func manualResetSource(', '    private func queuePendingManualResetNotices('])
sender = declaration(feishu, '    func sendManualReset(') + '\n' + declaration(feishu, '    private func send(\n        body: Data,')
# Verify that the normal comparison is passed to other channels first, while
# only the Feishu DTO receives the optional narrow suppression flag.
routing = declaration(usage, '    private func sendFeishuNotification(')
assert 'factsSnapshot: factsSnapshot, resetCreditComparison: resetCreditComparison, eventID:' in routing
assert 'resetCreditComparison: resetCreditComparison,' in routing
assert 'suppressResetCreditComparison: suppressFeishuResetCreditComparison,' in routing
assert 'suppressFeishuResetCreditComparison ? nil' not in routing
observer = declaration(usage, '    private func observeOfficialQuotaChanges(')
assert observer.count('resetNoticeDeliveryStore.hasSingleManualReset(') == 2
assert 'duplicateManual ? channels.filter { $0 != .feishu } : channels' in observer
assert 'after: comparison.previousObservedAt, through: comparison.observedAt' in observer
with tempfile.TemporaryDirectory(prefix='manual-notice-fixture-') as tmp:
    folder = Path(tmp)
    support = frozen[ROOT / 'tests/ManualResetNoticeFixture.swift'].replace('__USAGE_METHODS__', methods).replace('__SENDER_METHODS__', sender)
    support += '\n' + '\n'.join(declaration(channel, n) for n in ['enum MessageChannelError:', 'struct MessageDeliveryReceipt:', 'enum MessageDeliveryOutcome:'])
    sources = []
    for name, text in [('Fixture.swift', support)] + [(p.name, frozen[p]) for p in paths if p.name in ['CodexResetNotice.swift', 'UsageModels.swift', 'CodexResetNoticeDeliveryStore.swift']]:
        target = folder / name
        target.write_text(text)
        sources.append(str(target))
    binary = folder / 'checks'
    result = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-cache-path', str(folder / 'modules'), *sources, '-o', str(binary)], text=True, capture_output=True, timeout=60)
    output = result.stdout + result.stderr
    if result.returncode == 0:
        result = subprocess.run([str(binary)], text=True, capture_output=True, timeout=30)
        output += result.stdout + result.stderr
    print(output.replace(tmp, '<fixture>'), end='')
    print(json.dumps({'inputs': {str(p.relative_to(ROOT)): hashlib.sha256(v.encode()).hexdigest() for p,v in frozen.items()}, 'exitCode': result.returncode, 'realAccountIO': False, 'networkSends': 0, 'keychainIO': False, 'redemptionCalls': 0, 'scope': 'Extracted production callback, queue, identity admission and transport task; real temporary ledger; fake profile reader, credential completion and byte transport; routing suppression wiring guards'}, sort_keys=True))
    raise SystemExit(result.returncode)
