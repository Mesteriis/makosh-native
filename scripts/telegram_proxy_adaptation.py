# SPDX-License-Identifier: GPL-3.0-or-later
"""Reviewed dynamic in-memory proxy source; AccountManager never stores its credentials."""
import hashlib
NETWORK = "submodules/TelegramCore/Sources/Network/Network.swift"
ACCOUNT = "submodules/TelegramCore/Sources/Account/Account.swift"
INPUTS = {
    NETWORK: "1f61d68e6f89562f48a4c71cf7fe32fe3625db59bea6d6b9e15829fbd795209e",
    ACCOUNT: "579b57ad359cf87fdd589fc9e9c711125a809bd559955b5dd7bab947ea43b5ae",
}
OUTPUTS = {
    NETWORK: "58e6c84b4b60ea45265c271ae9ae6e119e75932a5fcb6696bdc9faf180a9b905",
    ACCOUNT: "2742b80e23e664e563ae0feb9c021dda87d61699933dd6a3dc4ffa354e546f7f",
}
HELPER_OUTPUT = "536434224ef2257a86f1341e0b2f2544da88e460abc68c2d4fe4ab5b942bf88a"

def adapt_proxy_source(path, source):
    if path not in INPUTS or hashlib.sha256(source.encode()).hexdigest() != INPUTS[path]:
        raise RuntimeError("Unexpected reviewed proxy adaptation input")
    if path == NETWORK:
        changes = [
            ("    public let isICloudEnabled: Bool\n", "    public let isICloudEnabled: Bool\n    public let makoshProxySettings: Signal<ProxySettings, NoError>?\n"),
            ("useBetaFeatures: Bool, isICloudEnabled: Bool) {", "useBetaFeatures: Bool, isICloudEnabled: Bool, makoshProxySettings: Signal<ProxySettings, NoError>? = nil) {"),
            ("        self.isICloudEnabled = isICloudEnabled\n", "        self.isICloudEnabled = isICloudEnabled\n        self.makoshProxySettings = makoshProxySettings\n"),
            ("useExperimentalFeatures: useExperimentalFeatures)", "useExperimentalFeatures: useExperimentalFeatures, makoshProxySettings: arguments.makoshProxySettings)"),
            ("            mtProto.checkForProxyConnectionIssues = true\n", "            mtProto.checkForProxyConnectionIssues = arguments.makoshProxySettings == nil\n"),
            ("    public let context: MTContext\n", "    public let context: MTContext\n    public let makoshProxySettings: Signal<ProxySettings, NoError>?\n    public var makoshUsesExternalProxySettings: Bool { makoshProxySettings != nil }\n"),
            ("useBetaFeatures: Bool, useExperimentalFeatures: Bool) {", "useBetaFeatures: Bool, useExperimentalFeatures: Bool, makoshProxySettings: Signal<ProxySettings, NoError>? = nil) {"),
            ("        self.useExperimentalFeatures = useExperimentalFeatures\n", "        self.useExperimentalFeatures = useExperimentalFeatures\n        self.makoshProxySettings = makoshProxySettings\n"),
        ]
    else:
        changes = [("""        self.managedOperationsDisposable.add((accountManager.sharedData(keys: [SharedDataKeys.proxySettings])
        |> map { sharedData -> ProxyServerSettings? in
            if let settings = sharedData.entries[SharedDataKeys.proxySettings]?.get(ProxySettings.self) {
                return settings.effectiveActiveServer
            } else {
                return nil
            }
        }""", """        self.managedOperationsDisposable.add((makoshProxySettingsSource(external: network.makoshProxySettings,
            stored: accountManager.sharedData(keys: [SharedDataKeys.proxySettings])
            |> map { $0.entries[SharedDataKeys.proxySettings]?.get(ProxySettings.self) })""")]
    for before, after in changes:
        if source.count(before) != 1:
            raise RuntimeError("Unexpected reviewed proxy adaptation context")
        source = source.replace(before, after)
    if path == NETWORK:
        start = source.index("func initializedNetwork(")
        end = source.index("\n}\n", start) + 3
        body = source[start:end]
        opening = body.index("\n") + 1
        original = body[opening:-2]
        import textwrap
        wrapped = (body[:opening] + "    return makoshInitialProxySettings(stored: proxySettings, external: arguments.makoshProxySettings)\n"
                   + "    |> mapToSignal { proxySettings in\n" + textwrap.indent(original, "    ") + "    }\n}\n")
        source = source[:start] + wrapped + source[end:]
    if hashlib.sha256(source.encode()).hexdigest() != OUTPUTS[path]:
        raise RuntimeError("Unexpected reviewed proxy adaptation output")
    return source

def proxy_helper_source():
    source = '''// Own Makosh MIT bridge; linked TelegramCore remains GPL-3.0-or-later.
import Postbox
import SwiftSignalKit

public func makoshInitialProxySettings(stored: ProxySettings?, external: Signal<ProxySettings, NoError>?) -> Signal<ProxySettings?, NoError> {
    if let external { return external |> take(1) |> map { Optional($0) } }
    return .single(stored)
}
public func makoshProxySettingsSource(external: Signal<ProxySettings, NoError>?, stored: Signal<ProxySettings?, NoError>) -> Signal<ProxyServerSettings?, NoError> {
    let settings: Signal<ProxySettings?, NoError>
    if let external { settings = external |> map { Optional($0) } } else { settings = stored }
    return settings |> map { $0?.effectiveActiveServer }
}
'''
    if hashlib.sha256(source.encode()).hexdigest() != HELPER_OUTPUT:
        raise RuntimeError("Unexpected proxy source bridge fingerprint")
    return source
