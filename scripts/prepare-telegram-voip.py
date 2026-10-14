#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Prepare and build the independently pinned one-to-one native call closure."""
import hashlib, io, json, os, re, subprocess, sys, tarfile, tempfile
from pathlib import Path, PurePosixPath
ROOT = Path(__file__).resolve().parent.parent
DEST = ROOT / '.local/telegram-voip'
PINS = [
    ('calls', 'https://github.com/overtake/tgcalls.git', '5ddc3ccf2086127722a06e3d836698fcd717f11b', 'df0c4e900ebf3f5ecd42743da6e26a5323334682', 'tgcalls-source.git'),
    ('owt', 'https://github.com/desktop-app/tg_owt.git', 'be39b8c8d0db1f377118f813f0c4bd331d341d5e', '9410c5c094e3d35d3abdd3dc7e5281c9a01651f1', 'tg-owt-source.git'),
    ('owt/src/third_party/abseil-cpp', 'https://github.com/abseil/abseil-cpp.git', 'd7aaad83b488fd62bd51c81ecf16cd938532cc0a', 'b7787164b428ec7b9dc8168cfe8d5363654e2600', 'voip-abseil-source.git'),
    ('owt/src/third_party/crc32c/src', 'https://github.com/google/crc32c.git', '21fc8ef30415a635e7351ffa0e5d5367943d4a94', '96bd5adb8040b61b0d5e887c229f714e2d407d2c', 'voip-crc32c-source.git'),
    ('owt/src/third_party/libsrtp', 'https://github.com/cisco/libsrtp.git', 'a566a9cfcd619e8327784aa7cff4a1276dc1e895', 'e578452a4c2b77f699c8d0e40ffc01f58b0b5aec', 'voip-libsrtp-source.git'),
    ('owt/src/third_party/libyuv', 'https://gitlab.com/chromiumsrc/libyuv.git', '04821d1e7d60845525e8db55c7bcd41ef5be9406', '46b29e13d76928a8423b346d085eda3eb215e4bb', 'voip-libyuv-source.git'),
]
ADAPTATIONS = {
    'owt/src/api/candidate.h': {'input': 'a0b0cc16788023af99146da8f93b243f1f977beb9af373bb4e737f689b1531b5', 'output': '2099f8aa5524c70ca29bf56542db9343fef6e408c7debd0012a7015f6a0c3808'},
    'calls/tgcalls/LogSinkImpl.h': {'input': 'bfb66a4d0b728bf9570fae6968b002462840f16dc16d2703ab1ca9d60c0e115f', 'output': 'b663ff649c42b833fabbb76d6a53dcefa02c9b31c2afde6448f322b8c82e8384'},
    'calls/tgcalls/LogSinkImpl.cpp': {'input': '709d0e5015a0f1692bd47d20302ab9d303c4f47f223ee80b8ca666b02eb1bfa3', 'output': '1218dd80c31986e2aefae5a0cd83cf213f26dd8c07194fb71066f45d4df2fcb6'},
    'calls/tgcalls/NetworkManager.cpp': {'input': 'bd20d1a897bab083a6a534ae7251ce9424e238e50f17a421cdc58498a1b06f60', 'output': '8bf9c95f3fc8826c4f93a687ebd2f4f5ce39cc94aa4a64b7f9759e122cda5216'},
    'calls/tgcalls/InstanceImpl.cpp': {'input': 'ce32b22907ce2901b574aa9aee2c3909075f62ec2b0491b02e82f42174dcd02b', 'output': '6b4c0a1864b36a6d2744c6f75fb85dcdb327b6eca48a2834c2b9b6d37a5af82d'},
    'calls/tgcalls/v2/ReflectorPort.cpp': {'input': '2cf7decd09254d69d595041f0f96075cac0418ab4e9e84ee2a3f1367396a81aa', 'output': '40c0faf07d2e64eac86b0938be8adf94d7129f2edc36cf2cb4a59624b3e44986'},
    'owt/src/p2p/base/basic_packet_socket_factory.cc': {'input': '4d5c410a9d40520a76a5e650f97d1ff1e562e36220afc015ff9bd1f51f071dc2', 'output': '4fd1ac70d65b3fe94fed21113e46dfecdf70fe93c77735fbe2c9b0715ceee417'},
}
def sha(value): return hashlib.sha256(value).hexdigest()
def fingerprint(files): return sha(json.dumps(files, sort_keys=True, separators=(',', ':')).encode())
def plain(path):
    if any(p.is_symlink() for p in [path, *path.parents]): raise ValueError('Symlink in native call preparation path')
