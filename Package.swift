// swift-tools-version: 6.2
import PackageDescription
import Foundation

let callLibraryDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent(".local/telegram-voip/build").path

let package = Package(
    name: "Makosh",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MakoshCore", targets: ["MakoshCore"]),
        .library(name: "MakoshTelegram", targets: ["MakoshTelegram"]),
        .executable(name: "Makosh", targets: ["MakoshApp"])
    ],
    dependencies: [
        .package(name: "MakoshOpus", path: ".local/voice-codec"),
        .package(name: "MakoshOpusFile", path: ".local/opusfile-codec"),
        .package(name: "MakoshMozjpeg", path: ".local/jpeg-codec"),
        .package(name: "MakoshPrisma", path: ".local/code-highlight-engine"),
        .package(name: "MakoshRLottie", path: ".local/rlottie-codec"),
        .package(name: "MakoshVPX", path: ".local/vpx-codec"),
        .package(name: "TelegramCore", path: ".local/telegram-engine/submodules/TelegramCore"),
        .package(name: "OpenSSLEncryption", path: ".local/telegram-engine/submodules/OpenSSLEncryptionProvider"),
        .package(name: "SSignalKit", path: ".local/telegram-engine/submodules/SSignalKit"),
        .package(name: "Postbox", path: ".local/telegram-engine/submodules/Postbox"),
        .package(name: "TelegramApi", path: ".local/telegram-engine/submodules/TelegramApi"),
        .package(name: "MtProtoKit", path: ".local/telegram-engine/submodules/MtProtoKit"),
        .package(name: "EncryptionProvider", path: ".local/telegram-engine/submodules/EncryptionProvider")
    ],
    targets: [
        .systemLibrary(name: "CPostgres", pkgConfig: "libpq", providers: [.brew(["libpq"])]),
        .target(name: "CMakoshTelegramVoIP", linkerSettings: [
            .unsafeFlags(["-L" + callLibraryDirectory, "-Xlinker", "-rpath", "-Xlinker", callLibraryDirectory,
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            .linkedLibrary("MakoshTelegramVoIP")]),
        .target(name: "MakoshCore", dependencies: ["CPostgres"]),
        .target(name: "MakoshOpusControl", dependencies: [.product(name: "COpus", package: "MakoshOpus")]),
        .target(name: "MakoshJPEGControl", dependencies: [.product(name: "CMozjpeg", package: "MakoshMozjpeg")]),
        .target(name: "MakoshCodeHighlight", dependencies: [.product(name: "CPrismaEngine", package: "MakoshPrisma")]),
        .target(name: "MakoshCustomEmojiControl", dependencies: [.product(name: "CRLottie", package: "MakoshRLottie"),
            .product(name: "CVPX", package: "MakoshVPX")]),
        .target(name: "MakoshTelegram", dependencies: ["MakoshCore", "CMakoshTelegramVoIP",
            .product(name: "TelegramApi", package: "TelegramApi"),
            .product(name: "MtProtoKit", package: "MtProtoKit"),
            "MakoshJPEGControl",
            "MakoshCodeHighlight",
            "MakoshCustomEmojiControl",
            "MakoshOpusControl", .product(name: "COpus", package: "MakoshOpus"),
            .product(name: "COgg", package: "MakoshOpusFile"),
            .product(name: "COpusFile", package: "MakoshOpusFile"),
            .product(name: "TelegramCore", package: "TelegramCore"),
            .product(name: "OpenSSLEncryption", package: "OpenSSLEncryption"),
            .product(name: "SwiftSignalKit", package: "SSignalKit"),
            .product(name: "Postbox", package: "Postbox")
        ]),
        .executableTarget(name: "MakoshApp", dependencies: ["MakoshCore", "MakoshTelegram"]),
        .testTarget(name: "MakoshCoreTests", dependencies: ["MakoshCore", "CPostgres"]),
        .target(name: "MakoshJPEGFaultFixture", dependencies: [.product(name: "CMozjpeg", package: "MakoshMozjpeg")],
            path: "Tests/MakoshJPEGFaultFixture",
            cSettings: [.headerSearchPath("../../Sources/MakoshJPEGControl/include")]),
        .testTarget(name: "MakoshTelegramTests", dependencies: ["MakoshApp", "MakoshTelegram", "MakoshCore", "CPostgres", "MakoshJPEGControl", "MakoshJPEGFaultFixture", "MakoshCodeHighlight", "MakoshCustomEmojiControl",
            .product(name: "COpus", package: "MakoshOpus"),
            .product(name: "Postbox", package: "Postbox"),
            .product(name: "TelegramCore", package: "TelegramCore"),
            .product(name: "TelegramApi", package: "TelegramApi"),
            .product(name: "MtProtoKit", package: "MtProtoKit"),
            .product(name: "OpenSSLEncryption", package: "OpenSSLEncryption"),
            .product(name: "EncryptionProvider", package: "EncryptionProvider")])
    ],
    cxxLanguageStandard: .cxx17
)
