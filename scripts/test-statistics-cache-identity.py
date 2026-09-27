#!/usr/bin/env python3
"""Exercise production cache methods with synthetic profile and quota snapshots."""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    source = (ROOT / 'Sources/CodexUsageWidget/Services/UsageStore.swift').read_text()
    start = source.find('    private struct StatisticsSnapshotCacheKey')
    if start == -1:
        start = source.index('    private struct StatisticsSnapshotCacheEntry')
    types = source[start:source.index('    private struct AuthFileState', start)]
    fields = '\n'.join(re.findall(r'^    private (?:var|let) statisticsSnapshotCache[^\n]*', source, re.M))
    start = source.index('    private func statisticsCacheKey(')
    methods = source[start:source.index('    private func statisticsSwitchingMessage', start)]
    start = source.index('    func updateStatisticsTimeZone(')
    update = source[start:source.index('    private func statisticsCacheKey(', start)]
    fixture = (ROOT / 'tests/StatisticsCacheIdentityFixture.swift').read_text()
    code = fixture.replace('// PRODUCTION_CACHE', types + fields + '\n' + methods + update)
    with tempfile.TemporaryDirectory(prefix='statistics-cache-identity-') as directory:
        directory = Path(directory)
        main = directory / 'main.swift'
        binary = directory / 'cache-fixture'
        main.write_text(code)
        subprocess.run(['/usr/bin/swiftc', '-swift-version', '5', '-O', str(main), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True, timeout=20)


if __name__ == '__main__':
    main()
