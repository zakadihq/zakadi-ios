# zakadi-ios

iOS SDK for Zakadi. Swift Package Manager targets `ZakadiSDK`, `ZakadiSDKUI` and the `ZakadiLottie` source adapter; XCFramework and a CocoaPods podspec in a private spec repo. Specification: `zakadi/spec/07-native-mobile-sdk.md` Part C and the SDK contract `spec/05-sdk-contract.md`.

Status: the `ZakadiSDK` package (iOS 15 and later, Swift 6 mode, dynamic library product) holds the protocol layer in `Sources/ZakadiSDK/Protocol/`, which imports only Foundation and CryptoKit: the media header codec, the probe and audio batch parsers and the `attest` hash chain of `spec/01-protocol.md` 1.3 and 1.4. Capture, transport, `ZakadiSDKUI` and `ZakadiLottie` are not written yet.

## Setup

On macOS with Xcode 26 or later (its Swift 6 toolchain includes `swift format`):

```sh
brew install lefthook swiftlint
lefthook install               # hooks: format and lint on commit; simulator build and tests on push
scripts/fetch-vectors.sh       # zakadi-protocol v0.1.0 vectors into vectors/ (gitignored), SHA-256 checked
swift build && swift test      # host build and the XCTest suite, which fails without the vectors
xcodebuild build -scheme ZakadiSDK -destination 'generic/platform=iOS Simulator'
swift format lint --strict --recursive Package.swift Sources Tests
swiftlint lint --strict
```

`.swift-format` and `.swiftlint.yml` configure the two linters. `.github/workflows/ci.yml` runs the same commands in the jobs `format`, `lint`, `unit` and `integration` (skipped until a simulator test target exists), and `lefthook run pre-commit --all-files` runs the commit hooks over the whole tree.

The tests run the `framing` and `chain` conformance vectors of `zakadi-protocol` at the tag pinned in `scripts/fetch-vectors.sh`, as `spec/05-sdk-contract.md` 5.16 requires of every release.

## Releases

A tag `v<version>` runs `.github/workflows/release.yml`: the tests, then `xcodebuild archive` for the device and the simulator with `BUILD_LIBRARY_FOR_DISTRIBUTION=YES` and `xcodebuild -create-xcframework`. `ZakadiSDK.xcframework.zip` (`ios-arm64`, `ios-arm64_x86_64-simulator`) is attached to the tag's GitHub release with the changelog section and its SwiftPM checksum. The framework is unsigned and carries no `PrivacyInfo.xcprivacy` until a signing identity exists (`spec/07-native-mobile-sdk.md` 7.28). Changes are listed in `CHANGELOG.md`.

## Licence

Zakadi SDKs and client libraries are open source under the Apache License 2.0 (see `LICENSE`; the `NOTICE` file reserves the Zakadi trademarks). They are clients for the Zakadi service, which is proprietary; using it requires an account and acceptance of the Zakadi Terms of Service. Zakadi and the Zakadi logo are trademarks and are not covered by the Apache licence.
