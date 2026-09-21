# MyTerm Development and Release Guide

[繁體中文](DEVELOPMENT.md) | **English**

This guide explains how to test source changes, build candidates, and prepare releases without affecting production MyTerm. Build scripts are stored in GitHub so a fresh checkout can reproduce the workflow without depending on a particular AI tool or local activity history.

## Environment and artifact isolation

| Purpose | Fixed output in a checkout | Description |
|---|---|---|
| Production | `/Applications/MyTerm.app` | The stable app for daily use. Development scripts do not modify or replace it. |
| Local testing | `build/dev/MyTerm Dev.app` | Daily development and manual checks. Rebuilt at the same location with separate Bundle ID, Application Support, and vault Keychain service. |
| Candidate | `build/candidates/MyTerm-<version>-build-<build>/MyTerm.app` | A candidate app for RC/production release preparation; never interchangeable with Dev. |
| Release assets | `build/releases/MyTerm-<version>-build-<build>/` | The five versioned files used by a GitHub Draft Release. |

Do not create or use `build/MyTerm.app`. A path with no version or channel makes it easy to confuse a running old app with newly built files. Build and verification scripts reject it.

All apps, ZIPs, test results, and release assets in `build/` are reproducible and excluded from Git. This is a temporary development/release workspace, not a long-term production backup. After GitHub Release, Cloudflare deployment, in-app updating, and manual acceptance all succeed, the five GitHub Release assets are the authoritative copy. Clear the entire `build/` directory and recreate it with the scripts during the next development cycle.

These paths define checkout build and automated verification rules, not hard-coded app runtime requirements. A verified `MyTerm Dev.app` sent to another Mac for manual testing may run from any stable, writable local folder. `~/Applications/MyTerm Dev.app` is recommended; there is no need to recreate `Documents/MySSHClient/build/dev/`. Isolation comes from the app's development Bundle ID, Application Support directory, and Keychain service, not its location. External testing must still record the actual path and verify version, Build, Bundle ID, and signature, without replacing `/Applications/MyTerm.app`.

Google sign-in is isolated by build channel too. Dev/Update Lab must not query or import early production Keychain sessions. The first run with the isolation fix clears only refresh tokens previously imported into that test channel by mistake; production remains untouched. After that one-time cleanup, accounts explicitly signed into Dev are retained in its own vault, and rebuilding the same channel does not repeatedly sign users out.

## Development requirements

- Apple Silicon Mac (arm64)
- macOS 26 or later
- Xcode 26 or compatible Command Line Tools
- The project's pinned Swift Package dependencies

### Terminal component source

The SwiftTerm library runtime is tracked under `Vendor/SwiftTerm` for minimal macOS display extensions supporting label highlighting and black/white text contrast. It is not a build cache. Normal builds do not require downloading a fork or editing `.build/checkouts`. See [SwiftTerm source notes](Vendor/SwiftTerm/UPSTREAM.md) for the upstream revision, MIT license, changes to two renderer files, and upgrade procedure. `Package.resolved` locks only the other remote dependencies.

Before an upgrade, obtain the upstream Git checkout at the documented revision and run `bash scripts/verify-swiftterm-vendor.sh /path/to/upstream-checkout`. It compares the runtime file list, unchanged files, and license, and presents the two renderer differences for review. After upgrading, run the full tests, a clean scratch build, Dev interaction checks, and packaged-resource verification. The app includes `SwiftTerm-LICENSE.txt`.

Firebase/OAuth/Cloudflare credentials, Sparkle private keys, and code-signing private keys are not required source files for a normal local build and must never be committed.

## Cloud-feature build modes

| Goal | Firebase/OAuth configuration | Result |
|---|---|---|
| Normal local development | Not required | SSH, Terminal, Serial, SFTP, and local data work; Google sign-in and sync report missing configuration. |
| Build with your own sync backend | Your own Firebase/Google Cloud project | Enables testing Google sign-in, Firestore Rules, and end-to-end encrypted cross-device sync. |
| Official release | Production settings supplied securely by the maintainer on the local Mac | Production settings must not be inferred or obtained from the repository, examples, or CI. |

