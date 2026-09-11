# Security maintenance and release verification

[繁體中文](SECURITY_MAINTENANCE.md) | **English**

This guide covers dependency maintenance and release verification. See [Security design](SECURITY.en.md) for application data boundaries and [Development](DEVELOPMENT.en.md) for build and release procedures.

## Dependency alerts and response

Enable GitHub's dependency graph and Dependabot alerts, and confirm the maintainer subscribes to security alerts and failed Actions notifications. Review existing alerts when enabling the feature; a new version is not approval to merge or publish automatically.

`.github/dependabot.yml` proposes weekly Swift, npm, GitHub Actions and verifier Python dependency updates. `.github/workflows/security-checks.yml` checks PRs/main and provides daily and manual monitoring; workflows become active after pushing them to the default branch. Monitoring examines both the source and the dependencies associated with the latest stable release. A fix on main does not mean installed apps are fixed. SHA-pinned Actions, Vendor/SwiftTerm and the libsodium binary inside swift-sodium receive additional upstream advisory checks. Unknown version ranges and failed queries are not considered safe.

The daily monitor retains the previous trusted scheduled/manual report and uses a failed check to notify the maintainer when findings, upstream versions or failure state change. Unchanged results do not produce repeated notifications. `scanStatus` and `lastSuccessfulScanAt` describe scan health; a quiet monitor does not mean outstanding findings disappeared. A previous successful scan older than 48 hours is marked stale on the next check. A schedule cannot notify immediately about its own complete failure to run, so maintainers must still watch Actions health.

```sh
python3 scripts/security-audit.py --output build/security-report.json
python3 scripts/security-audit.py --include-release OWNER/REPOSITORY --output build/security-report.json
```

Requires an authenticated `gh` with appropriate read access, Python 3.9.2 or newer, Node.js 24 or newer, and npm. Checks query public advisories and necessary source/version metadata, without reading local cloud configuration or signing private keys. `Config/Security/native-components.json` binds the libsodium version to the swift-sodium revision; review the actual XCFramework header after changing the wrapper. Vendor fixes announced by commit are checked using commit ancestry rather than an invented version.

New moderate/high risks, uncertain applicability and query failures block release preflight. Old vulnerabilities in the latest released app remain visible in monitoring but do not prevent building a follow-up from fixed sources. `Config/Security/exceptions.json` may contain explicit exceptions matching the advisory, component, version and development scope, with an accepting person, reason and expiry. Exceptions last at most 31 days and automatically stop suppressing the gate when expired. Development dependencies are not excluded as a category.

## Development dependency compatibility overrides

Current npm overrides preserve Firebase's CSV stream, PubSub trace-context propagator, Gaxios CommonJS UUID and qs APIs. Versions are exact; `Tests/Security/development-tools.test.cjs` and Firestore Emulator tests cover the consuming paths. Remove overrides when parent constraints allow safe versions, and review them at least monthly rather than accumulating unmaintained forced versions.

`scripts/firebase-tools.sh` permits only Firestore Rules/indexes deployment, local Auth/Firestore emulators under `demo-myterm`, and basic sign-in/project queries. Deployment requires explicit `--project` and Firestore `--only` options. Emulators require loopback configuration; `emulators:exec` accepts only this repository's fixed Rules test command. Auth import, Hosting, alternate configuration files and arbitrary emulator subprocess commands are rejected. This restricts the repository entry point; it cannot prevent a local owner from directly invoking the CLI in `node_modules`.

Firebase CLI still consumes `stream-json` 1.9.1, whose patched major version has an incompatible module interface. Passing tests does not resolve the advisory. Any temporary allowance requires explicit, expiring acceptance for the individual development risk while tracking a compatible upstream fix. The public source exception list remains empty and does not inherit the maintainer's private acceptance.

## Public-key release verification

Initial setup:

```sh
./scripts/setup-security-tools.sh
./scripts/security-python.sh -m unittest discover -s Tests/Security -v
```

Tools use a reproducible `.build/security-tools` Python venv, exact versions, wheel hashes and `--require-hashes`, without source-package build scripts. Python 3.9.2 or newer is supported. Existing release procedures retain signing material locally; CI needs only the public key.

```sh
./scripts/security-python.sh scripts/verify-signed-release.py \
  --assets /path/to/assets \
  --public-key-file /path/to/trusted-public-key.txt \
  --base-url https://updates.example.org \
  --version X.Y.Z --build BUILD --commit SOURCE_COMMIT
```

The key file contains a Base64-encoded 32-byte Ed25519 public key from trusted configuration or reviewed source, never a replacement key supplied by downloaded assets. Independent source distributors also set `MYTERM_SPARKLE_PUBLIC_KEY_FILE` and their own `MYTERM_UPDATE_BASE_URL`. Personal builds without an update service do not need this release tooling.

Verification proceeds through the complete feed signature and original byte length; one item's version, Build, platform and URLs; ZIP and release-notes signatures; signed source commit and dependency inventory; and consistency of all five assets, checksums and manifest. Signatures are checked before ZIP extraction or deployment. The same verified bytes are deployed, with another verification after copying rather than downloading replacement assets.

`bind-release-metadata.py` adds the source commit, dependency inventory and notes signature only before final feed signing. Published signed feeds must not be edited. The new flow rejects older assets without these signed fields; redeploying old releases requires a separate review of original assets and compatibility, not a skip-verification option.

## Safe testing and app updates

```sh
python3 scripts/run-isolated-tests.py
./scripts/run-sftp-security-tests.sh
```

The complete suite runs in a fresh temporary source copy with only its Application Support path redirected, preserving the tested implementation and using test-specific Keychain services. `run-tests.sh` is a lower-level entry point and should not be run directly on a Mac containing production data. This does not claim that every existing standalone AppPaths test entry point is isolated. The SFTP security suite uses a local fake peer and temporary data, not real hosts or credentials.

Applicable high-risk advisories need prompt assessment and remediation rather than waiting for weekly maintenance. A Sparkle fix reaches users through a rebuilt, signed and released application; changing a lockfile or appcast does not repair installed frameworks. If the update trust chain itself fails, evaluate an independently verified manual distribution path.
