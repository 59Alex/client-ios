// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ConnectKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ConnectCore", targets: ["ConnectCore"]),
        .library(name: "ConnectNetworking", targets: ["ConnectNetworking"]),
        .library(name: "ConnectAuth", targets: ["ConnectAuth"]),
        .library(name: "ConnectFeatures", targets: ["ConnectFeatures"]),
        .library(name: "ConnectCalls", targets: ["ConnectCalls"]),
        .library(name: "ConnectChat", targets: ["ConnectChat"]),
        .library(name: "ConnectFiles", targets: ["ConnectFiles"]),
        .library(name: "ConnectInbox", targets: ["ConnectInbox"]),
        .library(name: "ConnectRooms", targets: ["ConnectRooms"]),
        .library(name: "ConnectTestSupport", targets: ["ConnectTestSupport"]),
    ],
    targets: [
        .target(name: "ConnectCore"),
        .target(name: "ConnectNetworking", dependencies: ["ConnectCore"]),
        .target(name: "ConnectAuth", dependencies: ["ConnectCore", "ConnectNetworking"]),
        .target(name: "ConnectFeatures", dependencies: ["ConnectCore", "ConnectNetworking", "ConnectAuth"]),
        .target(name: "ConnectCalls", dependencies: ["ConnectCore", "ConnectNetworking"]),
        .target(name: "ConnectFiles", dependencies: ["ConnectNetworking"]),
        .target(name: "ConnectInbox", dependencies: ["ConnectNetworking"]),
        .target(name: "ConnectRooms", dependencies: ["ConnectCore", "ConnectNetworking", "ConnectChat"]),
        .target(name: "ConnectChat", dependencies: ["ConnectCore", "ConnectNetworking", "ConnectCalls", "ConnectFiles"]),
        .target(name: "ConnectTestSupport", dependencies: ["ConnectCore", "ConnectNetworking", "ConnectCalls", "ConnectChat", "ConnectFiles", "ConnectFeatures", "ConnectInbox", "ConnectRooms"]),
        .testTarget(name: "ConnectNetworkingTests", dependencies: ["ConnectNetworking", "ConnectTestSupport"]),
        .testTarget(name: "ConnectAuthTests", dependencies: ["ConnectAuth", "ConnectNetworking", "ConnectTestSupport"]),
        .testTarget(name: "ConnectFeaturesTests", dependencies: ["ConnectFeatures", "ConnectAuth", "ConnectNetworking", "ConnectTestSupport"]),
        .testTarget(name: "ConnectChatTests", dependencies: ["ConnectChat", "ConnectCalls", "ConnectNetworking", "ConnectTestSupport", "ConnectFiles"]),
        .testTarget(name: "ConnectInboxTests", dependencies: ["ConnectInbox", "ConnectNetworking", "ConnectTestSupport"]),
        .testTarget(name: "ConnectRoomsTests", dependencies: ["ConnectRooms", "ConnectChat", "ConnectNetworking", "ConnectTestSupport"]),
        .testTarget(name: "ConnectFilesTests", dependencies: ["ConnectFiles", "ConnectNetworking", "ConnectTestSupport"]),
        .testTarget(name: "ConnectCallsTests", dependencies: ["ConnectCalls", "ConnectCore", "ConnectNetworking", "ConnectTestSupport"]),
    ]
)