See [Firebase setup](FIREBASE_SETUP.en.md) for the Console, Desktop OAuth, Firestore, configuration generation, Rules deployment, and acceptance steps. Real settings belong in Git-ignored `Config/Local/`. The shared repository contains only examples without real values, Rules, Indexes, and safe deployment tools.

## Source builds and distribution boundaries

A checkout without `Config/Local/` does not inherit maintainer cloud settings and has no default update feed. Modified or independently distributed apps should use their own services, update source, and signing identity instead of connecting a custom build to the maintainer’s update chain. Desktop client settings in existing packages cannot serve as server-side secrets; see [Firebase setup](FIREBASE_SETUP.en.md).

History cleanup changes commit/tag identifiers and can affect PR diffs and signed feed source bindings. Do not rewrite history or replace signed assets merely to hide paths, public keys, or ordinary identifiers. Removing truly sensitive material requires a separate review of historical references and the update chain.

## Daily development workflow

Before launching MyTerm Dev, verify that the production app has exited. If `/Applications/MyTerm.app` is running, stop the Dev workflow and ask the user to “退出所有工作並關閉正式版本” (exit all work and quit the production app). Only the user closes production; tools must never terminate it. Recheck processes after the user's reply rather than treating a reply or elapsed time as proof.

`run-dev-app.sh` calls the read-only `check-dev-launch.py` gate before stopping/rebuilding Dev and again immediately before launch. A process-query failure also stops the workflow. Do not bypass it through direct open, Finder or Computer Use that launches apps automatically. Users of external test Macs must also quit production first; this is launch ordering, not an app-location requirement. Isolated tests that do not launch an app can continue while waiting.

Run `./scripts/project-python.sh Tests/Security/test_dev_launch_gate.py` to test the gate and a disposable runner, including production starting during a build. Tests never launch or terminate the real production app.

Dev versions follow `target-release-dev.sequence`, such as `1.0.22-dev.1` and `1.0.22-dev.2`. Do not use generic `0.0.0-dev.*` versions for feature-test deliveries. `CFBundleVersion` remains a distinct, increasing timestamp for every build; a version name does not replace Build or channel isolation. Versions in this guide are naming examples and must be adjusted to the actual target when building.

Run sync reliability regression tests independently with `zsh scripts/run-sync-reliability-tests.sh`; the complete `scripts/run-tests.sh` also includes them. Tests use temporary directories, isolated UserDefaults, synthetic backend results, and shortened scheduling intervals to exercise the real coordinator's single schedule, account generations, and JSON-save recovery without production cloud access. The real `CloudAccountStore`, with synthetic sign-in/Keychain dependencies confined to the test executable, covers offline cold launch, no retries before the next cycle, session/data recovery on the next cycle, single-flight requests, disable/sign-out/invalid credentials, and stale responses. Crypto tests also verify that an existing vault initializes without opening Settings.

Manual two-Mac automatic-sync acceptance requires a separate test Google account and the same verified Dev Build. Do not substitute Sync Now for launch, foreground-cycle, or offline-recovery checks. First test launch without opening Settings; only afterward use Account & Sync → Diagnostics → Copy Sync Execution Log to obtain redacted stage evidence. Record both apps' actual identities, triggers, and elapsed times, and keep them active for at least three five-minute cycles. Accelerated single-Mac tests do not establish successful transfer between two Macs.

Quick Action search, result IDs, shortcut migration, temporary SSH address parsing, and password-binding policy cases live in `SelfTests/QuickActionTests.swift`. `SelfTests/main.swift` also checks SSH arguments and the audit-record model for temporary connections. Both run through the isolated entry point below. Panel appearance and focus, IME composition, shortcut recording, main-window drag interactions, and actual SSH authentication, cancellation, and reconnection also require hands-on Dev acceptance.

Saved-host SFTP opening tests live in `SelfTests/SFTPHostOpeningTests.swift` and run through the same isolated entry point. They exercise the real coordinator with synthetic connection state for target reuse, switch confirmation, username cancellation, and inventory/connection changes, without remote connections or credentials. Transfer protection, directory preservation, and shared workspace interactions also require Dev acceptance.

