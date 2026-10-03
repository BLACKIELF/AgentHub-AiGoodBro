#!/usr/bin/env python3
"""Build-only, stdlib TokenMonitorEngine stager. Executes only a signed, pinned Node/Koffi smoke.

Production CLI has no fixture switch. Tests call pure helpers with isolated inputs.
SOURCE.json is a reviewed trust input, not generated from a working engine tree.
An unfrozen source, unpinned architecture or unreviewed runtime always fails closed.
"""
import argparse
import base64
import hashlib
import io
import json
import os
import platform
import plistlib
from pathlib import Path, PurePosixPath
import re
import struct
import subprocess
import sys
import tarfile
import tempfile
import unicodedata
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'Companion/TokenMonitorEngine'
MAX_ARCHIVE = 256 * 1024 * 1024
MAX_EXPANDED = 1024 * 1024 * 1024
MANIFEST = 'PACKAGING.json'
DEFAULT_CACHE = Path.home() / 'Library/Caches/AiGoodBro/Next/token-monitor-downloads'
UPSTREAM = 'dcccfb01557e2786888fd5479552f392ac6c0d32'
FORK = '06a9f1625d5a505f01b39eff29f7be44a2c52188'
BAD_PARTS = {'.git', '.env', '.DS_Store', '__pycache__', '.pytest_cache',
             'auth.json', 'credentials.json', '.npmrc', '.ssh', '.aws',
             'runtime-paths.json', 'runtime-python.txt'}


class PackagingError(Exception):
    pass


def need(condition, code):
    if not condition:
        raise PackagingError(code)


def digest(data, algorithm='sha256'):
    return hashlib.new(algorithm, data).hexdigest()


def canonical(obj):
    return (json.dumps(obj, indent=2, sort_keys=True) + '\n').encode()


def read_json(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            need(key not in result, 'duplicate_json_key')
            result[key] = value
        return result
    return json.loads(path.read_bytes(), object_pairs_hook=unique)


def arch_name(value):
    aliases = {'arm64': 'arm64', 'darwin-arm64': 'arm64', 'x64': 'x64',
               'x86_64': 'x64', 'darwin-x64': 'x64'}
    need(value in aliases, 'unsupported_target_architecture')
    return aliases[value]


def relative(value):
    need(isinstance(value, str) and value and '\\' not in value
         and not any(ord(c) < 32 for c in value), 'invalid_relative_path')
    p = PurePosixPath(value)
    need(not p.is_absolute() and all(x not in ('', '.', '..') for x in value.split('/')),
         'unsafe_relative_path')
    need(not any(':' in x for x in p.parts), 'unsafe_relative_path')
    return p


def sha_pin(value):
    need(isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value), 'missing_sha256_pin')
    return value


def archive_members(blob):
    """Validate whole archive before writing anything; reject ALL links (fail closed).

    Node distributions contain safe npm symlinks. They are validated for containment
    but never materialized by the selective Node extractor. Package extractor below
    rejects even internal links, so no extraction ordering can redirect a write.
    """
    need(len(blob) <= MAX_ARCHIVE, 'archive_too_large')
    tf = tarfile.open(fileobj=io.BytesIO(blob), mode='r:*')
    seen, entries, total = set(), [], 0
    for member in tf:
        name = member.name.rstrip('/') if member.isdir() else member.name
        p = relative(name)
        key = unicodedata.normalize('NFC', str(p)).casefold()
        need(key not in seen, 'duplicate_archive_path')
        seen.add(key)
        need(member.isfile() or member.isdir() or member.issym() or member.islnk(),
             'special_archive_entry')
        if member.issym() or member.islnk():
            target = member.linkname
            need(target and not target.startswith('/') and '\\' not in target,
                 'escaping_archive_link')
            parts = list(p.parent.parts) if member.issym() else []
            for part in target.split('/'):
                if part == '..':
                    need(len(parts) > 1, 'escaping_archive_link')
                    parts.pop()
                elif part not in ('', '.'):
                    parts.append(part)
            need(parts and parts[0] == p.parts[0], 'escaping_archive_link')
        total += member.size
        need(total <= MAX_EXPANDED and len(entries) < 100000, 'expanded_archive_too_large')
        entries.append((p, member))
    # Reject file/link ancestors regardless of archive order.
    kinds = {str(p).casefold(): m.isdir() for p, m in entries}
    for p, _ in entries:
        for parent in p.parents:
            need(kinds.get(str(parent).casefold(), True), 'archive_non_directory_parent')
    return tf, entries


