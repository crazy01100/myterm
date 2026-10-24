# Security maintenance and release verification

[繁體中文](SECURITY_MAINTENANCE.md) | **English**

This guide covers dependency maintenance and release verification. See [Security design](SECURITY.en.md) for application data boundaries and [Development](DEVELOPMENT.en.md) for build and release procedures.

## Dependency alerts and response

Enable GitHub's dependency graph and Dependabot alerts, and confirm the maintainer subscribes to security alerts and failed Actions notifications. Review existing alerts when enabling the feature; a new version is not approval to merge or publish automatically.

`.github/dependabot.yml` proposes weekly Monday updates for Swift, npm, GitHub Actions and verifier Python dependencies. `MyTerm security monitor` (security-checks.yml) runs daily at 09:23 Asia/Taipei and manually, checking source and the latest stable release. `MyTerm release security gate` (security-gate.yml) checks PRs/main pushes and retains moderate/high-risk blocking. Scheduled runs can be delayed.

Monitor success means scanning and Issue handling completed, not that no risks exist. Issues record advisories, components, versions, scope, upstream fix information and exception expiry. The same advisory/component/scope retains one Issue; unchanged findings cause no writes. Significant changes append a record. Only complete successful scans may close findings that no longer match; recurring findings reopen the same Issue. Human-authored Issues are untouched. Manually closing a still-affected automated Issue is not risk acceptance; the next scan reopens it.

Only operational errors in queries, tests, reports or Issue writes fail the daily monitor. Repeated identical errors must also fail. The separate source security gate continues to block unresolved risks; that policy rejection is distinct from monitor failure. Unknown applicability remains a finding requiring review rather than a claim of safety.

Issue write permission is limited to scheduled/manual monitoring on the default branch of `crazy01100/myterm`, never PRs. Forks do not automatically run this monitor job. The tool rejects public repositories by default; this workflow explicitly opts in with `--allow-public` for reviewed public-advisory metadata. Records contain public advisory and dependency metadata and acceptance status, not hosts, credentials or user data. `scanStatus` and `lastSuccessfulScanAt` describe scan health; a previous success older than 48 hours is flagged on the next run. A schedule cannot immediately alert about its own failure to run. Upstream versions remain in reports; ordinary new versions without matching advisories are tracked through Dependabot proposals rather than risk Issues.

npm dependencies are checked against both `npm audit` and the GitHub Advisory Database. Public advisories are queried in batches for every locked package/version, then merged by advisory and component. This covers differences in feed update timing without restricting checks to recent advisories. Any failed batch leaves the scan incomplete and cannot authorize Issue closure.

```sh
./scripts/project-python.sh scripts/security-audit.py --output build/security-report.json
./scripts/project-python.sh scripts/security-audit.py --include-release OWNER/REPOSITORY --output build/security-report.json
```

Requires an authenticated `gh` with appropriate read access, Python 3.12 or newer, Node.js 24 LTS, and npm. Checks query public advisories and necessary source/version metadata, without reading local cloud configuration or signing private keys. `Config/Security/native-components.json` binds the libsodium version to the swift-sodium revision; review the actual XCFramework header after changing the wrapper. Vendor fixes announced by commit are checked using commit ancestry rather than an invented version.

New moderate/high risks, uncertain applicability and query failures block release preflight. Old vulnerabilities in the latest released app remain visible in monitoring but do not prevent building a follow-up from fixed sources. `Config/Security/exceptions.json` may contain explicit exceptions matching the advisory, component, version and development scope, with an accepting person, reason and expiry. Ordinary time-limited exceptions last at most 31 days and automatically stop suppressing the gate when expired. Development dependencies are not excluded as a category.


`security-audit.py --monitor` fails only on scan operational errors and retains every finding in its report. Release preflight without `--monitor` continues to block unresolved risks. Independent distributors must configure their own tracking. Newly discovered unpublished vulnerabilities, private test evidence, and user data must not be automatically published; see [Security design](SECURITY.en.md) for reporting.


