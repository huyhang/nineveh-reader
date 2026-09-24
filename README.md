# Nineveh Reader

Nineveh Reader is a native, content-first comic and manga reader for macOS and
iPadOS. It connects to a [Nineveh](http://127.0.0.1:8081) OPDS 2.0 library while
keeping downloaded books and local CBZ files available offline.

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
  marked on their covers and shown in Finder (on iPad, shared) from Downloads
- Automatic local-first reading for downloaded publications
- A separate **On My Mac** (or **On My iPad**) library for imported and
  external CBZ files
- Offline access to cached metadata, downloads, and local reading progress

## Requirements

- macOS 15 Sequoia or newer, or iPadOS 18 or newer
- Xcode 16 or newer with the macOS 15 SDK, plus the iOS SDK for the iPad app
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

For the iPad app, select the **NinevehReader iPad** scheme and an iPad or iPad
simulator instead. An iPad has no Nineveh of its own, so sign in with the HTTPS
address of your server.

For cloning, command-line builds, installation, signing, and troubleshooting,
see [Getting Started](docs/getting-started.md).

To produce a locally signed release bundle from Terminal:

```sh
./Scripts/build-local.sh
```

The app and a ZIP archive are written to `dist/`.

## Installing on iPad with AltStore

An app installed from Xcode with a free Apple ID stops opening after seven
days. [AltStore](https://altstore.io) (AltStore Classic, not the EU's AltStore
PAL) keeps it signed without Xcode. How long each signature lasts depends on
the Apple ID you give AltStore:

- **Apple Developer Program membership:** signatures last a year, so you only
  refresh once a year. A membership also makes Xcode installs last a year, so
  with one, AltStore is a convenience rather than a necessity.
- **Free Apple ID:** signatures still last seven days, but AltStore renews them
  in the background whenever the iPad is on the same Wi-Fi as a Mac running
  AltServer. A free Apple ID can keep three sideloaded apps active, AltStore
  included.

### Set up AltStore once

1. Install AltServer on your Mac and use it to install AltStore on the iPad,
   following [AltStore's guide](https://faq.altstore.io).
2. On the iPad, trust your Apple ID under **Settings > General > VPN & Device
   Management**, and turn on **Settings > Privacy & Security > Developer
   Mode**.
3. For background refreshes, connect the iPad to the Mac once with a cable, and
   in Finder turn on **Show this iPad when on Wi-Fi**.

### Build and install the IPA

AltStore signs the app with your Apple ID as it installs it, so build it
unsigned and package it as an IPA:

```sh
xcodebuild -project NinevehReader.xcodeproj -scheme 'NinevehReader iPad' \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build
rm -rf .build/ipa && mkdir -p .build/ipa/Payload dist
cp -R ".build/DerivedData/Build/Products/Release-iphoneos/Nineveh Reader.app" \
  .build/ipa/Payload/
(cd .build/ipa && zip -qry "../../dist/Nineveh Reader.ipa" Payload)
```

Send `dist/Nineveh Reader.ipa` to the iPad with AirDrop or iCloud Drive. Then
in AltStore, open **My Apps**, tap **+**, and choose the IPA. To update, build a
new IPA and install it the same way; AltStore replaces the app in place.

To refresh by hand, open AltStore on the same Wi-Fi as AltServer and tap
**Refresh All** in **My Apps**. If an app does expire, it stays on the iPad but
won't open until it's refreshed. If AltStore itself has expired, reinstall it
from AltServer first.

## Project structure

- `App/` contains macOS bundle metadata, sandbox entitlements, assets, and the
  privacy manifest. `App/iOS/` holds the iPad app's bundle metadata and assets;
  it shares the privacy manifest and third-party notices.
- `Packages/NinevehReaderKit/Sources/NinevehCore/` contains platform-neutral
  models and service contracts.
- `Packages/NinevehReaderKit/Sources/NinevehKit/` contains Nineveh networking,
  persistence, downloads, CBZ handling, and adaptive SwiftUI features.
- `Packages/NinevehReaderKit/Sources/NinevehReaderApp/` contains the thin
  composition entry point both apps are built from.

The shared packages target both macOS 15 and iOS 18, and both apps run the same
SwiftUI views. Where the iPad differs, the views check `#if os(iOS)` or the
`isNarrow` environment value, which is true only in a compact-width iPad
window, so the Mac layout is unchanged.

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

Build the iPad app for the simulator without signing:

```sh
xcodebuild -project NinevehReader.xcodeproj -scheme 'NinevehReader iPad' \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

CI builds the sandboxed Mac app and the iPad app, and runs the shared unit
tests on macOS.

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
App Store submission, replace the placeholder app icons and bundle identifier,
select the distribution team, and provide Apple with a review-accessible
Nineveh account or demo catalog.