def extract_package(blob, destination):
    tf, entries = archive_members(blob)
    try:
        for p, m in entries:
            need(p.parts[0] == 'package', 'unexpected_archive_prefix')
            need(not (m.issym() or m.islnk()), 'package_links_forbidden')
            if len(p.parts) == 1:
                need(m.isdir(), 'invalid_package_root')
                continue
            rel = PurePosixPath(*p.parts[1:])
            need('node_modules' not in rel.parts, 'bundled_dependencies_forbidden')
            out = destination / str(rel)
            if m.isdir():
                out.mkdir(parents=True, exist_ok=True)
            else:
                out.parent.mkdir(parents=True, exist_ok=True)
                with out.open('xb') as stream:
                    stream.write(tf.extractfile(m).read())
                out.chmod(0o755 if m.mode & 0o111 else 0o644)
    finally:
        tf.close()


def node_payload(blob, arch):
    tf, entries = archive_members(blob)
    prefix = f'node-v22.23.2-darwin-{arch}'
    output = {}
    try:
        for p, m in entries:
            need(p.parts[0] == prefix, 'wrong_node_archive_target')
            if str(p) in (prefix + '/bin/node', prefix + '/LICENSE'):
                need(m.isfile(), 'invalid_node_archive_member')
                output[p.name] = tf.extractfile(m).read()
        need(set(output) == {'node', 'LICENSE'}, 'incomplete_node_archive')
        check_arch(output['node'], arch)
        return output
    finally:
        tf.close()


def registry_url(value):
    u = urlsplit(value)
    need(u.scheme == 'https' and u.netloc == 'registry.npmjs.org'
         and not u.query and not u.fragment and re.fullmatch(
             r'/(@[A-Za-z0-9._-]+/)?[A-Za-z0-9._-]+/-/[A-Za-z0-9._-]+\.tgz', u.path),
         'unapproved_registry_url')
    return value


def fetch(url, cache, expected, algorithm, offline):
    """Content-addressed archive cache only: extracted directories are never read."""
    need(algorithm in ('sha256', 'sha512'), 'invalid_hash_algorithm')
    need(re.fullmatch('[0-9a-f]{' + str(64 if algorithm == 'sha256' else 128) + '}', expected),
         'invalid_archive_digest')
    path = cache / (algorithm + '-' + expected)
    need(not cache.is_symlink() and not path.is_symlink(), 'unsafe_cache')
    if path.exists():
        need(path.is_file() and path.stat().st_size <= MAX_ARCHIVE, 'unsafe_cache_entry')
        blob = path.read_bytes()
        need(digest(blob, algorithm) == expected, 'cache_integrity_mismatch')
        return blob
    need(not offline, 'offline_cache_missing')
    cache.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.download-', dir=cache)
    os.close(fd)
    try:
        # Ignore user curlrc; never use automatic redirects or a shell. GitHub's
        # fixed release URL may make ONE explicit hop to its asset CDN only.
        initial = urlsplit(url)
        if initial.netloc == 'registry.npmjs.org':
            registry_url(url)
        elif initial.netloc == 'nodejs.org':
            need(re.fullmatch(r'https://nodejs.org/dist/v22\.23\.2/node-v22\.23\.2-darwin-(arm64|x64)\.tar\.gz', url),
                 'unapproved_download_url')
        else:
            need(re.fullmatch(r'https://github\.com/Javis603/tokscale/releases/download/token-monitor-06a9f162/tokscale-darwin-(arm64|x64)', url),
                 'unapproved_download_url')
        for hop in range(2):
            result = subprocess.run(['/usr/bin/curl', '--disable', '--proto', '=https', '--tlsv1.2',
                '--connect-timeout', '10', '--max-time', '30', '--max-filesize', str(MAX_ARCHIVE),
                '--fail', '--silent', '--show-error', '--output', temporary,
                '--write-out', '%{http_code}\n%{redirect_url}', url], capture_output=True, timeout=35)
            need(result.returncode == 0, 'bounded_download_failed')
            status, _, redirect = result.stdout.decode('ascii').partition('\n')
            if status == '200':
                break
            need(hop == 0 and initial.netloc == 'github.com' and status in ('301', '302', '303', '307', '308'),
                 'download_redirect_forbidden')
            cdn = urlsplit(redirect)
            need(cdn.scheme == 'https' and cdn.netloc == 'release-assets.githubusercontent.com'
                 and cdn.path.startswith('/github-production-release-asset/') and not cdn.fragment,
                 'download_redirect_forbidden')
            url = redirect
        else:
            raise PackagingError('bounded_download_failed')
        blob = Path(temporary).read_bytes()
        need(len(blob) <= MAX_ARCHIVE and digest(blob, algorithm) == expected,
             'download_integrity_mismatch')
        os.replace(temporary, path)
        return blob
    finally:
        Path(temporary).unlink(missing_ok=True)


