# Security maintenance and release verification

[繁體中文](SECURITY_MAINTENANCE.md) | **English**

This guide covers dependency maintenance and release verification. See [Security design](SECURITY.en.md) for application data boundaries and [Development](DEVELOPMENT.en.md) for build and release procedures.

## Dependency alerts and response

Enable GitHub's dependency graph and Dependabot alerts, and confirm the maintainer subscribes to security alerts and failed Actions notifications. Review existing alerts when enabling the feature; a new version is not approval to merge or publish automatically.

The included `.github/dependabot.yml` proposes weekly dependency updates after an owner enables it in their own repository. This source export does not include the maintainer's GitHub Actions workflows or active monitoring service. Run the audit script below or configure your own CI/schedule and notification policy. Monitor both deployed releases and current source, and separately track Vendor revisions and native libraries. Unknown advisory ranges and query failures are not a pass. A schedule cannot immediately report its own failure to run; retain last-success timestamps and check scheduler health.


```sh
python3 scripts/security-audit.py --output build/security-report.json
python3 scripts/security-audit.py --include-release OWNER/REPOSITORY --output build/security-report.json
```

Requires an authenticated `gh` with appropriate read access, Python 3.9.2 or newer, Node.js 24 or newer, and npm. Checks query public advisories and necessary source/version metadata, without reading local cloud configuration or signing private keys. `Config/Security/native-components.json` binds the libsodium version to the swift-sodium revision; review the actual XCFramework header after changing the wrapper. Vendor fixes announced by commit are checked using commit ancestry rather than an invented version.

New moderate/high risks, uncertain applicability and query failures block release preflight. Old vulnerabilities in the latest released app remain visible in monitoring but do not prevent building a follow-up from fixed sources. `Config/Security/exceptions.json` may contain explicit exceptions matching the advisory, component, version and development scope, with an accepting person, reason and expiry. Exceptions last at most 31 days and automatically stop suppressing the gate when expired. Development dependencies are not excluded as a category.


`security-audit.py --monitor` fails only on scan operational errors and retains every finding in its report. Release preflight without `--monitor` continues to block unresolved risks. Public source exports do not include the maintainer's private Issue automation; distributors must configure their own risk tracking.

## Development dependency compatibility overrides

Current npm overrides preserve Firebase's CSV stream, PubSub trace-context propagator, Gaxios CommonJS UUID and qs APIs. Versions are exact; `Tests/Security/development-tools.test.cjs` and Firestore Emulator tests cover the consuming paths. Remove overrides when parent constraints allow safe versions, and review them at least monthly rather than accumulating unmaintained forced versions.

`scripts/firebase-tools.sh` permits only Firestore Rules/indexes deployment, local Auth/Firestore emulators under `demo-myterm`, and basic sign-in/project queries. Deployment requires explicit `--project` and Firestore `--only` options. Emulators require loopback configuration; `emulators:exec` accepts only this repository's fixed Rules test command. Auth import, Hosting, alternate configuration files and arbitrary emulator subprocess commands are rejected. This restricts the repository entry point; it cannot prevent a local owner from directly invoking the CLI in `node_modules`.

Firebase CLI is pinned to `15.30.0` with an npm override selecting the officially patched `stream-json` `3.6.0`. The npm postinstall hook runs `scripts/patch-firebase-stream-json.py` to map three CLI consumers to the new Node stream APIs. It checks both package versions and SHA-256 hashes of all three files before writing, and verifies already-patched files on repeated runs. Version, input, or output drift is rejected; no expiring exception remains for this advisory. `firebase-tools.sh` also checks the patch before every launch. After `npm ci --ignore-scripts`, run the patch script explicitly and then `npm run test:development-tools`. Tests cover actual consumer loading, chunked JSON, existing CLI data semantics, excessive-depth rejection, and patch drift. Once upstream Firebase CLI supports a patched dependency natively, remove the override and adapter only after the same regression tests pass; never change versions or hashes merely to bypass verification.

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

Keep pre-release tests, signature checks and maintenance evidence in plans, CI and security Issues, outside ordinary update dialogs. Release notes still disclose user-relevant security fixes, limitations and required actions; see [Development](DEVELOPMENT.en.md) for content policy.