def safe(name):
    p = PurePosixPath(name)
    return bool(name) and not p.is_absolute() and not any(x in ('.', '..') for x in p.parts) and '\\' not in name and '\0' not in name

def archive_files(blob):
    if len(blob) > 160 * 1024 * 1024: raise ValueError('Native archive exceeds bounds')
    files, names, total = {}, set(), 0
    with tarfile.open(fileobj=io.BytesIO(blob), mode='r:') as archive:
        for member in archive:
            name = member.name.rstrip('/') if member.isdir() else member.name
            if not safe(name) or name in names or not (member.isfile() or member.isdir()): raise ValueError('Unsafe native archive member')
            names.add(name); total += member.size
            if len(names) > 20000 or member.size < 0 or member.size > 32 * 1024 * 1024 or total > 128 * 1024 * 1024: raise ValueError('Native archive member exceeds bounds')
            if member.isfile(): files[name] = archive.extractfile(member).read()
    return files

def adapt(path, source):
    record = ADAPTATIONS[path]
    digest = sha(source)
    if digest == record['output']: return source
    if digest != record['input']: raise ValueError('Native adaptation source differs from pin: ' + path)
    text = source.decode()
    if path.endswith('candidate.h'):
        text = text.replace('void set_type(absl::string_view type ABSL_ATTRIBUTE_LIFETIME_BOUND)', 'void set_type(absl::string_view type [[clang::lifetime_capture_by(this)]])')
    elif path.endswith('LogSinkImpl.h'):
        text = text.replace('return _data.str();', 'return {};').replace('\tstd::ofstream _file;\n\tstd::ostringstream _data;', '')
    elif path.endswith('LogSinkImpl.cpp'):
        text = '#include "LogSinkImpl.h"\nnamespace tgcalls {\nLogSinkImpl::LogSinkImpl(const FilePath &) {}\nvoid LogSinkImpl::OnLogMessage(const std::string &, rtc::LoggingSeverity, const char *) {}\nvoid LogSinkImpl::OnLogMessage(const std::string &, rtc::LoggingSeverity) {}\nvoid LogSinkImpl::OnLogMessage(const std::string &) {}\n}\n'
    elif path.endswith('NetworkManager.cpp'):
        text = text.replace('#include "NetworkManager.h"', '#include "NetworkManager.h"\n#include "CallNetworkPolicy.hpp"')
        start = text.index('    uint32_t flags = _portAllocator->flags();')
        end = text.index('    _portAllocator->set_step_delay', start)
        text = text[:start] + '    makosh::configureCallPortAllocator(*_portAllocator, _enableP2P, _enableTCP, bool(_proxy));\n\n' + text[end:]
        text = text.replace('    _portAllocator->set_flags(flags);\n', '')
        text = text.replace('        if (server.isTcp) {\n            continue;\n        }', '        const auto protocol = makosh::callRelayProtocol(server.isTcp, bool(_proxy));\n        if (!protocol) continue;')
        text = text.replace('                cricket::PROTO_UDP\n', '                *protocol\n')
        text = text.replace('        } else {\n            rtc::SocketAddress stunAddress', '        } else {\n            if (!_enableP2P || _proxy || server.isTcp) continue;\n            rtc::SocketAddress stunAddress')
    elif path.endswith('InstanceImpl.cpp'):
        text = text.replace('LogToDebug(rtc::LS_INFO)', 'LogToDebug(rtc::LS_NONE)').replace('AddLogToStream(_logSink.get(), rtc::LS_INFO)', 'AddLogToStream(_logSink.get(), rtc::LS_NONE)')
    elif path.endswith('ReflectorPort.cpp'):
        text = text.replace('#include "RawTcpSocket.h"', '#include "RawTcpSocket.h"\n#include "CallProxySocket.hpp"')
        text = text.replace('    if (socket->Connect(remote_address) < 0) {', '    if (proxy_info.type == rtc::PROXY_SOCKS5) {\n        socket = makosh::wrapCallSocks5(socket, proxy_info);\n    } else if (proxy_info.type != rtc::PROXY_NONE) {\n        delete socket;\n        return nullptr;\n    }\n    if (socket->Connect(remote_address) < 0) {')
        text = text.replace('    if (!SharedSocket()) {\n        delete socket_;\n    }\n    \n    if (server_address_.proto == cricket::PROTO_TCP) {\n        socket_->UnsubscribeCloseEvent(this);\n    }', '    if (socket_ && server_address_.proto == cricket::PROTO_TCP) {\n        socket_->UnsubscribeCloseEvent(this);\n    }\n    if (!SharedSocket()) {\n        delete socket_;\n    }')
        text = text.replace('if (server_address_.address.IsUnresolvedIP()) {', 'if (server_address_.address.IsUnresolvedIP() && proxy().type != rtc::PROXY_SOCKS5) {')
        text = text.replace('if (!IsCompatibleAddress(server_address_.address)) {', 'if (!server_address_.address.IsUnresolvedIP() && !IsCompatibleAddress(server_address_.address)) {')
    elif path.endswith('basic_packet_socket_factory.cc'):
        text = text.replace('#include "p2p/base/basic_packet_socket_factory.h"', '#include "p2p/base/basic_packet_socket_factory.h"\n#include "CallProxySocket.hpp"')
        text = text.replace('  if (proxy_info.type == PROXY_HTTPS) {', '  if (proxy_info.type == PROXY_SOCKS5) {\n    socket = makosh::wrapCallSocks5(socket, proxy_info);\n  } else if (proxy_info.type == PROXY_HTTPS) {')
    result = text.encode()
    if sha(result) != record['output']: raise ValueError('Native adaptation output differs from review: ' + path)
    return result