def integrity_hex(value):
    need(isinstance(value, str) and value.startswith('sha512-'), 'sha512_integrity_required')
    try:
        decoded = base64.b64decode(value[7:], validate=True)
    except ValueError:
        raise PackagingError('invalid_integrity') from None
    need(len(decoded) == 64, 'invalid_integrity')
    return decoded.hex()


def supports(entry, arch):
    for field, target in (('os', 'darwin'), ('cpu', arch)):
        values = entry.get(field, [])
        need(isinstance(values, list), 'invalid_platform_constraint')
        if '!' + target in values:
            return False
        positive = [x for x in values if not x.startswith('!')]
        if positive and target not in positive and 'any' not in positive:
            return False
    return True


def closure(lock, roots, arch):
    need(lock.get('lockfileVersion') in (2, 3), 'unsupported_lock_schema')
    packages, selected = lock['packages'], {}
    queue = [(name, '', False) for name in roots]
    while queue:
        name, origin, optional = queue.pop(0)
        need(re.fullmatch(r'(@[a-z0-9._-]+/)?[a-z0-9._-]+', name), 'invalid_dependency_name')
        directory = origin
        while True:
            key = (directory + '/' if directory else '') + 'node_modules/' + name
            if key in packages:
                break
            need(directory, 'missing_lock_dependency')
            directory = directory.rsplit('/node_modules/', 1)[0] if '/node_modules/' in directory else ''
        entry = packages[key]
        relative(key)
        need(not entry.get('link') and not entry.get('inBundle'), 'unsupported_lock_dependency')
        if not supports(entry, arch):
            need(optional, 'wrong_dependency_architecture')
            continue
        if key in selected:
            continue
        registry_url(entry['resolved'])
        integrity_hex(entry['integrity'])
        selected[key] = {k: entry[k] for k in ('version', 'resolved', 'integrity')}
        opts = entry.get('optionalDependencies', {})
        deps = dict(entry.get('dependencies', {}))
        deps.update(opts)
        for dep in sorted(deps):
            queue.append((dep, key, dep in opts))
        for dep in sorted(entry.get('peerDependencies', {})):
            if not entry.get('peerDependenciesMeta', {}).get(dep, {}).get('optional'):
                queue.append((dep, key, False))
    return dict(sorted(selected.items()))


def macho_arches(blob):
    if len(blob) < 8:
        return None
    magic = blob[:4]
    if magic in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce'):
        cpu = struct.unpack(('<' if magic[0] in (0xcf, 0xce) else '>') + 'I', blob[4:8])[0]
        return {cpu}
    if magic in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        count = struct.unpack('>I', blob[4:8])[0]
        stride = 32 if magic[-1] == 0xbf else 20
        need(0 < count <= 8 and len(blob) >= 8 + count * stride, 'invalid_fat_macho')
        return {struct.unpack('>I', blob[8+i*stride:12+i*stride])[0] for i in range(count)}
    return None


