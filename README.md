# Flowdeck SDK

iOS SDK (Swift Package) for Flowdeck: paywalls and onboarding flows that are
edited from the web dashboard and delivered remotely to apps.

Related repos: [flowdeck-dashboard](https://github.com/tuhage/flowdeck-dashboard),
[flowdeck-server](https://github.com/tuhage/flowdeck-server).

> Status: skeleton only — no product features yet.

## Requirements

- iOS 16+ (macOS 13+ only so the package builds and tests on the host)
- Swift 6 toolchain

## Install

Add the package in Xcode or `Package.swift`:

```swift
.package(url: "https://github.com/tuhage/flowdeck-sdk.git", branch: "main")
```

and depend on the `Flowdeck` product.

## Develop

```bash
swift build
swift test
```