The release security gate reports policy rejection as a failed check; it does not imply enforced GitHub branch protection. Maintainers must configure and verify branch protection separately in GitHub; neither the workflow's existence nor making a repository public establishes that protection is enabled. Do not merge failed checks; the local release entry point also rechecks the policy.

Issue bodies contain only the advisory link, component, scope, current version, version match, branch-specific patched versions, and scan time, without repeated monitor-health notices, links, or generic advice. Display timestamps use `YYYY-MM-DD HH:mm:ss (UTC+8)`; machine reports retain the original timezone-aware values. npm findings are matched to GitHub Advisory patched versions by the actual affected version ranges, with separate entries for installed major branches. No upstream patch and unconfirmed metadata are distinct states; lookup failures remain operational errors.

`security-risk-context.py` gathers lockfile dependency paths and reads case-specific source/input reviews from `Config/Security/impact-assessments.json`. Impact is classified as confirmed affected, confirmed not affected, or needs review, with concise rationale, scope, and public evidence. A dependency path does not prove function reachability; this is not a general-purpose automatic exploitability analysis on every scan. Reviews are bound to the advisory, versions, and hashes of relevant inputs; changed inputs invalidate the result. Historical reviews apply only to explicitly matched original scan timestamps and identify their source basis. Fixing current source does not rewrite the old impact conclusion. These assessments never automatically exempt a finding from the existing release gate.

`security-issue-format.py` preserves an allow-listed machine-readable snapshot and original scan/resolution timestamps. Manual monitoring can enable `refresh_issue_format` to reformat existing bot Issues. Formatting alone neither adds risk-change comments nor reopens closed Issues. Human comments and unrecognized body additions are preserved; records that cannot be parsed reliably are flagged for review. Actual risk changes preserve the preceding record, and only a complete successful scan can resolve a finding.

## Update grouping and support lifecycle

Weekly minor/patch proposals are grouped separately for GitHub Actions and Python verification tools; major updates remain separate for review. Grouping does not enable automatic merging or waive compatibility and security validation.

The governing principle is to **avoid all EoL/EoS dependencies**. During maintenance, check official support status for packages, tools, and runtimes. Each discovery of an unsupported or unmaintained component requires an individual review of its version, dependency path, actual use and inputs, inclusion in the App, known vulnerabilities and their applicability, and the compatibility risks and maintenance cost of upgrading, removing, or replacing it. No known vulnerability does not mean continued support, and continued upstream use is not a security endorsement. Record maintenance status and evidence when no formal end date exists; do not invent one.

Prefer supported versions or upstream fixes. Retention requires explicit maintainer confirmation and a record of the package/version/scope, date, rationale, decision, and reassessment triggers. One decision does not exempt all unmaintained components. Check those conditions whenever the component is encountered again; unchanged facts may refer to the existing decision without repeated deadline extensions or added replacement tests. Reassess when the version, use, exposure, vulnerabilities, or upstream options change.

Support-status retention decisions are separate from vulnerability exceptions and may use reassessment triggers instead of recurring deadline extensions. They do not change scanning, Issue tracking, or release gates, and do not accept future vulnerabilities. Ordinary time-limited vulnerability exceptions retain the existing acceptance rules and 31-day maximum in `Config/Security/exceptions.json`. The separate Issue #43 conditional decision is retired under the official-withdrawal procedure below; retaining json-ptr does not accept that vulnerability.