def check_arch(blob, arch):
    cpus = macho_arches(blob)
    need(cpus is not None and (0x100000c if arch == 'arm64' else 0x1000007) in cpus
         and cpus <= {0x100000c, 0x1000007}, 'wrong_native_architecture')


def inventory(tree):
    need(tree.is_dir() and not tree.is_symlink(), 'missing_resource_tree')
    result, seen = {}, set()
    for p in sorted(tree.rglob('*')):
        need(not p.is_symlink(), 'resource_symlink_forbidden')
        rel = p.relative_to(tree).as_posix()
        key = unicodedata.normalize('NFC', rel).casefold()
        need(key not in seen, 'ambiguous_resource_path')
        seen.add(key)
        need(p.is_file() or p.is_dir(), 'special_resource_entry')
        if p.is_file():
            result[rel] = {'sha256': digest(p.read_bytes()), 'mode': p.stat().st_mode & 0o777}
    return result


def validate_layout(tree, packages):
    need(not (tree / 'engine').exists(), 'nested_engine_layout')
    for rel in ('bridge.cjs', 'client-catalog.json', 'upstream/package-lock.json', 'upstream/LICENSE', 'runtime/node'):
        need((tree / rel).is_file(), 'missing_engine_resource')
    for rel in ('lib', 'hooks', 'upstream', 'vendor/node_modules'):
        need((tree / rel).is_dir(), 'missing_engine_directory')
    allowed_modules = {'vendor/node_modules'}
    for key in packages:
        parts = PurePosixPath('vendor/' + key).parts
        for i, part in enumerate(parts):
            if part == 'node_modules':
                allowed_modules.add('/'.join(parts[:i+1]))
    for p in tree.rglob('*'):
        rel = p.relative_to(tree).as_posix()
        need(not (set(p.relative_to(tree).parts) & BAD_PARTS), 'private_resource_forbidden')
        if p.name == 'node_modules':
            need(rel in allowed_modules, 'unverified_node_modules')
            children = []
            for child in p.iterdir():
                children.extend(child.iterdir() if child.name.startswith('@') and child.is_dir() else [child])
            for child in children:
                need(child.is_dir() and child.relative_to(tree / 'vendor').as_posix() in packages,
                     'extraneous_dependency')
        if p.is_file() and p.suffix in ('.js', '.cjs', '.mjs', '.json', '.py', '.sh'):
            data = p.read_bytes()
            need(not any(x in data for x in (b'/Users/', b'/home/', b'file:///Users/',
                b'.codex-account-manager', b'runtime-paths.json')), 'private_runtime_path')


def validate_import_boundaries(tree):
    # Static literal boundaries are enforceable here. Dynamic loaders/environment
    # behavior additionally require the pinned final-source review; this scanner
    # deliberately does not claim to prove arbitrary JavaScript safe.
    pattern = re.compile(r"(?:require\s*\(|import\s*\(|from\s+|import\s+)\s*['\"]([^'\"]+)['\"]")
    for p in tree.rglob('*'):
        if not p.is_file() or p.suffix not in ('.js', '.cjs', '.mjs'):
            continue
        for specifier in pattern.findall(p.read_text(errors='replace')):
            need(not specifier.startswith(('/', 'file:', 'http:', 'https:', '\\')),
                 'outside_runtime_import')
            if specifier.startswith('.'):
                need((p.parent / specifier).resolve().is_relative_to(tree.resolve()),
                     'outside_runtime_import')


def native_paths(tree, arch):
    result = []
    for p in sorted(tree.rglob('*')):
        if not p.is_file():
            continue
        blob = p.read_bytes()
        if macho_arches(blob) is not None or p.suffix in ('.node', '.dylib') or p == tree / 'runtime/node':
            check_arch(blob, arch)
            result.append(p.relative_to(tree).as_posix())
        elif blob[:4] == b'\x7fELF' or blob[:2] == b'MZ':
            raise PackagingError('foreign_native_binary')
    return result


