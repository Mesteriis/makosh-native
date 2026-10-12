#!/usr/bin/env python3
import unittest
from telegram_peer_management_adaptation import STATE_MANAGER, ANCHOR, adapt_peer_management_source


class PeerManagementAdaptationTests(unittest.TestCase):
    def test_only_the_public_wrapper_changes_and_replay_body_is_preserved(self):
        original = '    func addUpdates(_ updates: Api.Updates) { impl.addUpdates(updates) }\n' + ANCHOR
        self.assertEqual(adapt_peer_management_source(STATE_MANAGER, original),
                         original.replace(ANCHOR, ANCHOR.replace('    func ', '    public func ', 1)))
        self.assertEqual(adapt_peer_management_source('Other.swift', original), original)

    def test_missing_duplicate_or_previously_changed_context_is_refused(self):
        for source in ['', ANCHOR + ANCHOR, ANCHOR.replace('self.impl.with', 'self.other.with'),
                       ANCHOR.replace('    func ', '    public func ', 1)]:
            with self.assertRaises(RuntimeError):
                adapt_peer_management_source(STATE_MANAGER, source)


if __name__ == '__main__':
    unittest.main()
