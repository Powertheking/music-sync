// swift-tools-version:5.10
// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniele Mazzanti
import PackageDescription

let package = Package(
    name: "MusicSync",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MusicSync", path: "Sources/MusicSync")
    ]
)
