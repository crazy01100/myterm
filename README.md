# MyTerm

MyTerm 是專為 **Apple Silicon 上的 macOS 26** 設計的本機 SSH 管理工具。每台主機的密碼分別存入 macOS Keychain，SSH 工作階段直接顯示在 App 內；只有使用者明確指定的舊主機才會開放相容演算法。

為保留升級相容性，App 顯示名稱雖已改為 MyTerm，Bundle ID、Keychain service 與 Application Support 目錄仍刻意沿用原本的 `MySSHClient` 識別字，避免既有主機和密碼失去關聯。

## 版本 0.13 測試候選功能

- 建立、編輯、刪除與搜尋主機；名稱留空時以主機名稱或 IP 顯示。
- 可收合的多階層群組，支援建立、改名、刪除、指定主機、麵包屑路徑、下層數量與循環防止。
- 預設使用者名稱可留空；連線時再輸入，也可臨時改用其他帳號而不修改主機設定。
- 密碼、私鑰與 SSH Agent／config 驗證。
- 系統預設、舊式 RSA 相容與自訂 SSH 演算法模式。
- App 專用且嚴格驗證的 `known_hosts`。
- 單一視窗工作區：固定主機頁，以及每個 SSH、本機 Terminal 或 Serial 工作階段各自的分頁。
- 左側只顯示群組，右側以自適應卡片顯示群組與主機，適合較大的主機數量。
- 內建本機 Terminal，以 login shell 執行系統 `/bin/zsh`。
- 在 Shell 按 `Control-D` 送出 EOF，程序結束後關閉 SSH 或本機 Terminal 分頁；Serial 分頁則立即中斷並關閉。
- 內建 `/dev/cu.*` 與 `/dev/tty.*` Serial 工作區，提供 baud rate 及可收合的 data bit、stop bit、parity、flow control 設定。
- 依連線畫面中明確文字辨識 Linux、macOS、BSD 或網路設備家族；不會暗中執行偵測指令。
- 主機卡片以雙擊連線、右鍵選單編輯，避免工具列出現重複按鈕。
- 現代化終端機工作區，使用 SF Mono、精簡狀態列、圓角表面與自適應淺色／深色配色。
- 原生 App 圖示，以 `>_<` 終端機表情與淺色雲朵為主體。
- 原生設定視窗，可由 MyTerm 選單或 `Command-,` 開啟，支援自動、淺色與深色主題。
- 已固定整合 Sparkle 2.9.5，MyTerm App 選單提供「檢查更新…」入口。0.13 測試候選尚未放入正式更新網址與公鑰，因此只顯示安全說明，不會連線或下載檔案。
- 原生「資料」選單與「設定 > 匯入與匯出」，支援可預覽的 MyTerm JSON 匯入／匯出及 Termius 主機資料匯入。
- 匯入前預覽完整群組路徑、重複連線處理、錯誤資料報告，並自動建立僅擁有者可讀的備份。
- 匯入時可選擇全部或搜尋並逐台勾選；只建立實際接受主機所需的群組階層。
- 可攜式匯出包含主機資料、多階層群組、偵測平台與演算法設定；刻意排除密碼、私鑰內容與本機私鑰路徑。
- 獨立的 Known Hosts 工作區，只有按下「載入」或「同步」時才讀取 `~/.ssh/known_hosts`。
- 已匯入的 known-host 項目保存在僅擁有者可讀的檔案，以主機與金鑰指紋顯示，並作為獨立 SSH 信任來源，不會變成可編輯主機。
- 透過 Keychain 自動完成第一次 SSH 密碼登入，不使用剪貼簿。
- 主機未保存密碼時，MyTerm 只擷取 SSH 登入嘗試；等本機 OpenSSH 確認確實以 `password` 驗證成功後，才詢問是否保存到 Keychain。
- 第一次密碼輸入錯誤時會清除失敗內容，只保留後續成功的嘗試；排除 `keyboard-interactive`，避免保存 OTP 或驗證挑戰。
- 無法辨識或重複的密碼提示仍可使用手動「填入密碼」。
- MyTerm 專用自訂快捷鍵，包含複製、貼上、全選、搜尋、受密碼提示保護的 Keychain 密碼填入、主機／本機／Serial 工作區、分頁與中斷連線；每項都可重設或停用，並防止衝突與占用必要的 macOS 快捷鍵。
- 目前正式功能仍以純本機資料為主，不依賴外部密碼管理器。選用的 Firebase 帳號採 Google Desktop OAuth，可真實登入、從 ThisDeviceOnly Keychain 恢復登入狀態並完整登出；登入不等於啟用同步。
- 端對端加密核心已完成 HKDF-SHA256、AES-256-GCM、Argon2id 同步密語封套、256-bit 復原金鑰封套與固定格式版本；Master Key 只保存在這台 Mac 的 ThisDeviceOnly Keychain。
- 「帳號與同步」只有一個同步開關。使用者登入 Google、打開同步並輸入同步密語後，MyTerm 會在背景自動完成本機保管庫、雲端封套、首次主機／群組合併、密碼同步、基線與回讀驗證；全部成功後開關才會真正打開。新保管庫另顯示一次性復原金鑰。
- 跨裝置同步是選用功能，預設關閉，且啟用狀態綁定 Firebase UID；切換帳號不會沿用另一個帳號的同意。啟用後會在本機編輯、App 回到前景及前景每五分鐘自動檢查，並保留「立即同步」與完整進階只讀預覽。主機、群組與 Keychain 密碼會逐筆端對端加密同步；密碼在目的 Mac 解密後只寫入 Keychain，不建立明文檔。私鑰檔案、私鑰路徑與 known_hosts 永不跨裝置。
- 單方面變更會自動上傳或在建立 `0600` 備份後下載；同一筆在兩台 Mac 都修改時以最後確認上傳的內容建立下一個 revision。若 Firebase 的可信更新時間距今未滿五分鐘，MyTerm 會詢問「不更新」或「更新並同步」，不會靜默覆蓋。主機／群組刪除同步仍安全停用；不再使用的密碼紀錄則改為經驗證的加密 tombstone。Firestore 只允許登入者存取自己 UID 下的嚴格格式密文，拒絕明文欄位、跨帳號存取、直接刪除及不連續 revision。
- 自動遷移版本 0.1 主機陣列，建立僅擁有者可讀的 `hosts-v0.1-backup.json` 並保留主機 UUID。

