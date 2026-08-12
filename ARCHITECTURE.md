# MyTerm 系統架構

本文說明 MyTerm 1.0.3 正式版的公開系統架構、資料流與安全邊界。實作與部署細節以儲存庫中的程式碼及設定為準。

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

- `Sources/MySSHClient/Views`：主機庫、平台徽章、編輯器、終端機、Serial、SFTP 與設定畫面。
- `Sources/MySSHClient/MySSHClientApp.swift`：App 進入點、設定視窗、選單與整體生命週期。
- SwiftUI 負責狀態、頂部分頁與主要 App 外殼；Terminal 工作區以 AppKit 原生分割容器作為界線清楚的 native island，處理穩定 pane hosting、live divider tracking、macOS 游標與終端機尺寸調整。主視窗提供較大的預設尺寸並保留可縮放能力。
- 主機庫、SFTP 主機選擇器及兩側檔案列表共用一致的互動原則：滑鼠移入提供視覺回饋、單擊立即選取、雙擊才進入分類／資料夾或建立連線。

### 主機與本機資料

- `HostStore` 保存主機及多階層群組，資料檔權限限制為目前使用者。
- `LocalSecretVaultStore` 將登入狀態、同步 Master Key 與主機密碼保存於同一個 AES-GCM 本機保管庫；只有一把隨機根金鑰留在 macOS Keychain。
- `KeychainStore` 仍以主機 UUID 定位密碼，但只操作統一保管庫，主機資料本身不含密碼。
- `KnownHostsStore` 管理 MyTerm 專用 SSH 信任檔；使用者另可手動載入本機 `~/.ssh/known_hosts` 快照。
- `AppShortcutStore` 保存只在 MyTerm 內生效的快捷鍵設定。
- `TerminalWorkspaceCollection` 保存執行期間的視覺分頁順序、作用中窗格、分割方向與比例；每個工作區的不變條件限制為一或兩個 Terminal session，並負責把雙窗格中的任一 session 拆回獨立分頁及收斂原工作區。

### 連線與終端機

- SSH 使用 macOS 內建 `/usr/bin/ssh`，MyTerm 建立 pseudo-terminal 並顯示互動畫面。
- `SessionManager` 保有 Terminal process 生命週期，並把 Session 組成可拖曳重排的工作區；把分頁拖入前一個工作區的內容區可合併為左右或上下雙窗格，把窗格標題列拖回頂部分頁列則可拆開。合併、拆分、切換方向與調整比例都不重建底層 process。
- `TerminalWorkspaceSplitContainer` 為每個執行中 Session 保留穩定的 pane host；原生 `NSSplitView` 在拖曳期間直接更新 child view frame，完成拖曳後才把最終比例同步回 `TerminalWorkspaceCollection`，避免每個滑鼠事件都發布整個 SwiftUI 工作區狀態。
- 系統預設模式沿用 OpenSSH 的現代演算法政策；RSA 相容與自訂選項只套用至指定主機。
- 本機 Terminal 執行 `/bin/zsh` login shell，起始目錄為目前使用者家目錄。
- Serial 驗證並連接 `/dev/cu.*` 或 `/dev/tty.*`，參數直接傳給固定系統程式，不經 Shell 字串插值。
- SFTP 實作檔案瀏覽、傳輸、覆蓋確認與基本檔案管理；認證設定沿用相同主機資料與本機加密保管庫邊界。本機瀏覽器會解析可導覽的符號連結，因此 OneDrive 等 File Provider 目錄可留在 MyTerm 內操作。
- SFTP 路徑使用響應式 breadcrumb：空間足夠時顯示完整層級，空間不足時保留前後關鍵目錄並以 `…` 選單收合中段，不使用會遮住文字的水平捲軸。
- 平台辨識先被動解析終端機輸出；仍未知的平台可在不執行遠端修改的前提下，以背景 SSH probe 讀取作業系統資訊。辨識結果保存於主機資料，供主機庫、SFTP 選擇器、連線分頁與終端機窗格共用 SVG 平台徽章。

## 資料保存位置

