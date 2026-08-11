# MyTerm 系統架構

本文說明 MyTerm 1.0 的公開系統架構、資料流與安全邊界。實作與部署細節以儲存庫中的程式碼及設定為準。

## 架構總覽

```text
┌──────────────────────────── MyTerm.app ────────────────────────────┐
│ SwiftUI / AppKit                                                   │
│  ├─ 主機與多階層群組管理       ├─ 設定、匯入／匯出與快捷鍵          │
│  ├─ SSH / Terminal / Serial    └─ 雙欄 SFTP                        │
│                                                                    │
│ 系統服務                                                           │
│  ├─ /usr/bin/ssh + PTY          ├─ macOS Keychain                  │
│  ├─ App 專用 known_hosts        ├─ Application Support 本機資料    │
│  └─ Sparkle 更新器              └─ 選用的端對端加密同步             │
└────────────────────────────────────────────────────────────────────┘
             │ HTTPS（只有使用者啟用同步後）          │ HTTPS
             ▼                                       ▼
  Google OAuth / Firebase Auth             mtus.lieniapp.work
             │                              Sparkle appcast
             ▼                                       │
     Cloud Firestore（只保存密文）          GitHub Release 安裝包
```

MyTerm 的核心功能不依賴雲端。未登入或未啟用同步時，不會為主機資料初始化跨裝置同步流程。

## App 元件

### 使用者介面

- `Sources/MySSHClient/Views`：主機庫、編輯器、終端機、Serial、SFTP 與設定畫面。
- `Sources/MySSHClient/MySSHClientApp.swift`：App 進入點、設定視窗、選單與整體生命週期。
- SwiftUI 負責狀態與主要版面；AppKit 處理 macOS 視窗、終端機與拖放等原生互動。

### 主機與本機資料

- `HostStore` 保存主機及多階層群組，資料檔權限限制為目前使用者。
- `KeychainStore` 以主機 UUID 與帳號定位密碼，主機資料本身不含密碼。
- `KnownHostsStore` 管理 MyTerm 專用 SSH 信任檔；使用者另可手動載入本機 `~/.ssh/known_hosts` 快照。
- `AppShortcutStore` 保存只在 MyTerm 內生效的快捷鍵設定。

### 連線與終端機

- SSH 使用 macOS 內建 `/usr/bin/ssh`，MyTerm 建立 pseudo-terminal 並顯示互動畫面。
- 系統預設模式沿用 OpenSSH 的現代演算法政策；RSA 相容與自訂選項只套用至指定主機。
- 本機 Terminal 執行 `/bin/zsh` login shell，起始目錄為目前使用者家目錄。
- Serial 驗證並連接 `/dev/cu.*` 或 `/dev/tty.*`，參數直接傳給固定系統程式，不經 Shell 字串插值。
- SFTP 實作檔案瀏覽、傳輸、覆蓋確認與基本檔案管理；認證設定沿用相同主機資料與 Keychain 邊界。

## 資料保存位置

| 資料 | 保存位置 | 是否跨裝置 |
|---|---|---|
| 主機與群組 | Application Support 內的權限限制檔案 | 啟用同步時，以密文同步 |
| 主機密碼 | macOS Keychain，`WhenUnlockedThisDeviceOnly` | 啟用同步時先加密；目的 Mac 解密後寫回 Keychain |
| Master Key、登入狀態 | 各台 Mac 的 ThisDeviceOnly Keychain | 不直接同步 |
| 私鑰檔案與路徑 | 使用者指定的本機位置／本機設定 | 不同步 |
| MyTerm `known_hosts` | 各台 Mac 的 Application Support | 不同步 |
| 匯出檔 | 使用者選擇的位置 | 不由 MyTerm 自動同步 |

App 顯示名稱已改為 MyTerm，但 Bundle ID、Keychain service 與既有 Application Support 識別字保留舊名稱，以維持早期版本升級後的資料與密碼關聯。

## 端對端加密同步

同步是選用功能，資料流如下：

