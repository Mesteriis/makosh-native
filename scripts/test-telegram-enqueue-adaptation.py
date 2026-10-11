#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline source pin checks; encrypted receipt/reopen tests live in XCTest."""
import hashlib
from pathlib import Path
import unittest
from telegram_enqueue_adaptation import ENQUEUE, SOURCE_SHA256, ADAPTED_SHA256, adapt_enqueue_source


LEGACY_ADAPTED_SHA256 = "1eeaf9c208f35c6a0ea0bbffef9213df1008ed29f05cd66f1f3841d165edd35c"
SCALAR_SIGNATURE = "func enqueueMessages(transaction: Transaction, accountPeerId: PeerId, isSupportUser: Bool, timestamp: () -> Int32, peerId: PeerId, messages: [(Bool, EnqueueMessage)], disableAutoremove: Bool = false, transformGroupingKeysWithPeerId: Bool = false) -> [MessageId?] {"
NATIVE_BODY_SHA256 = "dd763ea7604c9fb09606b6cc61c2094e502c9a00e3e8c79672546a6f6bc1d2e7"


def upstream_fixture(source):
    """Undo only the previous exact reviewed patch in this test's memory.

    This permits testing before root regenerates the engine. Neither the adapter
    nor the test accepts a legacy digest as the new adaptation's output.
    """
    if hashlib.sha256(source.encode()).hexdigest() != LEGACY_ADAPTED_SHA256:
        return source
    signature = "public func enqueueMessages(account: Account, peerId: PeerId, messages: [EnqueueMessage]"
    source = source.replace(signature + ", transactionAdmission: ((Transaction) -> Bool)? = nil, transactionCommit: ((Transaction, [MessageId?]) -> Void)? = nil)", signature + ")", 1)
    source = source.replace("""            // Makosh: validate the owned pending draft before admitting any send.
            guard transactionAdmission?(transaction) ?? true else { return [] }
            let ids = enqueueMessages(transaction: transaction, account: account, peerId: peerId, messages: messages)
            // Persist queue admission beside the message, before the UI callback.
            transactionCommit?(transaction, ids)
            return ids""", """            return enqueueMessages(transaction: transaction, account: account, peerId: peerId, messages: messages)""", 1)
    if hashlib.sha256(source.encode()).hexdigest() != SOURCE_SHA256:
        raise RuntimeError("Legacy test fixture did not recover the exact upstream pin")
    return source


def function_body(source, signature):
    return source.split(signature, 1)[1].split("\n}", 1)[0]


class EnqueueAdaptationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(__file__).resolve().parent.parent / ".local/telegram-engine" / ENQUEUE
        if path.is_symlink():
            raise RuntimeError("Enqueue source fixture symlink refused")
        cls.source = upstream_fixture(path.read_text())

    def testExactPinAndIdempotency(self):
        self.assertIn(hashlib.sha256(self.source.encode()).hexdigest(), [SOURCE_SHA256, ADAPTED_SHA256])
        adapted = adapt_enqueue_source(self.source)
        self.assertEqual(hashlib.sha256(adapted.encode()).hexdigest(), ADAPTED_SHA256)
        self.assertEqual(adapt_enqueue_source(adapted), adapted)

    def testUnknownAndTamperedSourceFailClosed(self):
        for changed in [self.source + "\n", self.source.replace("import Foundation", "import Darwin", 1), "unknown"]:
            with self.assertRaises(ValueError):
                adapt_enqueue_source(changed)

    def testNativeCoreOnlySubstitutesReviewedAccountScalars(self):
        adapted = adapt_enqueue_source(self.source)
        self.assertTrue(SCALAR_SIGNATURE in adapted, "Shared native core still requires Account")
        core = function_body(adapted, SCALAR_SIGNATURE)
        self.assertNotIn("account.", core)
        restored = core.replace("accountPeerId", "account.peerId").replace("isSupportUser", "account.isSupportUser")
        restored = restored.replace("var timestamp = timestamp()", "var timestamp = Int32(account.network.context.globalTime())")
        self.assertEqual(hashlib.sha256(restored.encode()).hexdigest(), NATIVE_BODY_SHA256,
                         "Native message logic changed beyond the three reviewed scalar inputs")
    def testMutatedAdaptedOutputFailClosed(self):
        adapted = adapt_enqueue_source(self.source)
        mutations = [
            ("enqueueMessagesLocally", "enqueueMessagesElsewhere"),
            ("messages.map { (false, $0) }", "messages.map { (true, $0) }"),
            ("guard transactionAdmission?(transaction) ?? true else { return [] }", "// admission removed"),
            ("transactionCommit?(transaction, ids)", "// receipt removed"),
            ("var timestamp = timestamp()", "var timestamp: Int32 = 0"),
            ("if peerId == accountPeerId", "if peerId != accountPeerId"),
        ]
        for original, replacement in mutations:
            with self.subTest(contract=original):
                self.assertTrue(original in adapted, "Missing mutation target: " + original)
                with self.assertRaises(ValueError):
                    adapt_enqueue_source(adapted.replace(original, replacement, 1))


if __name__ == "__main__":
    unittest.main()
