# MyTerm Firebase and Google Sign-In Setup

[繁體中文](FIREBASE_SETUP.md) | **English**

This guide is for users and developers building MyTerm from source who want to enable Google sign-in and cross-device sync.

## Check whether you need this setup

| How you use MyTerm | Do you need your own Firebase project? |
|---|---|
| Build from source for hosts, SSH, Terminal, Serial, and SFTP only | No. Without cloud configuration, the build supports local features. |
| Build from source with Google sign-in and cross-device sync | Yes. Follow this guide using your own Firebase/Google Cloud project. |

Accounts, UIDs, Firestore data, and encrypted sync records are separate across Firebase projects. Each builder must use their own Firebase project; this source repository provides no hosted backend.

## Architecture and security boundaries

MyTerm's cloud flow has two layers:

1. Google Desktop OAuth obtains a Google ID token, which Firebase Authentication exchanges for a Firebase UID and ID token.
2. Only after the user enables sync does MyTerm use the Firebase ID token to access Cloud Firestore. Hosts, groups, passwords, and finalized Logs are end-to-end encrypted on the Mac first. Firestore stores ciphertext and necessary version information.

The actual access boundaries are Firebase Authentication, the project's [Firestore Security Rules](firestore.rules), and MyTerm's end-to-end encryption. The OAuth Client ID, Desktop Client Secret, and Firebase Web API Key ship with the desktop app and cannot be treated as server-side secrets. Even so, this project prohibits committing real configuration files to Git to prevent misuse of project identifiers and operational data.

## Requirements

- A Firebase/Google Cloud project you can administer.
- Node.js 24 or later; [package.json](package.json) defines the version requirement.
- The repository's pinned Firebase CLI, used through `scripts/firebase-tools.sh` after running `npm install` at the repository root.
- macOS 26, Apple Silicon, and Xcode 26 or compatible Command Line Tools to build MyTerm.

## 1. Create a Firebase project

1. Create a project in the Firebase Console, or add Firebase to a Google Cloud project you administer.
2. Record its Firebase Project ID. The Firebase, OAuth, and local configuration used below must all refer to that same project.
3. Do not use the literal `YOUR_FIREBASE_PROJECT_ID` placeholder as a real value.

A Project ID is not a password, but it determines the deployment and data-access target. Specify it explicitly for every deployment; MyTerm supplies no default production project.