Run `zsh scripts/run-sftp-transfer-tests.sh` for transfer cancellation, staging/replacement, single-queue scheduling, and timing regression tests; the complete isolated entry point includes them. The fake peer is confined to a UUID temporary root. Cases cover missing/wrong extension versions, channel reuse after cancellation, no cleanup without staging ownership, lost commit replies, and process exit. When available, the local native OpenSSH sftp-server also verifies replacement and recursive transfers using temporary data, without remote SSH connections. Real large-file transfers, cancellation, overwrite prompts, and the full-width transfer list still require Dev acceptance.
The full isolated runner also executes SnippetTerminalModeTests against the real SwiftTerm renderer: normal-buffer cursor hide/show, split sequences, alternate buffers, mouse reporting, shell false positives and soft reset. Real top/vim entry and exit still require app acceptance; boolean policy tests are not evidence of actual program behavior.

Command snippet checks run with `zsh scripts/run-command-snippet-tests.sh` and are included in the full isolated entry point. Temporary fixtures cover persistence/reload/failure, corrupt-file preservation, input restrictions, target generations, and shortcuts. Dev acceptance covers sidebar visibility, both split orientations with automatic target following, search/preview target retention, close/reconnect invalidation and reselection, reordering/merging/detaching, PTY resizing, single-line insertion without execution, multiline copying, and native text-field copy/paste.

Run `zsh scripts/run-snippet-sync-tests.sh` for snippet sync coverage; the full isolated runner includes it. It uses independent local stores, synthetic keys, an in-memory backend and intercepted REST responses for conflicts, CAS preconditions, response loss, account switching and migration. Validate Rules with `./scripts/project-node.sh --npm run test:firestore-rules`. If port 8080 is occupied, use a temporary configuration with free loopback ports; tests honor FIRESTORE_EMULATOR_HOST. Do not stop unrelated processes. Deploy compatible additive Rules before releasing the app, after verifying the target project and diff. Two-Mac acceptance includes create/edit/delete, offline conflicts, restart persistence and coexistence with older clients; in-memory tests do not replace it.

The fake SFTP peer must also use the project-validated Python runtime: `run-sftp-security-tests.sh` passes the interpreter selected by `project-python.sh` to the Swift tests, including pre-cancelled connections. A missing startup PID fails the test. Do not hard-code a separate system Python inside tests.

Run automated tests first:

```sh
./scripts/project-python.sh scripts/run-isolated-tests.py
```

For manual app checks, use the fixed development entry point:

```sh
./scripts/run-dev-app.sh \
  --version 1.0.22-dev.1 \
  --build "$(date '+%Y%m%d%H%M%S')"
```

This entry point:

1. Closes only the test app currently running from `build/dev/MyTerm Dev.app`.
2. Rebuilds at that same fixed location.
3. Verifies version, Build, bundle, and signature.
4. Launches Dev and verifies its actual executable path.

To check compilation and the app bundle without launching the UI:

```sh
./scripts/run-dev-app.sh \
  --version 1.0.22-dev.1 \
  --build "$(date '+%Y%m%d%H%M%S')" \
  --build-only
```

Documentation, comment, or instruction-only changes do not require building or launching Dev. Check links, relevant script syntax, and the Git diff instead.

Commit and push source after feature acceptance. On the primary development Mac, do not move `build/dev/MyTerm Dev.app` into system `/Applications` or use it to replace production. This does not prevent external test Macs from using the recommended per-user `~/Applications/MyTerm Dev.app` location.

### Firebase development tool compatibility

Development tools require Node.js 24 LTS and Python 3.12 or later. `./scripts/project-node.sh --npm ci` runs the version- and hash-verified `scripts/patch-firebase-stream-json.py`; installations using `--ignore-scripts` must run it explicitly. `./scripts/project-node.sh --npm run test:development-tools` checks the existing overrides, CLI consumers, and depth limits; `./scripts/project-node.sh --npm run test:firestore-rules` uses the local demo emulator. The wrapper verifies the patch again before every CLI launch. Source drift requires review and must not be bypassed. See [security maintenance](SECURITY_MAINTENANCE.en.md) for scope and removal conditions.