def validate_lock(lock):
    if set(lock) != {'schemaVersion', 'components', 'adaptations'} or lock['schemaVersion'] != 1 or lock['adaptations'] != ADAPTATIONS or len(lock['components']) != len(PINS): raise ValueError('Unreviewed native call lock')
    for item, (path, url, revision, tree, _) in zip(lock['components'], PINS):
        if set(item) != {'path', 'url', 'revision', 'tree', 'sourceFingerprint', 'preparedFingerprint', 'fileCount', 'license'} or (item['path'], item['url'], item['revision'], item['tree']) != (path, url, revision, tree): raise ValueError('Unreviewed native call origin')
        if type(item['fileCount']) != int or not 1 <= item['fileCount'] <= 20000 or any(not re.fullmatch('[a-f0-9]{64}', item[k]) for k in ['sourceFingerprint', 'preparedFingerprint']): raise ValueError('Invalid native call source fingerprint')

def git(cache, *args): return ['git', '-c', 'credential.helper=', '-c', 'core.hooksPath=/dev/null', '--no-replace-objects', '--git-dir=' + str(cache), *args]
def fetch_component(pin):
    path, url, revision, tree, cache_name = pin; cache = ROOT / '.local' / cache_name; plain(cache)
    if not cache.exists(): subprocess.run(['git', 'init', '--bare', '--quiet', str(cache)], check=True)
    if subprocess.run(git(cache, 'cat-file', '-e', revision + '^{commit}'), capture_output=True).returncode:
        subprocess.run(git(cache, 'fetch', '--depth', '1', '--no-tags', url, revision), check=True)
    for suffix, expected in [('commit', revision), ('tree', tree)]:
        if subprocess.check_output(git(cache, 'rev-parse', revision + '^{' + suffix + '}'), text=True).strip() != expected: raise ValueError('Native call Git pin differs')
    return archive_files(subprocess.check_output(git(cache, 'archive', '--format=tar', revision)))

