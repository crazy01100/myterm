# MyTerm System Architecture

[繁體中文](ARCHITECTURE.md) | **English**

This document describes MyTerm's current public architecture, data flows, and security boundaries. Repository code and configuration are authoritative for implementation and deployment details.

## Overview

```text
MyTerm.app
  SwiftUI / AppKit
    ├─ Hosts and nested groups
    ├─ Settings, import/export, and shortcuts
    ├─ SSH / Terminal / Serial
    ├─ Dual-pane SFTP
    └─ SSH audit Logs (local first, optional encrypted sync)
  System services
    ├─ /usr/bin/ssh + PTY
    ├─ macOS Keychain
    ├─ App-specific known_hosts
    ├─ Local data in Application Support
    ├─ Sparkle updater
    └─ Optional end-to-end encrypted sync

  Optional Google sign-in ── HTTPS ──> Google OAuth
                                         │
                                         v
                                Firebase Authentication
                                         │ Firebase ID token
                                         v (access only with sync enabled)
                                Cloud Firestore (ciphertext only)

  App updates ───────────── HTTPS ──> mtus.lieniapp.work
                                         │ Sparkle appcast
                                         v
                                GitHub Release archive
```

Core MyTerm features do not depend on the cloud. Google OAuth and Firebase Authentication establish the optional cloud account identity. Only after the user separately enables sync does MyTerm use a Firebase ID token to access Cloud Firestore and initialize cross-device sync for host data and finalized Logs.

See [Firebase setup](FIREBASE_SETUP.en.md) for configuration boundaries between the official app, local-only source builds, and independently configured sync backends, including Firebase/Google Cloud prerequisites.

## App components

### User interface

- `Sources/MySSHClient/Views`: the host library, platform badges, editors, terminal, Serial, SFTP, connection audit Logs, and settings.
- `Sources/MySSHClient/Views/AppVisualTheme.swift`: centralized semantic colors for window chrome, sidebar, content backgrounds, cards, selection, hover, and borders. Each role has light/dark values and supplies both `Color` and `NSColor` where needed across SwiftUI/AppKit, preventing hard-coded palettes from drifting between screens.
- `Sources/MySSHClient/Views/TerminalOutputTheme.swift`: terminal backgrounds, normal text, caret, selection, and light/dark 16-color ANSI palettes. `TerminalContainerView` installs the palette and clears SwiftTerm color caches only at creation or an appearance change, without rebuilding the Session/PTY or rewriting output. Existing indexed ANSI text updates while preserving bold and black/white endpoint semantics. The explicit `.xterm` strategy keeps indices 16–255 as standard fixed color blocks/grayscale instead of SwiftTerm's theme-derived `base16Lab` colors; true-color RGB is unchanged. OSC can temporarily override the palette; OSC 104/soft reset restores the installed theme. The next appearance change reapplies that mode's defaults. Arbitrary application-defined foreground/background pairs are not guaranteed to meet the contrast target for the default background.
- `TerminalMessageHighlight.swift` provides two display policies. Before attribute caching, `TerminalNeutralContrast` compensates neutral ANSI foregrounds (0/7/8/15) below 4.5:1 contrast against the actual background. During line construction in the existing renderer, `TerminalMessageHighlight` examines only the first 48 cells and returns one leading-label range and an appearance-specific color. A matched label may override its ANSI/RGB foreground, but subsequent text stays unchanged and selection wins. Wrapped continuations, alternate-buffer content, explicit backgrounds, and concealed/inverse/dim labels do not match. Neutral compensation also excludes conceal/inverse/dim and does not alter RGB or extended colors. It stores no output, changes no parser/buffer/PTY data, and adds neither a stream buffer nor full-scrollback scanning. The switch is stored in channel-specific UserDefaults and updates existing tabs.
- `Vendor/SwiftTerm` tracks a pinned upstream library runtime, MIT license, and library-only manifest. The macOS renderer has only two optional, nil-by-default hooks: foreground-pair transformation and line-range highlighting. Applying MyTerm's hooks invalidates existing color/line caches; it does not replace the drawing backend or change input/selection geometry. See `Vendor/SwiftTerm/UPSTREAM.md` for provenance, local differences, and upgrade checks.
- `Sources/MySSHClient/MySSHClientApp.swift`: app entry point, Settings window, menus, and overall lifecycle.
- Deep navy chrome, mist-blue content layers, and raised cards provide visual hierarchy using the existing system/light/dark appearance preference, without per-host themes. Terminal canvas/ANSI, platform logos, and success/warning/error/cancelled states retain dedicated colors and text/icon semantics instead of being replaced by the general palette.
- SwiftUI owns state, the unified workspace bar in the native macOS toolbar, and the app shell. It hides the native text title and shared toolbar capsule background while retaining system window dragging, resizing, and full-screen behavior. Tabs and content live in different toolbar/content hierarchies, so lightweight AppKit frame readers express their rectangles and mouse events in one window-top-left coordinate system. Tab reordering, four-direction merge previews, and pane detachment all use those coordinates without assuming a fixed toolbar height. A native AppKit split container forms a clearly bounded terminal view region, handling stable pane hosts, live divider tracking, macOS cursors, and terminal resizing. The main window has a larger default size and remains resizable.
- The host-library sidebar contains only Known Hosts and Logs. All hosts, groups, and ungrouped hosts are browsed in the right content area, with a breadcrumb rooted at All Hosts. The library, SFTP host picker, and both file lists share hover feedback, immediate single-click selection, and double-click opening of groups/folders or connections. All Hosts also allows dragging a host onto a group card. Dropping creates only a confirmation request; `HostStore` writes after confirmation. Group-detail pages and the left sidebar do not accept these drops.

