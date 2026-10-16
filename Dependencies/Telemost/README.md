# Telemost provenance

MakoshTelemost is independently authored Swift using the official Telemost REST
and Yandex ID PKCE/user-info contracts listed in the independent lock.
Bezooom/yandex-messenger-native at f0a237c6016088a8e3816dde2e56c06e4a47c5eb,
MIT, is an approach/workflow research reference. No code, GTK/GStreamer runtime,
credentials, cookies or private API mapping from it is included.

Foundation, AuthenticationServices, Security, CryptoKit and the existing
MakoshCore/libpq dependency boundary serve this module. Research clones are
optional and not read by build/run/test. The offline verifier checks the source
selection and that the runtime has no reference/private-endpoint dependency.
See docs/telemost-migration.md for behavior and acceptance boundaries.
