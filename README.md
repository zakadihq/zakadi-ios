# zakadi-ios

iOS SDK for Zakadi. Swift Package Manager targets `ZakadiSDK`, `ZakadiSDKUI` and the `ZakadiLottie` source adapter; XCFramework and a CocoaPods podspec in a private spec repo. Specification: `zakadi/spec/07-native-mobile-sdk.md` Part C and the SDK contract `spec/05-sdk-contract.md`.

Status: the `ZakadiSDK` package (iOS 15 and later, Swift 6 mode, dynamic library product) holds the protocol layer in `Sources/ZakadiSDK/Protocol/`, which imports only Foundation and CryptoKit: the media header codec, the probe and audio batch parsers and the `attest` hash chain of `spec/01-protocol.md` 1.3 and 1.4. Behind `@_spi(Testing)` it holds the front-camera capture pipeline and the VideoToolbox H.264 encoder of `spec/07-native-mobile-sdk.md` 7.29 and 7.30 in `Sources/ZakadiSDK/Capture/` and `Encode/`; the `ZakadiSDKTesting` library runs the phase 0 encoder probe over them, and the iPhone app in `Probe/` runs that probe on the front camera. Transport, audio, `ZakadiSDKUI` and `ZakadiLottie` are not written yet.

## Setup

On macOS with Xcode 26 or later (its Swift 6 toolchain includes `swift format`):

```sh
brew install lefthook swiftlint xcodegen
lefthook install               # hooks: format and lint on commit; simulator builds and tests on push
scripts/fetch-vectors.sh       # zakadi-protocol v0.1.0 vectors into vectors/ (gitignored), SHA-256 checked
swift build && swift test      # host build and the XCTest suite, which fails without the vectors
xcodebuild build -scheme ZakadiSDK -destination 'generic/platform=iOS Simulator'
xcodegen generate --spec Probe/project.yml --project Probe   # the probe app's project, ignored by git
xcodebuild build -project Probe/ZakadiProbe.xcodeproj -scheme ZakadiProbe -destination 'generic/platform=iOS Simulator'
swift format lint --strict --recursive Package.swift Sources Tests Probe
swiftlint lint --strict
```

`.swift-format` and `.swiftlint.yml` configure the two linters. `.github/workflows/ci.yml` runs the same commands in the jobs `format`, `lint`, `unit` and `integration` (the package's simulator test target and the probe app's unit tests on a simulator), and `lefthook run pre-commit --all-files` runs the commit hooks over the whole tree.

The tests run the `framing` and `chain` conformance vectors of `zakadi-protocol` at the tag pinned in `scripts/fetch-vectors.sh`, as `spec/05-sdk-contract.md` 5.16 requires of every release.

## iPhone probe

`Probe/` holds `ZakadiProbe`, the iPhone app of phase 0 measurement 6 (`spec/09-data-and-mlops.md` 9.11 item 6, D105): one portrait screen whose Run button drives schedule 1 of `ZakadiSDKTesting` on the front camera and writes one log in format 1 (D120) per run, in about three minutes with the screen kept on. XcodeGen writes the app's Xcode project from `Probe/project.yml`; the project is ignored by git, so it is generated again after a file is added:

```sh
brew install xcodegen && xcodegen generate --spec Probe/project.yml --project Probe
```

Then, in Xcode 27 with a signing team (a personal team signs for 7 days), run the `ZakadiProbe` scheme on the iPhone, or build and install it from the command line; `xcrun devicectl list devices` gives the udid, and the built app is under `~/Library/Developer/Xcode/DerivedData/ZakadiProbe-*/Build/Products/Debug-iphoneos/`:

```sh
xcodebuild -project Probe/ZakadiProbe.xcodeproj -scheme ZakadiProbe -destination 'platform=iOS,id=<udid>' -allowProvisioningUpdates DEVELOPMENT_TEAM=<team> build
xcrun devicectl device install app --device <udid> <the built ZakadiProbe.app>
```

Tap Run with the phone upright. The log lands in the app's `Documents/zakadi-probe/` as `probe-<unix ms>.jsonl`, which the Files app shows under On My iPhone, the share sheet sends when the run ends, and this command copies:

```sh
xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier dev.zakadi.ZakadiProbe --source Documents/zakadi-probe --destination probe-logs
```

Without a front camera, as on the simulator, a run logs `front_camera` false and ends `unsupported_device`; a refused camera permission runs nothing.

## Releases

A tag `v<version>` runs `.github/workflows/release.yml`: the tests, then `xcodebuild archive` for the device and the simulator with `BUILD_LIBRARY_FOR_DISTRIBUTION=YES` and `xcodebuild -create-xcframework`. `ZakadiSDK.xcframework.zip` (`ios-arm64`, `ios-arm64_x86_64-simulator`) is attached to the tag's GitHub release with the changelog section and its SwiftPM checksum. The framework is unsigned and carries no `PrivacyInfo.xcprivacy` until a signing identity exists (`spec/07-native-mobile-sdk.md` 7.28). Changes are listed in `CHANGELOG.md`.

## Licence

Zakadi SDKs and client libraries are open source under the Apache License 2.0 (see `LICENSE`; the `NOTICE` file reserves the Zakadi trademarks). They are clients for the Zakadi service, which is proprietary; using it requires an account and acceptance of the Zakadi Terms of Service. Zakadi and the Zakadi logo are trademarks and are not covered by the Apache licence.