### Hosts and local data

- `HostStore` persists hosts and nested groups, validates and moves hosts between groups transactionally, and uses a separate `HostConnectionRecencyIndex` to order library cards. Local file permissions restrict access to the current user. Moving a host preserves its UUID and changes only `groupID`/`updatedAt`, keeping passwords, platform, and recent-use associations intact. `HostLibraryDragMonitor` is active only while All Hosts is visible, no group is open, and no move confirmation is pending. It stops when Terminal or another view covers the library, a group opens, or confirmation appears, preventing invisible cards from intercepting other views' drags. It tracks drags that begin on host cards within the current window and compares the pointer against full group-card rectangles reported by SwiftUI; cards retain ordinary click/double-click/context-menu handling. AppKit resource lifetime is separate from SwiftUI drag state: window teardown, coordinator deallocation, or monitor replacement removes event tokens and internal tracking without writing back to SwiftUI state being destroyed. Only cancellation while the view is alive notifies SwiftUI to clear its drag state.
- `LocalSecretVaultStore` stores sign-in state, the sync master key, and host passwords in one local AES-GCM vault, with only one random root key in macOS Keychain. Production, development, and update-lab use different vault root keys. Only production can migrate early production sessions; isolated channels do not read old production refresh tokens.
- `KeychainStore` still locates passwords by host UUID but operates only on the unified vault. Host records contain no passwords.
- `KnownHostsStore` manages MyTerm's dedicated trust file. Users may also manually load a snapshot of local `~/.ssh/known_hosts`.
- `AppShortcutStore` stores shortcuts that apply only within MyTerm.
- Font zoom uses the same store. Default equals/plus and numeric-keypad aliases share matching and conflict rules and are released when an action is disabled or customized. A one-time migration adds unoccupied default zoom bindings while preserving existing customizations and disabled actions. Resetting one action to default also checks conflicts.
- `TerminalWorkspaceCollection` holds runtime visual tab order, active pane, split direction, and ratio. Each workspace is constrained to one or two terminal sessions. Detaching either session creates an independent tab and reduces the original workspace to a single pane.
- `TerminalSessionPresentation` contains runtime display rules independent of SwiftUI/SwiftTerm: session state maps to connection indicators, stable same-name numbers are assigned by base name independently of reordering/merging, and Session UUID sets aggregate unread output for background workspaces. Numbers and unread state stay in memory and never change host names, Logs, sync, or exports.
- `ConnectionAuditStore` uses a separate versioned document for interactive SSH host/account/source-device snapshots, start/authentication/end times, and structured outcomes. A known platform is captured at connection start. If initially unknown, the first platform subsequently identified by that terminal session may fill the same record once; it is not overwritten later or backfilled into other historical records from the current `HostStore`. A background serial queue saves records with limits of 30 days and 5,000 entries. Damaged files are isolated as backups, allowing the app to start with empty Logs. These records are separate from `HostStore` and host exports.
- `AutomaticConnectionAuditSyncStore` independently coordinates Logs download, deduplication, encrypted upload, and retention cleanup when existing sync is enabled and a master key is available. Active connections remain on their source device. Completion, failure, cancellation, or launch-time recovery as incompletely ended produces an immutable final record encrypted by `ConnectionAuditSyncCodec` and written through `FirestoreConnectionAuditBackend` to its own collection. Network work is outside PTY, keyboard, and terminal-output paths.

