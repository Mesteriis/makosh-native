#!/usr/bin/env python3
"""Prepare independently pinned portable syntax sources; never run installers."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import tempfile
from telegram_code_highlight_adaptation import SOURCE_SHA256, adapt_code_highlight_source

RECIPE = Path(__file__).resolve()
ROOT = RECIPE.parent.parent
LOCK_PATH = ROOT / 'Dependencies/CodeHighlight.lock.json'
DEST = ROOT / '.local/code-highlight-engine'
UNITS = ['Highlight', 'LanguageTree', 'SyntaxHighlighter', 'TokenList']


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fingerprint(files):
    return sha(json.dumps(files, sort_keys=True, separators=(',', ':')).encode())


def safe_path(path):
    return isinstance(path, str) and bool(re.fullmatch(r'[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*', path)) and not any(p in ('.', '..') for p in PurePosixPath(path).parts)


def validate_lock(lock):
    if lock.get('schemaVersion') != 1 or set(lock.get('dependencies', {})) != {'prisma', 'regex'}:
        raise ValueError('Unsupported syntax source lock')
    for name, pin in lock['dependencies'].items():
        url = {'prisma': 'https://github.com/desktop-app/libprisma.git', 'regex': 'https://github.com/boostorg/regex.git'}[name]
        if pin.get('sourceURL') != url or any(not isinstance(pin.get(k), str) or not re.fullmatch(r'[0-9a-f]{40}', pin[k]) for k in ('revision', 'tree')):
            raise ValueError('Invalid syntax source pin')
        files = pin.get('sourceFilesSHA256')
        if not isinstance(files, dict) or not 0 < len(files) <= 256 or any(not safe_path(p) or not isinstance(h, str) or not re.fullmatch(r'[0-9a-f]{64}', h) for p, h in files.items()):
            raise ValueError('Invalid syntax source inventory')
        if name == 'prisma' and set(files) != {'LICENSE', 'libprisma/grammars.dat'} | {'libprisma/' + n + e for n in UNITS for e in ('.cpp', '.h')}:
            raise ValueError('Unreviewed syntax compilation unit')
        if name == 'regex' and any(not p.startswith('include/boost/') or not p.endswith(('.h', '.hpp')) for p in files):
            raise ValueError('Unreviewed regex compilation unit')


def build_inputs(lock, sources):
    validate_lock(lock)
    expected = {('regex/' if n == 'regex' else '') + p: h for n, pin in lock['dependencies'].items() for p, h in pin['sourceFilesSHA256'].items()}
    if set(sources) != set(expected) or any(not isinstance(data, bytes) or sha(data) != expected[path] for path, data in sources.items()):
        raise ValueError('Syntax source bytes or inventory differ from locked blobs')
    result = {}
    for path, data in sources.items():
        if path in SOURCE_SHA256:
            data = adapt_code_highlight_source(path, data)
        if path.startswith('regex/'):
            result[path] = data
        elif path.endswith(('.cpp', '.h')):
            result['src/' + PurePosixPath(path).name] = data
        elif path == 'LICENSE':
            result['LICENSES/Prisma-MIT.notice'] = data
        else:
            result['Provenance/grammars.dat'] = data
    budget = (ROOT / 'Sources/MakoshCodeHighlight/MakoshPrismaBudget.h').read_bytes()
    result['src/include/MakoshPrismaBudget.h'] = budget
    result['LICENSES/Boost-1.0.notice'] = (ROOT / 'LICENSES/Boost-1.0.notice').read_bytes()
    grammar = sources['libprisma/grammars.dat']
    lines = [','.join(str(b) for b in grammar[i:i+64]) + ',' for i in range(0, len(grammar), 64)]
    result['src/include/MakoshPrismaGrammar.h'] = ('#pragma once\n#include <cstddef>\ninline constexpr unsigned char mk_prisma_grammar[] = {\n' + '\n'.join(lines) + '\n};\ninline constexpr size_t mk_prisma_grammar_size = sizeof(mk_prisma_grammar);\n').encode()
    result['src/include/CPrismaEngine.h'] = ('#pragma once\n' + ''.join('#include "../' + n + '.h"\n' for n in ["SyntaxHighlighter", "TokenList"])).encode()
    result['src/include/module.modulemap'] = b'module CPrismaEngine { requires cplusplus header "CPrismaEngine.h" export * }\n'
    result['Package.swift'] = b'''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "MakoshPrisma", platforms: [.macOS("26.0")],
    products: [.library(name: "CPrismaEngine", targets: ["CPrismaEngine"])],
    targets: [.target(name: "CPrismaEngine", path: ".",
        sources: ["src/Highlight.cpp", "src/LanguageTree.cpp", "src/SyntaxHighlighter.cpp", "src/TokenList.cpp"],
        publicHeadersPath: "src/include", cxxSettings: [
            .headerSearchPath("src"), .headerSearchPath("src/include"), .headerSearchPath("regex/include"),
            .define("BOOST_REGEX_STANDALONE"), .define("BOOST_REGEX_NON_RECURSIVE"),
            .define("BOOST_REGEX_MAX_BLOCKS", to: "16"), .define("BOOST_REGEX_MAX_CACHE_BLOCKS", to: "0"),
            .define("BOOST_REGEX_MAX_STATE_COUNT", to: "1000000")])], cxxLanguageStandard: .cxx17)
'''
    reviewed = lock.get('preparedFilesSHA256')
    if reviewed is not None and fingerprint({p: sha(d) for p, d in result.items()}) != reviewed:
        raise ValueError('Syntax prepared file set differs from reviewed output')
    return result


def git(cache, *args):
    return ['git', '--no-replace-objects', '--git-dir', str(cache), *args]


def output(*args):
    return subprocess.check_output(args).decode().strip()


def pinned_sources(lock):
    validate_lock(lock)
    result = {}
    for name, pin in lock['dependencies'].items():
        cache = ROOT / ('.local/code-highlight-' + name + '-source.git')
        if cache.is_symlink() or cache.parent.is_symlink(): raise RuntimeError('Syntax cache links refused')
        if not cache.exists():
            cache.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix='syntax-source-', dir=cache.parent) as temp:
                staged = Path(temp) / 'source.git'
                output('git', 'init', '--bare', '--quiet', '--initial-branch=main', str(staged))
                output(*git(staged, 'fetch', '--depth', '1', '--no-tags', pin['sourceURL'], pin['revision']))
                if output(*git(staged, 'rev-parse', 'FETCH_HEAD')) != pin['revision']: raise RuntimeError('Fetched syntax pin differs')
                staged.rename(cache)
        if output(*git(cache, 'rev-parse', '--is-bare-repository')) != 'true' or output(*git(cache, 'rev-parse', pin['revision'] + '^{tree}')) != pin['tree']:
            raise RuntimeError('Syntax Git source differs from pinned tree')
        total = 0
        for path, digest in pin['sourceFilesSHA256'].items():
            entry = subprocess.check_output(git(cache, 'ls-tree', '-z', pin['revision'], '--', path)).split(b'\0')
            if len(entry) != 2 or entry[1] != b'': raise RuntimeError('Missing syntax source blob')
            header, actual = entry[0].split(b'\t'); mode, kind, oid = header.decode().split()
            if actual.decode() != path or mode != '100644' or kind != 'blob': raise RuntimeError('Unsafe syntax Git path/mode')
            size = int(output(*git(cache, 'cat-file', '-s', oid))); total += size
            if size > 4 * 1024 * 1024 or total > 8 * 1024 * 1024: raise RuntimeError('Syntax source exceeds bounds')
            data = subprocess.check_output(git(cache, 'cat-file', 'blob', oid))
            if len(data) != size or sha(data) != digest: raise RuntimeError('Syntax source checksum differs')
            result[('regex/' if name == 'regex' else '') + path] = data
    return result


def prepared_hashes(destination):
    result, total = {}, 0
    if destination.is_symlink(): raise RuntimeError('Syntax artifact link refused')
    for path in sorted(destination.rglob('*')):
        if path.is_symlink() or not (path.is_file() or path.is_dir()): raise RuntimeError('Unsafe syntax artifact file')
        if path.is_file() and path != destination / 'preparation.json':
            total += path.stat().st_size
            if path.stat().st_size > 4 * 1024 * 1024 or total > 16 * 1024 * 1024 or len(result) >= 256: raise RuntimeError('Syntax artifact exceeds bounds')
            result[path.relative_to(destination).as_posix()] = sha(path.read_bytes())
    return result


def prepare():
    raw = LOCK_PATH.read_bytes()
    if len(raw) > 128 * 1024: raise RuntimeError('Oversized syntax lock')
    lock = json.loads(raw); validate_lock(lock)
    if not re.fullmatch(r'[0-9a-f]{64}', lock.get('preparedFilesSHA256', '')): raise RuntimeError('Missing reviewed syntax output fingerprint')
    identity = {'schemaVersion': 2, 'lockSHA256': sha(raw)}
    for key, path in [('recipeSHA256', RECIPE),
                      ('adapterSHA256', RECIPE.with_name('telegram_code_highlight_adaptation.py')),
                      ('budgetSHA256', ROOT / 'Sources/MakoshCodeHighlight/MakoshPrismaBudget.h'),
                      ('boostNoticeSHA256', ROOT / 'LICENSES/Boost-1.0.notice')]:
        if path.is_symlink() or not path.is_file(): raise RuntimeError('Syntax recipe input must be a regular file')
        identity[key] = sha(path.read_bytes())
    if DEST.exists() or DEST.is_symlink():
        marker = DEST / 'preparation.json'
        if marker.is_symlink() or not marker.is_file(): raise RuntimeError('Missing regular syntax preparation record')
        record = json.loads(marker.read_text())
        if record != identity or fingerprint(prepared_hashes(DEST)) != lock['preparedFilesSHA256']:
            raise RuntimeError('Syntax preparation changed; preserve/rename before preparing again')
        print('Syntax engine: locked preparation verified'); return
    files = build_inputs(lock, pinned_sources(lock))
    DEST.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='syntax-package-', dir=DEST.parent) as temporary:
        staged = Path(temporary) / 'package'; staged.mkdir()
        for path, data in files.items():
            target = staged / path; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(data)
        (staged / 'preparation.json').write_text(json.dumps(identity, sort_keys=True) + '\n')
        if fingerprint(prepared_hashes(staged)) != lock['preparedFilesSHA256']: raise RuntimeError('Syntax package write differs')
        staged.rename(DEST)
    print('Syntax engine: prepared pinned grammar, portable parser and standalone regex')


if __name__ == '__main__':
    prepare()