def load_production(source, arch):
    pin = read_json(source / 'SOURCE.json')
    need(pin['schemaVersion'] == 1 and pin['upstream']['commit'] == UPSTREAM
         and pin['tokscale']['commit'] == FORK and pin['node']['version'] == '22.23.2',
         'incorrect_provenance')
    final = pin['finalSource']
    need(final['status'] == 'frozen' and final['files'], 'final_source_not_frozen')
    need(final.get('runtimeIsolationReviewed') is True and final.get('reviewEvidenceSHA256'),
         'runtime_isolation_review_required')
    sha_pin(final['reviewEvidenceSHA256'])
    need(final.get('dependencyRootsReviewed') is True, 'dependency_root_review_required')
    actual = inventory(source)
    for rel, expected in final['files'].items():
        relative(rel)
        sha_pin(expected)
        need(rel in actual and actual[rel]['sha256'] == expected, 'frozen_source_mismatch')
    need(set(actual) == set(final['files']) | {'SOURCE.json'}, 'unreviewed_source_file')
    for required in ('bridge.cjs', 'client-catalog.json', 'upstream/package-lock.json', 'upstream/LICENSE'):
        need(required in final['files'], 'incomplete_frozen_source')
    for prefix in ('lib/', 'hooks/'):
        need(any(p.startswith(prefix) for p in final['files']), 'incomplete_frozen_source')
    sha_pin(final['lockSHA256'])
    need(final['files']['upstream/package-lock.json'] == final['lockSHA256'], 'lock_pin_mismatch')
    npin = pin['node']['platforms']['darwin-' + arch]
    sha_pin(npin['archiveSHA256'])
    need(npin['url'] == f'https://nodejs.org/dist/v22.23.2/node-v22.23.2-darwin-{arch}.tar.gz',
         'unapproved_node_url')
    tpin = pin['tokscale']['platforms']['darwin-' + arch]
    sha_pin(tpin['sha256'])
    need(tpin['url'] == f'https://github.com/Javis603/tokscale/releases/download/token-monitor-06a9f162/tokscale-darwin-{arch}',
         'unapproved_tokscale_url')
    need(tpin['package'] == '@tokscale/cli-darwin-' + arch, 'wrong_tokscale_package')
    return pin