### Connections and terminal

- SSH uses macOS `/usr/bin/ssh`; MyTerm creates a pseudo-terminal and displays the interactive session.
- Interactive SSH sessions derive structured stages from a private OpenSSH verbose log. `SSHConnectionLogParser` handles CR/LF/CRLF. Debug output is used only for internal classification; visible/copyable information is limited to allow-listed Traditional Chinese summaries and original non-debug OpenSSH errors, with local paths/agent information redacted. Only actual OpenSSH authentication success transitions a session to connected and updates its local recent-success time; failure, cancellation, or tab creation does not. A stopped SSH connection uses the same in-place retry entry point from the failure-screen button or Enter in the active terminal. It retains `TerminalSession`, the SwiftTerm view, workspace, and normal scrollback while rebuilding the PTY, OpenSSH arguments, temporary diagnostics, parser, and password-prompt state. Remote shell state is not restored locally. Success releases diagnostics in memory; temporary files from abnormal exits are cleaned up at the next launch.
- `SessionManager` owns terminal-process lifetimes and organizes sessions into reorderable workspaces, while managing same-name numbers and unread-output sets. `LoginAwareTerminalView` reports activity only when process output actually reaches the renderer. Visible-workspace output creates no unread indicator. A background workspace publishes only its first read-to-unread transition, avoiding repeated toolbar redraws under heavy output; selecting it clears child unread state. The manager sends each process attempt's start, actual authentication success, failure, cancellation, and end to `ConnectionAuditStore`. In-place reconnect preserves the pane session ID, but `ConnectionAuditIndex` treats that ID as idempotent only for the current active attempt. A reconnect after finalization creates a new record UUID, keeping Logs/sync records per connection attempt. Dragging a tab into content normally targets the preceding workspace, or the following workspace for the first tab, and permits horizontal/vertical merges. Dragging a pane title back to the tab bar detaches it. Merge, detach, direction changes, and divider adjustment neither restart processes nor create audit records.
- `TerminalWorkspaceSplitContainer` retains a stable pane host for each running session. Native `NSSplitView` updates child frames directly during dragging and sends the final ratio to `TerminalWorkspaceCollection` only when dragging ends, avoiding publication of the entire SwiftUI workspace on every mouse event. A separate `NSSplitViewDelegate` proxy, strongly retained by the split view, enforces 25%–75% boundaries. The delegate does not point back to the split view itself, avoiding recursive responder queries during AppKit sidebar-action validation.
- `TerminalContainerView`/`LoginAwareTerminalView` preserve SwiftTerm's native buffer and TUI mouse reporting. With remote mouse mode off, ordinary or continuous output does not clear existing local selection. With Vim/tmux mouse reporting enabled, ordinary clicks, drags, and scrolling go to the remote program; Shift-drag retains SwiftTerm's local selection. The content uses an I-beam and temporarily hides the system pointer during scrolling to avoid arrow/I-beam alternation. The caret is steady, and a remote hide/show batch applies only its final visibility. In default Vim without mouse reporting, alternate-buffer wheel fallback sends directional steps frame-by-frame through a display link and coalesces intermediate responses. Physical keyboard events, normal shell scrollback, and enabled remote mouse reports bypass that path.
- System-default mode follows OpenSSH's modern algorithm policy. RSA compatibility and custom options apply only to the specified host.
- Local Terminal launches `/bin/zsh` as a login shell in the current user's home directory.
- `TerminalSession.terminalFontSize` stores a 10–32 point font size only for the session lifetime, defaulting to 14. Zoom checks that the terminal owns keyboard focus and no modal/sheet is open before using `TerminalFontSizePolicy`. When the size changes, `TerminalContainerView` applies it through `TerminalFontZoom.swift`: it temporarily uses a zero-sized frame synchronously to skip the soft reset attached to SwiftTerm's font setter, then restores the frame and follows normal resize handling to notify the PTY of rows/columns. Processes, cursor modes, and scrollback survive. A font change clears current selection; later selection uses the new geometry. Sizes are absent from hosts, Logs, sync, and exports, and do not survive app restart.
- Serial validates and connects to `/dev/cu.*` or `/dev/tty.*`, passing arguments directly to fixed system executables without shell interpolation.
- SFTP handles browsing, transfer, overwrite confirmation, and basic file management. Shared `SFTPPermissionMode` formats POSIX permissions already obtained from local FileManager or SFTP v3 attributes as symbolic/octal values, without per-entry extra `stat` or SFTP requests. The visual permission matrix and octal input share one state and use existing local/remote chmod flows, reloading actual attributes on success. Unknown permissions are not assigned defaults. Local/remote file dragging uses private types declared in the app bundle and conforming to `public.data`; candidate/release verification rejects missing declarations. Host-library group moves instead use only mouse events and card rectangles in the current MyTerm window, with no externally accepted drag payload. Authentication shares host settings and vault boundaries. The local browser resolves navigable symbolic links, keeping OneDrive and other File Provider directories inside the app.
- SFTP uses responsive path breadcrumbs: full paths when space permits, otherwise key leading/trailing directories with intermediate levels in an `…` menu. It avoids a horizontal scrollbar that covers text.
- Platform detection first passively parses terminal output. Unknown hosts may receive a background read-only SSH probe for operating-system information. Results are stored in host data and drive shared SVG badges in the library, SFTP picker, tabs, and terminal panes. An unknown platform in the same session's Logs snapshot is likewise filled only with the first trusted result.

