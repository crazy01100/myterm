# MyTerm

[繁體中文](README.md) | **English**

<p>
  <a href="https://openai.com/brand/">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="Resources/Readme/openai-blossom-white.svg">
      <img src="Resources/Readme/openai-blossom-black.svg" alt="OpenAI" width="48" height="48" align="middle">
    </picture>
  </a>
  <strong>Developed with GPT-5.6 · GPT-6 Astra</strong>
</p>

MyTerm is a macOS SSH management tool whose code was primarily implemented by GPT-5.6 and GPT-6 Astra. My role is to define requirements, guide the product, and test and refine it through everyday use.

The project grew out of a personal need: managing different kinds of hosts across multiple Macs while keeping host settings and login passwords in sync, without entrusting readable passwords to another software developer. MyTerm therefore combines a local encrypted vault with optional end-to-end encrypted sync: the cloud stores ciphertext, and my own Macs decrypt it for use.

This is an independent personal project, not endorsed or sponsored by OpenAI. The attribution above identifies the tools used during development. The OpenAI logo belongs to OpenAI; see the [asset source and usage terms](Resources/Readme/NOTICE.md).

MyTerm is a native SSH management app for **Apple Silicon and macOS 26**. It brings host management, SSH, a local terminal, serial connections, and a dual-pane SFTP browser into one app. All local features work without signing in.