def assemble(source, tree, pin, arch, cache, offline):
    """Parameterized for synthetic Python tests; never reachable as a fixture CLI."""
    need(not tree.exists(), 'output_already_exists')
    tree.mkdir()
    for rel in sorted(pin['finalSource']['files']):
        p = relative(rel)
        # Ship runtime source and original license; build scripts/tests stay out.
        if p.parts[0] not in ('bridge.cjs', 'client-catalog.json', 'provenance.json', 'lib', 'hooks', 'upstream'):
            continue
        if p.parts[0] == 'upstream' and len(p.parts) > 1 and p.parts[1] in ('scripts', 'tests', '.github'):
            continue
        need('node_modules' not in p.parts and not set(p.parts) & BAD_PARTS, 'unsafe_source_payload')
        dst = tree / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        data = (source / rel).read_bytes()
        need(digest(data) == pin['finalSource']['files'][rel], 'source_changed_during_staging')
        dst.write_bytes(data)
        dst.chmod(0o644)
    (tree / 'SOURCE.json').write_bytes(canonical(pin))
    lock = read_json(tree / 'upstream/package-lock.json')
    tpin = pin['tokscale']['platforms']['darwin-' + arch]
    roots = sorted(set(pin['dependencyRoots'] + [tpin['package']]))
    packages = closure(lock, roots, arch)
    for key, package in packages.items():
        blob = fetch(registry_url(package['resolved']), cache,
                     integrity_hex(package['integrity']), 'sha512', offline)
        destination = tree / 'vendor' / key
        extract_package(blob, destination)
        meta = read_json(destination / 'package.json')
        need(meta['version'] == package['version'] and supports(meta, arch), 'package_metadata_mismatch')
    npin = pin['node']['platforms']['darwin-' + arch]
    payload = node_payload(fetch(npin['url'], cache, sha_pin(npin['archiveSHA256']), 'sha256', offline), arch)
    if npin.get('binaryPreSignSHA256'):
        need(digest(payload['node']) == npin['binaryPreSignSHA256'], 'node_binary_hash_mismatch')
    (tree / 'runtime').mkdir()
    (tree / 'runtime/node').write_bytes(payload['node'])
    (tree / 'runtime/node').chmod(0o755)
    (tree / 'runtime/LICENSE.txt').write_bytes(payload['LICENSE'])
    target = tree / 'vendor/node_modules' / tpin['package'] / 'bin/tokscale'
    need(target.is_file(), 'missing_tokscale_binary_slot')
    blob = fetch(tpin['url'], cache, sha_pin(tpin['sha256']), 'sha256', offline)
    check_arch(blob, arch)
    target.write_bytes(blob)
    target.chmod(0o755)
    validate_layout(tree, packages)
    validate_import_boundaries(tree)
    native = native_paths(tree, arch)
    need(target.relative_to(tree).as_posix() in native, 'tokscale_not_native')
    return {'schemaVersion': 1, 'architecture': arch, 'sourceSHA256': digest(canonical(pin)),
            'lockSHA256': digest((tree / 'upstream/package-lock.json').read_bytes()),
            'packages': packages, 'roots': roots, 'nativeFiles': native,
            'directories': sorted(p.relative_to(tree).as_posix() for p in tree.rglob('*') if p.is_dir()),
            'preSignFiles': inventory(tree)}


# Reviewed release subset: V8 JIT and Koffi FFI; no debug attach or DYLD overrides.
NODE_ENTITLEMENTS = {
    'com.apple.security.cs.allow-jit': True,
    'com.apple.security.cs.allow-unsigned-executable-memory': True,
    'com.apple.security.cs.disable-library-validation': True,
}


def codesign(path, identity=None):
    if identity is not None:
        cmd = ['/usr/bin/codesign', '--force', '--sign', identity]
        if identity != '-':
            cmd += ['--options', 'runtime', '--timestamp']
        cmd.append(str(path))
    else:
        cmd = ['/usr/bin/codesign', '--verify', '--strict', '--deep', str(path)]
    with tempfile.TemporaryDirectory(prefix='token-monitor-sign-') as temporary:
        if identity is not None and path.name == 'node' and path.parent.name == 'runtime':
            entitlements = Path(temporary) / 'node-entitlements.plist'
            entitlements.write_bytes(plistlib.dumps(NODE_ENTITLEMENTS))
            cmd[-1:-1] = ['--entitlements', str(entitlements)]
        r = subprocess.run(cmd, capture_output=True, timeout=120)
    need(r.returncode == 0, 'codesign_failed' if identity is not None else 'signature_verification_failed')


def runtime_smoke(tree, arch):
    """No collectors: isolated V8 optimization and packaged Koffi/libSystem call."""
    host = platform.machine().lower()
    if sys.platform != 'darwin' or host not in ('arm64', 'aarch64', 'x86_64', 'x64') or arch_name(host) != arch:
        return {'status': 'deferred-target-host', 'architecture': arch}
    script = """const path = require('node:path');
const assert = require('node:assert/strict');
function add(a,b) { return a+b; }
%PrepareFunctionForOptimization(add);
for(let i=0;i<10000;i++) add(i,1);
%OptimizeFunctionOnNextCall(add);
assert.equal(add(40,2),42);
const koffi = require(path.join(process.argv[1], 'vendor/node_modules/koffi'));
const libc = koffi.load('/usr/lib/libSystem.B.dylib');
assert.equal(libc.func('int abs(int)')(-17),17);
process.stdout.write('TOKEN_MONITOR_RUNTIME_OK');"""
    with tempfile.TemporaryDirectory(prefix='token-monitor-runtime-smoke-') as temporary:
        result = subprocess.run([str((tree / 'runtime/node').resolve()),
                                 '--allow-natives-syntax', '-e', script, str(tree.resolve())],
                                cwd=temporary, env={'HOME': temporary, 'TMPDIR': temporary,
                                                    'PATH': '/usr/bin:/bin'},
                                capture_output=True, timeout=30)
    need(result.returncode == 0 and result.stdout == b'TOKEN_MONITOR_RUNTIME_OK', 'runtime_smoke_failed')
    return {'status': 'passed', 'architecture': arch, 'checks': ['v8-optimization', 'packaged-koffi-libsystem-ffi']}