密碼到期提醒與自動送出 sudo 密碼刻意不納入目前版本。密碼提示辨識只用來保護手動按鈕與快捷鍵，避免在一般 Shell 提示意外送出已保存密碼。

## 建置需求

- macOS 26
- Apple Silicon Mac
- Command Line Tools for Xcode 26.6，或目前最新版完整 Xcode

這台 Mac 已安裝 Command Line Tools 26.6。若 Apple 更新後留下 2024 年舊版 `PackageDescription` 私有介面，導致 SwiftPM 回報未定義符號，可執行一次：

```sh
sudo mv /Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule/arm64-apple-macos.private.swiftinterface /Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule/arm64-apple-macos.private.swiftinterface.disabled
sudo mv /Library/Developer/CommandLineTools/usr/lib/swift/pm/PluginAPI/PackagePlugin.swiftmodule/arm64-apple-macos.private.swiftinterface /Library/Developer/CommandLineTools/usr/lib/swift/pm/PluginAPI/PackagePlugin.swiftmodule/arm64-apple-macos.private.swiftinterface.disabled
```

要復原時對調來源與目的路徑即可。另一個做法是安裝完整最新版 Xcode，就不需要此暫時處理。

完整候選建置與測試（不會上傳或發布）：

```sh
cd /path/to/MySSHClient
build_number="$(date '+%Y%m%d%H%M%S')"
./scripts/prepare-release-build.sh \
  --version 0.13.0 \
  --build "$build_number"
```

版本與 Build 必須明確提供；Build 只能增加，重複或倒退會被拒絕。流程會依序執行敏感資料檢查、276 項測試、arm64 Release 建置、App 驗證、ZIP 打包、SHA-256 產生，並將解壓後的 App 再驗證一次。App 產生在 `build/MyTerm.app`，ZIP 與 `CHECKSUMS.txt` 產生在 `build/release/`；目前採 ad-hoc 簽署。

只需執行測試時可使用 `./scripts/run-tests.sh`。單獨建置 App 時仍必須傳入 `--version` 與 `--build`。完整規則見 [本機正式候選建置說明](docs/RELEASE_BUILD_GUIDE.md)。

## 使用方式

