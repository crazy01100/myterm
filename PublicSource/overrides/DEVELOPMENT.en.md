# Building and Maintaining Your Own MyTerm

[繁體中文](DEVELOPMENT.md) | **English**

This project publishes source code, required assets, and documentation only. It provides no app downloads, hosted Firebase backend, or update service. MyTerm reflects the maintainer's personal workflow; adapt it, build it, and decide whether you want to operate your own distribution and update service.

<a id="build-tools"></a>
## Build prerequisites

You need Apple Silicon, macOS 26, Xcode 26/compatible Command Line Tools (Swift 6.2), Git, Python 3, and ripgrep (`rg`). If Apple development tools are missing, run `xcode-select --install` and complete the system prompts. With Xcode already installed, ensure the selected toolchain provides Swift 6.2. Check `swift --version`, `git --version`, `python3 --version`, and `rg --version`. Install missing ripgrep through your preferred package manager (existing Homebrew users can run `brew install ripgrep`).

The first build downloads Swift dependencies. A basic local build needs neither Node.js nor Firebase. Cloud configuration tools additionally need jq; Firestore Rules tests need Node.js 24 and the repository's npm dependencies.

## Build MyTerm.app for everyday use

Follow the [README build steps](README.en.md#building-from-source) to test, run `build-app.sh --channel candidate`, and verify with `verify-app.sh`. This produces a Release-optimized app with the regular MyTerm name and data identity. Building and verification do not launch, install, upload, or create an update service.

Existing scripts use `candidate` for the app's output location before installation: `build/candidates/MyTerm-<version>-build-<build>/MyTerm.app`. That directory name does not restrict the app to development or guarantee release acceptance of its source. The README's `1.0.21` is a version-label example; changing `--version` does not select Git source. Record the source commit you use. Each Build is a new, increasing positive integer, even when retaining the same version label.

Personal use needs neither `prepare-release-build.sh` nor `release.sh`. The former tests, builds, and packages a candidate with a pinned signing identity; the latter prepares distribution with your own update service. Personal builds use existing `build-app.sh` capabilities and do not remove distribution signing requirements.

<a id="install-and-data"></a>
## Installation and existing data

- First installation: after a successful build and verification, copy `MyTerm.app` in Finder into `/Applications`. If you cannot write there, use your own `~/Applications`. Open it from that location afterward; you do not need to revisit the source directory or rebuild each time.
- Existing MyTerm: check its source, version, Build, and data purpose first. Finish connection work and quit it before deciding to replace it. Do not run two apps with the same data identity together; choose Dev for separate testing. These instructions do not overwrite installations automatically.
- Regular builds use Bundle ID `tw.local.MySSHClient`, `~/Library/Application Support/MySSHClient/`, and the `tw.local.MySSHClient.local-secret-vault-root` Keychain root-key item. They may read existing regular MyTerm data on this Mac. Renaming or moving the app does not isolate data.
- Dev uses `tw.local.MySSHClient.Development`, `~/Library/Application Support/MyTerm Development/`, and a development Keychain service. Hosts, passwords, sign-in, and settings do not migrate automatically between Dev and regular builds. Use supported app import/export or your own sync service after checking what each transfers; do not directly copy vault files. Host exports contain no passwords; see [data boundaries](SECURITY.en.md).
- You can copy the complete app bundle to another compatible Mac, subject to that Mac's opening permissions and signature checks. The app does not depend on its source directory, but copying the app or data folder cannot transfer its device-local vault root key.

<a id="manual-update"></a>
## Manually update your everyday build

Keep your source directory for later updates. First run this inside it:

```sh
git pull --ff-only
```

Only after success, repeat the full README build/verification block. Resolve your source changes or a failed pull first; do not force-reset changes or delete configuration to fix it. `git pull` does not update the installed app.

After verifying the new app, quit the old one, replace it at the same installation location, and reopen it. Check the version/Build in About. Replacing the app does not require deleting Application Support, Keychain items, sync data, or `Config/Local/`; preserve these and your signing identity. Matching app identities reuse data locations, but check new source for migration or compatibility limitations. Vault ciphertext needs its device root key; a host export is not a password backup.

Clean source has no `SUFeedURL` by default and receives no updates from a default service. A public key alone does not start the updater either. Preserve your own sync or update configuration on each rebuild; do not simply copy files out of a previously built app.

<a id="local-signing"></a>
## Signing for personal use

Without a configured local code-signing identity, `build-app.sh` uses ad-hoc signing. Building requires no paid developer account, but this is not Developer ID signing or Apple notarization. macOS may require opening approval; Keychain may request authorization after rebuilding or changing signatures. A prompt-free upgrade is not guaranteed. Do not delete the vault root key or disable system protections to resolve prompts.

For ongoing maintenance, use your own stable code-signing identity via `MYTERM_CODE_SIGN_IDENTITY` or `Config/Local/CodeSigningIdentity.txt`. Keep its certificate/private key in your Keychain with secure backups. Stable signing helps retain identity but does not imply notarization. Full distribution signing and update requirements are covered under “Independent distribution” below.

## MyTerm Dev for development and testing

Run this in the source directory:

```sh
./scripts/run-dev-app.sh \
  --version 1.0.22-dev.1 \
  --build "$(date '+%Y%m%d%H%M%S')"
```

This builds, verifies, and launches the isolated `build/dev/MyTerm Dev.app`. Add `--build-only` to build without launching. Versions are examples. The script terminates only processes at this checkout's fixed Dev path, never `/Applications/MyTerm.app`; other nonstandard MyTerm processes block it. If your regular app is installed in `~/Applications`, quit it yourself before using the development entry point. Verify the actual path, version, Build, Bundle ID, signature, and development channel after each launch.

Dev also uses Release optimization; its name and data isolation are the distinction. A verified Dev build transferred to another Mac may run from a stable writable location such as `~/Applications/MyTerm Dev.app`; it does not depend on the primary checkout's path.

## Your own sync backend

Local features need no account. Google sign-in and sync require your own Firebase/Google OAuth project following [Firebase setup](FIREBASE_SETUP.en.md). Real settings belong only in Git-ignored `Config/Local/`. Hosts, groups, passwords, and finalized Logs are encrypted on the Mac before syncing; private-key paths and known_hosts do not sync.

## Optional: your own in-app updates

The update source is selected at build time, not in the app's Settings UI. Use your own HTTPS appcast and Sparkle Ed25519 public key, matching the signed archives you publish.

```sh
export MYTERM_SPARKLE_FEED_URL="https://updates.example.org/appcast.xml"
export MYTERM_SPARKLE_PUBLIC_KEY="YOUR_BASE64_ED25519_PUBLIC_KEY"
```

After setting these in the same Terminal, rerun the README everyday-build block or the Dev command above. A URL and public key alone do not provide updates; you also need the signed assets and service described below. Replace the examples. The verification key must be a Base64-encoded 32-byte Ed25519 public key. `build-app.sh` also accepts `--sparkle-feed-url`/`--sparkle-public-key`. Verification prioritizes `MYTERM_SPARKLE_PUBLIC_KEY` when set, otherwise checking your generated `Config/Release/SparklePublicKey.txt` if present. Build entry points retain channel/path isolation and do not directly overwrite production apps.

## Optional: independent distribution

Before distributing to others, give your build a distinct app/data identity to avoid sharing data with other MyTerm builds. Review the Bundle ID in `Resources/Info.plist` and the development Bundle ID, Application Support, and Keychain service settings in `build-app.sh`/`verify-app.sh`; update corresponding checks when changing identity. Personal regular builds and Dev have different identities, but multiple regular derivative distributions are not guaranteed to coexist unchanged.

You need your own stable code-signing identity, Sparkle private key, and HTTPS host. Keep private keys in your Keychain with secure backups, never in the repository. Once you have a signing identity, run `stage-code-signing-baseline.sh --identity <IDENTITY>` to stage its local baseline; `create-sparkle-signing-key.sh` creates your Sparkle public key. Build dependencies before generating keys. These tools may access Keychain or create keys; use them deliberately.

No signing baseline ships with the source. `Config/Release/` is Git-ignored here and holds your locally generated public key and code-signing baseline. Sparkle tools default to the `MyTerm.Source.Release.ed25519` account, or an explicit `MYTERM_SPARKLE_KEY_ACCOUNT`. Generation, signing, and verification must all use the same account.

To use the optional release tools, explicitly supply your update base URL:

```sh
export MYTERM_UPDATE_BASE_URL="https://updates.example.org"
export MYTERM_SPARKLE_KEY_ACCOUNT="MyTerm.Source.Release.ed25519"
./scripts/release.sh \
  --version 1.0.22 \
  --build "$(date '+%Y%m%d%H%M%S')" \
  --notes /path/to/your-release-notes.md \
  --prepare-only
```

Replace the examples. `--prepare-only` does not upload. Tools require a clean main matching origin/main, your own usable signing baseline, and passing full tests. Missing or invalid HTTPS configuration stops the workflow; no maintainer service is assumed. `release.sh` derives `/appcast.xml` from the base URL and uses `/downloads/` for ZIPs. Asset generation and verification share `MYTERM_UPDATE_BASE_URL`. Apps configured for your updates must use that same feed and public key.

Removing `--prepare-only` creates a GitHub Draft Release in the project identified by the current origin. Do this only when intentionally distributing from your own fork. This source project remains source-only. Distributors review and publish their ZIP, appcast, release notes, CHECKSUMS, and manifest, keeping versions, Builds, hashes, and signatures consistent.

`prepare-pages-deployment.sh` prepares static content from your signed assets. `verify-public-update-site.sh` uses `MYTERM_UPDATE_BASE_URL` or an explicit `--base-url`. No automatic deployment workflow or cloud credentials are supplied. Deploy to your own Cloudflare Pages or compatible HTTPS service; see [update-site notes](update-site/README.en.md).

## Tests, resources, and cleanup

- `run-tests.sh` covers core, OAuth, crypto/sync, sign-in recovery, and real terminal renderer tests. `run-crypto-tests.sh` and `run-sync-reliability-tests.sh` can run independently.
- Firestore Rules tests use `npm install` followed by `npm run test:firestore-rules`, against Firebase Emulator rather than production cloud data.
- SwiftTerm is pinned in `Vendor/SwiftTerm`. See [UPSTREAM.md](Vendor/SwiftTerm/UPSTREAM.md) for the two renderer hooks and upgrade checks. Preserve the MIT license; upgrades require source comparison, full tests, a clean build, and app interaction checks.
- Use `verify-app.sh`, `verify-packaged-resources.sh`, and `package-app.sh` for app/package verification. Tests do not replace manual dragging, focus, scrolling, splitting, and real-connection acceptance.
- Build directories, SwiftPM caches, and ZIPs are reproducible. Before cleanup, check for running processes and assets still under review or used by a release. Do not remove user data, Keychain items, Config/Local, or signing/recovery material.

## Documentation and maintenance

| Document | Traditional Chinese | English |
|---|---|---|
| Introduction | [README.md](README.md) | [README.en.md](README.en.md) |
| Architecture | [ARCHITECTURE.md](ARCHITECTURE.md) | [ARCHITECTURE.en.md](ARCHITECTURE.en.md) |
| Development | [DEVELOPMENT.md](DEVELOPMENT.md) | [DEVELOPMENT.en.md](DEVELOPMENT.en.md) |
| Security | [SECURITY.md](SECURITY.md) | [SECURITY.en.md](SECURITY.en.md) |
| Firebase | [FIREBASE_SETUP.md](FIREBASE_SETUP.md) | [FIREBASE_SETUP.en.md](FIREBASE_SETUP.en.md) |
| Termius | [TERMIUS_MIGRATION.md](TERMIUS_MIGRATION.md) | [TERMIUS_MIGRATION.en.md](TERMIUS_MIGRATION.en.md) |
| Update site | [README.md](update-site/README.md) | [README.en.md](update-site/README.en.md) |
| UpdateLab | [Chinese fixture](Resources/UpdateLab/1.0.0-beta.2.md) | [English companion](Resources/UpdateLab/1.0.0-beta.2.en.md) |
| Security maintenance | [SECURITY_MAINTENANCE.md](SECURITY_MAINTENANCE.md) | [SECURITY_MAINTENANCE.en.md](SECURITY_MAINTENANCE.en.md) |

Prepare a plan and acceptance cases before changes and obtain maintainer approval. Review each language at the end of the plan, recording whether an update is needed, why, and what was done. Update affected translations and links before closing. Translation does not change the original UpdateLab fixture's script references; preserve upstream licenses and original English notices. The app interface remains primarily Traditional Chinese.

Original code and documentation use the [MIT License](LICENSE); third-party assets retain their terms, including [OpenAI brand assets](Resources/Readme/NOTICE.md). Preserve attribution and original-author notices; development-tool attribution is not an official endorsement.

Dependency alerts, isolated tests and public-key deployment verification: [Security maintenance](SECURITY_MAINTENANCE.en.md).
