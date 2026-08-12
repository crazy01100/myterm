# MyTerm

MyTerm 是為 **Apple Silicon 與 macOS 26** 設計的原生 SSH 管理工具。它把主機管理、SSH、本機 Terminal、Serial Port 與雙欄 SFTP 放在同一個 App 中；不登入帳號也能完整使用本機功能。

目前正式版本：**1.0.5**

- [下載與安裝](https://mtus.lieniapp.work/install/)
- [更新說明](https://mtus.lieniapp.work/)
- [開發與發布指南](DEVELOPMENT.md)
- [系統架構](ARCHITECTURE.md)
- [安全設計](SECURITY.md)

## 主要功能

- 多階層群組、搜尋、主機卡片與可選的預設使用者名稱。
- 密碼、私鑰、SSH Agent／config 驗證，以及系統預設、舊式 RSA 相容與自訂演算法。
- 使用系統 OpenSSH 與 MyTerm 專用 `known_hosts`，新主機金鑰必須由使用者確認。
- 主機密碼保存於本機 AES-GCM 加密保管庫；只有一把根金鑰存於 macOS Keychain。密碼不寫入主機資料檔，也不透過剪貼簿填入。
- 同一視窗中的 SSH 分頁、本機 zsh、Serial Port 與雙欄 SFTP；終端機分頁可用滑鼠重新排序，快捷鍵會跟隨畫面順序。
- 可把終端機分頁往下拖入相鄰連線的內容區，依綠色預覽合併為左右或上下雙窗格；一般分頁優先與前一個連線合併，第一個分頁則會使用後一個連線。每個 Workspace 最多兩個連線，可拖曳分隔線調整比例、個別切換焦點或關閉，也可把窗格標題列拖回頂部分頁列重新拆開。
- SFTP 上傳、下載、覆蓋確認、新增資料夾、重新命名、刪除與權限調整；可從 Finder 把檔案或資料夾拖到右側遠端窗格，上傳至目前遠端目錄；本機面板可在 App 內進入 OneDrive 等符號連結資料夾。
- 主機庫與 SFTP 使用一致的滑過、單擊選取及雙擊開啟操作；深層 SFTP 路徑會自動保留關鍵層級並以 `…` 收合中段目錄。
- MyTerm／Termius 主機資料匯入、可選項目預覽與 MyTerm 主機資料匯出。
- 可調整或停用的 App 內快捷鍵；已儲存密碼只會在安全的密碼提示階段允許填入。
- 自動辨識終端機輸出中的作業系統或網路設備資訊；尚未辨識的 SSH 主機會使用唯讀背景探測，並在主機庫、SFTP、連線分頁與終端機標題使用一致的平台徽章。
- Sparkle 安全更新，可由「MyTerm → 檢查更新⋯」下載並安裝正式版本。

## 選用的跨裝置同步

同步預設關閉。需要時登入 Google 帳號、開啟同步並設定同步密語，MyTerm 才會同步主機、群組與主機密碼。

- 每筆資料在 Mac 上以 AES-256-GCM 端對端加密後才送往 Firebase。
- 同步密語使用 Argon2id 派生金鑰；Master Key 與解密後密碼只保存在各台 Mac 的本機加密保管庫。
- Firebase 保存密文與必要的版本資訊，無法直接讀取主機內容或密碼。
- 私鑰檔案、私鑰路徑及 `known_hosts` 永遠只保留在各台 Mac。
- 可停用同步並繼續以純本機模式使用 App。

## 安裝需求

- Apple Silicon Mac（arm64）
- macOS 26 或更新版本

下載並解壓縮後，請先把 `MyTerm.app` 移到「應用程式」資料夾，再從該位置啟動。不要直接從 ZIP、磁碟映像、下載後的暫時位置或唯讀位置執行；macOS App Translocation 或無法替換 App 的位置會阻止 Sparkle 完成更新。

目前版本未加入 Apple Developer Program，因此第一次從網站下載後，macOS 仍可能顯示無法驗證開發者；請在「系統設定 → 隱私權與安全性」確認檔案來源後允許開啟一次。零費用自簽憑證沒有 Apple Team ID，無法保證跨版本延續 Keychain 身分；1.0.1 已將所有本機機密收斂至單一加密保管庫，使更新後需要的 Keychain 驗證不會隨主機數量增加。App 內更新仍會另外驗證 Sparkle Ed25519 簽章。

## 基本使用

1. 按「＋」建立群組或主機；主機名稱留空時會顯示主機位址。
2. 預設使用者名稱可以留空，連線時再選擇帳號。
3. 一般主機維持「系統預設」演算法；只有確認為舊設備時才啟用 RSA 相容或自訂演算法。
4. 雙擊主機卡片建立 SSH 分頁。第一次看到主機指紋時，請先透過可信管道核對。
5. 已儲存的 SSH 登入密碼會在第一次登入提示自動送出；`sudo`／`su` 等後續提示可按「填入密碼」或使用設定的快捷鍵。
6. 「Terminal」開啟位於目前使用者家目錄的本機 zsh；「Serial」連接 `/dev/cu.*` 或 `/dev/tty.*` 裝置。
7. 「SFTP」開啟本機與遠端雙欄檔案工作區；單擊選取主機、分類或檔案，雙擊才會進入分類／資料夾或建立連線。
8. 在頂部分頁列內拖曳終端機分頁可重新排序；把分頁往下拖入內容區時，MyTerm 會顯示相鄰的合併目標，並以綠色區域預覽放手後的左、右、上或下雙窗格位置。一般分頁使用前一個連線，第一個分頁改用後一個連線。合併分頁固定顯示為「Workspace」，最多容納兩個連線；可拖曳分隔線調整比例，或把任一窗格的標題列拖回頂部分頁列重新拆開。

## 從原始碼建置

需要 macOS 26、Apple Silicon，以及 Xcode 26 或相容的 Command Line Tools。

```sh
git clone https://github.com/crazy01100/myterm.git
cd myterm
./scripts/run-tests.sh
./scripts/run-dev-app.sh \
  --version 1.0.5-dev.1 \
  --build "$(date '+%Y%m%d%H%M%S')"
```

測試 App 固定位於 `build/dev/MyTerm Dev.app`，腳本只會關閉與重啟這個路徑，不會變更 `/Applications/MyTerm.app`。候選版與發布成品則分別放在帶版本與 Build 的 `build/candidates/`、`build/releases/`。`build/`、SwiftPM 快取、ZIP 與本機 Firebase／OAuth 設定都不屬於原始碼，不會提交至 Git。

目前原始碼的完整正式候選流程會執行安全檢查、329 項測試、arm64 Release 建置、固定發行憑證驗證、封裝與 SHA-256 產生：

```sh
./scripts/prepare-release-build.sh \
  --version 1.0.5-rc.1 \
  --build "$(date '+%Y%m%d%H%M%S')"
```

發布流程只會先建立私人 GitHub Draft Release，必須人工核對後才公開；公開 Release 會觸發 GitHub Actions，把簽署的更新資訊部署至 Cloudflare Pages。

各建置通道、腳本用途、候選版與發布流程請見 [DEVELOPMENT.md](DEVELOPMENT.md)。

## 資料與安全界線

- 主機清單不包含密碼；所有本機機密共用 AES-GCM 保管庫，其單一根金鑰使用 `WhenUnlockedThisDeviceOnly` Keychain 項目。
- 主機匯出檔是明文，可能包含位址、帳號與備註，必須由使用者自行妥善保管。
- MyTerm 不解密 Termius Vault；Termius 密碼需要重新輸入或依未來的官方匯出方式遷移。
- 1.0.1 起，主機／群組刪除會以通過端對端驗證的加密刪除標記同步；套用遠端刪除前會先建立本機還原備份。
- `sudo`／`su` 密碼不會自動送出，需在已辨識的安全提示中按按鈕或快捷鍵。

更多信任邊界與儲存方式請見 [SECURITY.md](SECURITY.md) 及 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 發布驗證

MyTerm 1.0.4 已完成平台圖示資源封裝修補、第二台 Mac 乾淨候選驗收，以及 GitHub Release → Cloudflare Pages 外部更新站驗證。1.0.5 在此基準上恢復 SFTP 檔案拖放傳輸，並讓第一個 Terminal 分頁也能選取後一個相鄰連線合併；候選與正式發布流程會共同驗證下列項目：

- 329 項本機自動測試，以及既有 Firestore Security Rules 測試。
- 兩台 Mac 的 Google 登入、同步密語復原、端對端加密主機與密碼同步。
- 兩台 Mac 透過正式更新鏈升級至 1.0.1；重啟、主機、群組、密碼、SSH、SFTP 與同步均維持正常。
- 使用另一台 Mac 同步而來的密碼實際建立 SSH 連線。
- 主機與群組的端對端加密刪除同步，以及套用遠端刪除前的本機備份。
- 舊版分散 Keychain 項目遷移至單一本機加密保管庫；驗證次數不再隨主機數量增加。
- Sparkle 下載、Ed25519 驗證、替換、重啟、離線失敗及竄改拒絕測試。
- SFTP 本機與遠端檔案的拖放上傳／下載，以及封裝內自訂拖放資料型別宣告。
- 第一個與非第一個 Terminal 分頁的合併、雙窗格拖曳調整與重新拆分。
- 正式 GitHub Release → GitHub Actions → Cloudflare Pages 自動部署、外部下載驗證，以及正式 1.0.4 → 1.0.5 App 內更新驗收。

正式更新來源為 <https://mtus.lieniapp.work/appcast.xml>。