The upstream repository also provides `scripts/invite-sync-user.sh --help` for maintainer administration. It requires local Google Cloud CLI and administrator authorization; it is not an app build dependency or an expansion of the existing Firebase CLI wrapper. Run its isolated safety suite with `./scripts/project-node.sh --test Tests/Security/invite-sync-user.test.mjs`; normal Python test discovery under `Tests/Security` also runs it. Administrator settings, credentials, and private operating notes stay out of Git. This tool is not part of the independent source export.

### Document languages and synchronized maintenance

GitHub's default homepage is the Traditional Chinese [README.md](README.md); the English entry point is [README.en.md](README.en.md). The project's own document pairs are listed below. Current guides provide language links at the top. English documents should link to English counterparts and Chinese documents to Chinese counterparts where available.

| Document | Traditional Chinese | English |
|---|---|---|
| Project introduction | [README.md](README.md) | [README.en.md](README.en.md) |
| Architecture | [ARCHITECTURE.md](ARCHITECTURE.md) | [ARCHITECTURE.en.md](ARCHITECTURE.en.md) |
| Development and releases | [DEVELOPMENT.md](DEVELOPMENT.md) | [DEVELOPMENT.en.md](DEVELOPMENT.en.md) |
| Security design | [SECURITY.md](SECURITY.md) | [SECURITY.en.md](SECURITY.en.md) |
| Firebase setup | [FIREBASE_SETUP.md](FIREBASE_SETUP.md) | [FIREBASE_SETUP.en.md](FIREBASE_SETUP.en.md) |
| Termius migration | [TERMIUS_MIGRATION.md](TERMIUS_MIGRATION.md) | [TERMIUS_MIGRATION.en.md](TERMIUS_MIGRATION.en.md) |
| Update site | [update-site/README.md](update-site/README.md) | [update-site/README.en.md](update-site/README.en.md) |
| UpdateLab beta.2 test notes | [Original Chinese fixture](Resources/UpdateLab/1.0.0-beta.2.md) | [English reading companion](Resources/UpdateLab/1.0.0-beta.2.en.md) |
| Security maintenance | [SECURITY_MAINTENANCE.md](SECURITY_MAINTENANCE.md) | [SECURITY_MAINTENANCE.en.md](SECURITY_MAINTENANCE.en.md) |

When changing project descriptions, features, architecture, security, installation, builds, deployment, or migration instructions, update both languages of each affected document. Contents, commands, configuration keys, data flows, and limitations must agree. Documentation translation does not mean that the app or update website has an English interface. Add English files as `<original-name>.en.md` in the same directory, then update this table and language links. Do not put them in local Git-ignored `docs/`.

The original Chinese UpdateLab file is a historical fixture used by the local update script; the English file is for reading on GitHub only. This table links both versions. Do not add a language bar to the original fixture or change the script's selected language. If test requirements later change the original text, update its English companion too. Already-English upstream documents and original LICENSE/NOTICE files retain their original wording; bilingual maintenance does not justify rewriting third-party content.

Before development, present a plan and acceptance cases for maintainer approval. At the end of the plan, review the Chinese and English files for README, ARCHITECTURE, DEVELOPMENT, SECURITY, FIREBASE_SETUP, TERMIUS_MIGRATION, the update site, and UpdateLab individually, adding LICENSE and asset notices when affected. Record whether each needs an update, why, and what was done. Close the plan only after necessary changes and content/link/language-switch checks are complete; unaffected files may explicitly be marked as requiring no update. Development attribution and image labels must also agree across languages.

MyTerm's original code and documentation use the root [MIT LICENSE](LICENSE). Third-party components and assets retain their own LICENSE/NOTICE files; do not overwrite them when updating project license information.

README brand assets live in `Resources/Readme/`; [NOTICE.md](Resources/Readme/NOTICE.md) records their sources and terms. The OpenAI logo identifies development tools only, using the original black/white versions selected for the color scheme. Do not crop, recolor, or incorporate it into MyTerm's own logo. It is not covered by the project's MIT License. Check both READMEs' presentation and notices when editing the header.

## Build and release scripts

Every main script supports `--help`. Check it when unsure about arguments:

```sh
./scripts/build-app.sh --help
./scripts/release.sh --help
```

