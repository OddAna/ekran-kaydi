// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "EkranKaydi",
    defaultLocalization: "tr",
    platforms: [
        // En düşük hedef: macOS 12 Monterey (Xcode 27 SDK'sının izin verdiği en düşük sürüm).
        // Sistem sesi ScreenCaptureKit ile macOS 13+; macOS 12'de yalnız görüntü (+ mikrofon) (README › Desteklenen macOS).
        .macOS(.v12),
    ],
    products: [
        .executable(name: "EkranKaydi", targets: ["EkranKaydi"]),
    ],
    targets: [
        .target(
            name: "EkranKaydiCore",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                // macOS 12.3 öncesinde ScreenCaptureKit yok: zayıf bağlanır ki uygulama eski sürümde de açılsın.
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "ScreenCaptureKit"]),
            ]
        ),
        .executableTarget(
            name: "EkranKaydi",
            dependencies: ["EkranKaydiCore"]
        ),
        .testTarget(
            name: "EkranKaydiCoreTests",
            dependencies: ["EkranKaydiCore"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
