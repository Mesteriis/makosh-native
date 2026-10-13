import unittest
from telegram_proxy_adaptation import NETWORK, ACCOUNT, adapt_proxy_source

class ProxyAdaptationTests(unittest.TestCase):
    def test_changed_network_source_is_refused_before_adaptation(self):
        with self.assertRaises(RuntimeError):
            adapt_proxy_source(NETWORK, "Unreviewed network input")

    def test_changed_account_source_is_refused_before_adaptation(self):
        with self.assertRaises(RuntimeError):
            adapt_proxy_source(ACCOUNT, "Unreviewed account input")

    def test_unknown_scope_cannot_be_adapted(self):
        with self.assertRaises(RuntimeError):
            adapt_proxy_source("submodules/Other/Unrelated.swift", "Unrelated source")

if __name__ == "__main__":
    unittest.main()