| Script | Purpose | Publishes? |
|---|---|---|
| `scripts/run-tests.sh` | Main regression and crypto/sync tests. | No |
| `scripts/run-crypto-tests.sh` | Crypto, vault, and sync tests separately. | No |
| `scripts/configure-cloud.sh` | Generate runtime cloud configuration from local Firebase/Desktop OAuth inputs. | No |
| `scripts/deploy-firestore.sh` | Require an explicit Firebase Project ID and deploy Rules/Indexes. | Yes, only Firestore configuration in the specified project |
| `scripts/run-dev-app.sh` | Safely build, verify, and optionally launch the fixed test app. | No |
| `scripts/build-app.sh` | Lower-level app builder with channel-specific path restrictions. | No |
| `scripts/verify-app.sh` | Verify a specified app's version, Build, architecture, signature, and update settings. | No |
| `scripts/verify-packaged-resources.sh` | Compare platform icons in apps/ZIPs and reject a MyTerm SwiftPM resource accessor that depends on the build machine. | No |
| `scripts/check-release-safety.sh` | Scan release settings, secrets, and unsafe artifacts. | No |
| `scripts/prepare-release-build.sh` | Run tests, build a versioned candidate, and package a ZIP. | No |
| `scripts/package-app.sh` | Package an explicitly specified candidate as a versioned ZIP. | No |
| `scripts/prepare-release-assets.sh` | Create appcast, release notes, checksums, and manifest. | No |
| `scripts/verify-release-assets.sh` | Verify the five GitHub/Cloudflare release assets. | No |
| `scripts/release.sh` | Complete release preparation, creating at most a GitHub Draft Release. | Draft only |
| `scripts/cleanup-build-artifacts.sh` | After full production acceptance, download and verify the five GitHub assets, ensure no app runs from `build/`, and clear local build output. Preview by default; requires `--apply` to act. | No |
| `scripts/prepare-pages-deployment.sh` | Prepare static Cloudflare Pages content from published assets. | No |
| `scripts/verify-public-update-site.sh` | Externally verify the production appcast, downloads, and security headers. | No |

Lower-level scripts support these entry points. Use `run-dev-app.sh` for normal development and `release.sh` for production releases instead of assembling a seemingly equivalent sequence manually.

## App versioning and release decisions

MyTerm uses `Major.Minor.Patch`, based on user impact and compatibility:

- **Patch**: compatible bug/security fixes, performance improvements, or small presentation refinements.
- **Minor**: compatible feature additions/expansions, or deprecation notices while the feature remains usable.
- **Major**: incompatible changes to existing functionality, data formats, synchronization, or platform support; raising the minimum macOS version also belongs here.

Use the highest applicable level for mixed changes. Work size, vulnerability severity, and upstream dependency version numbers do not determine the App level. Judge UI redesigns and data migrations by their actual compatibility impact. CI, tooling, or documentation-only maintenance may need no App release; necessary fixes packaged inside the App still need delivery in a new release.

Reset Patch when increasing Minor, and reset both lower fields when increasing Major; there is no count threshold. Dev/RC versions append a suffix to the target version (such as `1.1.0-dev.1` or `1.1.0-rc.1`), with independently increasing Builds. Apply this policy to future releases without renumbering published versions or overwriting signed assets.

Every release plan records: **current → proposed version | level and reason | compatibility impact and required user actions | whether an App release is needed**. Proceed through the existing workflow after maintainer confirmation. Automation verifies consistency; it does not select the level or publish automatically.

## Release-note content and presentation

Update dialogs show user-visible features/fixes, necessary compatibility, significant known limitations, and actions users must take after updating. Keep test counts, verification procedures, CI, deployment, monitoring and development-tool exceptions in feature plans, CI or security Issues. Continue disclosing security information that directly affects app users.

Do not add a “Validation and maintenance” section to ordinary release notes. Omit the version heading or provide `# MyTerm X.Y.Z` as the first line, matching the target version. Private and public asset scripts share `scripts/render-release-notes.py` to generate signed HTML with one version heading and no website navigation. The app and website use the same concise content and `update-site/assets/release-notes.css`; homepage styling does not apply to release notes.

