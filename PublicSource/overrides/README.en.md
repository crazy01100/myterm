# MyTerm

[繁體中文](README.md) | **English**

This repository provides source code, build resources, and documentation only. MyTerm is shaped around the maintainer’s personal workflow; build and adapt it for your own needs. No prebuilt app or hosted sync/update service is provided.

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


- [Build, installation, and development guide](DEVELOPMENT.en.md)
- [Set up your own Firebase sync backend](FIREBASE_SETUP.en.md)
- [Migrate host metadata from Termius](TERMIUS_MIGRATION.en.md)
- [System architecture](ARCHITECTURE.en.md)
- [Security design](SECURITY.en.md)

The linked project guides are available in English, with language links to their Traditional Chinese counterparts. The app interface remains in Traditional Chinese. English menu descriptions below refer to the corresponding Chinese controls.

## Features

- Organize hosts into nested groups, search your inventory, browse host cards, and optionally set a default username. The host library places the most recently authenticated SSH hosts first and keeps a stable order for hosts without a successful connection. In the All Hosts view, drag a host card onto a group card and confirm to move it.
- Authenticate with a password, private key, SSH Agent, or SSH config. Use system-default algorithms, legacy RSA compatibility, or per-host custom algorithms.
- Connect through the system OpenSSH client and a dedicated MyTerm `known_hosts` file. New host keys require user confirmation.
- View connection-stage summaries in Traditional Chinese and error details that preserve OpenSSH's original wording. Verbose debug output is used only to identify connection stages; it is not displayed or copied. Error details redact local paths and sensitive information. Failed connections classify common network, authentication, host-key, private-key, and algorithm issues, with actions to retry, edit the host, or copy diagnostics. After an authenticated connection drops, press Enter in the same tab to reconnect while keeping local terminal scrollback. Diagnostics are released on success, and temporary files left by an abnormal exit are cleaned up at the next launch.
- Open Logs from the host library sidebar to search and filter interactive SSH connection records. Records include connection time, duration, the host and account endpoint at the time of connection, source device, and outcomes such as in progress, completed, failed, cancelled, or ended incompletely. Logs contain no commands or terminal output and retain only the most recent 30 days.
- Store host passwords in a local AES-GCM encrypted vault, with only its root key in macOS Keychain. Passwords are kept out of the host inventory and are never filled through the clipboard.
- Use one workspace bar at the top of the window for hosts, SFTP, SSH tabs, local zsh, and serial sessions. Terminal tabs show connection status, stable numbers for sessions with the same name, and a separate indicator when a background workspace receives output. Drag tabs to reorder them; keyboard shortcuts follow their visual order.
- Drag a terminal tab down into an adjacent connection's content area to merge them into a horizontal or vertical split, following the green preview. A tab normally targets the preceding connection; the first tab targets the following connection. Each workspace supports at most two sessions. Drag the divider to resize panes, focus or close each pane independently, or drag a pane's title back to the tab bar to detach it.
- Use a text-selection pointer and a steady, non-blinking terminal caret. Drag, double-click, or triple-click to select text in a shell, `cat`, or continuous output. When Vim, tmux, or another application enables mouse reporting, ordinary clicks, drags, and scrolling go to that application. Shift-drag still forces local text selection in MyTerm.
- Increase terminal font size with `⌘+` / `⌘=`, decrease it with `⌘−`, or reset it to 14 points with `⌘0`. Changes use one-point steps within a 10–32 point range and affect only the active pane. Each session retains its size across tab switches, merges, detachments, and reconnections; new sessions use the default. Customize, disable, or reset these actions under Settings → Shortcuts → Terminal. The default bindings also support numeric keypad plus, minus, and zero.
- Upload and download through SFTP with overwrite confirmation, folder creation, rename, delete, and permission editing. Local and remote lists show symbolic POSIX permissions below each filename. Edit permissions with an owner/group/others read/write/execute matrix or octal values. Drag files or folders from Finder into the remote pane to upload them to the current remote directory. The local pane can navigate symbolic-link folders such as OneDrive locations within the app.
- Use consistent hover feedback, single-click selection, and double-click opening in the host library and SFTP. Deep SFTP paths keep key levels visible and collapse intermediate directories into an `…` menu.
- Use a shared blue-and-white color system throughout the window, sidebar, host cards, Logs, SFTP, terminal workspaces, and settings, with system, light, and dark appearance options. Terminal ANSI colors, platform logos, and success/warning/error colors retain their distinct meanings.
- Switch the terminal's 16-color ANSI palette with the app appearance: light backgrounds use darker yellow, green, blue, and other foregrounds, while dark backgrounds use softer bright colors. Existing colored output updates as well. Black, gray, and white text receives display contrast compensation when needed, while white text on black stays bright. Inverse, hidden, and dim effects are preserved. Extended colors at indices 16–255 use the standard fixed xterm palette.
- Toggle terminal message-label highlighting under Settings → Appearance. At the start of a line, `[資訊]` / `[INFO]` labels appear blue, warnings orange, pass labels cyan-blue, success green, errors red, debug purple, and hints blue-gray. Only the label changes; the following text and copied content stay intact, and unmatched RGB text keeps the application's specified color. Matching requires a complete label within the first 48 character cells and excludes wrapped continuation lines, full-screen terminal applications, custom backgrounds, inverse, dim, and hidden labels. Colors are a visual category, not proof that a message is true or a command succeeded.
- Import MyTerm or Termius host metadata with a selectable preview, and export MyTerm host metadata. See [Termius migration](TERMIUS_MIGRATION.en.md) for supported data and the optional conversion tool.
- Customize or disable shortcuts that apply within the app. Saved passwords can only be filled at recognized safe password prompts. If the initial automatic login password fails, MyTerm offers to replace it only after OpenSSH confirms that the next manually entered password authenticated successfully. For a forced password change, both new entries must match and the server must explicitly report success before MyTerm offers to update the local vault.
- Detect operating systems and network platforms from terminal output, with a read-only background probe for SSH hosts that remain unidentified. The host library, SFTP picker, connection tab, terminal title, and that connection's Logs record use consistent platform badges.
- Optionally use Sparkle updates from your own configured HTTPS feed and verification key. Without that configuration, update by rebuilding from source.