Reference: [Firebase project and Apple app setup](https://firebase.google.com/docs/ios/setup)

## 2. Enable Firebase Authentication

1. Open Authentication in the Firebase Console.
2. Under Sign-in method, enable the Google provider.
3. Set the project's support email address.

MyTerm calls the Firebase Identity Toolkit and Secure Token APIs to exchange the Google ID token for a Firebase session and refresh it. If the Google provider is disabled, Firebase sign-in will fail even if Google OAuth succeeds.

Reference: [Enable Google sign-in for Firebase Authentication](https://firebase.google.com/docs/auth/web/google-signin)

## 3. Create Cloud Firestore

1. Create the Cloud Firestore `(default)` database in the Firebase Console.
2. Choose a region appropriate for your users and regulatory requirements. Its location generally cannot be changed directly after creation.
3. The initial rules mode is not MyTerm's final access policy. Deploy the repository's `firestore.rules` and `firestore.indexes.json` before production use.

MyTerm uses these data paths:

```text
users/<Firebase UID>/vaultKeys/current
users/<Firebase UID>/vault/<record UUID>
users/<Firebase UID>/connectionLogs/<record UUID>
```

The repository's rules allow signed-in users to access only their own UID paths and constrain document fields, size, revisions, and ciphertext format. `connectionLogs` contains encrypted final records that cannot be updated after creation. Deletion is used by the app's fixed 30-day retention cleanup; the Logs interface offers no manual deletion. Do not replace these rules with unrestricted test rules.

Reference: [Create and manage Cloud Firestore databases](https://firebase.google.com/docs/firestore/manage-databases)

## 4. Register the app and obtain Firebase configuration

1. Add an Apple app in the Firebase project settings.
2. Match its Bundle ID to `CFBundleIdentifier` in [Resources/Info.plist](Resources/Info.plist). The original project defaults to `tw.local.MySSHClient`. If a fork changes the Bundle ID, update both the Firebase app and the plist.
3. Download `GoogleService-Info.plist`.
4. Save it at:

```text
Config/Local/GoogleService-Info.plist
```

`scripts/configure-cloud.sh` reads only the Firebase API Key and Project ID from this file. At runtime, MyTerm uses the generated `MyTermCloudConfig.plist`; a normal build does not need to bundle the original `GoogleService-Info.plist`.

## 5. Create a Google Desktop OAuth client

1. Configure the OAuth consent screen/Google Auth Platform branding and audience in the same Google Cloud project.
2. If the application is in Testing, add the accounts you will use to its test users.
3. Create an OAuth client with the Desktop app application type. Do not create a Web application client.
4. Download the OAuth client JSON and save it at:

```text
Config/Local/GoogleOAuthClient.json
```

A desktop client does not need a fixed redirect URI registered in the Console. Each sign-in starts a temporary callback on a random port at `127.0.0.1`, using the `openid email profile` scopes, PKCE, state, and nonce.

Reference: [Google OAuth 2.0 for Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app)

## 6. Generate MyTerm cloud configuration

Confirm that both input files exist:

```text
Config/Local/GoogleService-Info.plist
Config/Local/GoogleOAuthClient.json
```

Then run:

```sh
chmod 600 Config/Local/GoogleService-Info.plist Config/Local/GoogleOAuthClient.json
./scripts/configure-cloud.sh
```

The script validates the OAuth JSON format and matching Project IDs, then generates:

```text
Config/Local/MyTermCloudConfig.plist
```

All three real configuration files belong in Git-ignored `Config/Local/`. Do not commit them, upload them to issues, attach them to releases, or paste them into chats. These commands check formats and required keys; avoid recording, screenshotting, or sharing real values:

```sh
plutil -lint Config/Local/GoogleService-Info.plist
plutil -lint Config/Local/MyTermCloudConfig.plist
jq -e '.installed.client_id and .installed.client_secret and .installed.project_id' \
  Config/Local/GoogleOAuthClient.json
```

## 7. Test and deploy Firestore Rules

Install the pinned tools and run the Emulator tests first:

```sh
npm install
npm run test:firestore-rules
```

Sign in to the Firebase CLI:

```sh
./scripts/firebase-tools.sh login
```

After confirming that the account can administer the target project, deploy Rules and Indexes with an explicit Project ID:

```sh
npm run deploy:firestore -- --project YOUR_FIREBASE_PROJECT_ID
```

The deployment script stops if `--project` is missing or malformed, or if the Firebase CLI fails. Do not embed a production Project ID in `package.json`, `.firebaserc`, or example configuration.

Reference: [Firebase CLI deployment and `--only firestore`](https://firebase.google.com/docs/cli)

## 8. Build MyTerm with cloud features

After configuration, rebuild your everyday app using the [README build and verification steps](README.en.md#building-from-source), then install or replace it as described there. Both regular personal builds and Dev include the allowed fields from `Config/Local/MyTermCloudConfig.plist`; adding settings later does not update an installed app.

For the resulting `MyTerm.app` revealed in Finder, choose Show Package Contents and check for `Contents/Resources/MyTermCloudConfig.plist` without disclosing its settings. Then complete the sign-in/sync acceptance checks in section 9.

To test with isolated data first, use the MyTerm Dev flow below. Dev sign-in and hosts do not automatically move to regular MyTerm; configure sign-in and sync separately in each app.

When `Config/Local/MyTermCloudConfig.plist` exists, the standard development build includes its four allow-listed runtime fields in the app. The Dev version below is a naming example; replace it with the actual target version:

```sh
./scripts/run-dev-app.sh \
  --version 1.0.22-dev.1 \
  --build "$(date '+%Y%m%d%H%M%S')"
```

After building, check that the file exists without disclosing its contents:

```sh
test -f "build/dev/MyTerm Dev.app/Contents/Resources/MyTermCloudConfig.plist"
```

Without `MyTermCloudConfig.plist`, the app still builds and supports local features, but Google sign-in and sync in Settings report that cloud configuration is missing.

## 9. Manual acceptance checks

Complete at least these cases:

1. Google sign-in succeeds, shows the correct account, and safely restores the session after restarting the app.
2. Existing local hosts and passwords are not uploaded before sync is enabled.
3. Enabling sync creates a passphrase and recovery key. Firestore contains only encrypted documents under the current UID; `connectionLogs` reveals no plaintext host, account, address, source-device, time, or outcome fields.
4. A second Mac using the same Google account and sync passphrase can recover hosts, groups, passwords, and finalized Logs, then establish an actual SSH connection.
5. A different Firebase UID cannot read or write another UID's `users/<UID>/...` paths.
6. Host/group deletions propagate as encrypted tombstones. The receiving Mac creates a local backup before applying them.
7. While device A's SSH connection is active, device B cannot see its in-progress Logs record. After A completes, fails, or cancels the connection, B receives one final record with the source-device name.
8. Offline devices do not re-upload Logs older than 30 days, and expired ciphertext is removed during a subsequent sync.
9. After disabling sync, local SSH, Terminal, Serial, SFTP, and Logs remain usable.

## Troubleshooting

### The app reports missing cloud configuration

Confirm that `scripts/configure-cloud.sh` ran and that `Config/Local/MyTermCloudConfig.plist` existed before building. Adding configuration after a build does not change that app; rebuild it.

### Google OAuth succeeds but Firebase sign-in fails

Check that Firebase Authentication has the Google provider enabled, the OAuth client belongs to the same Project ID, and the Firebase API Key allows calls to the Identity Toolkit and Secure Token APIs.

### Firestore returns permission denied

Check the Firebase CLI account, verify that Rules were deployed to the intended Project ID, and confirm that the data-path UID matches the Firebase ID token. Do not weaken Rules to hide a project or account mismatch.

### Can I commit the API Key or Desktop Client Secret?

A desktop app cannot securely conceal these client-side settings, so they are not the Firestore authorization boundary. This project nevertheless prohibits committing real configuration files. The shared repository contains only examples without real values; production access must rely on Firebase Authentication, Security Rules, and end-to-end encryption.
