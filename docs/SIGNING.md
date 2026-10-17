# Sign and launch MacVolvo

## Current signing status

Version **1.1 build 9** is Developer ID signed with team `QZTVN6KK9H`.
Apple accepted the app and unpacked runtime, and then the DMG, on October 17,
2026. Both are stapled and Gatekeeper accepts them as `Notarized Developer ID`.
The app also passes the updater's notarization, team, identifier and version
checks. The signed runtime archive is unchanged from v1.0.

- App submission: `1079ef6e-21b2-49dc-a7ac-258aed40791b`.
- DMG submission: `14efd357-6e2e-464a-b6d9-da10b56a2ffb`.
- App: `runtime/build/v1.1-signed/MacVolvo.app`.
- Installer: `runtime/release/MacVolvo-1.1.dmg` (242,766,908 bytes).
- SHA-256: `81f3c800db6f28a88db285ec77286f89447fb95b06797db533fd8be6c196cf3b`.

Validation includes 137 portable tests, Swift launch-readiness/update checks
and ten synthetic DXMT display-change checkpoints. Deadlock's reported UI
misalignment remains unresolved; see [v1.1 release notes](releases/v1.1.md).
The original v1.0 and GPTK4 evaluation installers are retained.

## MacVolvo 1.0 signing record

Version 1.0 build 6 and its runtime are Developer ID signed with team
`QZTVN6KK9H`. Signature verification, all 230 bundle-file hashes, 114 portable
tests and four signing-input tests passed. The unsigned native code is identical
to the preceding candidate; this is a signing change, not a new game fix.

Apple submission: `dc249d02-8564-43ec-ad2c-82856e747036` (October 15, 2026).
Apple **accepted** the app and unpacked runtime. The app is stapled and passes
Gatekeeper as `Notarized Developer ID`. The DMG is also accepted, stapled and
Gatekeeper-verified (October 16, 2026). DMG submission:
`cb06b4c8-6bab-42a7-8924-810b9670a1fb`.

Installer: `runtime/release/MacVolvo-1.0.dmg` (242,555,182 bytes).
SHA-256: `9db10b59ea5d94fb5b259ed971e14032dbed52489a6da77c8b0bd38461003c7a`.

```sh
xcrun notarytool info dc249d02-8564-43ec-ad2c-82856e747036 \
  --keychain-profile macvolvo-notary
open runtime/build/v1.0-signed/MacVolvo.app
```

Quit the existing MacVolvo launcher before opening the notarized app above.
Finish any running game before switching runtime versions. The commands
below document how to reproduce signing, notarization and packaging.

## Launch the earlier local build

From the repository root:

```sh
open runtime/build/release/MacVolvo.app
```

That path contains version 1.0, build 5. Old v0.x app bundles were removed.
The source-built copy remains at `runtime/build/v1.0/MacVolvo.app`. The local
build does not require a Developer ID certificate to be built or launched on
this development Mac. This is distinct from distributing a notarized download.

## Get the public-distribution certificate

1. Use an Apple Developer Program membership with permission to create Developer
   ID certificates. In Xcode → Settings → Accounts, select your team, open Manage
   Certificates, and create **Developer ID Application**. Alternatively, use
   Certificates, Identifiers & Profiles in your Apple Developer account.
2. Install the certificate and its matching private key in this Mac's login
   keychain. Check it locally:

   ```sh
   security find-identity -v -p codesigning
   ```

   The result must include `Developer ID Application: Your Name (TEAMID)`.
   The existing **Apple Development** certificate is not suitable for notarizing
   a public app download. Do not share the private key or credentials in chat/git.
3. Save notarization credentials in Keychain using the interactive prompts:

   ```sh
   xcrun notarytool store-credentials macvolvo-notary
   ```

   Use your Apple ID, team ID and app-specific password, or the supported App
   Store Connect API-key option. The profile name is used by the commands below.

