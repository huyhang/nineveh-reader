# Getting started

This guide builds, runs, and installs Nineveh Reader on a Mac. The app requires
macOS 15 or newer.

## 1. Install the prerequisites

Install Xcode 16 or newer from the Mac App Store or Apple Developer website.
Open it once so it can install its required components, then accept the license
when prompted.

Confirm the command-line tools are available:

```sh
xcodebuild -version
swift --version
```

The first build also needs internet access so Swift Package Manager can fetch
the pinned ZIPFoundation dependency.

## 2. Get the source

Clone the repository and enter it:

```sh
git clone <repository-url> nineveh-reader
cd nineveh-reader
```

If you already have the repository, run the remaining commands from its root—the
directory containing `NinevehReader.xcodeproj`.

## 3. Start Nineveh

Start your Nineveh server according to its own installation instructions. For
the default local configuration, verify its readiness with:

```sh
curl http://127.0.0.1:8081/api/v1/health/ready
```

A healthy instance returns JSON containing `"status": "ok"`.

You will need a Nineveh username and password. The reader supports:

- HTTP for `localhost`, `127.0.0.1`, and `::1`
- HTTPS for every other host

Plain HTTP to another computer on the network is intentionally rejected.

## 4. Configure signing

1. Open `NinevehReader.xcodeproj` in Xcode.
2. Wait for **Resolving Package Graph** to finish.
3. Select the **NinevehReader** project in the navigator.
4. Select the **NinevehReader** application target.
5. Open **Signing & Capabilities**.
6. Leave **Automatically manage signing** enabled and select your team. A free
   Personal Team is sufficient for running the app on your own Mac.
7. If Xcode reports that `com.nineveh.reader` is unavailable, replace it with a
   unique bundle identifier, such as `com.yourname.NinevehReader`.

The checked-in sandbox configuration grants only outbound networking,
user-selected file reading, and persistent app-scoped bookmarks.

## 5. Build and run

Choose **NinevehReader > My Mac** in Xcode's scheme selector, then press
**Command-R**. On first launch:

1. Leave the server set to `http://127.0.0.1:8081`, or enter your HTTPS URL.
2. Enter your Nineveh username and password.
3. Select **Sign In**.

The password is stored in macOS Keychain. It is not written to SwiftData,
UserDefaults, or logs.

If Nineveh is unavailable, choose **Browse On My Mac**. Previously downloaded
publications become available automatically after a successful sign-in and
remain readable during later outages.

## 6. Add local CBZ files

Open **On My Mac** from the sidebar, then choose one of these options:

- **Import…** copies the selected CBZ files into the app-managed library.
- **Open File…** keeps each file in its existing location and stores a
  security-scoped bookmark.
- Dragging CBZ files onto the view imports copies.

You can also open a CBZ from Finder with **Open With > Nineveh Reader**. If an
external file moves or macOS revokes access, remove it from **On My Mac** and
open it again.

## 7. Install a release build

### Build a local app from Terminal

From the repository root, run:

```sh
./Scripts/build-local.sh
```

This creates:

- `dist/Nineveh Reader.app`
- `dist/Nineveh Reader.zip`

The app receives an ad-hoc local signature with the checked-in sandbox
entitlements. To install it:

1. Open the repository's `dist` folder in Finder.
2. Drag **Nineveh Reader.app** into your Applications folder.
3. Open **Nineveh Reader** from Applications.

Because this build was created locally, it is intended for this Mac. Use a
Developer ID or App Store signature before distributing it to other people.

### Build and install with Xcode

For a development-team-signed installation:

1. Select **My Mac** as the run destination.
2. Choose **Product > Archive**.
3. When Organizer opens, select the new archive and choose **Distribute App**.
4. Choose **Copy App** for personal installation.
5. Export the app and move **Nineveh Reader.app** into your Applications folder.

For another Mac, use **Developer ID** distribution and notarization instead of
**Copy App**. For the Mac App Store, use **App Store Connect** and complete the
release items listed below.

## Command-line verification

Build the Xcode project without signing:

```sh
xcodebuild \
  -project NinevehReader.xcodeproj \
  -scheme NinevehReader \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run the shared unit tests:

```sh
cd Packages/NinevehReaderKit
swift test
```

An unsigned command-line build is useful for verification, but use Xcode's
signed archive flow for installation so the sandbox and Keychain behavior match
the shipped application.

## Troubleshooting

### Package resolution fails

In Xcode, choose **File > Packages > Reset Package Caches**, followed by
**File > Packages > Resolve Package Versions**. Also confirm that GitHub is
reachable from your network.

In a restricted shell environment, Swift Package Manager may report
`sandbox_apply: Operation not permitted`. Tests can still be run with:

```sh
swift test --disable-sandbox
```

The local build script supports the same workaround:

```sh
NINEVEH_DISABLE_SWIFT_SANDBOX=1 ./Scripts/build-local.sh
```

Use the normal Xcode application to build the signed app; do not disable macOS
system security.

### Sign-in fails

- Confirm the readiness URL from step 3 still returns `"status": "ok"`.
- Verify the username and password in Nineveh's web interface.
- Use `http://127.0.0.1:8081` only when Nineveh runs on the same Mac.
- Use a valid HTTPS certificate for a remote server. The app does not bypass
  certificate validation.

### A downloaded title opens remotely

Check **Downloads** for a completed status. Failed items expose **Retry**. A
download is used locally only after the CBZ has been completely received and
validated.

### An external CBZ no longer opens

The file may have moved or its permission may have expired. Remove its entry
from **On My Mac**, then use **Open File…** to grant access again.

## Before App Store submission

Complete these release-specific steps:

1. Replace the placeholder AppIcon contents with final artwork.
2. Set the final bundle identifier and Apple Developer team.
3. Update version, build number, copyright, and support information.
4. Test a signed Release archive on a clean macOS 15 installation.
5. Supply App Review with an HTTPS-accessible Nineveh test account or an
   appropriate demo catalog.
6. Review the privacy manifest and App Store privacy answers against the final
   product behavior.
7. Capture final screenshots and complete accessibility and localization QA.