Latest stable release and downloads: [GitHub Releases](https://github.com/crazy01100/myterm/releases/latest).

- [Download and installation](https://mtus.lieniapp.work/install/)
- [Release notes](https://mtus.lieniapp.work/)
- [Development and release guide](DEVELOPMENT.en.md)
- [Set up your own Firebase sync backend](FIREBASE_SETUP.en.md)
- [Migrate host metadata from Termius](TERMIUS_MIGRATION.en.md)
- [System architecture](ARCHITECTURE.en.md)
- [Security design](SECURITY.en.md)

The linked project guides are available in English, with language links to their Traditional Chinese counterparts. The app interface and update website remain in Traditional Chinese. English menu descriptions below refer to the corresponding Chinese controls.

## Features

- Open Quick Actions from View → Quick Actions or the default `⌘K` shortcut to search hosts by name, address, username, or group, switch to open sessions, or open SFTP, Terminal, Serial, Known Hosts, and Logs. Moving the pointer over a result highlights and selects it; arrow keys also change the selection. Click or press Enter to open, and Esc to dismiss. Hosts with open sessions lead to existing panes; selecting a disconnected session does not reconnect it. Customize or disable the binding in Settings → Shortcuts → Sessions. If an existing action already uses `⌘K`, upgrading preserves that assignment. Search queries are neither saved nor synced. Host results reuse identified platform icons; unidentified hosts keep a generic icon, and opening the panel does not probe hosts.
- Enter `ops@192.0.2.10` or `ops@server.example.com:2222` in Quick Actions and select Temporary Connection to open SSH. The default port is 22; use `ops@[2001:db8::10]:2222` for IPv6. System SSH Agent/config and password prompts apply. This does not add a saved host or save/replace MyTerm passwords. Use a saved host for custom key files or algorithms. Normal Logs (including encrypted sync when enabled) and confirmed host fingerprints are retained.

- Organize hosts into nested groups, search your inventory, browse host cards, and optionally set a default username. The host library places the most recently authenticated SSH hosts first and keeps a stable order for hosts without a successful connection. In the All Hosts view, drag a host card onto a group card and confirm to move it.
- Authenticate with a password, private key, SSH Agent, or SSH config. Use system-default algorithms, legacy RSA compatibility, or per-host custom algorithms.
- Connect through the system OpenSSH client and a dedicated MyTerm `known_hosts` file. New host keys require user confirmation.
- View connection-stage summaries in Traditional Chinese and error details that preserve OpenSSH's original wording. Verbose debug output is used only to identify connection stages; it is not displayed or copied. Error details redact local paths and sensitive information. Failed connections classify common network, authentication, host-key, private-key, and algorithm issues, with actions to retry, edit the host, or copy diagnostics. After an authenticated connection drops, press Enter in the same tab to reconnect while keeping local terminal scrollback. Diagnostics are released on success, and temporary files left by an abnormal exit are cleaned up at the next launch.
- Open Logs from the host page to search and filter interactive SSH connection records. Records include connection time, duration, the host and account endpoint at the time of connection, source device, and outcomes such as in progress, completed, failed, cancelled, or ended incompletely. Logs contain no commands or terminal output and retain only the most recent 30 days.
- Store host passwords in a local AES-GCM encrypted vault, with only its root key in macOS Keychain. Passwords are kept out of the host inventory and are never filled through the clipboard.
- Use one workspace bar at the top of the window for hosts, SFTP, SSH tabs, local zsh, and serial sessions. Terminal tabs show connection status, stable numbers for sessions with the same name, and a separate indicator when a background workspace receives output. Drag tabs to reorder them; keyboard shortcuts follow their visual order.
- Drag a terminal tab down into an adjacent connection's content area to merge them into a horizontal or vertical split, following the green preview. A tab normally targets the preceding connection; the first tab targets the following connection. Each workspace supports at most two sessions. Drag the divider to resize panes, focus or close each pane independently, or drag a pane's title back to the tab bar to detach it.
- Use a text-selection pointer and a steady, non-blinking terminal caret. Drag, double-click, or triple-click to select text in a shell, `cat`, or continuous output. When Vim, tmux, or another application enables mouse reporting, ordinary clicks, drags, and scrolling go to that application. Shift-drag still forces local text selection in MyTerm.
- Increase terminal font size with `⌘+` / `⌘=`, decrease it with `⌘−`, or reset it to 14 points with `⌘0`. Changes use one-point steps within a 10–32 point range and affect only the active pane. Each session retains its size across tab switches, merges, detachments, and reconnections; new sessions use the default. Customize, disable, or reset these actions under Settings → Shortcuts → Terminal. The default bindings also support numeric keypad plus, minus, and zero. Terminal line spacing is fixed at 1.15 times the renderer baseline and retains that multiplier when zooming.
- Upload and download through SFTP with overwrite confirmation, folder creation, rename, delete, and permission editing. Local and remote lists show symbolic POSIX permissions below each filename. Edit permissions with an owner/group/others read/write/execute matrix or octal values. Drag files or folders from Finder into the remote pane to upload them to the current remote directory. The local pane can navigate symbolic-link folders such as OneDrive locations within the app.
- Use consistent hover feedback, single-click selection, and double-click opening in the host library and SFTP. Deep SFTP paths keep key levels visible and collapse intermediate directories into an `…` menu.
- Use a shared blue-and-white color system throughout the window, sidebar, host cards, Logs, SFTP, terminal workspaces, and settings, with system, light, and dark appearance options. Terminal ANSI colors, platform logos, and success/warning/error colors retain their distinct meanings.
- Switch the terminal's 16-color ANSI palette with the app appearance: light backgrounds use darker yellow, green, blue, and other foregrounds, while dark backgrounds use softer bright colors. Existing colored output updates as well. Black, gray, and white text receives display contrast compensation when needed, while white text on black stays bright. Inverse, hidden, and dim effects are preserved. Extended colors at indices 16–255 use the standard fixed xterm palette.
- Toggle terminal message-label highlighting under Settings → Appearance. At the start of a line, `[資訊]` / `[INFO]` labels appear blue, warnings orange, pass labels cyan-blue, success green, errors red, debug purple, and hints blue-gray. Only the label changes; the following text and copied content stay intact, and unmatched RGB text keeps the application's specified color. Matching requires a complete label within the first 48 character cells and excludes wrapped continuation lines, full-screen terminal applications, custom backgrounds, inverse, dim, and hidden labels. Colors are a visual category, not proof that a message is true or a command succeeded.
- Import MyTerm or Termius host metadata with a selectable preview, and export MyTerm host metadata. See [Termius migration](TERMIUS_MIGRATION.en.md) for supported data and the optional conversion tool.
- Customize or disable shortcuts that apply within the app. Saved passwords can only be filled at recognized safe password prompts. If the initial automatic login password fails, MyTerm offers to replace it only after OpenSSH confirms that the next manually entered password authenticated successfully. For a forced password change, both new entries must match and the server must explicitly report success before MyTerm offers to update the local vault.
- Detect operating systems and network platforms from terminal output, with a read-only background probe for saved SSH hosts that remain unidentified. Temporary connections use only passive detection from existing output. The host library, SFTP picker, connection tab, terminal title, and that connection's Logs record use consistent platform badges.
- Install stable releases through Sparkle's secure updater using MyTerm → Check for Updates.

## Optional cross-device sync

Developer-hosted sync is currently unavailable. To use the sync capabilities below, follow the guide to set up your own service and build MyTerm.

Sync is off by default. To sync hosts, groups, host passwords, and finalized Logs, sign in with Google, enable sync, and set a sync passphrase.

When Google verification succeeds but the sync service has not enabled the account, “重新嘗試” (Try Again) retries the sync-service sign-in directly for up to 30 minutes while the Google credential remains valid. You can also choose “使用其他 Google 帳號” (Use Another Google Account). Expiry, quitting the app, or signing out requires a new Google sign-in.

- Each record is end-to-end encrypted on your Mac with AES-256-GCM before it is sent to Firebase.
- The sync passphrase derives a key using Argon2id. The master key and decrypted passwords are stored only in each Mac's local encrypted vault.
- Firebase stores ciphertext and necessary version information; it cannot directly read host contents or passwords.
- Logs sync only after a connection completes, fails, is cancelled, or is recovered as having ended incompletely. Live connection status and timing remain on the originating Mac and are not continuously sent to other devices.
- Sync Now uploads and fetches data on the current Mac. Other Macs receive changes when they sync manually, return to the foreground, or run their own periodic sync; the source device does not push UI state directly to them.
- Hosts, groups, passwords, Logs and snippets share one schedule. Launch, foreground, wake, and local changes to synced data request a sync, with another sync every five minutes while the app is active. Opening Logs also requests an update if the last successful full sync is over 60 seconds old or no sync has succeeded yet. Sync is not guaranteed while the app is closed or the Mac is asleep.
- Settings shows one overall status and one last-success time. That time advances only when hosts, passwords, Logs and snippets all finish in the same round and received data has been saved locally. Temporary failures wait for the existing five-minute foreground cycle; there is no additional short-interval retry. Incomplete work is never reported as a successful round.
- If a network problem prevents sign-in restoration at launch, a later sync cycle first tries to restore the session with the saved credentials, then syncs data. Foreground, wake, and manual sync can also trigger recovery. Explicit sign-out, disabled sync, invalid credentials, or missing credentials prevent periodic recovery attempts. Disabling sync does not change the normal one-time sign-in restoration at app launch. Local data remains available while offline.
- Account & Sync → Diagnostics → Copy Sync Execution Log provides up to seven days of local triggers, processing stages, and error codes for troubleshooting. Diagnostics is collapsed by default, contains no hosts, accounts, passwords, or terminal content, and is not uploaded automatically.
- Private-key files, private-key paths, and `known_hosts` always remain local to each Mac.
- Disable sync at any time and continue using the app locally.

The developer-hosted cloud sync service uses a free plan and, due to its capacity limits, is currently unavailable. To use cloud sync, follow the [project guide](FIREBASE_SETUP.en.md) to set up your own service and build MyTerm. Local features do not require Google sign-in.

## Requirements and installation

- Apple Silicon Mac (arm64)
- macOS 26 or later

After downloading and extracting the archive, move `MyTerm.app` to Applications before launching it. Do not run it directly from an archive, disk image, temporary download location, or read-only location. macOS App Translocation or a location where the app cannot be replaced can prevent Sparkle from completing updates.

The project is not currently enrolled in the Apple Developer Program, so macOS may warn that it cannot verify the developer on the first manual download. After verifying the source, allow the app once in System Settings → Privacy & Security. The self-signed certificate has no Apple Team ID and cannot guarantee Keychain identity continuity across builds. All local secrets share one encrypted vault so that the number of Keychain approvals required after an update does not grow with the number of hosts. In-app updates separately verify Sparkle Ed25519 signatures.

## Getting started

1. Use `+` to create a group or host. If the host name is blank, its address is displayed instead.
2. Leave the default username blank if you prefer to choose an account when connecting.
3. Keep system-default algorithms for ordinary hosts. Enable RSA compatibility or custom algorithms only for confirmed legacy-device requirements.
4. Double-click a host card to open an SSH tab. Verify a new host fingerprint through a trusted channel before accepting it.
   After authentication succeeds, the host moves to the front of the All Hosts view, its group, and matching search results. Failure or cancellation does not affect ordering. This recent-use order is local to the current Mac and does not change the SFTP host picker.
   To move a host, drag its card onto a group card in All Hosts, review the source and destination, and confirm Move. This replaces its existing group, if any. Dropping it onto the same group or cancelling makes no change. Use the All Hosts › Group breadcrumb to return to a parent level.
   If an authenticated SSH connection drops because of a VPN, network, or remote-service interruption, MyTerm keeps its tab and local terminal display. Once connectivity is restored, press Enter in that terminal to reconnect. This preserves local display and scrollback only, not the remote shell's working directory, environment, or processes. Use `tmux` or `screen` when you need to preserve remote work.
5. A saved SSH password is submitted automatically at the first login prompt. If it is rejected, a later successful manual login can be used to update the saved value. When the server forces a password change, complete the current-password, new-password, and confirmation prompts; MyTerm offers to replace the saved value only after the server reports success. Later `sudo` / `su` prompts require the Fill Password button or its configured shortcut.
6. On the host page, Known Hosts opens SSH trust records and Logs opens connection history. Use Return to Hosts on either page to return to All Hosts. Search or filter Logs by host, endpoint, source device, or outcome. Records are read-only and retained for 30 days. With sync enabled, only finalized records are end-to-end encrypted and shared across devices.
7. Terminal opens a local zsh session in your home directory. Serial connects to a `/dev/cu.*` or `/dev/tty.*` device. Drag to select ordinary terminal output. If Vim, tmux, or another program has enabled terminal mouse mode, it receives ordinary mouse actions; hold Shift while dragging to select text locally for copying.
8. SFTP opens the local and remote file panes. Single-click a host, group, or file to select it; double-click to enter a group or folder, or establish a connection. Actual permissions such as `-rw-r--r--` appear below the filename. Choose Edit Permissions from the file menu, verify the full path, then use the permission matrix or octal values such as `644` / `755`.
   You can also right-click a saved host card and choose “Open SFTP” to connect directly. Reopening the same target preserves its connection and directory. Switching targets requires confirmation; finish pending transfers, file operations, or overwrite decisions first. This entry does not follow the SSH shell’s current directory.
   The transfer list spans the bottom of the SFTP workspace. Collapse it, cancel one or all transfers, or clear ended records. For known sizes, a left-to-right fill and percentage show progress alongside speed, estimated time remaining, completion time, and elapsed time. Final file operations are shown as finishing, rather than completed. Directory transfers with unknown total size show neither a percentage nor an ETA. History lasts only for the current app session and retains at most 200 ended items.
   Cancellation waits for the current protocol response. If the server stops responding, “Disconnect SFTP…” stops the entire SFTP connection and unfinished work without affecting SSH terminals. Uploads use a temporary location before publication. Replacing a regular file requires safe-replacement support from the server; same-name remote directories are not replaced wholesale. Rename the upload or enter the directory to transfer individual files. Disconnection may leave temporary items; uncertain final publication is reported for inspection and is never automatically retried.
9. Drag terminal tabs within the top bar to reorder them. Sessions with identical names receive stable `(1)`, `(2)`, and similar suffixes in tabs and pane titles. A background workspace shows a separate blue indicator when new output arrives; selecting it clears the indicator. This means there is unseen output, not necessarily that a remote command has finished. Dragging a tab down into the content area displays the adjacent merge target and a green preview for left, right, top, or bottom placement. Most tabs target the previous connection; the first targets the next. Merged tabs are named Workspace and hold at most two sessions. Resize them with the divider, or drag either pane's title back to the tab bar to detach it.

## Command snippets

Click `{}` in an SSH or local Terminal pane header, search for the snippet library in Quick Actions (default `⌘K`), or use the View menu to open the shared right panel. Save a name, command, category and note, then search and preview before use.

Inserting a single line does not send Enter or clear existing terminal input. Multiline snippets and control characters are copy-only. Alternate screens, hidden cursors or mouse reporting disable insertion until normal terminal state returns; still check that the terminal is ready to receive a command. Split panes share one library. The insertion target follows pane selection by click or keyboard navigation, with its name shown below; interacting with the library retains that terminal. Closing or reconnecting disables the old target until a valid pane is selected again.

Each save immediately persists on this Mac and survives quitting the app. The existing cross-device sync switch also controls snippets: enabling it automatically includes snippets for the current account, with no separate activation. Names, commands, categories and notes are end-to-end encrypted for sync. Offline edits remain local until the existing sync workflow runs; Sync Now affects this Mac, and other Macs pull on their own sync triggers. Self-hosted services must update the [Firestore rules](FIREBASE_SETUP.en.md) first.

Concurrent edits preserve a conflict copy for review: keep and sync it, or delete the copy. Stale offline data does not resurrect a deleted original. Switching accounts does not automatically transfer the previous account's snippets. Dev and production use separate local data, and host exports exclude snippets. The local file is not an encrypted secret vault; do not store passwords or tokens.

## Building from source

You need macOS 26, Apple Silicon, and Xcode 26 or compatible Command Line Tools. The Dev version below is a naming example; replace it with the actual target version when building.

```sh
git clone https://github.com/crazy01100/myterm.git
cd myterm
./scripts/project-python.sh scripts/run-isolated-tests.py
./scripts/run-dev-app.sh \
  --version 1.0.22-dev.1 \
  --build "$(date '+%Y%m%d%H%M%S')"
```

In a source checkout, the test app is built at `build/dev/MyTerm Dev.app`, with a separate bundle ID, Application Support directory, and vault Keychain service. Google sessions are also isolated by channel: Dev does not import the production app's legacy sign-in and requires its own test-account sign-in. The script only closes and relaunches the app at that Dev path; it does not read, write, or change the production app's data for `/Applications/MyTerm.app`. This is a build and process-isolation rule, not a runtime dependency on that directory. If you send a verified Dev app to another Mac for manual testing, `~/Applications/MyTerm Dev.app` is recommended, but any stable, writable local folder is acceptable. Candidates and release assets use version-and-build-specific directories under `build/candidates/` and `build/releases/`. Build output, SwiftPM caches, ZIP archives, and local Firebase/OAuth configuration are not source files and are excluded from Git.

See [DEVELOPMENT.en.md](DEVELOPMENT.en.md) for build channels, scripts, candidate builds, and the release process.

## Data and security boundaries

- The host inventory contains no passwords. All local secrets share an AES-GCM vault whose single root key uses a `WhenUnlockedThisDeviceOnly` Keychain item.
- Host exports are plaintext and may contain addresses, usernames, and notes. Store them securely.
- The MyTerm app does not read the Termius Vault directly. The repository's optional conversion tool handles only compatible host/group metadata, not passwords or private keys. See [Termius migration](TERMIUS_MIGRATION.en.md) for the full limitations.
- Host and group deletions sync as authenticated, end-to-end encrypted deletion markers. MyTerm creates a local recovery backup before applying remote deletions.
- Logs are sensitive usage history containing host names, account endpoints, source devices, times, and outcomes. They are not included in host exports and contain no passwords, commands, terminal input/output, or OpenSSH verbose debug output. Records are read-only and limited to 30 days and 5,000 entries. With sync enabled, finalized records are end-to-end encrypted with the master key before upload; the cloud cannot read their plaintext content.
- `sudo` / `su` passwords are not submitted automatically. Use the button or shortcut at a recognized password prompt.

See [SECURITY.en.md](SECURITY.en.md) and [ARCHITECTURE.en.md](ARCHITECTURE.en.md) for storage details and trust boundaries.

## License

MyTerm's original code and documentation are licensed under the [MIT License](LICENSE), Copyright (c) 2026 LienYi.

Third-party components and assets retain their own licenses and copyright notices, including [SwiftTerm](Vendor/SwiftTerm/LICENSE), the [platform icon attribution](Sources/MySSHClient/Resources/PlatformIcons/NOTICE.txt), and the [OpenAI brand asset notice](Resources/Readme/NOTICE.md). MyTerm's MIT License does not replace those licenses.

Dependency alerts, isolated tests and public-key deployment verification: [Security maintenance](SECURITY_MAINTENANCE.en.md).

Source tests and administration scripts require Python 3.12 or newer through the project launcher; see [Python tool environment](DEVELOPMENT.en.md#python-runtime). App users do not need Python.