Apple references: [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
and [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Sign the runtime, then the launcher

The current runtime includes a locally ad-hoc-signed repair. Signing only the
outer app does not sign executables inside its embedded runtime archive.
Complete the source/dependency steps in [BUILDING.md](BUILDING.md), including
corresponding-source and license review, before public binary distribution.

Once the source-build outputs exist, assemble a new signed runtime:

```sh
export MACVOLVO_SIGN_ID='Developer ID Application: Your Name (TEAMID)'
python3 scripts/assemble_portable_runtime.py --workspace runtime/phase-2 \
  --version macvolvo-1.0-signed.1 --identity "$MACVOLVO_SIGN_ID"
```

This produces `runtime/phase-2/artifacts/macvolvo-1.0-signed.1.tar.gz` and its
manifest/proof. Update `runtimeVersion` and `runtimeSHA256` in
`app/Resources/release.json` to that archive's version and SHA-256. Keep the
archive filename field `runtime.tar.gz`; the app builder uses that embedded name.
Then build to a fresh output folder:

```sh
python3 scripts/build_native_app.py --output runtime/build/v1.0-signed/MacVolvo.app \
  --runtime-archive runtime/phase-2/artifacts/macvolvo-1.0-signed.1.tar.gz \
  --identity "$MACVOLVO_SIGN_ID"
codesign --verify --deep --strict runtime/build/v1.0-signed/MacVolvo.app
```

## Re-sign the existing qualified candidate

When preserving the already-tested runtime instead of rebuilding its dependencies,
use the signing derivation tool. It checks every manifest hash, preserves identifiers
and entitlements, leaves Apple's library intact, and verifies that removing the old
and new signatures produces identical native code. This does not replace the source
and license review required before public distribution.

```sh
python3 scripts/sign_runtime.py \
  --archive runtime/build/display-query/runtime.tar.gz \
  --output runtime/build/signed-runtime/macvolvo-1.0-signed.1 \
  --version macvolvo-1.0-signed.1 --identity "$MACVOLVO_SIGN_ID"
```

Use a fresh output path for each run. The signed candidate uses runtime
`macvolvo-1.0-signed.1` and app version 1.0, build 6. Its archive is
`runtime/build/signed-runtime/macvolvo-1.0-signed.1.tar.gz`; use that path with
`build_native_app.py --runtime-archive`. The release manifest pins its SHA-256.

## Notarize and package

```sh
mkdir -p runtime/release
# Include the unpacked runtime so Apple scans the native executables directly.
mkdir runtime/release/notary-stage-1.0
cp -Rc runtime/build/v1.0-signed/MacVolvo.app runtime/release/notary-stage-1.0/
cp -Rc runtime/build/signed-runtime/macvolvo-1.0-signed.1 \
  runtime/release/notary-stage-1.0/runtime
ditto -c -k --sequesterRsrc runtime/release/notary-stage-1.0 \
  runtime/release/MacVolvo-1.0-notary.zip
xcrun notarytool submit runtime/release/MacVolvo-1.0-notary.zip \
  --keychain-profile macvolvo-notary --wait
```

Proceed only after the submission says **Accepted**. For a rejection, use
`xcrun notarytool log SUBMISSION_ID --keychain-profile macvolvo-notary` and fix the
reported issues; do not disable signature checks.

```sh
xcrun stapler staple runtime/build/v1.0-signed/MacVolvo.app
xcrun stapler validate runtime/build/v1.0-signed/MacVolvo.app
spctl --assess --type execute --verbose=2 runtime/build/v1.0-signed/MacVolvo.app
python3 scripts/build_release_dmg.py --app runtime/build/v1.0-signed/MacVolvo.app \
  --output runtime/release/MacVolvo-1.0.dmg --identity "$MACVOLVO_SIGN_ID" \
  --notary-profile macvolvo-notary --plain
```

`--plain` avoids the optional dmgbuild dependency. Omit it after installing
`dmgbuild==1.6.5` if you want the styled Finder window. The script signs,
notarizes and staples the DMG, then writes its SHA-256 file. Upload those two
files to the existing v1.0 draft release, test on another Mac, update the
release notes' signing status and publish when ready. Launch the signed app with:

```sh
open runtime/build/v1.0-signed/MacVolvo.app
```