The renderer preserves author-supplied sections rather than silently removing content. Review their scope when writing notes. Signing and release-validation requirements remain intact. Check narrow layouts, light/dark appearance and scrolling before release, then verify the actual Sparkle update dialog; browser previews do not replace in-app acceptance. Do not overwrite published signed notes or appcasts; template changes take effect with the next authorized release.

## Candidate and release workflow

To build a candidate without creating a GitHub Release, replace `X.Y.Z` with the intended release version:

```sh
./scripts/prepare-release-build.sh \
  --version X.Y.Z-rc.1 \
  --build "$(date '+%Y%m%d%H%M%S')"
```

The full release entry point requires a local release-notes file:

```sh
./scripts/release.sh \
  --version X.Y.Z-rc.1 \
  --build "$(date '+%Y%m%d%H%M%S')" \
  --notes build/release-notes/X.Y.Z-rc.1.md
```

`release.sh` enforces these boundaries:

1. A clean working tree on `main`, with local `HEAD` equal to `origin/main`.
2. Safety scanning, all tests, an arm64 Release build, and stable-signature verification.
3. Creation and re-verification of the five release assets.
4. Stop after creating the GitHub Draft Release.

The five production assets are:

- `MyTerm-<version>-build-<build>-arm64.zip`
- `appcast.xml`
- `release-notes.html`
- `CHECKSUMS.txt`
- `release-manifest.json`

The Draft requires human confirmation before publication. Candidate apps, packaged ZIPs, and assets downloaded again from GitHub undergo the same resource checks. Publishing the GitHub Release triggers `.github/workflows/deploy-update-site.yml`, which checks the downloaded ZIP again before Cloudflare deployment. Production acceptance still requires updating an existing app through Sparkle and completing manual checks; directly replacing `/Applications/MyTerm.app` is not a substitute.

After all manual acceptance is complete and the corresponding plan is ready to close, run:

```sh
./scripts/cleanup-build-artifacts.sh \
  --version X.Y.Z \
  --build <build> \
  --apply
```

Cleanup accepts only a production version that is GitHub's latest non-Draft, non-prerelease release. It downloads the five assets into a system temporary directory and fully verifies them. It refuses deletion if processes cannot be listed or an app is still running from the checkout's `build/`. It removes only the entire `build/` directory, not `/Applications/MyTerm.app`, Application Support, Keychain, `Config/Local/`, signing/recovery material, or SwiftPM dependency caches.

### Production deployment protection

The update-site workflow runs only in `crazy01100/myterm`. Manual redeployment must select `main` and an existing `release_tag`; release publication can still trigger it from a release tag. The deployment job declares `environment: production`, selects Node 24.21.0, and downloads and verifies existing signed assets before deployment.

An administrator must separately configure required reviewers in GitHub's `production` environment, allow only the `main` branch and `v*` tags, and disallow bypassing protection rules. A sole maintainer may approve deployments they triggered; this is an explicit deployment confirmation, not a second-person review. Declaring an environment does not create approval rules or restrict workflows that do not reference it.

Store `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` as production environment Secrets. An administrator enters the existing values securely, without putting them in source, command records, or Issues. After verifying deployment through that environment, remove repository-level Secrets with the same names so jobs outside production cannot keep using the original credentials. Workflows on older tags may lack the environment binding; redeploy through the current main entry point without changing old tags or signed assets.

These settings must be enabled and verified remotely; source files do not prove enforcement. Before making the repository public or later returning it to private, check whether the current plan supports the required rules and environment Secrets. GitHub Free ignores existing environment protections and Secrets after conversion to private. See [GitHub environment documentation](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments).

## Signing and secrets

Safe to commit:

- Signing and deployment scripts
- Sparkle public keys and public designated-requirement baselines
- Configuration examples without credential values

Never commit:

- Code-signing private keys, `.p12` files, Keychain exports, or encrypted-backup passwords
- Sparkle Ed25519 private keys
- Google OAuth client secrets, Firebase tokens, or Cloudflare tokens
- Production Firebase Project IDs hard-coded into examples, `.firebaserc`, or shared npm scripts
- Sync passphrases, recovery keys, host passwords, or real host inventories
- Local `.env` files, actual Firebase settings, or `build/` output

