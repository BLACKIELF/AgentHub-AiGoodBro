#!/usr/bin/env python3
"""Reconstruct the exact approved 1027 scanner source; never run a scan.

Input is the fixed fa5f source archive already used by the Mac backport. Every
final file is checked against the frozen inventory before any build is allowed.
No Git checkout, fuzzy patch application, package installation or network I/O.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import tarfile

ROOT = Path(__file__).resolve().parents[2]
BACKPORT = ROOT / 'Companion/TokenMonitorEngine/scanner-backports/1027v1'
ARCHIVE_SHA = '5f7fcc2872b40d61319ef88a847c9ef4bb0ef240cfd16139a4fa65de03f47503'
PATCH_SHA = 'a5c09f55a7e70f167e4a48b793a169043fdc45c946773360b4e2739cdff5f52d'
INVENTORY_SHA = '5f9c2d938d7df0167cbe316f5bd3c9cba8991994283119f517faf029ef5e3054'
BASE_COMMIT = 'fa5f0c13324838d1a988fda317597f9b90da7ad0'

def sha(data): return hashlib.sha256(data).hexdigest()
def need(value, code):
    if not value: raise ValueError(code)
def safe(raw):
    need(raw and '\\' not in raw and ':' not in raw and not raw.startswith('/') and all(p not in ('', '.', '..') for p in raw.split('/')), 'unsafe_scanner_source')
    return PurePosixPath(raw)

def apply_patch(files, patch):
    lines = patch.decode('utf-8').splitlines(keepends=True)
    index = 0
    while index < len(lines):
        need(lines[index].startswith('--- a/'), 'invalid_scanner_patch')
        old = str(safe(lines[index][6:].rstrip('\n'))); index += 1
        need(index < len(lines) and lines[index] == '+++ b/' + old + '\n', 'invalid_scanner_patch')
        need(old in files, 'scanner_patch_missing_source'); index += 1
        original = files[old].decode('utf-8').splitlines(keepends=True)
        result = []; cursor = 0
        while index < len(lines) and lines[index].startswith('@@ '):
            match = re.fullmatch(r'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@[^\n]*\n', lines[index])
            need(match, 'invalid_scanner_hunk')
            old_start, old_count, new_start, new_count = (int(value) if value is not None else 1 for value in match.groups())
            begin = old_start - 1
            need(cursor <= begin <= len(original), 'overlapping_scanner_hunk')
            result.extend(original[cursor:begin]); cursor = begin; index += 1
            need(len(result) == new_start - 1, 'scanner_hunk_position_mismatch')
            removed = added = 0
            while index < len(lines) and not lines[index].startswith(('@@ ', '--- a/')):
                line = lines[index]; need(line and line[0] in ' +-','invalid_scanner_hunk_line')
                if line[0] in ' -':
                    need(cursor < len(original) and original[cursor] == line[1:], 'scanner_patch_context_mismatch')
                    cursor += 1; removed += 1
                if line[0] in ' +': result.append(line[1:]); added += 1
                index += 1
            need(removed == old_count and added == new_count, 'scanner_hunk_count_mismatch')
        result.extend(original[cursor:]); files[old] = ''.join(result).encode('utf-8')
    return files

def reconstruct(archive_path, output):
    need(not output.exists(), 'scanner_output_exists')
    archive_bytes = archive_path.read_bytes(); need(sha(archive_bytes) == ARCHIVE_SHA, 'scanner_archive_hash_mismatch')
    patch = (BACKPORT / 'selected-backport.patch').read_bytes(); need(sha(patch) == PATCH_SHA, 'scanner_patch_hash_mismatch')
    inventory_bytes = (BACKPORT / 'source-inventory.json').read_bytes(); need(sha(inventory_bytes) == INVENTORY_SHA, 'scanner_inventory_hash_mismatch')
    inventory = json.loads(inventory_bytes); files = {}; seen = set(); total = 0
    with tarfile.open(fileobj=io.BytesIO(archive_bytes), mode='r:gz') as archive:
        for member in archive:
            rel = safe(member.name.rstrip('/')); need(member.isfile() or member.isdir(), 'unsafe_scanner_archive_entry')
            if len(rel.parts) == 1: continue
            inner = str(PurePosixPath(*rel.parts[1:])); key = inner.casefold()
            need(key not in seen, 'duplicate_scanner_archive_entry'); seen.add(key)
            total += member.size; need(total <= 256 * 1024 * 1024, 'expanded_scanner_archive_too_large')
            if member.isfile(): files[inner] = archive.extractfile(member).read()
    apply_patch(files, patch)
    need(set(files) == set(inventory), 'scanner_source_inventory_mismatch')
    for name, expected in inventory.items(): need(sha(files[name]) == expected, 'scanner_source_hash_mismatch')
    output.mkdir(parents=True)
    try:
        for name, data in files.items():
            target = output.joinpath(*safe(name).parts); target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(data)
        receipt = {'schemaVersion': 1, 'baseCommit': BASE_COMMIT, 'sourceArchiveSHA256': ARCHIVE_SHA, 'patchSHA256': PATCH_SHA, 'sourceInventorySHA256': INVENTORY_SHA, 'sourceFiles': len(files)}
        (output / 'SCANNER-SOURCE.json').write_text(json.dumps(receipt, sort_keys=True, indent=2) + '\n')
        return receipt
    except BaseException:
        shutil.rmtree(output); raise

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args=parser.parse_args(); print(json.dumps(reconstruct(args.archive, args.output), sort_keys=True))
if __name__ == '__main__': main()