def component_hashes(root, nested=()):
    plain(root); result = {}
    for path in root.rglob('*'):
        name = path.relative_to(root).as_posix()
        if any(name == sub or name.startswith(sub + '/') for sub in nested): continue
        if path.is_symlink(): raise ValueError('Symlink in prepared native source')
        if path.is_file(): result[name] = sha(path.read_bytes())
    return result

def verify_component(root, component, nested=()):
    hashes = component_hashes(root, nested)
    if len(hashes) != component['fileCount'] or fingerprint(hashes) != component['preparedFingerprint']: raise ValueError('Prepared native source differs from reviewed closure')

def prepare_sources(lock):
    source = DEST / 'source'; plain(source)
    if source.exists():
        for item in lock['components']:
            nested = [other['path'][len(item['path']) + 1:] for other in lock['components'] if other['path'].startswith(item['path'] + '/')]
            verify_component(source / item['path'], item, nested)
        return source
    DEST.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='voip-source-', dir=DEST) as temporary:
        stage = Path(temporary)
        for item, pin in zip(lock['components'], PINS):
            files = fetch_component(pin)
            if fingerprint({n: sha(v) for n, v in files.items()}) != item['sourceFingerprint']: raise ValueError('Native archive content differs from reviewed source')
            prepared = {n: adapt(item['path'] + '/' + n, data) if item['path'] + '/' + n in ADAPTATIONS else data for n, data in files.items()}
            if len(prepared) != item['fileCount'] or fingerprint({n: sha(v) for n, v in prepared.items()}) != item['preparedFingerprint']: raise ValueError('Native prepared content differs from review')
            for name, value in prepared.items():
                target = stage / item['path'] / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(value)
        stage.rename(source)
    return source

def vpx_build_permissions(source):
    for name in ['configure', 'build/make/version.sh', 'build/make/rtcd.pl', 'build/make/gen_asm_deps.sh']:
        path = source / name; plain(path); path.chmod(0o755)

def prepare_vpx():
    import importlib.util
    spec = importlib.util.spec_from_file_location('call_vpx', ROOT / 'scripts/prepare-vpx.py'); vpx = importlib.util.module_from_spec(spec); spec.loader.exec_module(vpx)
    archive = ROOT / '.local/vpx-archives' / (vpx.ARCHIVE_CONTENT_SHA256 + '.tar.gz')
    plain(archive)
    files = vpx.archive_files(archive.read_bytes() if archive.exists() else vpx.download_archive())
    source = DEST / 'vpx'; expected = {n: sha(v) for n, v in files.items()}
    if source.exists():
        if component_hashes(source) != expected: raise ValueError('Call VPX source differs from pin')
    else:
        source.mkdir()
        for name, value in files.items():
            path = source / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(value)
    vpx_build_permissions(source)
    return source

