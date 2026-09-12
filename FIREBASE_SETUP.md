# MyTerm Firebase 與 Google 登入設定

**繁體中文** | [English](FIREBASE_SETUP.en.md)

本文件供「從原始碼自行建置，且希望啟用 Google 登入與跨裝置同步」的開發者使用。

## 先確認你是否需要設定

| 使用方式 | 是否需要自己的 Firebase 專案 |
|---|---|
| 安裝 MyTerm 官方發布版 | 本機功能不需要；開發者代管同步暫不開放新使用者，既有使用者可繼續使用 |
| 從原始碼建置，只使用主機、SSH、Terminal、Serial、SFTP | 不需要；沒有雲端設定時會建立純本機版 |
| 從原始碼建置，並使用 Google 登入與跨裝置同步 | 需要；請依本文件建立自己的 Firebase／Google Cloud 專案 |

不同 Firebase 專案的帳號、UID、Firestore 資料與同步密文彼此獨立。自行建置的 App 不應使用 MyTerm 官方 Firebase 專案。

## 服務使用範圍與登入提示

開發者代管服務受免費方案額度限制，暫不開放新使用者。MyTerm 本身保留同步能力；自行架設時使用自己的 Firebase 專案與服務政策，無需連接開發者的服務。不同專案的既有密文與帳號不會自動轉移，不能把更換 Project ID 當成資料遷移。

若看到「此雲端同步服務暫未開放此 Google 帳號使用」，既有使用者先確認 Google 帳號是否正確；新使用者請依本指南自行架設並建置。這不是要求建立另一組 MyTerm 帳戶。一般網路錯誤、服務配額或 Google 憑證問題不會被一律解讀為這項限制。

維護自己的服務時，可在 Firebase Authentication → Settings → User actions 關閉「Enable create／啟用建立功能」，限制新帳號加入服務；保留 Google provider 才能維持既有帳號登入。這不限制既有帳號用量，也不取代 Firestore Security Rules。變更後核對既有登入／重新啟動後恢復／同步，以及新帳號被拒絕；不要直接關閉 Google provider 或啟用不相容的 App Check enforcement。

可選的 `Config/Local/CloudSyncServiceNotice.txt` 是純文字的服務使用說明。建置含雲端設定且非 Update Lab 的 App 時，腳本將它加入 `MyTermCloudSyncServiceNotice`，顯示於「帳號與同步」的登入區。沒有該檔案時不顯示代管說明；自架者可省略或撰寫自己的說明。它不改變任何後端權限，也不得放入憑證或私人資料。

## 架構與安全邊界

MyTerm 的雲端流程分成兩層：

1. Google Desktop OAuth 取得 Google ID token，再由 Firebase Authentication 建立 Firebase UID 與 ID token。
2. 使用者啟用同步後，MyTerm 才以 Firebase ID token 存取 Cloud Firestore。主機、群組、密碼與已結束的 Logs 會先在 Mac 上端對端加密，Firestore 只保存密文與必要的版本資訊。

真正的資料存取邊界是 Firebase Authentication、專案內的 [Firestore Security Rules](firestore.rules) 與 MyTerm 的端對端加密；OAuth Client ID、Desktop Client Secret 與 Firebase Web API Key 會隨桌面 App 發布，不能視為伺服器端秘密。即使如此，本專案仍禁止把實際設定檔提交至 Git，避免專案識別與操作資料被誤用。

## 需求

- 一個可管理的 Firebase／Google Cloud 專案。
- Node.js 24 或更新版本；版本要求以 [package.json](package.json) 為準。
- 專案鎖定的 Firebase CLI；在 repository 根目錄執行 `./scripts/project-node.sh --npm install` 後由 `scripts/firebase-tools.sh` 使用。
- 開發工具另需 Node.js 24 LTS與 Python 3.12 以上。npm 安裝會套用經雜湊驗證的 CLI 相容補丁；若停用安裝腳本，先執行 `./scripts/project-python.sh scripts/patch-firebase-stream-json.py`，再用 `./scripts/project-node.sh --npm run test:development-tools` 驗證。
- macOS 26、Apple Silicon 與 Xcode 26 或相容 Command Line Tools，用於建置 MyTerm。

Firebase 工具入口僅支援本指南的 Firestore 部署、基本帳號設定及 `demo-myterm` 本機 Emulator；Auth 匯入、Hosting、替代設定與任意測試子命令會被拒絕。相依例外、期限與限制詳見[安全維護指南](SECURITY_MAINTENANCE.md)。

## 1. 建立 Firebase 專案

