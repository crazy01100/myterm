# Security maintenance and release verification

[繁體中文](SECURITY_MAINTENANCE.md) | **English**

This guide covers dependency maintenance and release verification. See [Security design](SECURITY.en.md) for application data boundaries and [Development](DEVELOPMENT.en.md) for build and release procedures.

## Dependency alerts and response

Enable GitHub's dependency graph and Dependabot alerts, and confirm the maintainer subscribes to security alerts and failed Actions notifications. Review existing alerts when enabling the feature; a new version is not approval to merge or publish automatically.

`.github/dependabot.yml` proposes weekly Monday updates for Swift, npm, GitHub Actions and verifier Python dependencies. `MyTerm security monitor` (security-checks.yml) runs daily at 09:23 Asia/Taipei and manually, checking source and the latest stable release. `MyTerm release security gate` (security-gate.yml) checks PRs/main pushes and retains moderate/high-risk blocking. Scheduled runs can be delayed.

Monitor success means scanning and Issue handling completed, not that no risks exist. Issues record advisories, components, versions, scope, upstream fix information and exception expiry. The same advisory/component/scope retains one Issue; unchanged findings cause no writes. Significant changes append a record. Only complete successful scans may close findings that no longer match; recurring findings reopen the same Issue. Human-authored Issues are untouched. Manually closing a still-affected automated Issue is not risk acceptance; the next scan reopens it.

Only operational errors in queries, tests, reports or Issue writes fail the daily monitor. Repeated identical errors must also fail. The separate source security gate continues to block unresolved risks; that policy rejection is distinct from monitor failure. Unknown applicability remains a finding requiring review rather than a claim of safety.

Issue write permission is limited to scheduled/manual monitoring on the default branch of `crazy01100/myterm`, never PRs. Forks do not automatically run this monitor job. The tool rejects public repositories by default; this workflow explicitly opts in with `--allow-public` for reviewed public-advisory metadata. Records contain public advisory and dependency metadata and acceptance status, not hosts, credentials or user data. `scanStatus` and `lastSuccessfulScanAt` describe scan health; a previous success older than 48 hours is flagged on the next run. A schedule cannot immediately alert about its own failure to run. Upstream versions remain in reports; ordinary new versions without matching advisories are tracked through Dependabot proposals rather than risk Issues.

```sh
./scripts/project-python.sh scripts/security-audit.py --output build/security-report.json
./scripts/project-python.sh scripts/security-audit.py --include-release OWNER/REPOSITORY --output build/security-report.json
```

Requires an authenticated `gh` with appropriate read access, Python 3.12 or newer, Node.js 24 LTS, and npm. Checks query public advisories and necessary source/version metadata, without reading local cloud configuration or signing private keys. `Config/Security/native-components.json` binds the libsodium version to the swift-sodium revision; review the actual XCFramework header after changing the wrapper. Vendor fixes announced by commit are checked using commit ancestry rather than an invented version.

New moderate/high risks, uncertain applicability and query failures block release preflight. Old vulnerabilities in the latest released app remain visible in monitoring but do not prevent building a follow-up from fixed sources. `Config/Security/exceptions.json` may contain explicit exceptions matching the advisory, component, version and development scope, with an accepting person, reason and expiry. Exceptions last at most 31 days and automatically stop suppressing the gate when expired. Development dependencies are not excluded as a category.


`security-audit.py --monitor` fails only on scan operational errors and retains every finding in its report. Release preflight without `--monitor` continues to block unresolved risks. Independent distributors must configure their own tracking. Newly discovered unpublished vulnerabilities, private test evidence, and user data must not be automatically published; see [Security design](SECURITY.en.md) for reporting.


The release security gate reports policy rejection as a failed check; it does not imply enforced GitHub branch protection. Maintainers must configure and verify branch protection separately in GitHub; neither the workflow's existence nor making a repository public establishes that protection is enabled. Do not merge failed checks; the local release entry point also rechecks the policy.

## Update grouping and support lifecycle

Weekly minor/patch proposals are grouped separately for GitHub Actions and Python verification tools; major updates remain separate for review. Grouping does not enable automatic merging or waive compatibility and security validation.

During dependency maintenance, check official support status for packages, tools, and their runtimes. Do not knowingly adopt or continue depending on EoL/EoS versions. Absence of known vulnerabilities does not establish support. For components without a formal lifecycle, record upstream maintenance status and evidence rather than inventing an expiry date. Prioritize a supported replacement when support has ended, validate it before migration, and explicitly document impact, deadlines, and acceptance when immediate removal is not feasible.