## Data storage

| Data | Location | Cross-device behavior |
|---|---|---|
| Hosts and groups | Permission-restricted files in Application Support | Encrypted when sync is enabled |
| Recent successful SSH times | Separate `0600` file in Application Support, containing only host UUIDs and times | Neither synced nor exported |
| SSH audit Logs | `0600` `connection-audit-log.json` in Application Support; connection-time host, account endpoint, source device, times, and outcome; up to 30 days/5,000 entries | Only finalized records sync as ciphertext; not exported |
| Host passwords | Local AES-GCM vault; root key in a `WhenUnlockedThisDeviceOnly` Keychain item | End-to-end encrypted for sync; the destination Mac decrypts into its own vault |
| Master key and sign-in state | Same local vault and single Keychain root key as host passwords | Not directly synced |
| Private-key files and paths | User-selected local files/settings | Not synced |
| MyTerm `known_hosts` | Each Mac's Application Support | Not synced |
| Temporary SSH diagnostics | Short-lived `0600` files in Application Support; removed on success, failure, or close, with crash leftovers cleaned at next launch | Not synced |
| Exports | User-selected location | Not automatically synced by MyTerm |

The production display name changed to MyTerm, but its Bundle ID, Keychain services, and Application Support identifiers retain their old names for upgrade compatibility and password associations. `MyTerm Dev.app` has its own Bundle ID, Application Support directory, and vault Keychain service. Development acceptance must not access production data or inherit its Google session. If an older Dev build mistakenly imported a production session, the isolated channel performs one-time cleanup; subsequent explicit Dev sign-ins are retained normally.

## End-to-end encrypted sync

`AutomaticSyncCoordinator` owns daily scheduling. After account restoration, `VaultSetupStore.prepareForAutomaticSync` initializes the existing local vault without waiting for a Settings scene. The coordinator invokes independent metadata/password and Logs workers concurrently and waits for both. A conflict awaiting confirmation does not block Logs, but cannot count as a successful full round. Hosts/passwords and Logs retain their existing encryption and collections.

AppKit active/inactive events control the single five-minute foreground cycle. Launch, wake, local changes, and a stale Logs view also request sync. Local changes are coalesced over about 1.2 seconds; requests during a run are merged into a subsequent round without repeatedly postponing current work. Temporary failures wait for the existing cycle or an explicit foreground/wake/manual trigger; there is no short-interval backoff timer, and ordinary data/state changes after failure do not create tight retry loops. A 120-second round deadline cancels and waits for both workers to release without scheduling a separate retry. Disabling sync or changing accounts cancels the old generation; workers check cancellation at network-response and local-application boundaries, so an old generation cannot publish success for a new account.

