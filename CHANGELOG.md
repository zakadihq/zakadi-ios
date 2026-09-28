# Changelog

All notable changes to this package are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The `ZakadiSDK` Swift package for iOS 15 and later in Swift 6 mode, built as a
  dynamic framework and released as `ZakadiSDK.xcframework` (`ios-arm64`,
  `ios-arm64_x86_64-simulator`) attached to each tag's GitHub release.
- The `zakadi.v1` media framing codec (header, probe and audio batch payloads) and the
  `attest` hash chain, checked against the `zakadi-protocol` v0.1.0 conformance vectors.
- The front-camera capture pipeline and the VideoToolbox H.264 encoder, behind
  `@_spi(Testing)`: 420v capture with the pacer and decimation, rung 3 and 4 scaling,
  Constrained Baseline with the Baseline fallback, Annex-B output, keyframe, bitrate and
  size changes, and the front camera and encoder checks of the capability probe.
- The `ZakadiSDKTesting` library for tests and the phase 0 encoder probe: log format 1,
  schedule 1 and its summaries, a probe runner over any frame source and a synthetic
  source. It is never part of a release app.
- `ZakadiProbe`, the iPhone app in `Probe/` that runs the phase 0 encoder probe: schedule 1
  on the front camera, one log in format 1 per run in `Documents/zakadi-probe/`, offered in
  the share sheet. XcodeGen generates its project from `Probe/project.yml`; CI builds it and
  runs its tests on the simulator. It is not part of the package or its release.

[Unreleased]: https://github.com/zakadihq/zakadi-ios/commits/main
