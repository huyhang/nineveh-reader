# Nineveh Reader

Nineveh Reader is a native, content-first comic and manga reader for macOS. It
connects to a [Nineveh](http://127.0.0.1:8081) OPDS 2.0 library while keeping
downloaded books and local CBZ files available offline.

## Features

- Secure Nineveh sign-in with credentials stored in Keychain
- Library search and comics, manga, series, and publication browsing
- Author browsing credited from Nineveh series metadata (writers and artists)
- Refresh Metadata (⇧⌘R, or per series) to pick up metadata edited on the server, including how downloaded volumes pair their spreads
- Per-server library toggles in Settings to hide whole libraries from the app
- Single-page, two-page, and continuous-scroll reading
- Automatic manga right-to-left navigation with per-title overrides
- Reading-progress persistence and synchronization
- Individual and whole-series downloads with progress and retry support,
  marked on their covers and shown in Finder from Downloads
- Automatic local-first reading for downloaded publications
- A separate **On My Mac** library for imported and external CBZ files
- Offline access to cached metadata, downloads, and local reading progress

## Requirements

- macOS 15 Sequoia or newer
- Xcode 16 or newer with the macOS 15 SDK
- A running Nineveh server and reader account for online features
- Internet access during the first build to download ZIPFoundation

Nineveh Reader accepts HTTP only for loopback hosts such as
`127.0.0.1`. All remote servers must use HTTPS.

## Quick start

1. Start Nineveh and verify that `http://127.0.0.1:8081` is reachable.
2. Open `NinevehReader.xcodeproj` in Xcode.
3. Select the **NinevehReader** scheme and **My Mac** destination.
4. Choose your development team under **Signing & Capabilities**.
5. Press **Command-R**.
6. Sign in with the server URL and your Nineveh credentials.

For cloning, command-line builds, installation, signing, and troubleshooting,
see [Getting Started](docs/getting-started.md).

To produce a locally signed release bundle from Terminal:

```sh
./Scripts/build-local.sh
```

The app and a ZIP archive are written to `dist/`.

## Project structure

- `App/` contains macOS bundle metadata, sandbox entitlements, assets, and the
  privacy manifest.
- `Packages/NinevehReaderKit/Sources/NinevehCore/` contains platform-neutral
  models and service contracts.
- `Packages/NinevehReaderKit/Sources/NinevehKit/` contains Nineveh networking,
  persistence, downloads, CBZ handling, and adaptive SwiftUI features.
- `Packages/NinevehReaderKit/Sources/NinevehReaderApp/` contains the thin
  macOS composition entry point.

The shared packages target both macOS 15 and iOS 18. A future universal
iPhone/iPad target can reuse them without importing AppKit into shared code.

## Development

Open `NinevehReader.xcodeproj`, select the `NinevehReader` scheme, and run.
The default sign-in URL is `http://127.0.0.1:8081`. Non-loopback connections
must use HTTPS.

Run shared unit tests from the package directory:

```sh
cd Packages/NinevehReaderKit
swift test
```

Build the complete application entry point with Swift Package Manager:

```sh
cd Packages/NinevehReaderKit
swift build --product NinevehReaderApp
```

CI builds the sandboxed Xcode app and runs the shared unit tests on macOS.

## API contract

`Packages/NinevehReaderKit/Contract/` holds the part of Nineveh's API this app
uses, `app-openapi.json`, copied from a Nineveh checkout along with a `SOURCE`
file that records the commit it came from. The `responses/` directory holds
responses captured from a running server. The contract tests check that every
request the client builds is published, that the image widths it asks for are
the ones the server renders, and that the decoders read the captured
responses. The client keeps its own hand-written, forgiving decoders; nothing
is generated.

After Nineveh's app contract changes, copy it again from a checkout beside this
repository, or from the one `NINEVEH_CHECKOUT` names:

```sh
Scripts/sync-api-contract.sh
```

When a checkout is present, a test fails until the copy matches it. CI has no
checkout, so it skips that test.

To capture fresh responses, run this against a server with at least one series
and one volume. The script only sends GET requests:

```sh
NINEVEH_USER=admin NINEVEH_PASSWORD=… Scripts/capture-api-fixtures.py
```

## Distribution status

The repository includes App Sandbox entitlements, a privacy manifest,
versioned persistence, release settings, and third-party notices. Before an
App Store submission, replace the placeholder app icon and bundle identifier,
select the distribution team, and provide Apple with a review-accessible
Nineveh account or demo catalog.