`CloudAccountStore` restores sign-in with a single-flight task and initial/retryableFailure/blocked/restored states. Only temporary network/service errors are eligible for a later cycle's retry. `SyncSettingsStore.sessionRecoveryEnabled` remembers the last known account's sync choice to decide whether recovery is allowed while sign-in is unavailable; it does not enable data sync while signed out. Five-minute, foreground, wake, or manual triggers first attempt eligible recovery and continue with sync on success. Availability callbacks do not recursively request sign-in. Explicit sign-out, disabled sync, missing credentials, and permanent invalidation prevent periodic recovery. The normal one-time session restore at launch is independent of sync enablement. Google ID token refresh uses a shared single-flight task, and account-generation checks reject responses arriving after sign-out.

`ConnectionAuditStore` retains unsaved revisions so disk writes can be retried even after downloaded records have been deduplicated in memory. The Logs worker waits for `persistForSync` to succeed before reporting completion. Worker and full-round success times are stored by account digest in channel-specific UserDefaults. Daily sync settings show only the overall status and one full-round success time, not worker details. Cancellation, partial failure, and no prior success cannot be presented as full completion. `SyncDiagnosticsJournal` stores only bounded, allow-listed local execution events, separate from sync data and connection audit Logs. Diagnostic tools are collapsed by default.

Sync is optional and follows this flow:

1. The user signs in through Google Desktop OAuth. PKCE, state, nonce, and a temporary callback bound only to `127.0.0.1` reduce authorization-code interception risk.
2. A sync passphrase derives a protection key with Argon2id to unlock or create the master-key envelope.
3. Each host, group, password, and finalized Logs record is encrypted with AES-256-GCM. Host/account/address/source-device/time/outcome details in Logs all reside inside ciphertext.
4. Firebase Authentication establishes account identity; Firestore Security Rules limit the current UID to correctly formatted encrypted paths.
5. Another Mac uses the same account and passphrase to unlock the master key and write decrypted passwords into its own local vault.
6. Hosts, groups, and group membership sync as encrypted metadata revisions. Sync Now uploads/fetches only on the current device. Other Macs fetch on their own manual, foreground, or periodic events, without cross-device realtime UI push.

Firestore stores no plaintext host or Logs contents, source-device names, sync passphrases, master keys, or decrypted passwords. A recovery key provides an independent way to recover when a passphrase is lost; MyTerm does not keep its plaintext on the user's behalf.

Host/group deletions propagate as AES-256-GCM-authenticated tombstones containing a revision and device identity. Applying a remote deletion first creates a local recovery backup.

Logs use separate immutable documents at `users/<UID>/connectionLogs/<record UUID>`, not host metadata snapshots or tombstones. Each sync obtains server time from the Firestore HTTP response, excludes local records older than 30 days, uploads missing final records, and cleans up expired ciphertext. Offline devices cannot revive expired records when reconnecting. There is no individual-delete or clear-all UI; cloud deletion permission supports only this fixed retention cleanup.

## SSH password flow

- Saved SSH login passwords are automatically sent to the PTY only at the first login `password:` prompt and when the configured account matches.
- Without a saved password, MyTerm temporarily captures the entry and offers to save only after OpenSSH diagnostics confirm successful `password` authentication. If the initial automatic saved-password attempt fails, subsequent prompts capture manual input, with the same OpenSSH evidence required before offering replacement.
- Forced password changes use a separate state machine. Only after recognizing the current-password prompt does it privately capture a new password and confirmation. Both entries must match in constant time, and the remote must explicitly report success before an offer to overwrite the local vault. Candidate buffers are overwritten and released on failure, cancellation, mismatch, declined saving, or session cleanup.
- `keyboard-interactive` input is not treated as a saveable password, avoiding accidental storage of OTPs or one-time challenges.
- Later `sudo` / `su` prompts are separate from SSH login callbacks. MyTerm permits only manual one-click filling at recognized prompts.

## Updates and releases

```text
Development Mac
  └─ Tests, arm64 Release build, stable local certificate, Sparkle Ed25519 signing
       └─ Private GitHub Draft Release
            └─ Human review and publication
                 └─ GitHub Actions
                      ├─ Download and verify five Release Assets
                      ├─ Direct Upload to Cloudflare Pages
                      └─ Externally recheck site, appcast, ZIP, and security headers
```