## Optional cross-device sync

Sync is off by default. To sync hosts, groups, host passwords, and finalized Logs, sign in with Google, enable sync, and set a sync passphrase.

When Google verification succeeds but the sync service has not enabled the account, “重新嘗試” (Try Again) retries the sync-service sign-in directly for up to 30 minutes while the Google credential remains valid. You can also choose “使用其他 Google 帳號” (Use Another Google Account). Expiry, quitting the app, or signing out requires a new Google sign-in.

- Each record is end-to-end encrypted on your Mac with AES-256-GCM before it is sent to Firebase.
- The sync passphrase derives a key using Argon2id. The master key and decrypted passwords are stored only in each Mac's local encrypted vault.
- Firebase stores ciphertext and necessary version information; it cannot directly read host contents or passwords.
- Logs sync only after a connection completes, fails, is cancelled, or is recovered as having ended incompletely. Live connection status and timing remain on the originating Mac and are not continuously sent to other devices.
- Sync Now uploads and fetches data on the current Mac. Other Macs receive changes when they sync manually, return to the foreground, or run their own periodic sync; the source device does not push UI state directly to them.
- Hosts, groups, passwords, and Logs share one schedule. Launch, foreground, wake, and local changes to synced data request a sync, with another sync every five minutes while the app is active. Opening Logs also requests an update if the last successful full sync is over 60 seconds old or no sync has succeeded yet. Sync is not guaranteed while the app is closed or the Mac is asleep.
- Settings shows one overall status and one last-success time. That time advances only when hosts, passwords, and Logs all finish in the same round and Logs have been saved locally. Temporary failures wait for the existing five-minute foreground cycle; there is no additional short-interval retry. Incomplete work is never reported as a successful round.
- If a network problem prevents sign-in restoration at launch, a later sync cycle first tries to restore the session with the saved credentials, then syncs data. Foreground, wake, and manual sync can also trigger recovery. Explicit sign-out, disabled sync, invalid credentials, or missing credentials prevent periodic recovery attempts. Disabling sync does not change the normal one-time sign-in restoration at app launch. Local data remains available while offline.
- Account & Sync → Diagnostics → Copy Sync Execution Log provides up to seven days of local triggers, processing stages, and error codes for troubleshooting. Diagnostics is collapsed by default, contains no hosts, accounts, passwords, or terminal content, and is not uploaded automatically.
- Private-key files, private-key paths, and `known_hosts` always remain local to each Mac.
- Disable sync at any time and continue using the app locally.

To enable Google sign-in and sync in your own build, configure your own Firebase project using the [Firebase setup guide](FIREBASE_SETUP.en.md). Without cloud configuration, all local features remain available.

## Requirements and installation

- Apple Silicon Mac (arm64)
- macOS 26 or later

Follow “Build and install for everyday use” below to create and install `MyTerm.app`. Local features need no account, cloud configuration, or update service; fetch newer source and rebuild when you want to update. Development and testing use the separate `MyTerm Dev.app`.

## Getting started

1. Use `+` to create a group or host. If the host name is blank, its address is displayed instead.
2. Leave the default username blank if you prefer to choose an account when connecting.
3. Keep system-default algorithms for ordinary hosts. Enable RSA compatibility or custom algorithms only for confirmed legacy-device requirements.
4. Double-click a host card to open an SSH tab. Verify a new host fingerprint through a trusted channel before accepting it.
   After authentication succeeds, the host moves to the front of the All Hosts view, its group, and matching search results. Failure or cancellation does not affect ordering. This recent-use order is local to the current Mac and does not change the SFTP host picker.
   To move a host, drag its card onto a group card in All Hosts, review the source and destination, and confirm Move. This replaces its existing group, if any. Dropping it onto the same group or cancelling makes no change. Use the All Hosts › Group breadcrumb to return to a parent level.
   If an authenticated SSH connection drops because of a VPN, network, or remote-service interruption, MyTerm keeps its tab and local terminal display. Once connectivity is restored, press Enter in that terminal to reconnect. This preserves local display and scrollback only, not the remote shell's working directory, environment, or processes. Use `tmux` or `screen` when you need to preserve remote work.
