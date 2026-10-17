// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Facet",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Facet",
            path: "Sources/Facet",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