| 資料 | 保存位置 | 是否跨裝置 |
|---|---|---|
| 主機與群組 | Application Support 內的權限限制檔案 | 啟用同步時，以密文同步 |
| 主機密碼 | AES-GCM 本機保管庫；根金鑰為 `WhenUnlockedThisDeviceOnly` Keychain 項目 | 啟用同步時再端對端加密；目的 Mac 解密後寫入其本機保管庫 |
| Master Key、登入狀態 | 與主機密碼共用本機保管庫及單一 Keychain 根金鑰 | 不直接同步 |
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
5. 另一台 Mac 使用相同帳號與同步密語解開 Master Key，再將密碼寫入該台 Mac 的本機加密保管庫。

Firestore 不保存明文主機內容、同步密語、Master Key 或解密後密碼。復原金鑰是使用者遺失同步密語時的獨立復原途徑，MyTerm 不代為保存其明文。

## SSH 密碼流程

- 已保存的 SSH 登入密碼只在設定帳號一致且第一次登入 `password:` 提示時自動送入 PTY。
- 未保存密碼時，MyTerm 暫存該次輸入；只有 OpenSSH 診斷資料確認以 `password` 成功驗證後，才詢問是否保存。
- `keyboard-interactive` 不會被當成可保存密碼，避免誤存 OTP 或一次性挑戰。
- `sudo`／`su` 等後續提示與 SSH 登入回呼分離；MyTerm 只允許使用者在已辨識提示中手動一鍵填入。

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
- MyTerm 自有的 SVG 平台圖示由建置腳本放入標準 `Contents/Resources/PlatformIcons`，執行期只從 `Bundle.main` 載入，不使用會嵌入建置機 fallback 路徑的 executable-target `Bundle.module`。候選 App、封裝 ZIP、GitHub 回下載資產與 Cloudflare 部署前會共同驗證圖示內容並拒絕不安全的 MyTerm SwiftPM resource accessor。
- Sparkle 不要求 App 路徑名稱必須是 `/Applications`，但會拒絕從 App Translocation、唯讀映像、暫時位置或無法替換 App 的位置更新。正式安裝一律先將 `MyTerm.app` 移到「應用程式」資料夾；專案 `build/` 內的 App 只供開發測試。
- 目前未使用 Apple Developer ID，因此第一次手動下載可能需要 macOS 使用者確認。零費用自簽憑證無法取得 Apple Team ID，Keychain 仍可能把每次建置視為新的程式身分；1.0.1 已將分散機密收斂到單一 Keychain 根金鑰，使更新後的驗證不會隨主機數量增加。這不會取代 Sparkle 的更新簽章驗證。

## 儲存庫結構

| 路徑 | 用途 |
|---|---|
| `Sources/MySSHClient` | App 原始碼 |
| `Sources/MySSHClient/Resources/PlatformIcons` | 內建作業系統與設備平台 SVG 徽章 |
| `SelfTests`、`Tests` | 核心、加密、OAuth 與 Firestore Rules 測試 |
| `Resources` | App 圖示、Info.plist 與測試資源 |
| `Config` | 可公開的設定範例與 Sparkle 公鑰 |
| `scripts` | 建置、測試、封裝、發布與驗證工具 |
| `.github/workflows` | GitHub Release 發布後的 Cloudflare 自動部署 |
| `update-site` | Cloudflare Pages 靜態網站來源 |
| `firebase.json`、`firestore.rules` | Firebase Emulator 與正式安全規則 |

`build/`、SwiftPM 快取、`node_modules/`、本機 Firebase 設定、OAuth secret、使用者匯出資料及內部計劃紀錄均不屬於公開原始碼。

## 1.0.3 已知限制

- 只支援 macOS 26 與 Apple Silicon arm64。
- 私鑰、私鑰路徑及 `known_hosts` 不跨裝置同步。
- 1.0.1 起，主機與群組刪除會以帶有 revision、裝置識別與 AES-256-GCM 驗證的 tombstone 傳播；遠端刪除套用前會建立本機還原備份。
- `sudo`／`su` 需要按鈕或快捷鍵，不會自動送出密碼。
- 跨裝置同步由 App 啟動、回到前景、切換主要功能及定期排程等本機事件觸發，不使用常駐推播；另一台 Mac 的變更會在下一次同步觸發時套用。
- 目前未使用 Apple Developer ID 與公證，第一次安裝可能出現 macOS 無法驗證開發者的提示。
