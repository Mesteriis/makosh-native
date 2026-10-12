#!/usr/bin/env python3
"""Prepare independently pinned portable VP9 C11 sources; no upstream scripts."""
import importlib.util
import io
import json
from pathlib import Path, PurePosixPath
import re
import tarfile
import tempfile
import urllib.request

RECIPE = Path(__file__).resolve()
ROOT = RECIPE.parent.parent
spec = importlib.util.spec_from_file_location('vpx_archive_helpers', RECIPE.with_name('prepare-opus.py'))
helpers = importlib.util.module_from_spec(spec); spec.loader.exec_module(helpers)
spec = importlib.util.spec_from_file_location('vpx_rtcd', RECIPE.with_name('vpx_rtcd_preparation.py'))
rtcd = importlib.util.module_from_spec(spec); spec.loader.exec_module(rtcd)
REVISION = '6df3ec34557879fff673706f4a1d9fbd0f3a6f0e'
TREE = 'f83d33a1ba18b3a203e43596b5223042b62417a3'
ARCHIVE_SHA256 = '3438fed428d5b272528b5e397cc3aa24cf080751933f600af3f8fcfcce1ab55b'
URL = 'https://chromium.googlesource.com/webm/libvpx/+archive/' + REVISION + '.tar.gz'
LEGAL = {'LICENSE', 'PATENTS', 'AUTHORS'}
DECLARATIONS = {'vp9_rtcd': 'vp9/common/vp9_rtcd_defs.pl',
    'vpx_dsp_rtcd': 'vpx_dsp/vpx_dsp_rtcd_defs.pl', 'vpx_scale_rtcd': 'vpx_scale/vpx_scale_rtcd.pl'}
ENABLED = {'CONFIG_VP9', 'CONFIG_VP9_DECODER', 'CONFIG_DECODERS', 'CONFIG_MULTITHREAD',
    'CONFIG_OS_SUPPORT', 'CONFIG_SIZE_LIMIT', 'HAVE_PTHREAD_H', 'HAVE_POSIX_MEMALIGN', 'HAVE_UNISTD_H'}


def safe_path(name):
    return isinstance(name, str) and bool(re.fullmatch(r'[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*', name)) and \
        not any(p in ('.', '..') for p in PurePosixPath(name).parts)


def validate_lock(lock):
    keys = {'schemaVersion', 'version', 'revision', 'tree', 'sourceURL', 'archiveSHA256', 'sourceFilesSHA256', 'sources'}
    if set(lock) not in [keys, keys | {'preparedFilesSHA256'}] or lock['schemaVersion'] != 1 or \
            lock['version'] != '1.17.0' or lock['revision'] != REVISION or lock['tree'] != TREE or \
            lock['sourceURL'] != URL or lock['archiveSHA256'] != ARCHIVE_SHA256:
        raise ValueError('Unreviewed VPX source origin or version')
    files = lock['sourceFilesSHA256']
    if not isinstance(files, dict) or len(files) != 126 or not (LEGAL | set(DECLARATIONS.values())).issubset(files):
        raise ValueError('Incomplete VPX source closure')
    for name, digest in files.items():
        if not safe_path(name) or not (name in LEGAL or name in DECLARATIONS.values() or name.endswith(('.h', '.c'))) or \
                not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest):
            raise ValueError('Unsafe VPX source or digest')
    units = sorted(name for name in files if name.endswith('.c'))
    if len(units) != 48 or lock['sources'] != units or len([n for n in files if n.endswith('.h')]) != 72:
        raise ValueError('Unreviewed VPX compilation closure')
    if 'preparedFilesSHA256' in lock and not re.fullmatch(r'[0-9a-f]{64}', lock['preparedFilesSHA256']):
        raise ValueError('Invalid VPX prepared fingerprint')


def archive_files(blob, expected_sha=ARCHIVE_SHA256):
    if len(blob) > 12 * 1024 * 1024 or helpers.sha(blob) != expected_sha:
        raise ValueError('VPX archive checksum or size mismatch')
    files, names, total = {}, set(), 0
    with tarfile.open(fileobj=io.BytesIO(blob), mode='r:gz') as archive:
        for member in archive:
            name = member.name.rstrip('/') if member.isdir() else member.name
            if not safe_path(name) or name in names or not (member.isfile() or member.isdir()):
                raise ValueError('Unsafe VPX archive member')
            names.add(name); total += member.size
            if member.size < 0 or member.size > 20 * 1024 * 1024 or total > 64 * 1024 * 1024 or len(names) > 5000:
                raise ValueError('VPX source archive exceeds bounds')
            if member.isfile(): files[name] = archive.extractfile(member).read()
    return files


