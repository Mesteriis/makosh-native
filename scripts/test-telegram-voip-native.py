#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Actual native media/transport fixtures; never uses physical devices/accounts."""
from pathlib import Path
import subprocess
ROOT = Path(__file__).resolve().parent.parent
build = ROOT / '.local/telegram-voip/build'
expected = set((ROOT / 'Native/TelegramVoIP/exports.txt').read_text().splitlines())
actual = {line.split()[-1] for line in subprocess.check_output(['nm', '-gU', str(build / 'libMakoshTelegramVoIP.dylib')], text=True).splitlines() if line.strip()}
if actual != expected: raise SystemExit('Native call dylib exports symbols beyond the reviewed C ABI')
for mode in ['proxy', 'proxy-auth', 'packet-proxy', 'teardown-null', 'teardown-connect', 'teardown-owned',
             'domain', 'ipv6', 'method-denied', 'auth-denied', 'auth-downgrade', 'reply-denied', 'reply-invalid', 'reply-address']:
    subprocess.run([str(build / 'makosh_call_relay_socket_tests'), mode], check=True, timeout=15)
subprocess.run([str(build / 'makosh_call_socks5_loopback_tests')], check=True, timeout=15)
for version in ['2.7.7', '5.0.0']:
    subprocess.run([str(build / 'makosh_call_media_tests'), version], check=True)
print('Native call symbol isolation and both negotiated protocol media fixtures pass')