1. 可先從「+」建立群組，再新增主機並選擇密碼、私鑰或 SSH Agent／config 驗證。
2. 主機名稱與預設使用者名稱都可留空；名稱留空時顯示位址，使用者名稱留空時每次連線詢問帳號。
3. 除非主機較舊，演算法維持「系統預設（推薦）」。
4. 確認是 RSA／SHA-1 舊主機時使用「舊式 RSA 相容」；只有主機明確需要特定 KEX、cipher 或 key algorithm 時才用「自訂」。
5. 左側選擇群組，右側卡片顯示主機；單擊選取、雙擊連線。
6. 按「Terminal」開啟本機 zsh 分頁。切回「主機」時連線仍保持，關閉工作階段分頁才結束程序。
7. 在 Shell 提示按 `Control-D` 可結束程序並關閉分頁。
8. 按「Serial」選擇已連接裝置；安全預設為 9600／8-N-1／無 flow control，裝置有特殊要求時才展開進階設定。
9. 新主機指紋只能在透過可信管道核對後接受。
10. 使用密碼驗證時，只有工作階段使用主機設定中的預設帳號，第一次 SSH `password:` 才會自動填入；臨時帳號需自行輸入密碼。
11. 由「MyTerm > 設定⋯」或 `Command-,` 選擇自動、淺色或深色外觀。
12. 在側邊欄開啟 Known Hosts，第一次按「載入」，需要更新時按「同步」；MyTerm 不在背景讀取 `~/.ssh/known_hosts`。
13. 由「資料 > 匯入主機資料⋯」或「設定 > 匯入與匯出」預覽 MyTerm 或支援的 Termius JSON。預設匯入全部並跳過位址／連接埠／帳號相同的連線；使用「自訂選擇」可小範圍測試。
14. 使用「資料 > 匯出主機資料⋯」建立明文主機資料備份。密碼不會離開來源 Mac 的 Keychain，目的 Mac 需重新輸入。
15. 匯入的密碼主機可正常輸入密碼；OpenSSH 確認該次嘗試成功後，MyTerm 才詢問是否保存。選擇「不要儲存」會立即丟棄。
16. 在「設定 > 快捷鍵」記錄、停用或重設 MyTerm 專用快捷鍵。`Command-P` 不經剪貼簿直接送出目前主機的 Keychain 密碼，但只在畫面正等待已辨識密碼提示時生效。

平台徽章刻意採保守策略。若登入 banner 或指令輸出沒有明確作業系統／設備標記，主機會保留通用伺服器圖示。品牌相關徽章以系統符號重新設計，不複製廠商圖案。

## Termius 資料遷移

Termius 桌面版 vault 資料以 Electron IndexedDB 加密，加密材料由作業系統 Keychain 保護。MyTerm 不會繞過保護或從執行中的 App 擷取明文密碼。Termius 目前沒有公開一般用途的主機加密碼完整匯出格式，因此密碼需重新輸入，除非未來提供官方匯出方式。

專案內的 Termius 匯出工具會產生 `myterm-termius-host-export-v1` JSON，只包含可人工檢查的主機與群組資料。MyTerm 透過與原生匯入相同的預覽與衝突檢查處理該檔案；CSV 與原始 Termius vault 檔不接受直接匯入。

安全界線請見 [SECURITY.md](SECURITY.md)，版本里程碑請見 [PLAN.md](PLAN.md)，選用的 Firebase 同步與正式發布則由 [雲端同步與發布總覽](docs/README.md) 追蹤。純本機模式仍是預設，不需要帳號。

## 已驗證建置

版本 0.13.0 Build 20260810050000 測試候選已在 macOS 26 arm64 與 Command Line Tools 26.6 建置與測試。2026-08-10 的 132 項核心自我測試、2 項 OAuth loopback 與 142 項端對端加密／復原／Keychain／Firestore／主機與密碼同步／五分鐘保護政策測試，共 276 項全數通過；既有 9 項 Firestore Security Rules 測試亦已完成。真實兩台 Mac 已完成登入、Master Key 復原、加密主機資料上下載、基線與衝突情境驗收。Google 登入採系統瀏覽器、PKCE S256、state、nonce、僅限 127.0.0.1 的隨機連接埠與 Firebase REST；登入狀態使用獨立的 ThisDeviceOnly Keychain 項目。Release App 與解壓後封裝皆通過 ad-hoc 簽章、純 arm64、macOS 26、版本、Sparkle framework／helpers／rpath、正式更新公鑰及禁止檔案驗證；目前尚未設定正式更新 feed。ZIP SHA-256 為 `e0f245b67dc9eb89597d12ff883a9f0c15ab6a69907417912d4f2ee6d3040ab4`。本機更新實驗室已完成 `1.0.0-beta.1` 到 `1.0.0-beta.2` 的真實下載、簽章驗證、替換、重啟與版本切換；相同版本不重複提示，離線、404、無效 XML、竄改檔案與錯誤簽章皆安全失敗。libsodium 靜態併入 App，不需要另一台 Mac 額外安裝。主機／群組刪除同步仍保持安全停用。

建置流程會將指定的版本、Build 與打包時間注入實際 App bundle，並顯示在「設定 → 帳號與同步 → 目前狀態」。重新打包不會替換已載入記憶體的舊程序；測試新版前必須完整結束並重開。為避免中斷 SSH／Terminal／Serial，重啟應在確認沒有需要保留的連線後執行。
