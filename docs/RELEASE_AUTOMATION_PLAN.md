# MyTerm 1.0 正式上線與自動更新執行計劃

最後更新：2026-08-10
文件狀態：`已核准並執行`
實作狀態：`R5 已完成；下一階段為 R6 Cloudflare Pages 更新站`

> 2026-08-10 使用者已核准本計劃。R1 至 R4 已完成；Sparkle 私鑰與加密備份已就緒，GitHub 採私人 repository，Cloudflare 正式更新站尚未建立。

## 1. 目標

本計劃要把目前的 MyTerm 測試版整理為可正式發布的 `1.0.0`，並讓使用者在第一次手動安裝後，可以直接在 MyTerm 內完成後續更新。

完成後的使用流程：

```text
第一次安裝
  下載 MyTerm → 移到「應用程式」→ 處理一次 Gatekeeper 提示

後續更新
  MyTerm → 檢查更新… → 查看更新說明 → 下載並驗證 → 自動替換 → 重新啟動
```

開發者發布流程的第一階段目標：

```text
執行一個本機發布指令
  → 測試
  → 建置 ARM64 App
  → 簽署更新檔
  → 建立校驗碼與 appcast
  → 建立 GitHub Draft Release
  → 人工確認
  → 正式發布並更新 Cloudflare Pages
```

## 2. 已確認的發布決策

| 項目 | 決策 |
|---|---|
| 正式版本 | `1.0.0`；必須從第一版起內建更新器 |
| 支援平台 | macOS 26，僅 Apple Silicon `arm64` |
| 更新框架 | Sparkle `2.9.5`，固定精確版本；升級需另做安全檢查 |
| 更新入口 | App 選單與設定頁提供「檢查更新…」 |
| 初期更新策略 | 使用者主動檢查；不在背景靜默安裝 |
| 更新檔驗證 | Sparkle Ed25519／EdDSA 簽章；拒絕未簽署、簽章錯誤或遭竄改的檔案 |
| 更新清單 | 使用 HTTPS `appcast.xml`；更新清單與更新說明也啟用簽章驗證 |
| 安裝檔 | GitHub Releases 保存 ZIP |
| 更新網站 | Cloudflare Pages 保存靜態 `appcast.xml` 與 release notes |
| Cloudflare Worker | 不使用；目前沒有動態程式需求 |
| Apple Developer Program | 現階段不加入，不產生年費 |
| App 簽署 | 暫時維持 ad-hoc；接受第一次安裝仍有 Gatekeeper 提示 |
| Firebase | 只負責帳號與加密資料同步，不承載 App 更新檔 |
| 使用者資料 | 更新只替換 `.app`；不得刪除 Application Support、Keychain、known_hosts 或同步設定 |
| 正式發布方式 | 先採「本機一鍵發布＋人工放行」；不把 Sparkle 私鑰直接交給一般雲端 CI |
| 完全自動發布 | `1.0` 穩定後再獨立評估；不阻擋使用者端自動更新 |

官方依據：