def check_manifest(tree, expected, signature_verifier):
    actual = read_json(tree / MANIFEST)
    need({k: actual.get(k) for k in expected} == expected, 'manifest_provenance_mismatch')
    files = inventory(tree)
    files.pop(MANIFEST, None)
    need(actual.get('postSignFiles') == files, 'manifest_content_mismatch')
    need(set(files) == set(expected['preSignFiles']), 'manifest_file_set_mismatch')
    for rel, before in expected['preSignFiles'].items():
        if rel in expected['nativeFiles']:
            need(files[rel]['mode'] == before['mode'], 'native_mode_mismatch')
            signature_verifier(tree / rel)
        else:
            need(files[rel] == before, 'unsigned_content_changed')
    need(sorted(p.relative_to(tree).as_posix() for p in tree.rglob('*') if p.is_dir())
         == expected['directories'], 'manifest_directory_set_mismatch')
    validate_layout(tree, expected['packages'])
    validate_import_boundaries(tree)
    need(native_paths(tree, expected['architecture']) == expected['nativeFiles'], 'native_set_mismatch')


def receipt_path(path, resources, bundle=None):
    need(path is not None, 'trusted_receipt_required')
    path = path.absolute()
    need(not any(p.is_symlink() for p in (path, *path.parents)), 'receipt_symlink_forbidden')
    resolved = path.resolve()
    excluded = [resources.resolve()]
    if bundle is not None:
        excluded.append(bundle.resolve())
    need(not any(resolved.is_relative_to(p) for p in excluded)
         and not any(p.suffix.lower() == '.app' for p in (path, *path.parents)),
         'receipt_inside_bundle')
    return path


def native_receipt(expected, post, identity):
    # External build trust input: never inferred from bundled metadata.
    return {'schemaVersion': 1, 'architecture': expected['architecture'],
            'sourceSHA256': expected['sourceSHA256'],
            'fixedInputsSHA256': digest(canonical(expected)), 'signingIdentity': identity,
            'nativeFiles': {rel: {'pre': expected['preSignFiles'][rel], 'post': post[rel]}
                            for rel in expected['nativeFiles']}}


def check_receipt(tree, expected, path, identity):
    need(path.is_file(), 'trusted_receipt_missing')
    need(read_json(path) == native_receipt(expected, inventory(tree), identity),
         'trusted_receipt_mismatch')


def final_runtime_smoke(tree, arch):
    smoke = runtime_smoke(tree, arch)
    need(smoke.get('status') == 'passed' and smoke.get('architecture') == arch,
         'runtime_smoke_incomplete_target_host_required')
    return smoke