1. 在 Firebase Console 建立新專案，或將 Firebase 加入你可管理的 Google Cloud 專案。
2. 記下 Firebase Project ID。後續 Firebase、OAuth 與本機設定必須使用同一個 Project ID。
3. 不要把本文件中的 `YOUR_FIREBASE_PROJECT_ID` 當成實際值。

Project ID 不是密碼，但它決定部署與資料存取的目標。部署指令必須每次明確指定，MyTerm 不提供預設正式專案。

參考：[Firebase 專案與 Apple App 設定](https://firebase.google.com/docs/ios/setup)

## 2. 啟用 Firebase Authentication

1. 在 Firebase Console 開啟「Authentication」。
2. 進入「Sign-in method」，啟用 Google 登入供應商。
3. 設定專案支援電子郵件。

MyTerm 會呼叫 Firebase Identity Toolkit 與 Secure Token API，把 Google ID token 換成 Firebase session 並更新登入狀態。若 Google provider 未啟用，Google OAuth 即使成功，Firebase 登入仍會失敗。

參考：[啟用 Google 作為 Firebase Authentication 登入供應商](https://firebase.google.com/docs/auth/web/google-signin)

## 3. 建立 Cloud Firestore

1. 在 Firebase Console 建立 Cloud Firestore 的 `(default)` database。
2. 選擇適合使用者與法規需求的區域；建立後通常無法直接更換位置。
3. 初始規則模式不代表 MyTerm 的最終權限。正式使用前必須部署 repository 內的 `firestore.rules` 與 `firestore.indexes.json`。

MyTerm 使用以下資料路徑：

```text
users/<Firebase UID>/vaultKeys/current
users/<Firebase UID>/vault/<record UUID>
users/<Firebase UID>/connectionLogs/<record UUID>
```

Repository 內的 Rules 只允許已登入使用者存取自己的 UID 路徑，並限制文件欄位、大小、revision 與密文格式。`connectionLogs` 是建立後不可更新的加密最終紀錄；刪除權限只供 App 執行固定 30 天到期整理，Logs 介面不提供人工刪除。不要以測試用的全開規則取代它。

參考：[建立與管理 Cloud Firestore database](https://firebase.google.com/docs/firestore/manage-databases)

## 4. 登錄 App 並取得 Firebase 設定

1. 在 Firebase 專案設定中新增 Apple App。
2. Bundle ID 必須與 [Resources/Info.plist](Resources/Info.plist) 的 `CFBundleIdentifier` 相同；原始專案預設為 `tw.local.MySSHClient`。Fork 若更改 Bundle ID，Firebase App 與 plist 也必須一起更改。
3. 下載 `GoogleService-Info.plist`。
4. 保存為：

```text
Config/Local/GoogleService-Info.plist
```

`scripts/configure-cloud.sh` 只從這個檔案讀取 Firebase API Key 與 Project ID。MyTerm 執行時使用產生後的 `MyTermCloudConfig.plist`；一般建置不需要把原始 `GoogleService-Info.plist` 包入 App。

## 5. 建立 Google Desktop OAuth Client

1. 在同一個 Google Cloud 專案設定 OAuth consent screen／Google Auth Platform 品牌與目標使用者。
2. 若應用程式仍處於 Testing，將實際測試帳號加入 test users。
3. 建立 OAuth Client，Application type 選擇「Desktop app」。不要建立 Web application client。
4. 下載 OAuth client JSON，保存為：

```text
Config/Local/GoogleOAuthClient.json
```

Desktop client 不需要在 Console 固定登錄 redirect URI。MyTerm 每次登入只在 `127.0.0.1` 隨機連接埠啟動短期 callback，並使用 `openid email profile` scopes、PKCE、state 與 nonce。

參考：[Google OAuth 2.0 for Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app)

## 6. 產生 MyTerm 雲端設定

確認兩個輸入檔都存在：

```text
Config/Local/GoogleService-Info.plist
Config/Local/GoogleOAuthClient.json
```

接著執行：

```sh
chmod 600 Config/Local/GoogleService-Info.plist Config/Local/GoogleOAuthClient.json
./scripts/configure-cloud.sh
```

腳本會確認 OAuth JSON 格式、兩份設定的 Project ID 一致，並產生：

```text
Config/Local/MyTermCloudConfig.plist
```

三個實際設定檔都位於 Git 排除的 `Config/Local/`，不得 commit、上傳 Issue、附在 Release 或貼到聊天中。可以用下列指令檢查格式與鍵名；輸出實際值時請自行避免錄影、截圖或分享：

```sh
plutil -lint Config/Local/GoogleService-Info.plist
plutil -lint Config/Local/MyTermCloudConfig.plist
jq -e '.installed.client_id and .installed.client_secret and .installed.project_id' \
  Config/Local/GoogleOAuthClient.json
```

## 7. 測試並部署 Firestore Rules

安裝專案鎖定工具並先執行 Emulator 測試：

```sh
./scripts/project-node.sh --npm install
./scripts/project-node.sh --npm run test:firestore-rules
```

登入 Firebase CLI：

```sh
./scripts/firebase-tools.sh login
```

確認目前帳號有權管理目標專案後，明確指定 Project ID 部署 Rules 與 Indexes：

```sh
./scripts/project-node.sh --npm run deploy:firestore -- --project YOUR_FIREBASE_PROJECT_ID
```

部署腳本在缺少 `--project`、格式不合法或 Firebase CLI 失敗時會停止。不要把正式 Project ID 寫回 `package.json`、`.firebaserc` 或範例設定。

參考：[Firebase CLI 部署與 `--only firestore`](https://firebase.google.com/docs/cli)

## 8. 建置含雲端功能的 MyTerm Dev

只要 `Config/Local/MyTermCloudConfig.plist` 存在，標準開發建置就會把 allow-list 中的四個執行期欄位放入 App。下列 Dev 版本僅為命名範例，請依實際目標版本調整：

```sh
./scripts/run-dev-app.sh \
  --version 1.0.22-dev.1 \
  --build "$(date '+%Y%m%d%H%M%S')"
```

建置後可以確認檔案存在，但不要公開其內容：

```sh
test -f "build/dev/MyTerm Dev.app/Contents/Resources/MyTermCloudConfig.plist"
```

若 `MyTermCloudConfig.plist` 不存在，App 仍可建置與使用本機功能，但設定頁的 Google 登入與同步會回報尚未加入雲端設定。

## 9. 人工驗收

至少完成以下案例：

1. Google 登入成功，顯示正確帳號，重新啟動 App 後可安全還原登入狀態。
2. 未啟用同步前，既有本機主機與密碼不會自動上傳。
3. 啟用同步時可建立同步密語與復原金鑰，Firestore 只出現目前 UID 下的密文文件；`connectionLogs` 不含明文主機、帳號、位址、來源裝置、時間或結果。
4. 第二台 Mac 以相同 Google 帳號與同步密語復原後，能取得主機、群組、密碼與已結束 Logs，並實際建立 SSH 連線。
5. 不同 Firebase UID 無法讀寫另一個 UID 的 `users/<UID>/...` 路徑。
6. 主機或群組刪除以加密 tombstone 傳播，目的 Mac 套用遠端刪除前會建立本機備份。
7. A 裝置的 SSH 仍在連線時，B 裝置看不到該筆進行中 Logs；A 完成、失敗或取消後，B 才取得一次含來源裝置名稱的最終紀錄。
8. 超過 30 天的 Logs 不會由離線裝置重新上傳，且到期密文會在下一次同步時整理。
9. 停用同步後，本機 SSH、Terminal、Serial、SFTP 與本機 Logs 仍可正常使用。

## 常見問題

### App 顯示尚未加入雲端設定

確認已執行 `scripts/configure-cloud.sh`，且建置前存在 `Config/Local/MyTermCloudConfig.plist`。已建好的 App 不會因為事後新增設定檔而自動更新，必須重新建置。

### OAuth 成功後 Firebase 登入失敗

Google 驗證完成但同步服務暫未開放帳號時，畫面會提供「重新嘗試」：在最多 30 分鐘且 Google 憑證仍有效期間，直接重試同步服務登入。也可選擇「使用其他 Google 帳號」。逾期、關閉 App 或登出後，需重新登入 Google。

瀏覽器顯示「已收到 Google 回應」只代表授權回應已交回 App，請回到 MyTerm 查看最終結果。若 App 提示需要確認既有身分、額外驗證或帳號已停用，請由同步服務管理者處理；若提示資料格式不正確，不代表本機主機資料遺失，請保留畫面並回報。不要把所有登入失敗都當成尚未開放。

確認 Firebase Authentication 已啟用 Google provider、OAuth Client 屬於同一個 Project ID，且 Firebase API Key 未被限制到無法呼叫 Identity Toolkit／Secure Token API。

### Firestore 回傳 permission denied

確認 Firebase CLI 登入的是正確帳號、Rules 已部署至同一個 Project ID，且資料路徑 UID 與 Firebase ID token 的 UID 相同。不要用放寬 Rules 的方式掩蓋專案或帳號不一致。

### 可以提交 API Key 或 Desktop Client Secret 嗎？

桌面 App 無法安全隱藏這些 client-side 設定，因此它們不是 Firestore 的授權邊界；但本專案仍禁止提交實際設定檔。公開 repository 只保留無真實值的範例，正式資料存取必須依靠 Firebase Authentication、Security Rules 與端對端加密。