- [Sparkle 2 官方文件](https://sparkle-project.org/documentation/)
- [Sparkle 2.9.5 Release](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.5)
- [Sparkle 發布更新文件](https://sparkle-project.org/documentation/publishing/)
- [Apple Developer ID 說明](https://developer.apple.com/support/developer-id/)
- [Apple 公證說明](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## 3. 重要限制與預期行為

### 3.1 沒有 Apple Developer Program 仍可使用自動更新

Sparkle 更新檔會以獨立的 Ed25519 私鑰簽署，MyTerm 內只嵌入公開金鑰。沒有 Apple Developer ID 不會阻止 Sparkle下載、驗證及替換更新。

目前接受的限制：

- 其他人第一次下載 MyTerm 時，macOS 可能顯示「Apple 無法驗證」。
- 第一次安裝應把 MyTerm 移到 `/Applications`，不能直接從 ZIP、唯讀磁碟映像或 App Translocation 路徑執行。
- 特殊權限或非標準安裝位置仍可能要求輸入該 Mac 的管理密碼。
- 無法使用 Apple 公證提供的開發者身分與惡意程式掃描票證。
- 若將來購買 Apple Developer Program，可以在不更換更新架構的情況下補上 Developer ID 與公證。

### 3.2 更新私鑰是正式發布的最高風險資產

由於目前沒有 Developer ID 可作為金鑰輪替的後備信任來源，Sparkle 私鑰一旦遺失，已發布的 MyTerm 可能無法安全接受使用新金鑰簽署的更新。

正式 `1.0.0` 發布前必須：

1. 在主要開發 Mac 的 Keychain 產生私鑰。
2. 匯出一份加密備份，保存到不會同步進 GitHub 的位置。
3. 建立第二份離線加密備份。
4. 實際用備份還原到隔離測試 Keychain，確認可簽署且公鑰一致。
5. 文件只記錄公鑰指紋與備份驗證日期，不記錄私鑰或備份密碼。

禁止把私鑰提交至 Git、Cloudflare Pages、GitHub Release、Firebase 或原始碼。

## 4. 目前專案基線

截至 2026-08-10 的已知狀態：

| 項目 | 現況 |
|---|---|
| App 版本 | `0.13.0` Build `20260810050000` R4 測試候選；尚未標記為正式 `1.0.0` |
| 支援架構 | Apple Silicon `arm64` |
| 最低系統 | macOS 26 |
| 自我測試 | 最近完整回歸為 276 項通過、0 失敗 |
| 更新框架 | Sparkle `2.9.5` 已固定並嵌入；正式公鑰已配置，正式 feed 尚未配置 |
| 版本來源 | 建置時由 `--version` 單一參數注入，不再寫死於 `Info.plist` |
| Bundle Build | 由 `--build` 明確提供；預設拒絕重複或倒退 |
| 簽署 | 保留 Sparkle framework／helpers 既有簽章，再以 ad-hoc 封裝外層 App；不再用 blanket `--deep` 重簽 |
| Git | 工作目錄尚未完成正式 Git／GitHub 發布初始化 |
| GitHub Actions | 尚未建立 `.github/workflows` |
| Cloudflare Pages | 尚未建立 MyTerm 正式更新站 |
| Sparkle 金鑰 | 正式金鑰已建立於登入 Keychain，並完成 iCloud AES-256 備份與隔離還原簽署驗證 |
| `appcast.xml` | 本機更新實驗室已建立並完成簽章驗證；正式公開 feed 尚未建立 |

此表是後續驗收基準；任何現況變更都要在進度表記錄證據。

## 5. 系統架構

```text
主要開發 Mac
├── MyTerm 原始碼
├── Sparkle 私鑰（Keychain）
├── 本機發布腳本
└── 加密的離線私鑰備份
        │
        ├── GitHub repository：原始碼與發布工具
        ├── GitHub Draft Release：MyTerm ZIP、SHA-256、更新說明
        └── Cloudflare Pages：appcast.xml、release notes
                                     │
                                     ▼
                             使用者的 MyTerm
                       HTTPS 讀取已簽署 appcast
                       驗證 ZIP 的 Ed25519 簽章
                       替換 App 並重新啟動
```

## 6. 分階段執行計劃

進度狀態統一使用：

| 狀態 | 意義 |
|---|---|
| `尚未開始` | 尚未修改或執行 |
| `進行中` | 已開始，但驗收證據尚未齊全 |
| `等待人工驗證` | 程式部分完成，必須由使用者操作或確認 |
| `受阻` | 缺少外部資料、權限、決策或出現費用要求 |
| `已完成` | 自動測試及指定人工驗證都完成，證據已記錄 |
| `延後` | 不屬於 1.0 必要範圍 |

### R0 — 計劃核准與凍結範圍

目標：在開始修改前確認方向，避免做到一半才增加付費、外部服務或安全風險。

| 編號 | 狀態 | 執行者 | 任務 | 驗收證據／人工動作 |
|---|---|---|---|---|
| R0.1 | `已完成` | Codex | 查核目前專案建置、版本、簽署與發布現況 | 本文件第 4 節 |
| R0.2 | `已完成` | Codex | 查核 Sparkle 與 Apple 官方條件 | 官方連結已記錄 |
| R0.3 | `已完成` | Codex | 建立本計劃草案 | 本文件 |
| R0.4 | `已完成` | 使用者 | 審閱並核准／要求修改本計劃 | 2026-08-10 使用者明確核准並要求開始 |

完成條件：使用者核准本計劃；未核准前不執行 R1 以後工作。

### R1 — 正式版本與建置流程整理

目標：讓版本不再硬編碼，並確保每次發布都可以重現。

| 編號 | 狀態 | 執行者 | 任務 | 驗收證據／人工動作 |
|---|---|---|---|---|
| R1.1 | `已完成` | Codex | 將 `CFBundleShortVersionString` 改由發布參數提供 | `Info.plist` 不再硬編碼；腳本接受 `1.0.0-beta.1` 格式 |
| R1.2 | `已完成` | Codex | 保留單調遞增 `CFBundleVersion`，並防止倒退 | 重複 Build 與 Build `1` 均以狀態 65 拒絕 |
| R1.3 | `已完成` | Codex | 建立統一 `build`、`test`、`package`、`verify` 流程 | 0.12.0 Build 20260810020000：276 項測試通過，App 與解壓後 ZIP 驗證成功；SHA-256 `6f90d67aee6b5e162b36f26cd51a75e61dd1852e5d4f73e2a1dff5cc9b31dc84` |
| R1.4 | `已完成` | Codex | 建立發布前敏感資料與禁止檔案檢查 | 2026-08-10 掃描通過；Local 原始檔／匯出／私鑰禁止進包，runtime config 採欄位白名單重建 |
| R1.5 | `已完成` | 使用者 | 開啟新建置並確認版本顯示正確 | 2026-08-10 確認顯示 `0.12.0`／Build `20260810020000` |

完成條件：尚未加入 Sparkle時，既有功能與 276 項測試仍通過，產物可重現且版本可控制。

### R2 — Sparkle 核心整合

目標：讓 MyTerm 具備安全檢查及安裝更新的能力，但先不連正式網站。

| 編號 | 狀態 | 執行者 | 任務 | 驗收證據／人工動作 |
|---|---|---|---|---|
| R2.1 | `已完成` | Codex | 以精確版本加入 Sparkle `2.9.5` | `Package.resolved` 固定 `2.9.5` |
| R2.2 | `已完成` | Codex | 建立單一 Updater Controller，避免視窗重建時重複初始化 | App 層只建立一個 `AppUpdaterStore`；未配置時不啟動 Sparkle 網路流程 |
| R2.3 | `已完成` | Codex | App 選單加入「檢查更新…」 | MyTerm App 選單已有入口；未配置時顯示安全說明 |
| R2.4 | `已完成` | Codex | 提供版本、Build 與「檢查更新」操作 | 版本與 Build 沿用帳號頁狀態區；依人工驗證意見移除重複的更新頁籤，只保留 App 選單入口 |
| R2.5 | `已完成` | Codex | 加入 `SUFeedURL`、`SUPublicEDKey` 及簽署 feed 所需設定 | 建置參數驗證 HTTPS feed 與 32-byte Ed25519 公鑰；公鑰可先安全嵌入、feed 不可在缺少公鑰時啟用；實際值等待 R3／R6 |
| R2.6 | `已完成` | Codex | 重整自訂 App 打包，正確嵌入 Sparkle framework／helpers | App 內含 framework、Updater、Autoupdate、Downloader／Installer XPC；不使用 blanket `--deep` 重簽 |
| R2.7 | `已完成` | Codex | 驗證 Sparkle helper、framework 與 App 簽章完整性 | 精簡設定頁後的 0.13.0 Build `20260810033000`：276 項測試、App 與解壓後 ZIP 的 framework／helper／rpath／簽章驗證全部通過；ZIP SHA-256 `a9cb42cdd5406cdeb2916368d7cfdb499c4187720b93b21ead8bfbefa5c43f8e` |
| R2.8 | `已完成` | 使用者 | 測試未配置正式來源時的訊息與操作流暢度 | 2026-08-10 確認功能正常，並要求精簡為只保留 App 選單入口 |

完成條件：MyTerm 可以安全讀取測試 feed，且沒有更新時不修改 App 或使用者資料。

### R3 — 更新簽章金鑰與災難復原

目標：建立不依賴 Apple Developer Program 的更新信任根。

| 編號 | 狀態 | 執行者 | 任務 | 驗收證據／人工動作 |
|---|---|---|---|---|
| R3.1 | `已完成` | Codex＋使用者 | 執行 Sparkle `generate_keys` 產生金鑰 | 2026-08-10 使用固定 account `MyTerm.Release.ed25519` 完成；公鑰 SHA-256 `bbf8cf94fa2ce3e7dc1ff6b21e50f472c8dad7b79c6ebd40e9c02e7ee686baae` |
| R3.2 | `已完成` | Codex | 將公鑰寫入 App，不保存私鑰內容 | 0.13.0 Build `20260810040000` 的 `SUPublicEDKey` 已與專案正式公鑰完全一致；`verify-app.sh` 往後也會強制比對 |
| R3.3 | `已完成` | 使用者 | 選擇更新私鑰備份位置 | 2026-08-10 確認只使用私人 iCloud Drive；沒有私人外接設備，組織 OneDrive 不使用。接受目前只有一份 AES-256 外部備份的取捨，未來有私人外接設備再補第二份 |
| R3.4 | `已完成` | 使用者＋Codex | 在隔離環境測試從備份還原並簽署測試 ZIP | iCloud AES-256 備份已真實解鎖；一次性 Keychain account 還原後公鑰一致，測試簽署與驗章通過，暫存資料已清除 |
| R3.5 | `已完成` | Codex | 建立金鑰遺失、外洩與停止發布處理說明 | `docs/SPARKLE_KEY_RECOVERY.md`；另完成 AES-256 備份、隔離 account 還原、簽署與驗章工具 |

完成條件：依目前個人使用決策，iCloud AES-256 備份必須真正通過解鎖、隔離 account 還原、公鑰比對、簽署與驗章；取得私人外接設備後再補第二份備份。

### R4 — 本機更新實驗室

目標：在沒有正式對外發布前，證明完整升級鏈可運作。

測試版本不直接稱為正式 `1.0.0`：

```text
1.0.0-beta.1 → 1.0.0-beta.2
```

| 編號 | 狀態 | 執行者 | 任務 | 驗收證據／人工動作 |
|---|---|---|---|---|
| R4.1 | `已完成` | Codex | 建立測試 ZIP、簽章、release notes 與測試 appcast | beta.2 ZIP SHA-256 `dd26891416af1421d344c8f0b78915c3cdda454298252d893120ee0b599ef60d`；官方 Sparkle `generate_appcast` 與 `sign_update --verify` 均通過 |
| R4.2 | `已完成` | Codex | 建立 beta.1／beta.2，確認版本比較正確 | beta.1 能看到 beta.2；更新後再次檢查顯示「1.0.0-beta.2 已是目前最新的版本」 |
| R4.3 | `已完成` | 使用者 | 從隔離的 beta.1 按下「檢查更新」 | 2026-08-10 實際下載、安裝、重新啟動成功；使用者確認重啟後版本已更新為 beta.2 |
| R4.4 | `已完成` | Codex | 修改一份 ZIP 內容，確認簽章驗證拒絕 | 原始 ZIP／appcast 驗章成功；遭竄改 ZIP、錯誤簽章與遭竄改 appcast 全部被拒絕 |
| R4.5 | `已完成` | Codex | 測試 feed 離線、404、無效 XML與錯誤簽章 | feed 離線與 404 都只顯示安全錯誤；無效 XML 與錯誤簽章被拒絕，既有 beta.2 版本與簽章保持有效；長逾時情境移至 R8 網路驗收 |
| R4.6 | `移至 R8` | 使用者 | 升級後檢查主機、群組、Keychain、設定與登入狀態 | R4 採獨立 Bundle ID、`MyTerm Update Lab` 資料目錄且不含雲端設定，保證不讀寫正式資料；正式資料升級驗收留給 R8 |
| R4.7 | `移至 R8` | 使用者 | 升級後測試 SSH、SFTP、本機 Terminal、Serial | 隔離實驗室只驗證更新鏈；正式候選的四項核心操作集中於 R8 驗收 |

完成條件：beta.1 到 beta.2 的真實更新成功；破壞簽章的更新一定失敗；本機資料不受影響。

R4 隔離界線：測試 App 使用 `tw.local.MySSHClient.UpdateLab`、獨立 Application Support 目錄，且不封裝 Firebase／Google 設定；HTTP 只在明確的更新實驗室模式下允許 `127.0.0.1`／`localhost`。一般建置仍強制 HTTPS。測試結束後本機 feed 已停止，更新後的 App 仍為有效簽章。

### R5 — Git 與 GitHub 發布準備

目標：在任何原始碼或產物離開這台 Mac 前完成資料安全檢查。

| 編號 | 狀態 | 執行者 | 任務 | 驗收證據／人工動作 |
|---|---|---|---|---|
| R5.1 | `已完成` | Codex＋使用者 | 決定 LICENSE 與是否先建立私人 repository | 2026-08-10 選擇 Private；現階段不加入開源 LICENSE，未來公開前再決定 |
| R5.2 | `已完成` | Codex | 最終檢查 `.gitignore` 與歷史候選檔案 | 120 個來源候選已檢查；Exports、舊 ZIP、`.app`、Build cache、Local config、Firebase CLI Token 與 Keychain 資料均被忽略 |
| R5.3 | `已完成` | Codex | 執行主機名稱、IP、帳號、OAuth、Firebase、私鑰掃描 | 276 項測試與 `check-release-safety.sh` 通過；只保留 Firebase Project ID、測試保留網段與 Sparkle 公鑰等非機密公開參數 |
| R5.4 | `已完成` | Codex | 初始化 Git，建立第一個本機提交 | 首次提交 `ffac6ee16b671fdb9af8ffdb5e148ad94c3391d6` 已推送；本機與 `origin/main` 完全一致，作者使用 GitHub noreply 身分 |
| R5.5 | `已完成` | 使用者 | 建立／確認 GitHub repository 名稱與可見性 | 已核准 `crazy01100/myterm`；GitHub API 確認為空白 Private repository |
| R5.6 | `已完成（現階段）` | Codex | 建立保護規則：PR 不取得發布金鑰、第三方 Action 固定 SHA | `docs/GITHUB_SECURITY.md`；初始 repository 不建立 workflow，Sparkle 私鑰不進 GitHub；日後第三方 Action 必須固定完整 SHA |
| R5.7 | `移至首次啟用 Actions 前` | 使用者 | GitHub Actions 用量與付款設定確認 | 初始版本不執行 Actions，不產生用量；第一次建立 workflow 前再檢查，若要求付款或信用卡立即停止 |

完成條件：第一次 push 前再做一次完整敏感資料審核，使用者核准目的 repo 與可見性。

### R6 — Cloudflare Pages 更新站

目標：提供固定、安全、可回復的 HTTPS 更新網址。

建議結構：

```text
updates.example.com/
├── appcast.xml
├── releases/1.0.0.md
├── install/index.html
├── privacy/index.html
└── security/index.html
```

ZIP 不放 Pages，`appcast.xml` 連到 GitHub Release 的固定 HTTPS 資產網址。

| 編號 | 狀態 | 執行者 | 任務 | 驗收證據／人工動作 |
|---|---|---|---|---|
| R6.1 | `尚未開始` | 使用者 | 選擇更新用子網域 | 例如 `updates.<你的網域>` |
| R6.2 | `尚未開始` | Codex＋使用者 | 建立 Cloudflare Pages Free 靜態專案 | 不啟用 Worker、Functions、R2 或付費方案 |
| R6.3 | `尚未開始` | Codex | 設定安全回應標頭與 HTTPS | `curl`／瀏覽器驗證 |
| R6.4 | `尚未開始` | Codex | 部署測試 appcast 與 release notes | URL 穩定且可下載 |
| R6.5 | `等待人工驗證` | 使用者 | 確認 Cloudflare 沒有要求付費升級 | 若出現付款要求立即停止 |
| R6.6 | `尚未開始` | Codex | 驗證舊 appcast 可快速回復 | Pages 部署歷史或 Git revert 測試 |

完成條件：正式 App 使用的 feed URL 已固定，錯誤部署可以回復，沒有新增付費服務。

### R7 — 一鍵發布與人工放行

目標：讓每次發布不再手動拼湊指令，同時保留最後一道人工安全確認。

| 編號 | 狀態 | 執行者 | 任務 | 驗收證據／人工動作 |
|---|---|---|---|---|
| R7.1 | `尚未開始` | Codex | 建立 `release` 腳本，要求版本與 release notes | 缺參數或工作目錄不乾淨時拒絕發布 |
| R7.2 | `尚未開始` | Codex | 自動執行 276 項測試、Release 建置與簽章驗證 | 測試紀錄 |
| R7.3 | `尚未開始` | Codex | 自動建立 ZIP、Ed25519 簽章、SHA-256 與 appcast | 產物清單與驗證 |
| R7.4 | `尚未開始` | Codex | 自動建立 GitHub Draft Release，不立即公開 | Draft URL |
| R7.5 | `等待人工驗證` | 使用者 | 檢查版本、說明、下載檔、校驗碼與更新預覽 | 使用者按下放行前不公開 |
| R7.6 | `尚未開始` | Codex | 放行後發布 GitHub Release，再部署已簽署 appcast | 發布 URL 與 feed 驗證 |
| R7.7 | `尚未開始` | Codex | 發布後從外部 URL 重下載並再次驗證簽章／SHA-256 | 避免上傳後內容錯誤 |

完成條件：開發者只需提供版本與更新說明；機械工作自動完成，但公開前仍必須由使用者確認。

### R8 — 1.0 Release Candidate 人工驗收

目標：在第二台 Mac 上模擬真正使用者，不使用開發機的既有信任狀態。

| 編號 | 狀態 | 驗證項目 | 人工驗收方式 |
|---|---|---|---|
| R8.1 | `尚未開始` | 全新下載與 Gatekeeper | 第二台 Mac 下載、移入 Applications，以系統允許方式第一次開啟；不得關閉 Gatekeeper |
| R8.2 | `尚未開始` | 純本機模式 | 不登入 Google 也能建立主機、SSH、SFTP、Terminal、Serial |
| R8.3 | `尚未開始` | Google 登入與同步 | 登入、啟用同步、下載主機及密碼 |
| R8.4 | `尚未開始` | 更新安裝 | RC1 從 App 內更新到 RC2 |
| R8.5 | `尚未開始` | 資料保留 | 主機、群組、密碼、known_hosts、設定、登入與同步狀態都存在 |
| R8.6 | `尚未開始` | 同名／舊版本 | 相同版本不提示；較舊版本不覆蓋新版 |
| R8.7 | `尚未開始` | 更新失敗復原 | 中斷網路或提供錯誤簽章，舊 App 仍可開啟 |
| R8.8 | `尚未開始` | 第二位測試者 | 至少一位工程師朋友依安裝說明完成安裝與更新，回報不清楚處 |

完成條件：所有必要項目通過；任何核心資料遺失、簽章繞過或無法啟動都阻擋 1.0。

### R9 — 正式發布 `1.0.0`

| 編號 | 狀態 | 執行者 | 任務 | 驗收證據／人工動作 |
|---|---|---|---|---|
| R9.1 | `尚未開始` | Codex | 將 RC 的已驗證程式設定為 `1.0.0` | Git commit／tag 候選 |
| R9.2 | `尚未開始` | Codex | 重新執行全部測試、安全掃描與發布腳本 | 最終報告 |
| R9.3 | `等待人工驗證` | 使用者 | 審閱 Release、安裝說明、已知限制與隱私／安全文件 | 明確核准發布 |
| R9.4 | `尚未開始` | Codex | 發布 GitHub Release 與 Cloudflare Pages appcast | 公開 URL |
| R9.5 | `尚未開始` | Codex | 從正式 `appcast.xml` 檢查版本與簽章 | 線上驗證報告 |
| R9.6 | `等待人工驗證` | 使用者 | 第二台 Mac 下載正式 `1.0.0` 並確認啟動 | 最終安裝確認 |

完成條件：正式網址可用、下載檔與 appcast 簽章一致、第二台 Mac 可用、已知限制有明確說明。

### R10 — 發布後驗證 `1.0.1`

`1.0.0` 上線不代表更新鏈已永久完成。必須再發布一個不影響資料的小型 `1.0.1`，驗證真正的正式版本能收到下一版。

| 編號 | 狀態 | 任務 | 驗收證據／人工動作 |
|---|---|---|---|
| R10.1 | `尚未開始` | 準備一項低風險修正或文件／介面調整 | `1.0.1` Release Candidate |
| R10.2 | `等待人工驗證` | 從正式 `1.0.0` 按「檢查更新」升級 | 更新成功截圖／確認 |
| R10.3 | `尚未開始` | 確認 `1.0.1` 後所有資料與核心功能正常 | 回歸測試與人工確認 |
| R10.4 | `尚未開始` | 完成正式自動更新鏈驗收 | 本計劃標記完成 |

## 7. 發布阻擋條件

發生以下任一情況，不能發布 `1.0.0`：

- 自動測試不是全部通過。
- 更新私鑰沒有兩份加密備份，或備份未通過還原測試。
- 遭竄改 ZIP 仍能被安裝。
- 更新會刪除或重設主機、Keychain、known_hosts、同步資料或設定。
- Sparkle framework／helper 簽章驗證失敗。
- App 只能從開發目錄更新，放到 `/Applications` 後失敗。
- Git 歷史或 Release 產物包含真實主機、IP、帳號、Token、Firebase Local config、私鑰或密語。
- GitHub、Cloudflare、Firebase 或 Apple 要求新增付款方式、信用卡或付費方案，且使用者尚未再次批准。
- 第二台 Mac 尚未完成 RC1 → RC2 的真實更新。
- 沒有可回復的上一版 App、appcast 與發布紀錄。

## 8. 回復與事故處理

### 發布前失敗

- 不修改正式 `appcast.xml`。
- GitHub Release 保持 Draft。
- 使用者仍停留在上一個可用版本。

### 發布後發現新版有問題

- 不把 appcast 指回較小版本，避免版本比較與降級風險。
- 以最後正常程式碼建立更高版本，例如以 `1.0.0` 程式碼發布 `1.0.2`。
- 更新說明明確標示回復內容。
- 保留有問題版本的調查證據，但可從預設 appcast 移除，避免新使用者繼續取得。

### 私鑰疑似外洩

- 立即停止更新站與所有 Release 發布。
- 不使用疑似外洩金鑰簽署「修復版本」。
- 通知現有測試者不要安裝新更新。
- 在沒有 Developer ID 後備信任時，不自行假設可以無縫換鑰；先重新查核 Sparkle 官方輪替流程並取得使用者批准。

### GitHub 或 Cloudflare 無法使用

- 已安裝的 MyTerm 本機功能與 Firebase 同步繼續正常。
- 更新按鈕顯示無法取得更新，不得影響 SSH／SFTP。
- 等服務恢復後再發布；不臨時改用未審查的下載站。

## 9. 費用護欄

本計劃的必要路徑預期為零新增費用：

| 服務 | 必要用途 | 預期新增費用 |
|---|---|---:|
| Sparkle | App 內更新 | NT$0，開源 |
| GitHub repository／Releases | 原始碼與 ZIP | NT$0 範圍內使用 |
| Cloudflare Pages | 靜態 appcast 與說明 | NT$0 Free |
| Firebase | 原有加密資料同步 | 不因 App 更新增加服務 |
| Apple Developer Program | 不加入 | NT$0 |

若任何操作要求付款、綁定信用卡、升級 GitHub runner、Cloudflare Paid、Firebase Blaze 或 Apple Developer Program，該階段立即改為 `受阻`，先向使用者說明原因、價格、續約與免費替代方案。

## 10. 完全自動發布的延後項目

使用者端的自動更新不需要等待這些項目。以下只影響「開發者發布新版」能否完全無人值守：

| 編號 | 狀態 | 項目 | 延後原因 |
|---|---|---|---|
| F1 | `延後` | GitHub Actions 自動持有 Sparkle 私鑰並直接發布 | 雲端保存更新信任根的風險較高 |
| F2 | `延後` | 自架 GitHub ARM Mac runner | 公開 repo 的 runner 安全與維護成本 |
| F3 | `延後` | 背景自動下載與靜默安裝 | 先觀察手動檢查更新的穩定性 |
| F4 | `延後` | Sparkle delta 更新 | 先確保完整 ZIP 更新可靠；目前 App 體積可接受 |
| F5 | `延後` | Developer ID 與 Apple 公證 | 需要 Apple Developer Program 年費 |

`1.0` 採本機一鍵發布與人工放行，是為了避免私鑰離開主要開發 Mac。等 `1.0.1` 驗證完成後，再決定是否值得將發布簽章自動化到雲端。

## 11. 總進度表

| 階段 | 狀態 | 自動驗證 | 人工驗證 | 完成標準 |
|---|---|---:|---:|---|
| R0 計劃核准 | `已完成` | 已完成 | 已完成 | 2026-08-10 使用者核准本文件 |
| R1 版本與建置整理 | `已完成` | 已完成 | 已完成 | 276 項測試與封裝驗證通過；版本顯示已確認 |
| R2 Sparkle 核心 | `已完成` | 已完成 | 已完成 | 0.13.0 候選通過封裝驗證；未配置提示正常，介面精簡為 App 選單單一入口 |
| R3 更新金鑰 | `已完成` | 已完成 | 已完成 | 正式金鑰、公鑰嵌入、iCloud AES-256 備份與隔離還原簽署均通過；第二份私人外接備份列為未來強化 |
| R4 本機更新實驗室 | `已完成` | 已完成 | 已完成 | beta.1 → beta.2 真實更新、重啟與版本切換成功；相同版本不重複提示；離線、404、竄改與錯簽安全失敗 |
| R5 Git／GitHub | `已完成` | 已完成 | 已完成 | `crazy01100/myterm` Private repository 已建立並完成首次 push；沒有 Actions、Release、機密或付費資源 |
| R6 Cloudflare Pages | `尚未開始` | 需要 | 必要 | HTTPS feed 與回復流程正常 |
| R7 一鍵發布 | `尚未開始` | 需要 | 必要 | 一個指令建立 Draft，人工放行 |
| R8 Release Candidate | `尚未開始` | 需要 | 必要 | 第二台 Mac 全情境驗收 |
| R9 正式 1.0.0 | `尚未開始` | 需要 | 必要 | 正式下載與 appcast 可用 |
| R10 正式 1.0.1 更新鏈 | `尚未開始` | 需要 | 必要 | 1.0.0 可自動升級至 1.0.1 |

## 12. 進度維護規則

1. 每次實作必須同步更新本文件的狀態與驗收證據。
2. 只有程式碼完成，不能標記 `已完成`；指定的人工驗證也必須通過。
3. 每個新版本都記錄：版本、Build、Git commit、ZIP SHA-256、Sparkle 簽章、appcast URL、測試總數與人工驗證日期。
4. 不在文件中保存任何私鑰、密語、復原金鑰、OAuth token 或本機 Keychain 內容。
5. 發布程序遇到新外部服務、付款要求或安全權限時，先停止並修改本計劃，再請使用者重新批准。
6. 任何會對外公開、push、建立 Release、部署 Pages 或產生正式信任金鑰的動作，都要在執行前清楚告知使用者。

## 13. 已完成的第一個工作包

使用者核准本計劃後，只先執行 R1，不會一次把 GitHub、Cloudflare 與正式發布全部打開：

1. 參數化版本號與 Build。
2. 整理可重現的建置／測試／打包／驗證腳本。
3. 在設定頁顯示版本與 Build。
4. 執行完整回歸測試。
5. 重新打包、重啟，請使用者人工確認版本資訊。
6. 更新本文件進度，並在使用者同意後完成 R2 Sparkle 整合。

這種拆法讓每個重要階段都能單獨回復，也避免尚未驗證建置流程時就先產生正式更新私鑰或建立外部發布資源。