def verify_resources(resources, arch, cache, source=SOURCE, bundle=None, receipt=None, identity='-'):
    need(bundle is not None and resources.resolve() == (bundle / 'Contents/Resources').resolve(),
         'final_bundle_required')
    receipt = receipt_path(receipt, resources, bundle)
    need(receipt.is_file(), 'trusted_receipt_missing')
    codesign(bundle)
    pin = load_production(source, arch)
    with tempfile.TemporaryDirectory(prefix='token-monitor-verify-') as temporary:
        expected = assemble(source, Path(temporary) / 'TokenMonitorEngine', pin, arch, cache, True)
        check_receipt(resources / 'TokenMonitorEngine', expected, receipt, identity)
        check_manifest(resources / 'TokenMonitorEngine', expected, codesign)
        smoke = final_runtime_smoke(resources / 'TokenMonitorEngine', arch)
        print('TokenMonitorEngine runtime smoke: ' + smoke['status'])
    # Preserve the global prohibition except the exact independently rebuilt closure.
    for p in resources.rglob('node_modules'):
        need(p.is_relative_to(resources / 'TokenMonitorEngine/vendor'), 'outside_node_modules')
    for p in resources.rglob('*'):
        need(p.name not in BAD_PARTS, 'private_resource_forbidden')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resources', type=Path, required=True)
    parser.add_argument('--arch', required=True)
    parser.add_argument('--cache', type=Path, default=DEFAULT_CACHE)
    parser.add_argument('--node-archive', type=Path, help='Read-only seed; bytes must match the Node pin')
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--sign-identity', default='-')
    parser.add_argument('--trusted-receipt', type=Path, required=True,
                        help='Independent trusted build receipt outside the app and public dist')
    parser.add_argument('--verify', action='store_true')
    parser.add_argument('--bundle', type=Path)
    args = parser.parse_args()
    arch = arch_name(args.arch)
    if args.verify:
        verify_resources(args.resources, arch, args.cache, bundle=args.bundle, receipt=args.trusted_receipt, identity=args.sign_identity)
        print('TokenMonitorEngine: frozen payload and final signatures verified')
        return
    receipt = receipt_path(args.trusted_receipt, args.resources, args.bundle)
    pin = load_production(SOURCE, arch)
    if args.node_archive:
        npin = pin['node']['platforms']['darwin-' + arch]
        need(args.node_archive.is_file() and not args.node_archive.is_symlink(), 'unsafe_node_seed')
        blob = args.node_archive.read_bytes()
        need(digest(blob) == npin['archiveSHA256'], 'node_seed_hash_mismatch')
        args.cache.mkdir(parents=True, exist_ok=True)
        target = args.cache / ('sha256-' + npin['archiveSHA256'])
        if target.exists():
            need(not target.is_symlink() and digest(target.read_bytes()) == npin['archiveSHA256'],
                 'cache_integrity_mismatch')
        else:
            with target.open('xb') as stream:
                stream.write(blob)
    args.resources.mkdir(parents=True, exist_ok=True)
    output = args.resources / 'TokenMonitorEngine'
    need(not output.exists() and not output.is_symlink(), 'output_already_exists')
    with tempfile.TemporaryDirectory(prefix='.token-monitor-', dir=args.resources) as temporary:
        tree = Path(temporary) / 'TokenMonitorEngine'
        manifest = assemble(SOURCE, tree, pin, arch, args.cache, args.offline)
        for rel in manifest['nativeFiles']:
            codesign(tree / rel, args.sign_identity)
            codesign(tree / rel)
        expected = dict(manifest)
        manifest['runtimeSmoke'] = runtime_smoke(tree, arch)
        manifest['postSignFiles'] = inventory(tree)
        (tree / MANIFEST).write_bytes(canonical(manifest))
        check_manifest(tree, {k: v for k, v in manifest.items() if k not in ('postSignFiles', 'runtimeSmoke')}, codesign)
        record = native_receipt(expected, manifest['postSignFiles'], args.sign_identity)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=receipt.parent, delete=False) as stream:
            receipt_temp = Path(stream.name)
            stream.write(canonical(record))
        try:
            os.replace(receipt_temp, receipt)
            check_receipt(tree, expected, receipt, args.sign_identity)
            os.rename(tree, output)
        finally:
            receipt_temp.unlink(missing_ok=True)
    print('TokenMonitorEngine: staged verified frozen payload; final app signing still required')


if __name__ == '__main__':
    try:
        main()
    except (PackagingError, OSError, ValueError, KeyError, TypeError, tarfile.TarError,
            subprocess.TimeoutExpired) as error:
        # No URLs, private paths, response bodies or subprocess stderr in diagnostics.
        print('TokenMonitorEngine: ' + (str(error) if isinstance(error, PackagingError)
                                      else type(error).__name__), file=sys.stderr)
        sys.exit(1)