1. 使用者以 Google Desktop OAuth 登入；PKCE、state、nonce 與只監聽 `127.0.0.1` 的暫時回呼降低授權碼攔截風險。
2. 使用者輸入同步密語。MyTerm 以 Argon2id 派生保護金鑰，用來解開或建立 Master Key 封套。
3. 每筆主機、群組與密碼資料使用 AES-256-GCM 加密，並帶有格式與 revision 資訊。
4. Firebase Authentication 限制帳號身分；Firestore Security Rules 只允許目前 UID 存取符合格式的密文路徑。
5. 另一台 Mac 使用相同帳號與同步密語解開 Master Key，再將密碼寫入該台 Mac 的 Keychain。

Firestore 不保存明文主機內容、同步密語、Master Key 或解密後密碼。復原金鑰是使用者遺失同步密語時的獨立復原途徑，MyTerm 不代為保存其明文。

## SSH 密碼流程

- 已保存的 SSH 登入密碼只在設定帳號一致且第一次登入 `password:` 提示時自動送入 PTY。
- 未保存密碼時，MyTerm 暫存該次輸入；只有 OpenSSH 診斷資料確認以 `password` 成功驗證後，才詢問是否保存。
- `keyboard-interactive` 不會被當成可保存密碼，避免誤存 OTP 或一次性挑戰。
- `sudo`／`su` 等後續提示與 SSH 登入回呼分離；1.0.0 只允許使用者在已辨識提示中手動一鍵填入。

## 更新與發布

```text
開發 Mac
  └─ 測試、arm64 Release 建置、固定本機發行憑證簽署、Sparkle Ed25519 簽署
       └─ 私人 GitHub Draft Release
            └─ 人工核對並發布
                 └─ GitHub Actions
                      ├─ 下載並驗證五個 Release Assets
                      ├─ Direct Upload 至 Cloudflare Pages
                      └─ 從外部重新驗證網站、appcast、ZIP 與安全標頭
```

- GitHub Releases 保存正式 ZIP、`appcast.xml`、更新說明、校驗碼與 manifest。
- Cloudflare Pages 提供安裝頁、更新說明與 Sparkle feed；不需要 Cloudflare Worker。
- Sparkle 以 App 內嵌的 Ed25519 公鑰驗證更新。修改過、錯誤簽章或下載不完整的封裝會被拒絕。
- 目前未使用 Apple Developer ID，因此第一次手動下載可能需要 macOS 使用者確認；1.0.1 起固定使用同一個本機發行憑證，以維持後續版本的 Keychain 存取身分。這不會取代 Sparkle 的更新簽章驗證。

## 儲存庫結構

| 路徑 | 用途 |
|---|---|
| `Sources/MySSHClient` | App 原始碼 |
| `SelfTests`、`Tests` | 核心、加密、OAuth 與 Firestore Rules 測試 |
| `Resources` | App 圖示、Info.plist 與測試資源 |
| `Config` | 可公開的設定範例與 Sparkle 公鑰 |
| `scripts` | 建置、測試、封裝、發布與驗證工具 |
| `.github/workflows` | GitHub Release 發布後的 Cloudflare 自動部署 |
| `update-site` | Cloudflare Pages 靜態網站來源 |
| `firebase.json`、`firestore.rules` | Firebase Emulator 與正式安全規則 |

`build/`、SwiftPM 快取、`node_modules/`、本機 Firebase 設定、OAuth secret、使用者匯出資料及內部計劃紀錄均不屬於公開原始碼。

## 1.0 已知限制

- 只支援 macOS 26 與 Apple Silicon arm64。
- 私鑰、私鑰路徑及 `known_hosts` 不跨裝置同步。
- 1.0.1 起，主機與群組刪除會以帶有 revision、裝置識別與 AES-256-GCM 驗證的 tombstone 傳播；遠端刪除套用前會建立本機還原備份。
- `sudo`／`su` 在 1.0.0 需要按鈕或快捷鍵，不會自動送出密碼。
- 目前未使用 Apple Developer ID 與公證，第一次安裝可能出現 macOS 無法驗證開發者的提示。