5. A saved SSH password is submitted automatically at the first login prompt. If it is rejected, a later successful manual login can be used to update the saved value. When the server forces a password change, complete the current-password, new-password, and confirmation prompts; MyTerm offers to replace the saved value only after the server reports success. Later `sudo` / `su` prompts require the Fill Password button or its configured shortcut.
6. The host library sidebar starts collapsed; use the sidebar button at the top of the window to expand it. Known Hosts opens SSH trust records, and Logs opens connection history. Search or filter Logs by host, endpoint, source device, or outcome. Records are read-only and retained for 30 days. With sync enabled, only finalized records are end-to-end encrypted and shared across devices.
7. Terminal opens a local zsh session in your home directory. Serial connects to a `/dev/cu.*` or `/dev/tty.*` device. Drag to select ordinary terminal output. If Vim, tmux, or another program has enabled terminal mouse mode, it receives ordinary mouse actions; hold Shift while dragging to select text locally for copying.
8. SFTP opens the local and remote file panes. Single-click a host, group, or file to select it; double-click to enter a group or folder, or establish a connection. Actual permissions such as `-rw-r--r--` appear below the filename. Choose Edit Permissions from the file menu, verify the full path, then use the permission matrix or octal values such as `644` / `755`.
9. Drag terminal tabs within the top bar to reorder them. Sessions with identical names receive stable `(1)`, `(2)`, and similar suffixes in tabs and pane titles. A background workspace shows a separate blue indicator when new output arrives; selecting it clears the indicator. This means there is unseen output, not necessarily that a remote command has finished. Dragging a tab down into the content area displays the adjacent merge target and a green preview for left, right, top, or bottom placement. Most tabs target the previous connection; the first targets the next. Merged tabs are named Workspace and hold at most two sessions. Resize them with the divider, or drag either pane's title back to the tab bar to detach it.

## Building from source

### Build and install for everyday use

To use MyTerm, follow these steps to create **MyTerm.app**. You do not need to change code, create a GitHub Release, host an update service, or configure Firebase. This produces a Release-optimized build with the regular MyTerm name and data identity.

You need an Apple Silicon Mac, macOS 26, Xcode 26 or compatible Command Line Tools (Swift 6.2), Git, Python 3.12+, and ripgrep (`rg`). Check availability with `swift --version`, `git --version`, `./scripts/project-python.sh --version`, and `rg --version`. The first build downloads dependencies over the internet. See [build tools](DEVELOPMENT.en.md#build-tools) for setup.

**1.** Open macOS Terminal, download the source, and enter its directory:

```sh
git clone https://github.com/crazy01100/myterm-source.git
cd myterm-source
```

**2.** Paste the entire block below into the same Terminal. It runs tests, builds, and verifies the app, then reveals it in Finder only if every step succeeds. Any failed step stops the sequence. `1.0.21` is a replaceable version-label example; it does not select that source version. The app's contents come from the source currently checked out.

```sh
(
  set -e
  myterm_version="1.0.21"
  myterm_build="$(date '+%Y%m%d%H%M%S')"
  myterm_app="$PWD/build/candidates/MyTerm-$myterm_version-build-$myterm_build/MyTerm.app"

  ./scripts/project-python.sh scripts/run-isolated-tests.py
  ./scripts/build-app.sh --channel candidate \
    --version "$myterm_version" --build "$myterm_build"
  ./scripts/verify-app.sh --app "$myterm_app" \
    --version "$myterm_version" --build "$myterm_build"
  open -R "$myterm_app"
)
```

**3.** Drag **MyTerm.app** from Finder into Applications, then open it from there for everyday use. The build commands do not install or launch it automatically. If an app with that name already exists, read [existing installations and data](DEVELOPMENT.en.md#install-and-data), decide whether to replace it, and finish your SSH work and quit the old app first.

This is your own build, without the maintainer's release signature or Apple notarization. Without your own signing identity configured, it uses ad-hoc signing. macOS or Keychain may require approval when first opening it or after rebuilding; see [signing notes](DEVELOPMENT.en.md#local-signing). The default contains no sync configuration or update URL.

### Updating later

Run `git pull --ff-only` in your retained source directory. After it succeeds, repeat the build block above, quit the old app, and replace it at the same installation location with the verified new app. Each run generates a new Build number. Preserve existing local data, Keychain items, and your own `Config/Local/` settings. If you have source changes or are switching from Dev, follow the [update and data guidance](DEVELOPMENT.en.md#manual-update) first.

### Development and testing

To change features while keeping everyday data separate, use **MyTerm Dev.app**:

```sh
./scripts/run-dev-app.sh \
  --version 1.0.22-dev.1 \
  --build "$(date '+%Y%m%d%H%M%S')"
```

Dev has its own data directory and Keychain service, with output at `build/dev/MyTerm Dev.app`. It does not automatically import regular MyTerm hosts, passwords, or Google sign-in. See [DEVELOPMENT.en.md](DEVELOPMENT.en.md) for development, your own sync backend, in-app updates, and independent distribution.

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