- GitHub Releases store the production ZIP, `appcast.xml`, release notes, checksums, and manifest.
- Cloudflare Pages serves installation instructions, release notes, and the Sparkle feed. No Cloudflare Worker is required.
- Sparkle verifies updates with the Ed25519 public key embedded in the app. Altered, incorrectly signed, or incomplete archives are rejected.
- Build scripts copy MyTerm's platform SVG icons to standard `Contents/Resources/PlatformIcons`. Runtime loading uses only `Bundle.main`, avoiding the executable target's `Bundle.module` accessor and its embedded build-machine fallback path. Candidate apps, packaged ZIPs, GitHub re-downloads, and pre-Cloudflare deployment checks verify the same icon contents and reject unsafe MyTerm SwiftPM resource accessors.
- Sparkle does not require the literal `/Applications` path, but refuses updates from App Translocation, read-only images, temporary locations, or places where the app cannot be replaced. Production installation places `MyTerm.app` in Applications first; apps under the checkout's `build/` are for testing only.
- Apple Developer ID is not currently used, so the first manual download may require macOS user approval. Free self-signed certificates have no Apple Team ID, and Keychain may regard each build as a new identity. One encrypted vault and one Keychain root key keep post-update verification from increasing with the number of hosts. This does not replace Sparkle signature verification.

## Repository structure

| Path | Purpose |
|---|---|
| `Sources/MySSHClient` | App source |
| `Sources/MySSHClient/Resources/PlatformIcons` | Built-in OS/network-platform SVG badges |
| `SelfTests`, `Tests` | Core, crypto, OAuth, and Firestore Rules tests |
| `Resources` | App icons, Info.plist, and test resources |
| `Config` | Shareable configuration examples and Sparkle public key |
| `scripts` | Build, test, package, release, and verification tools |
| `.github/workflows` | Cloudflare deployment after a GitHub Release is published |
| `update-site` | Cloudflare Pages static source |
| `firebase.json`, `firestore.rules` | Firebase Emulator and production security rules |

`build/`, SwiftPM caches, `node_modules/`, local Firebase settings, OAuth secrets, user exports, and internal plans are not public source files.

## Current limitations

- Supports only macOS 26 and Apple Silicon arm64.
- Private keys, their paths, and `known_hosts` do not sync between devices.
- `sudo` / `su` require a button or shortcut; passwords are not submitted automatically.
- Logs record only interactive SSH metadata for connections created from the host library. They exclude local Terminal, SFTP, Serial, commands, and terminal output, and cannot backfill history from before the feature was enabled. Only finalized records sync; other devices' active connection status and timers are not shown.
- Sync is triggered by launch, foreground, wake, local changes to synced data, stale Logs views, and foreground periodic events, not a persistent push service. Another Mac's changes apply at the next local trigger. There is no continuous polling guarantee while the app is closed, asleep, or inactive.
- Apple Developer ID and notarization are not currently used, so macOS may warn that it cannot verify the developer at first installation.

## Security control components

`SFTPCancellation` retains a lock-protected cancellation action before protocol initialization. The transport polls nonblocking pipe descriptors with monotonic deadlines; cancellation does not wait for the serial operation lock or close/reuse descriptors while an operation owns them. Browser generation checks prevent an old connection from replacing current state.

`dependency-inventory.py` reads the Swift lockfile, Vendor revision and reviewed native binary metadata. `bind-release-metadata.py` binds that inventory and the source commit into the feed before signing. `verify-signed-release.py` verifies the original feed bytes with a trusted public key before trusting URLs or extracting the archive, and checks notes plus all five release assets. `security-audit.py` separately checks current and released dependencies; signatures establish provenance, not freedom from vulnerabilities. Operational requirements are in [Security maintenance](SECURITY_MAINTENANCE.en.md).

Private monitoring maps complete successful scans to bot-owned private Issues using `sync-security-issues.py`, deduplicated by advisory/component/scope. Only default-branch scheduled/manual jobs receive issues:write. Monitor execution health is distinct from risk presence; separate PR/release gates preserve security blocking.

`render-release-notes.py` is the shared release-note HTML generator for private/public distributions. It preserves text escaping and authored sections while normalizing the version heading. Dedicated release-notes.css handles narrow light/dark presentation; HTML remains signed and verified through the existing pipeline and contains no website navigation.
