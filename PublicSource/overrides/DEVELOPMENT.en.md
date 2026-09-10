# Building and Maintaining Your Own MyTerm

[繁體中文](DEVELOPMENT.md) | **English**

This project publishes source code, required assets, and documentation only. It provides no app downloads, hosted Firebase backend, or update service. MyTerm reflects the maintainer's personal workflow; adapt it, build it, and decide whether you want to operate your own distribution and update service.

## Local build

You need Apple Silicon, macOS 26, Xcode 26/compatible Command Line Tools (Swift 6.2), Git, and ripgrep. Cloud configuration tools also require jq; Firestore Rules tests require Node.js 24 and the repository's npm dependencies.

```sh
git clone https://github.com/crazy01100/myterm-source.git
cd myterm-source
./scripts/run-tests.sh
./scripts/run-dev-app.sh \
  --version 1.0.22-dev.1 \
  --build "$(date '+%Y%m%d%H%M%S')" \
  --build-only
```

Versions are examples; adjust them to your own target. Remove `--build-only` to launch through the same safe entry point. After every launch, verify actual path, version, Build, Bundle ID, signature, and development channel. The script terminates only processes at this checkout's fixed `build/dev/MyTerm Dev.app` path, never `/Applications/MyTerm.app`. Other nonstandard MyTerm processes block the operation.

The default is MyTerm Dev with separate Bundle ID, Application Support, and vault service. Without a local signing identity, it uses ad-hoc code signing. No maintainer certificate, cloud configuration, or update public key is needed. A verified build sent to another Mac may run from a stable writable location such as `~/Applications/MyTerm Dev.app`; it does not depend on the checkout's absolute path. Still verify the actual app identity on that Mac.

## Updating your build

The simplest update is to fetch source changes and rebuild:

```sh
git pull --ff-only
./scripts/run-tests.sh
./scripts/run-dev-app.sh \
  --version 1.0.22-dev.2 \
  --build "$(date '+%Y%m%d%H%M%S')"
```

Resolve any merges with your own changes first. The default build has no `SUFeedURL` and contacts no default update service. A public key alone, without a feed URL, does not start the updater either.

## Your own sync backend

Local features need no account. Google sign-in and sync require your own Firebase/Google OAuth project following [Firebase setup](FIREBASE_SETUP.en.md). Real settings belong only in Git-ignored `Config/Local/`. Hosts, groups, passwords, and finalized Logs are encrypted on the Mac before syncing; private-key paths and known_hosts do not sync.

## Optional: your own in-app updates

The update source is selected at build time, not in the app's Settings UI. Use your own HTTPS appcast and Sparkle Ed25519 public key, matching the signed archives you publish.

```sh
export MYTERM_SPARKLE_FEED_URL="https://updates.example.org/appcast.xml"
export MYTERM_SPARKLE_PUBLIC_KEY="YOUR_BASE64_ED25519_PUBLIC_KEY"
./scripts/run-dev-app.sh \
  --version 1.0.22-dev.1 \
  --build "$(date '+%Y%m%d%H%M%S')" \
  --build-only
```

Replace the examples. The verification key must be a Base64-encoded 32-byte Ed25519 public key. `build-app.sh` also accepts `--sparkle-feed-url`/`--sparkle-public-key`. Verification prioritizes `MYTERM_SPARKLE_PUBLIC_KEY` when set, otherwise checking your generated `Config/Release/SparklePublicKey.txt` if present. Build entry points retain channel/path isolation and do not directly overwrite production apps.

## Optional: independent distribution

Before distributing to others, give your build a distinct app/data identity to avoid sharing data with other MyTerm builds. Review the Bundle ID in `Resources/Info.plist` and the development Bundle ID, Application Support, and Keychain service settings in `build-app.sh`/`verify-app.sh`; update corresponding checks when changing identity. This source defaults to local Dev use and does not promise that multiple derivative distributions coexist unchanged.

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

Prepare a plan and acceptance cases before changes and obtain maintainer approval. Review each language at the end of the plan, recording whether an update is needed, why, and what was done. Update affected translations and links before closing. Translation does not change the original UpdateLab fixture's script references; preserve upstream licenses and original English notices. The app interface remains primarily Traditional Chinese.

Original code and documentation use the [MIT License](LICENSE); third-party assets retain their terms, including [OpenAI brand assets](Resources/Readme/NOTICE.md). Preserve attribution and original-author notices; development-tool attribution is not an official endorsement.