def run_build(source):
    for recipe in ['prepare-opus.py', 'prepare-mozjpeg.py']:
        subprocess.run([sys.executable, str(ROOT / 'scripts' / recipe)], cwd=ROOT, check=True)
    vpx = prepare_vpx(); vpx_build = DEST / 'vpx-build'; vpx_build.mkdir(exist_ok=True)
    flags = ['--target=arm64-darwin25-gcc', '--disable-neon', '--disable-neon-dotprod', '--disable-neon-i8mm', '--disable-sve', '--disable-sve2', '--disable-runtime-cpu-detect', '--disable-examples', '--disable-tools', '--disable-docs', '--disable-unit-tests', '--enable-pic', '--disable-shared', '--enable-static', '--enable-vp8', '--enable-vp9', '--disable-vp9-encoder', '--disable-webm-io', '--size-limit=1920x1080']
    environment = dict(os.environ, CFLAGS='-fPIC -fvisibility=hidden -DVPX_MAX_ALLOCABLE_MEMORY=67108864 -mmacosx-version-min=26.0')
    subprocess.run(['bash', str(vpx / 'configure'), *flags], cwd=vpx_build, env=environment, check=True)
    subprocess.run(['make', '-j4', 'libvpx.a'], cwd=vpx_build, env=environment, check=True)
    # Prepared Opus/Mozjpeg are verified by their existing source preparation recipes first.
    opus = ROOT / '.local/voice-codec/Sources/COpus'; jpeg = ROOT / '.local/jpeg-codec/Sources/CMozjpeg'
    inputs = {'opus': sorted(str(p) for p in opus.rglob('*.c')), 'jpeg': [str(jpeg / n) for n in json.loads((ROOT / 'Dependencies/Mozjpeg.lock.json').read_text())['sources']]}
    (DEST / 'CompilationInputs.cmake').write_text('\n'.join('set(MAKOSH_' + name.upper() + '_SOURCES\n' + '\n'.join(' "' + p + '"' for p in paths) + '\n)' for name, paths in inputs.items()) + '\n')
    openssl = subprocess.check_output(['brew', '--prefix', 'openssl@3'], text=True).strip()
    build = DEST / 'build'
    subprocess.run(['cmake', '-S', str(ROOT / 'Native/TelegramVoIP'), '-B', str(build), '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=26.0', '-DCMAKE_POLICY_VERSION_MINIMUM=3.5', '-DMAKOSH_CALL_SOURCE=' + str(source), '-DMAKOSH_CALL_DEST=' + str(DEST), '-DMAKOSH_OPENSSL=' + openssl], check=True)
    subprocess.run(['cmake', '--build', str(build), '--target', 'MakoshTelegramVoIP', 'makosh_call_media_tests', 'makosh_call_admission_tests', 'makosh_call_network_policy_tests', 'makosh_call_audio_admission_tests', 'makosh_call_relay_socket_tests', 'makosh_call_socks5_loopback_tests', '-j', '4'], check=True)
    subprocess.run([str(build / 'makosh_call_admission_tests')], check=True)
    subprocess.run([str(build / 'makosh_call_network_policy_tests')], check=True)
    subprocess.run([str(build / 'makosh_call_audio_admission_tests')], check=True)
    binary = build / 'libMakoshTelegramVoIP.dylib'
    # Save the actual built-artifact fingerprint together with compiler and all canonical build inputs.
    inputs = {str(p.relative_to(ROOT)): sha(p.read_bytes()) for base in [ROOT / 'Native/TelegramVoIP', ROOT / 'Sources/CMakoshTelegramVoIP/include'] for p in base.rglob('*') if p.is_file()}
    inputs['Dependencies/TelegramVoip.lock.json'] = sha((ROOT / 'Dependencies/TelegramVoip.lock.json').read_bytes())
    (DEST / 'build-provenance.json').write_text(json.dumps({'inputs': inputs, 'binarySHA256': sha(binary.read_bytes()), 'compiler': subprocess.check_output(['clang++', '--version'], text=True).splitlines()[0]}, indent=2) + '\n')

def main():
    lock = json.loads((ROOT / 'Dependencies/TelegramVoip.lock.json').read_text()); validate_lock(lock)
    source = prepare_sources(lock)
    if '--sources-only' not in sys.argv: run_build(source)
    print('Telegram calls: independent pinned native closure verified')
if __name__ == '__main__': main()