def build_inputs(files, lock):
    validate_lock(lock)
    if set(files) != set(lock['sourceFilesSHA256']) or any(not isinstance(data, bytes) or
        helpers.sha(data) != lock['sourceFilesSHA256'][name] for name, data in files.items()):
        raise ValueError('VPX source differs from reviewed closure')
    result = {}
    for name, data in files.items():
        target = 'Licenses/' + name if name in LEGAL else 'Provenance/' + name if name in DECLARATIONS.values() else 'Sources/CVPX/' + name
        result[target] = data
    macros, owned = set(), set()
    for name, value in files.items():
        if not name.endswith(('.c', '.h')): continue
        text = value.decode()
        macros.update(re.findall(r'\b(?:CONFIG_|HAVE_|ARCH_|VPX_ARCH_)[A-Z0-9_]+\b', text))
        owned.update(re.findall(r'^\s*#\s*define\s+((?:CONFIG_|HAVE_|ARCH_|VPX_ARCH_)[A-Z0-9_]+)\b', text, re.M))
    if ENABLED & owned: raise ValueError('VPX option unexpectedly owned upstream')
    config = ['#ifndef MAKOSH_VPX_CONFIG_H', '#define MAKOSH_VPX_CONFIG_H']
    config += [f'#define {name} {int(name in ENABLED)}' for name in sorted((macros - owned) | ENABLED)]
    config += ['#define INLINE inline', '#define RESTRICT __restrict', '#define DECODE_WIDTH_LIMIT 512',
        '#define DECODE_HEIGHT_LIMIT 512', '#define VPX_MAX_ALLOCABLE_MEMORY (8 * 1024 * 1024)', '#endif', '']
    result['Sources/CVPX/vpx_config.h'] = '\n'.join(config).encode()
    result['Sources/CVPX/vpx_version.h'] = (
        '#define VERSION_PACKED ((1 << 16) | (17 << 8))\n'
        '#define VERSION_STRING_NOSP "v1.17.0-makosh-6df3ec34"\n'
        '#define VERSION_EXTRA "makosh-6df3ec34"\n').encode()
    result['Sources/CVPX/vpx_config.c'] = (
        '#include "vpx/vpx_codec.h"\n'
        'const char *vpx_codec_build_config(void) { return "Makosh portable VP9 decoder 6df3ec34; 512px; 8-bit; pthread_once; C-only"; }\n').encode()
    for stem, relative in DECLARATIONS.items():
        prototypes = rtcd.portable_prototypes(files[relative].decode(), ENABLED)
        result['Sources/CVPX/' + stem + '.h'] = rtcd.portable_header(stem, prototypes).encode()
    result['Sources/CVPX/include/CVPX.h'] = b'#pragma once\n#include "../vpx/vpx_decoder.h"\n#include "../vpx/vp8dx.h"\n'
    result['Sources/CVPX/include/module.modulemap'] = b'module CVPX { header "CVPX.h" export * }\n'
    units = lock['sources'] + ['vpx_config.c']
    result['Package.swift'] = ('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "MakoshVPX", platforms: [.macOS("26.0")],
    products: [.library(name: "CVPX", targets: ["CVPX"])],
    targets: [.target(name: "CVPX", path: "Sources/CVPX",
        sources: ''' + json.dumps(units) + ''', publicHeadersPath: "include",
        cSettings: [.headerSearchPath(".")])], cLanguageStandard: .c11)
''').encode()
    if 'preparedFilesSHA256' in lock and helpers.fingerprint({n: helpers.sha(v) for n, v in result.items()}) != lock['preparedFilesSHA256']:
        raise ValueError('VPX prepared closure differs from review')
    return result


def prepare(lock_path, cache, destination):
    raw = lock_path.read_bytes()
    if len(raw) > 64 * 1024: raise ValueError('Oversized VPX pin')
    lock = json.loads(raw); validate_lock(lock)
    if 'preparedFilesSHA256' not in lock: raise ValueError('Missing VPX prepared output pin')
    helpers.plain_parent(destination)
    identity = {'lockSHA256': helpers.sha(raw), 'recipeSHA256': helpers.sha(RECIPE.read_bytes()),
        'helperSHA256': helpers.sha(helpers.RECIPE.read_bytes()), 'rtcdSHA256': helpers.sha(RECIPE.with_name('vpx_rtcd_preparation.py').read_bytes())}
    if destination.exists():
        marker = destination / 'preparation.json'
        if marker.is_symlink() or not marker.is_file(): raise ValueError('Unmarked VPX output; preserve before preparing')
        hashes = helpers.prepared_hashes(destination)
        if helpers.fingerprint(hashes) != lock['preparedFilesSHA256'] or json.loads(marker.read_bytes()) != dict(identity, preparedFiles=hashes):
            raise ValueError('VPX output, recipe or pin changed; preserve before preparing')
        print('VPX: verified independent source preparation'); return
    helpers.plain_parent(cache); cache.mkdir(parents=True, exist_ok=True)
    archive = cache / (ARCHIVE_SHA256 + '.tar.gz')
    if archive.is_symlink(): raise ValueError('VPX archive cache link refused')
    if not archive.exists():
        with urllib.request.urlopen(URL, timeout=30) as response:
            if not response.url.startswith('https://'): raise ValueError('VPX transport downgrade')
            blob = response.read(12 * 1024 * 1024 + 1)
        if len(blob) > 12 * 1024 * 1024 or helpers.sha(blob) != ARCHIVE_SHA256: raise ValueError('VPX archive differs from pin')
        with archive.open('xb') as output: output.write(blob)
    if not archive.is_file() or archive.stat().st_size > 12 * 1024 * 1024: raise ValueError('VPX source cache exceeds bounds')
    all_files = archive_files(archive.read_bytes())
    if not set(lock['sourceFilesSHA256']).issubset(all_files): raise ValueError('Missing VPX source closure')
    files = build_inputs({n: all_files[n] for n in lock['sourceFilesSHA256']}, lock)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='vpx-prepared-', dir=destination.parent) as temporary:
        staged = Path(temporary) / 'package'; staged.mkdir()
        for name, data in files.items():
            path = staged / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(data)
        hashes = helpers.prepared_hashes(staged)
        (staged / 'preparation.json').write_text(json.dumps(dict(identity, preparedFiles=hashes), indent=2, sort_keys=True) + '\n')
        if destination.exists() or destination.is_symlink(): raise ValueError('VPX destination appeared')
        staged.rename(destination)
    print('VPX: prepared reviewed portable source closure')


if __name__ == '__main__':
    prepare(ROOT / 'Dependencies/VPX.lock.json', ROOT / '.local/vpx-archives', ROOT / '.local/vpx-codec')
