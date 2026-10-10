// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Makosh",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MakoshCore", targets: ["MakoshCore"]),
        .executable(name: "Makosh", targets: ["MakoshApp"])
    ],
    targets: [
        .systemLibrary(name: "CPostgres", pkgConfig: "libpq", providers: [.brew(["libpq"])]),
        .target(name: "MakoshCore", dependencies: ["CPostgres"]),
        .executableTarget(name: "MakoshApp", dependencies: ["MakoshCore"]),
        .testTarget(name: "MakoshCoreTests", dependencies: ["MakoshCore", "CPostgres"])
    ]
)