Shared scripts may describe how to obtain or use local credentials, but must not embed them. Derive personal paths from the project root or pass them as arguments.

## Codex skills and source code

The local `release-myterm` skill is a safety manual for Codex operating MyTerm releases. It is neither a build dependency nor part of this repository.

This guide and script `--help` output are the authoritative GitHub instructions for human developers. Testing, candidate preparation, and Draft creation must be possible using these documents and scripts without installing a Codex skill.

## Troubleshooting

### The app still looks like an old version

Do not rely on the Dock icon or app files on disk. Check the actual executable path, version, and Build first. The correct executable for daily testing in the primary checkout is:

```text
build/dev/MyTerm Dev.app/Contents/MacOS/MySSHClient
```

### Can a test build overwrite production?

No. Development scripts restrict output to `build/dev/`, `build/candidates/`, or `build/update-lab/`. Production changes only through a user-initiated Sparkle update or an explicitly authorized production installation.

### Why is `build/MyTerm.app` prohibited?

It identifies neither development, candidate, nor production and makes it easy to confuse builds on disk with running processes. Scripts reject this path.

### Does the release script publish immediately?

No. `release.sh` creates at most a Draft. Public release, production update-site deployment, and in-app update acceptance have separate human confirmation gates.

Dependency alerts, isolated tests and public-key deployment verification: [Security maintenance](SECURITY_MAINTENANCE.en.md).

<a id="python-runtime"></a>
## Python tool environment

Project administration, tests, and release scripts use an upstream-supported stable Python 3.12 or newer through `./scripts/project-python.sh`. It selects an explicit `MYTERM_PYTHON`, the project environment at `.build/python-runtime/bin/python3`, or a supported interpreter on PATH, in that order. It rejects versions below 3.12 and does not replace the system Python.

With Python 3.12 installed, create an isolated environment at the repository root:

```sh
python3.12 -m venv .build/python-runtime
./scripts/project-python.sh --version
./scripts/setup-security-tools.sh
```

Alternatively, point `MYTERM_PYTHON` to your installed supported interpreter. The minimum-version check does not replace lifecycle review: check official EoL/EoS status during tool updates. Verification packages use the separate `.build/security-tools` environment. Running setup recreates that reproducible directory with the selected Python, installing pinned wheels with verified hashes. App users do not need Python.

Use `./scripts/project-node.sh` for Node/npm. It selects Node 24 LTS from `MYTERM_NODE`, `.build/node-runtime/bin/node`, or an installed Node 24, and gives subprocesses the same PATH. `./scripts/project-node.sh --npm ci` avoids an EoL odd-numbered system default. Extract the complete official Node 24 distribution into `.build/node-runtime` or select an installed Node 24 executable without replacing global Node. Package engine constraints and `.npmrc` also reject installations on other major versions.

## Build-time sync service notices

Developer-hosted sync is closed to new users; existing users retain sync and source builds still support your own cloud service. `Config/Local/CloudSyncServiceNotice.txt` can describe a distributor’s service; it is embedded as `MyTermCloudSyncServiceNotice` only for cloud-configured builds outside Update Lab. Keep the file out of Git; it is not backend authorization. Rebuild to change the notice; older apps do not receive new text automatically. See [Firebase setup](FIREBASE_SETUP.en.md) for setup and verification.

Sign-in response tests live in `SelfTests/GoogleFirebaseAuthResponseTests.swift` and run through `scripts/run-tests.sh` as part of the isolated regression suite. An ephemeral URLSession with URLProtocol intercepts every request to test sign-in failures inside successful HTTP responses, missing fields, privacy boundaries, and normal sign-in, without production cloud access or real credentials.

Thirty-minute retry deadline/clock cases live in `SelfTests/GoogleSignInRetryTests.swift`. `CloudAccountRecoveryTests.swift` exercises the real store for OAuth reuse, single-flight, cancellation, switching, expiry, and persistence boundaries. `GoogleFirebaseAuthResponseTests.swift` uses synthetic transport to retry Firebase with the same Google credential, without waiting half an hour or touching production accounts. The full entry point remains `scripts/run-isolated-tests.py`.
