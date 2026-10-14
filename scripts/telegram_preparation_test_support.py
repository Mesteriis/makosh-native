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
    # Every warm-cache fixture must include all canonical native adaptations.
    from telegram_account_startup_adaptation import ACCOUNT_MANAGER, ENGINE_LOG, adapt_account_startup_source, adapt_disabled_short_log_source
    for relative, adapt in [(ACCOUNT_MANAGER, adapt_account_startup_source), (ENGINE_LOG, adapt_disabled_short_log_source)]:
        original = subprocess.check_output(preparation.source_git('show', preparation.SHA + ':' + relative)).decode()
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(adapt(original))