Project Python tools require at least 3.12, CI uses 3.12, and administration scripts select their interpreter through `scripts/project-python.sh`. The minimum-version guard does not track future EoL dates; lifecycle review remains part of each maintenance pass. See the [tool environment](DEVELOPMENT.en.md#python-runtime).

## Security Issue remediation summaries

At closure, decide whether a summary is needed by asking whether a future maintainer can understand the remediation and its verification evidence. Within the task's authorized Issue-update scope, read the Issue body and existing comments first:

- A straightforward dependency upgrade needs no repeated comment when the commit/PR and scan results already provide sufficient traceability. If only links are missing, add those links.
- Add a short summary for compatibility patches, custom code or configuration, feature restrictions, temporary exceptions or compensating controls, and rollback or removal conditions. Do not duplicate an adequate explanation for the same commit and results; add a follow-up when material results change.
- Explain what changed and why, the actual verification results with commit/PR/CI links, and remaining limitations or follow-up actions. State only confirmed facts and distinguish a fix from mitigation or acceptance of an expiring exception. Fixed source does not imply that every user's device has been updated.
- Check the summary after required remote verification and before declaring the task complete. If monitoring has already closed the Issue, add the comment to the closed Issue without reopening it. Preserve the original alert, resolution record, and history; read the comment back after writing.
- Omit full test logs, credentials, private endpoints, and unrelated internal discussion. These are maintainer tracking records, not material for ordinary user-facing release notes.

The maintainer or agent performing the remediation writes the summary from actual evidence. An automated resolution record only establishes that the scan no longer matches within its scope; it does not describe how the remediation was performed. This judgment does not change scanning, exception, or Issue-closure conditions.

## Development dependency compatibility overrides

Current npm overrides preserve Firebase's CSV stream, PubSub trace-context propagator, Gaxios CommonJS UUID and qs APIs. Versions are exact; `Tests/Security/development-tools.test.cjs` and Firestore Emulator tests cover the consuming paths. Remove overrides when parent constraints allow safe versions, and review them at least monthly rather than accumulating unmaintained forced versions.

`scripts/firebase-tools.sh` permits only Firestore Rules/indexes deployment, local Auth/Firestore emulators under `demo-myterm`, and basic sign-in/project queries. Deployment requires explicit `--project` and Firestore `--only` options. Emulators require loopback configuration; `emulators:exec` accepts only this repository's fixed Rules test command. Auth import, Hosting, alternate configuration files and arbitrary emulator subprocess commands are rejected. This restricts the repository entry point; it cannot prevent a local owner from directly invoking the CLI in `node_modules`.

Firebase CLI is pinned to `15.30.0` with an npm override selecting the officially patched `stream-json` `3.6.0`. The npm postinstall hook runs `scripts/patch-firebase-stream-json.py` to map three CLI consumers to the new Node stream APIs. It checks both package versions and SHA-256 hashes of all three files before writing, and verifies already-patched files on repeated runs. Version, input, or output drift is rejected; no expiring exception remains for this advisory. `firebase-tools.sh` also checks the patch before every launch. After `./scripts/project-node.sh --npm ci --ignore-scripts`, run the patch script explicitly and then `./scripts/project-node.sh --npm run test:development-tools`. Tests cover actual consumer loading, chunked JSON, existing CLI data semantics, excessive-depth rejection, and patch drift. Once upstream Firebase CLI supports a patched dependency natively, remove the override and adapter only after the same regression tests pass; never change versions or hashes merely to bypass verification.

## Public-key release verification

Initial setup:

```sh
./scripts/setup-security-tools.sh
./scripts/security-python.sh -m unittest discover -s Tests/Security -v
```

Tools use a reproducible `.build/security-tools` Python venv, exact versions, wheel hashes and `--require-hashes`, without source-package build scripts. Python 3.12 or newer is supported. Existing release procedures retain signing material locally; CI needs only the public key.

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
./scripts/project-python.sh scripts/run-isolated-tests.py
./scripts/run-sftp-security-tests.sh
```

The complete suite runs in a fresh temporary source copy with only its Application Support path redirected, preserving the tested implementation and using test-specific Keychain services. `run-tests.sh` is a lower-level entry point and should not be run directly on a Mac containing production data. This does not claim that every existing standalone AppPaths test entry point is isolated. The SFTP security suite uses a local fake peer and temporary data, not real hosts or credentials.

Applicable high-risk advisories need prompt assessment and remediation rather than waiting for weekly maintenance. A Sparkle fix reaches users through a rebuilt, signed and released application; changing a lockfile or appcast does not repair installed frameworks. If the update trust chain itself fails, evaluate an independently verified manual distribution path.

Keep pre-release tests, signature checks and maintenance evidence in plans, CI and security Issues, outside ordinary update dialogs. Release notes still disclose user-relevant security fixes, limitations and required actions; see [Development](DEVELOPMENT.en.md) for content policy.

## Deployment permissions and environments

Before public visibility, verify main's required security check, force-push/deletion restrictions, and fork PR workflow approval policy. The update-site workflow's repository/main guard and production binding are source-level conditions; administrators must still configure environment reviewers, deployable refs, and environment Secrets, then validate an actual deployment approval. Do not treat the environment binding as credential isolation while repository-level Cloudflare Secrets remain. See [Development](DEVELOPMENT.en.md#production-deployment-protection) for setup and plan checks before returning to private.
