# SPDX-License-Identifier: MIT
"""Test-only fixtures from the independently pinned, already fetched source cache."""
import subprocess
from telegram_secret_chat_adaptation import ADAPTED_SHA256, adapt_secret_chat_source

def write_secret_native_fixture(root, preparation):
    for relative in ADAPTED_SHA256:
        original = subprocess.check_output(preparation.source_git('show', preparation.SHA + ':' + relative)).decode()
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(adapt_secret_chat_source(relative, original))
