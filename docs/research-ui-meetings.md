# UI / meetings source audit — 2026-10-10

## Aether Courier

Pinned `8ab37e1da22363744be5d7b019f4300d8238d625`. [MIT license](https://github.com/ic3y808/aether-courier/blob/8ab37e1da22363744be5d7b019f4300d8238d625/LICENSE); [project.yml](https://github.com/ic3y808/aether-courier/blob/8ab37e1da22363744be5d7b019f4300d8238d625/project.yml) declares macOS 26.0, Swift 6.0, local EmailKit package, generated Xcode project and hardened-runtime signing settings. Build script was read, not executed. Its networking/AI claims were not runtime verified and do not change our selected MMail functional basis.

Actual XERJ queries `NavigationSplitView RootView ReadingPaneView` and `ReadingPaneView` retrieved [RootView](https://github.com/ic3y808/aether-courier/blob/8ab37e1da22363744be5d7b019f4300d8238d625/Aether-Courier/App/RootView.swift) and [ReadingPaneView](https://github.com/ic3y808/aether-courier/blob/8ab37e1da22363744be5d7b019f4300d8238d625/Aether-Courier/Features/Reading/ReadingPaneView.swift). Current source was then read. `docs/screenshot.png` was visually inspected from the clone with an image viewer, separately from indexing. Useful ideas: sidebar/list/reading hierarchy, inspector as secondary context, violet selection emphasis, large subject/person header, compact metadata and expandable source details. These informed Makosh's original three-pane contact/dossier UI. No UI assets or source were copied.

XERJ `mk-ui-aether`: exit 3 completed-with-junk, 70 files, 923 records, 57/57 classified code files, 11 PNGs skipped. Exact skipped paths remain in `.local/aether-junk.json`; screenshots are interpreted visually, not represented as searchable source text.

## Yandex Messenger / Telemost reference

Pinned `f0a237c6016088a8e3816dde2e56c06e4a47c5eb`. [MIT license](https://github.com/Bezooom/yandex-messenger-native/blob/f0a237c6016088a8e3816dde2e56c06e4a47c5eb/LICENSE). [Cargo.toml](https://github.com/Bezooom/yandex-messenger-native/blob/f0a237c6016088a8e3816dde2e56c06e4a47c5eb/Cargo.toml) identifies a Linux GTK4/libadwaita application, optional WebKit6/soup3, GStreamer WebRTC and XDG portal dependencies. That is not a macOS SwiftUI embedding surface. No build/portability/live service claim was tested.

Actual XERJ query `TelemostClient` returned [src/api/telemost.rs](https://github.com/Bezooom/yandex-messenger-native/blob/f0a237c6016088a8e3816dde2e56c06e4a47c5eb/src/api/telemost.rs#L23); source comments explicitly identify HTTP mapping as best-effort and needing live confirmation. The client offers create/start/end/info methods against messenger endpoints; those names are not evidence of official API support. `src/api/gst_webrtc.rs` provides a Linux GStreamer backend and remains a second-stage research reference.

The official [Telemost documentation](https://yandex.ru/dev/telemost/doc/ru/) was read live: REST access is limited to Yandex 360 for Business organization-domain accounts. Makosh's first stage therefore offers only a user-supplied official HTTPS meeting URL handoff, with honest disconnected API status. No account/token/API was used. A full native WebRTC client is not included.

XERJ `mk-meetings-yandex`: exit 3 completed-with-junk, 132 files, 2,206 records, 73/73 classified code files, 10 PNGs skipped and 2 duplicate-content files detected. Exact skips remain in `.local/yandex-junk.json`. Both queries were confirmed by reading the pinned source directly.
