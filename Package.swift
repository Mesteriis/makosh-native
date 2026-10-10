// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Makosh",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MakoshCore", targets: ["MakoshCore"]),
        .library(name: "MakoshTelegram", targets: ["MakoshTelegram"]),
        .executable(name: "Makosh", targets: ["MakoshApp"])
    ],
    dependencies: [
        .package(name: "TelegramCore", path: ".local/telegram-engine/submodules/TelegramCore"),
        .package(name: "OpenSSLEncryption", path: ".local/telegram-engine/submodules/OpenSSLEncryptionProvider"),
        .package(name: "SSignalKit", path: ".local/telegram-engine/submodules/SSignalKit"),
        .package(name: "Postbox", path: ".local/telegram-engine/submodules/Postbox"),
        .package(name: "TelegramApi", path: ".local/telegram-engine/submodules/TelegramApi"),
        .package(name: "EncryptionProvider", path: ".local/telegram-engine/submodules/EncryptionProvider")
    ],
    targets: [
        .systemLibrary(name: "CPostgres", pkgConfig: "libpq", providers: [.brew(["libpq"])]),
        .target(name: "MakoshCore", dependencies: ["CPostgres"]),
        .target(name: "MakoshTelegram", dependencies: [
            .product(name: "TelegramCore", package: "TelegramCore"),
            .product(name: "OpenSSLEncryption", package: "OpenSSLEncryption"),
            .product(name: "SwiftSignalKit", package: "SSignalKit"),
            .product(name: "Postbox", package: "Postbox")
        ]),
        .executableTarget(name: "MakoshApp", dependencies: ["MakoshCore", "MakoshTelegram"]),
        .testTarget(name: "MakoshCoreTests", dependencies: ["MakoshCore", "CPostgres"]),
        .testTarget(name: "MakoshTelegramTests", dependencies: ["MakoshTelegram",
            .product(name: "TelegramCore", package: "TelegramCore"),
            .product(name: "TelegramApi", package: "TelegramApi"),
            .product(name: "OpenSSLEncryption", package: "OpenSSLEncryption"),
            .product(name: "EncryptionProvider", package: "EncryptionProvider")])
    ]
)