Project Python tools require at least 3.12, CI uses 3.12, and administration scripts select their interpreter through `scripts/project-python.sh`. The minimum-version guard does not track future EoL dates; lifecycle review remains part of each maintenance pass. See the [tool environment](DEVELOPMENT.en.md#python-runtime).

### Reviewed retention: json-ptr 3.1.1

- **Decision date / approver**: 2026-10-01, explicitly confirmed by the project maintainer.
- **Scope and use**: The current chain is `firebase-tools 15.34.0 → exegesis 4.3.0 → json-ptr 3.1.1`, primarily for local Auth Emulator API specification and JSON reference parsing. Shared Firebase modules may also load it. It is not bundled with MyTerm and does not participate in the released App's Google sign-in or synchronization.
- **Evidence**: [npm marks the package unsupported](https://www.npmjs.com/package/json-ptr). GitHub Advisory version matching and npm audit on 2026-10-01 did not flag 3.1.1. Historical [high-severity](https://github.com/advisories/GHSA-x5r6-x823-9848) / [another high-severity record](https://github.com/advisories/GHSA-rrqv-vjrw-hrcr) and [moderate-severity](https://github.com/advisories/GHSA-8gwj-8hxc-285w) advisories were patched in 2.1.0 and 3.0.0 respectively. Firebase CLI 15.32.1, the latest at review time, still included this dependency chain; no explicit upstream security endorsement addressing its unsupported status was found.
- **Decision and rationale**: Retain the official dependency combination. No urgent vulnerability was confirmed, while a custom replacement would add compatibility and ongoing maintenance costs. Do not replace it, add a custom adapter, or perform replacement prototypes or small-scale replacement tests. Do not set recurring extension deadlines. Keep the unsupported status visible; do not label it fixed or supported.
- **Rechecked 2026-10-05**: Firebase CLI 15.32.1 retains the same Auth Emulator entry source and exegesis/json-ptr versions. Use and exposure are unchanged; the existing retention decision continues. No replacement testing was performed.
- **Rechecked 2026-10-13**: Firebase CLI 15.33.0 retains the Auth Emulator sources from 15.32.1 and still uses exegesis 4.3.0 / json-ptr 3.1.1. Use and exposure are unchanged; the existing retention decision continues without replacement testing.
- **Rechecked 2026-10-20**: Firebase CLI 15.34.0 still uses exegesis 4.3.0 / json-ptr 3.1.1. The Auth parsing entry is unchanged; utils only changes the phone-number prefix check to startsWith. Use and local exposure remain unchanged, so the existing retention decision continues without replacement testing.
- **Ongoing tracking**: Continue existing vulnerability monitoring. Reassess on a new advisory affecting the installed version, an actual compatibility problem, an upstream removal/replacement option, or a change in version, use, or exposure. This decision does not exempt new alerts or release security gates.

## Security Issue remediation summaries

At closure, decide whether a summary is needed by asking whether a future maintainer can understand the remediation and its verification evidence. Within the task's authorized Issue-update scope, read the Issue body and existing comments first:

- A straightforward dependency upgrade needs no repeated comment when the commit/PR and scan results already provide sufficient traceability. If only links are missing, add those links.
- Add a short summary for compatibility patches, custom code or configuration, feature restrictions, temporary exceptions or compensating controls, and rollback or removal conditions. Do not duplicate an adequate explanation for the same commit and results; add a follow-up when material results change.
- Explain what changed and why, the actual verification results with commit/PR/CI links, and remaining limitations or follow-up actions. State only confirmed facts and distinguish a fix from mitigation or acceptance of an expiring exception. Fixed source does not imply that every user's device has been updated.
- Check the summary after required remote verification and before declaring the task complete. If monitoring has already closed the Issue, add the comment to the closed Issue without reopening it. Preserve the original alert, resolution record, and history; read the comment back after writing.
- Omit full test logs, credentials, private endpoints, and unrelated internal discussion. These are maintainer tracking records, not material for ordinary user-facing release notes.

The maintainer or agent performing the remediation writes the summary from actual evidence. An automated resolution record only establishes that the scan no longer matches within its scope; it does not describe how the remediation was performed. This judgment does not change scanning, exception, or Issue-closure conditions.

## Development dependency compatibility overrides

Current npm overrides cover the PubSub trace-context propagator, Gaxios CommonJS UUID, qs, `@grpc/grpc-js 1.14.5`, and `glob 13.0.6`. gRPC unifies patched versions across Firebase and Google gax; glob replaces the unsupported free 10.x line used by Firebase file discovery and its archiving, cleanup, and controller-loading dependencies. Versions are pinned exactly. Tests cover actual consumers, loopback gRPC, and the isolated Firestore Emulator; `firebase-glob.test.cjs` covers dotfiles, exclusions, symlinks, sync/async/stream APIs, and temporary-file operations. Remove overrides when parent constraints permit supported, patched versions, and review them at least monthly.

`scripts/firebase-tools.sh` permits only Firestore Rules/indexes deployment, local Auth/Firestore emulators under `demo-myterm`, and basic sign-in/project queries. Deployment requires explicit `--project` and Firestore `--only` options. Emulators require loopback configuration; `emulators:exec` accepts only this repository's fixed Rules test command. Auth import, Hosting, alternate configuration files and arbitrary emulator subprocess commands are rejected. This restricts the repository entry point; it cannot prevent a local owner from directly invoking the CLI in `node_modules`.

Firebase CLI is pinned to `15.34.0`, which natively supports patched `stream-json`, `stream-chain`, and `csv-parse` versions. The source-rewriting adapter, postinstall hook, and the two dedicated overrides have been retired. `npm ci` checks lockfile and archive integrity. `scripts/verify-firebase-tools.cjs` performs read-only checks in the wrapper and CI: the exact CLI version, manifest/lockfile agreement, and the three stream dependencies actually resolved by the CLI. It does not hash every installed source file or replace clean installation, advisory scanning, or consumer tests. Regression coverage includes actual Auth JSON/CSV and DatabaseImporter paths with intercepted transport, chunked data, Next.js pipeline semantics, excessive-depth rejection, and missing/stale/shadowing dependency failures. The command allow-list and other necessary npm overrides remain. Compatible transitive security fixes are applied through lockfile updates without adding unnecessary overrides.

`compression 1.8.2` and `proxy-addr 2.0.8` are locked within existing parent compatibility ranges without new overrides. `firebase-http-dependencies.test.cjs` covers compression resource cleanup after aborted gzip/deflate/Brotli responses, actual superstatic compressed and identity responses, and proxy-trust subnet and loopback HTTP cases through the Express 4/5 consumers used by Firebase and MCP. Both are development-only dependencies; the Hosting command restriction does not substitute for patching them.

`@modelcontextprotocol/sdk 1.32.1`, `hono 4.13.11`, and `@hono/node-server 2.1.3` are locked within their parent compatibility ranges without new overrides. SDK 1.x remains in its official bug/security maintenance period; this change does not migrate to 2.x. Firebase MCP uses SDK Server with stdio and optional HTTP/SSE modes. The project wrapper rejects mcp and experimental:mcp, so its allowed workflows do not start those entry points. Firebase does not configure experimental taskStore or use the SDK HTTP/OAuth clients, bearer middleware, or Hono serveStatic; OneMcpServer uses Firebase's own apiv2.Client. These source assessments do not cover direct wrapper bypasses or other MCP applications.

The SDK update fixes task/session binding and HTTP/OAuth cross-origin redirect policy; do not restore the old behavior with `redirectPolicy: 'follow'`. The new protections for GHSA-46jr-4wx8-v453 and GHSA-rvq5-wwqv-78pq are off by default. Any future HTTP MCP integration must separately limit tool input elements (`maxToolInputElements`) and request bodies. SDK bearer authentication requires both `expectedResource` and a verifier returning `AuthInfo.resource`. A package update alone does not protect every HTTP configuration. Previous OAuth issuer/expectedIssuer and legacy credential requirements also remain.

Both Hono and its Node adapter include the serveStatic duplicate path-decoding fix; do not enable the `allowPercentInPath` fallback. `firebase-mcp-sdk.test.cjs` retains synthetic Server/stdio handshakes, tool listing, and OAuth issuer checks. `test_firebase_policy.py` explicitly checks rejection of MCP commands and their alias. Source-bound advisory assessments are retained in `Config/Security/impact-assessments.json`; historical version matches are not proof of exploitability, and these descriptions do not lower the existing risk classifications.

`ip-address 10.7.4` and `stream-json 3.7.0` are locked within their parent ranges, `^10.2.0` and `^3.6.0`, without new overrides or source adapters. The former is introduced by MCP’s express-rate-limit; ordinary IPv4, IPv6 subnet, and IPv4-mapped behavior is checked through its actual ipKeyGenerator. The latter retains Firebase Auth, DatabaseImporter, and Next.js pipeline regression coverage; the CLI bridge does not use the advisory’s FlexAssembler rule filters. These source scopes are not advisory exemptions and do not cover independent uses that bypass the wrapper. Closure depends on official fixed versions, compatibility regression, and complete scans. Both packages are development-only and are not bundled in the App.

`body-parser` branches are locked to 1.20.9 / 2.4.0, `fast-uri` to 3.1.9, `undici` to compatible 6.29.1 / 8.12.2 branches, and `zod` to 4.6.6 without cross-major replacement. The required `content-type 2.1.0` and `qs 6.16.1` accompany body-parser 2.4.0; qs retains its existing exact override. Compatibility coverage includes compressed JSON/form parsing through both Express branches, Undici HTTP decoding and ordinary Zod input validation. These tools are not bundled in the App, and ordinary workflow validation is not an exploitability assessment.

### Retained braces entry-point guard

`braces 3.0.3` remains installed; GHSA-vfj7-8cjw-p6xm was officially withdrawn, not patched. Firestore Emulator watches its Rules file through chokidar. Before startup, the project wrapper rejects `{`/`}` in the Rules path, project directory, or resolved symlink path, preventing those inputs from reaching brace expansion while preserving normal Rules reloads. This protects only the project entry point, does not patch the package, and cannot prevent a local owner from bypassing the wrapper or changing files/configuration after validation.

[Issue #43](https://github.com/crazy01100/myterm/issues/43) remains open until the approved withdrawal-retirement change passes main verification and receives a withdrawal closure summary. Preserve the original 2026-10-19 expiry and prior risk decisions as history; no extension or new exemption is created.

Firebase CLI 15.34.0 removed the unused `proxy-agent`, `universal-analytics`, and `@apphosting/common` dependencies. The lockfile also no longer contains the PAC proxy chain through `get-uri` / `basic-ftp`. The get-uri-scoped override and its FTP consumer tests are retired rather than reintroducing packages to keep obsolete tests running. `firebase-removed-dependencies.test.cjs` checks every lockfile level, installed package resolution, and upstream declarations for reintroduction. Other applicable security overrides and tests remain. Historical basic-ftp impact assessments are not rewritten as unaffected. These development tools are separate from MyTerm SFTP.


### Issue #43 conditional risk acceptance

The current decision is **revision 6 / retired (official advisory withdrawal)**. On 2026-10-24 the maintainer explicitly approved `issue43-withdrawal-retirement-1`, proposal SHA-256 `c979cbc420118841efdd8306681356da605bb038c71872425b752417a3cbc0f9`. GitHub Advisory Database withdrew [GHSA-vfj7-8cjw-p6xm](https://github.com/advisories/GHSA-vfj7-8cjw-p6xm) on 2026-10-23 at 12:53:02 UTC because it is not practically exploitable. This is an official withdrawal, not a package fix, an extended exception, or a project exploitability-test result.

`Config/Security/conditional-acceptances.json` preserves the revision 5 baseline, acceptance record and original expiry history, with a separate retirement approval, advisory digest and enforcement-source fingerprints. Revisions 1–5 and their PR Reviews remain traceable in Git history; historical assessments are not rewritten. `accepted=false` and `retirementVerified=true` distinguish no risk exemption from verified withdrawal. Other findings retain ordinary gates and the existing 31-day maximum for exceptions.

At every development/maintenance start, cross-day resumption, Firebase invocation, release preparation, Draft publication and redeployment, the shared entry rereads official withdrawal evidence and verifies advisory identity/content and enforcement sources. It neither executes npm packages nor consumes cached success receipts. Retired historical lockfile/Rules fingerprints no longer constrain unrelated updates, while changes to enforcement, security entries or policy still require review. Reinstatement, changed withdrawal content, missing evidence or source errors stop progress and require reassessment; no automatic renewed acceptance or treating absence as safety. New advisories, including new braces findings, remain subject to normal gates.

```sh
./scripts/project-python.sh scripts/security-conditional-risk.py \
  --purpose development --task TASK_ID \
  --output docs/TASK_ID-conditional-review.json
```

Purposes are development, firebase, ci, monitor, release, publish and redeploy; purpose is not an exemption. Publication and redeployment still require separate authorization. Keep the existing wrapper allow-list, loopback emulator scope and brace-path guard; this does not authorize unreviewed input or direct CLI use. Existing json-ptr and other EoL/EoS decisions remain unchanged.

The PR decision must match the reviewed base or receive maintainer Review on the exact current head. Other-author PRs use native APPROVED reviews. A same-repository PR targeting main and authored by the designated maintainer may use a formal COMMENTED Review containing `MYTERM-CONDITIONAL-REVIEW-V1`. The verifier pins crazy01100 / 43394184 / User and binds PR, full head/base, revision and raw policy-byte SHA-256. Retirement uses `action=retire` and a withdrawal-specific statement, not the old risk-acceptance statement. Revoked, stale, pending, malformed and ordinary comments are not approvals, and later reviews cannot silently revive old approval.

CI and pre-merge checks reread the complete PR/reviews, match local policy bytes to the exact remote head, and recheck sources/reviews after official queries. Retirement cannot return early and skip review. Exact Review is not proof that all CI passed, a second-person review or protection against the account owner bypassing controls; `mergeAuthorized=false` remains. Use the normal exact-head merge procedure without an admin bypass.

A stale npm finding is excluded only with matching official advisory/package identity and a valid withdrawal date, recorded in `withdrawnAdvisories`; raw npm counts retain their source meaning. Missing or invalid metadata still fails the scan. Issue #43 never closes automatically on disappearance or retirement: first complete approval, main security checks/full monitoring/CodeQL and fresh withdrawal verification, then close manually as official withdrawal / no longer applicable, preserving history. Reinstated findings can reopen through normal monitoring.

Preflight failures save preflight and conditional-review diagnostics; a diagnostic file does not imply a completed scan. Policy tests use mocks/stubs only. Complete development-tool regression contains existing vulnerability cases and still requires explicit authorization for that task. Never resume Daybreak or the terminated actual-exploitability plan.

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

New release-note links carry equal `length` and `sparkle:length` attributes for older updaters and Sparkle 2.10. The verifier retains support for signed historical metadata, but rejects any incorrect or conflicting length. Signing tools must come from a SwiftPM artifact whose framework version matches `Package.resolved`; stale caches cannot select tools from another version.

### CI verification profiles

scripts/security-test-profile.py computes actual Git changes from PR base/head, push before/after, or the current monitoring commit and its first parent. Only additions/modifications to explicitly listed policy, formatting, entry, documentation and mock-test files use run-policy-tests.py. Lockfiles, Rules, App files, deletions, renames, unknown files and empty diffs retain full verification; failed comparisons stop execution. Environment overrides and PR labels cannot choose the profile. Existing vulnerability cases remain unchanged and the policy-only report explicitly says they were not executed. Advisory scanning and CodeQL remain required. Changes to the selector require maintainer review; this is not a boundary against writers modifying the code.
