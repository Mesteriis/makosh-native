#!/usr/bin/env python3
"""Contract checks at the independently prepared upstream acknowledgement sites."""
from pathlib import Path
import sys
import unittest

ENGINE=Path(sys.argv.pop(1)) if len(sys.argv)>1 else Path('.local/whatsapp-engine')
class DurabilityBoundaryTests(unittest.TestCase):
    def test_history_hook_is_awaited_before_late_receipt_and_dispatch(self):
        source=(ENGINE/'src/history_sync.rs').read_text()
        early=source[source.index('let DetachedHistorySyncNotification {'):source.index('// Use take()')]
        self.assertIn('if self.inbound_durability_hook().is_none()',early)
        late=source[source.index('let lazy_hs = LazyHistorySync::new'):source.index('Some((Err(e), _)')]
        self.assertLess(late.index('hook.on_history(self.clone(), &lazy_hs).await.is_err()'),late.index('self.send_protocol_receipt('))
        self.assertLess(late.index('return; // no receipt'),late.index('self.send_protocol_receipt('))
        self.assertLess(late.index('self.send_protocol_receipt('),late.index('.dispatch(Event::HistorySync('))
    def test_fallback_messages_do_not_bypass_durable_hook(self):
        source=(ENGINE/'src/client/node_io.rs').read_text()
        self.assertIn('crate::inbound_early_ack_allowed(self.inbound_durability_hook().is_some(),j.is_newsletter(),j.is_status_broadcast())',source)
        self.assertIn('"status" => is_status_broadcast_stanza(node)',source)
        for filename in ['src/message/dispatch.rs','src/pdo.rs']:
            source=(ENGINE/filename).read_text()
            self.assertIn('hook.on_messages(self.clone(), std::slice::from_ref(&message)).await.is_err()',source)
            self.assertIn('.hook_committed(committed)',source)
if __name__=='__main__': unittest.main()
