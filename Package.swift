// swift-tools-version: 6.0
//
// The Octoroom Swift client (iOS and macOS). The sources live in swift/;
// this file sits at the repository root so SwiftPM can depend on the repo.
import PackageDescription

let package = Package(
  name: "Octoroom",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [
    .library(name: "Octoroom", targets: ["Octoroom"]),
    .library(name: "OctoroomCore", targets: ["OctoroomCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/stasel/WebRTC.git", from: "137.0.0")
  ],
  targets: [
    // The Phoenix channel client and the room's signaling, behind a media
    // engine protocol: no WebRTC dependency, so it tests without one.
    .target(name: "OctoroomCore", path: "swift/Sources/OctoroomCore"),
    // The WebRTC media engine, capture (mic, camera, screen) and video views.
    .target(
      name: "Octoroom",
      dependencies: ["OctoroomCore", .product(name: "WebRTC", package: "WebRTC")],
      path: "swift/Sources/Octoroom"
    ),
    .testTarget(
      name: "OctoroomCoreTests",
      dependencies: ["OctoroomCore"],
      path: "swift/Tests/OctoroomCoreTests"
    ),
  ]
)
