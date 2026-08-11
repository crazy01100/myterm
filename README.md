# MyTerm

MyTerm 是為 **Apple Silicon 與 macOS 26** 設計的原生 SSH 管理工具。它把主機管理、SSH、本機 Terminal、Serial Port 與雙欄 SFTP 放在同一個 App 中；不登入帳號也能完整使用本機功能。

目前正式版本：**1.0.0**

- [下載與安裝](https://mtus.lieniapp.work/install/)
- [更新說明](https://mtus.lieniapp.work/)
- [系統架構](ARCHITECTURE.md)
- [安全設計](SECURITY.md)

## 主要功能

- 多階層群組、搜尋、主機卡片與可選的預設使用者名稱。
- 密碼、私鑰、SSH Agent／config 驗證，以及系統預設、舊式 RSA 相容與自訂演算法。
- 使用系統 OpenSSH 與 MyTerm 專用 `known_hosts`，新主機金鑰必須由使用者確認。
- 主機密碼保存於 macOS Keychain，不寫入主機資料檔，也不透過剪貼簿填入。
- 同一視窗中的 SSH 分頁、本機 zsh、Serial Port 與雙欄 SFTP。
- SFTP 上傳、下載、拖放、覆蓋確認、新增資料夾、重新命名、刪除與權限調整。
- MyTerm／Termius 主機資料匯入、可選項目預覽與 MyTerm 主機資料匯出。
- 可調整或停用的 App 內快捷鍵；已儲存密碼只會在安全的密碼提示階段允許填入。
- 自動辨識已顯示在終端機中的作業系統或網路設備資訊，並以保守策略顯示平台徽章。
- Sparkle 安全更新，可由「MyTerm → 檢查更新⋯」下載並安裝正式版本。

## 選用的跨裝置同步

同步預設關閉。需要時登入 Google 帳號、開啟同步並設定同步密語，MyTerm 才會同步主機、群組與主機密碼。

- 每筆資料在 Mac 上以 AES-256-GCM 端對端加密後才送往 Firebase。
- 同步密語使用 Argon2id 派生金鑰；Master Key 與解密後密碼只保存在各台 Mac 的 Keychain。
- Firebase 保存密文與必要的版本資訊，無法直接讀取主機內容或密碼。
- 私鑰檔案、私鑰路徑及 `known_hosts` 永遠只保留在各台 Mac。
- 可停用同步並繼續以純本機模式使用 App。

## 安裝需求

- Apple Silicon Mac（arm64）
- macOS 26 或更新版本

目前版本未加入 Apple Developer Program，因此第一次從網站下載後，macOS 仍可能顯示無法驗證開發者；請在「系統設定 → 隱私權與安全性」確認檔案來源後允許開啟一次。1.0.1 起的正式版本會固定使用同一個本機發行憑證簽署，後續更新可維持一致的 Keychain 存取身分；App 內更新仍會另外驗證 Sparkle Ed25519 簽章。

## 基本使用

1. 按「＋」建立群組或主機；主機名稱留空時會顯示主機位址。
2. 預設使用者名稱可以留空，連線時再選擇帳號。
3. 一般主機維持「系統預設」演算法；只有確認為舊設備時才啟用 RSA 相容或自訂演算法。
4. 雙擊主機卡片建立 SSH 分頁。第一次看到主機指紋時，請先透過可信管道核對。
5. 已儲存的 SSH 登入密碼會在第一次登入提示自動送出；`sudo`／`su` 等後續提示可按「填入密碼」或使用設定的快捷鍵。
6. 「Terminal」開啟位於目前使用者家目錄的本機 zsh；「Serial」連接 `/dev/cu.*` 或 `/dev/tty.*` 裝置。
7. 「SFTP」開啟本機與遠端雙欄檔案工作區。

## 從原始碼建置

需要 macOS 26、Apple Silicon，以及 Xcode 26 或相容的 Command Line Tools。

```sh
git clone https://github.com/crazy01100/myterm.git
cd myterm
./scripts/run-tests.sh
./scripts/build-app.sh --version 1.0.0 --build 20260810141610
```

產生的 App 位於 `build/MyTerm.app`。`build/`、SwiftPM 快取、ZIP 與本機 Firebase／OAuth 設定都不屬於原始碼，不會提交至 Git。

完整正式候選流程會執行安全檢查、291 項測試、arm64 Release 建置、固定發行憑證驗證、封裝與 SHA-256 產生：

```sh
./scripts/prepare-release-build.sh \
  --version 1.0.1 \
  --build "$(date '+%Y%m%d%H%M%S')"
```

發布流程只會先建立私人 GitHub Draft Release，必須人工核對後才公開；公開 Release 會觸發 GitHub Actions，把簽署的更新資訊部署至 Cloudflare Pages。

## 資料與安全界線

- 主機清單不包含密碼；密碼使用 `WhenUnlockedThisDeviceOnly` Keychain 項目。
- 主機匯出檔是明文，可能包含位址、帳號與備註，必須由使用者自行妥善保管。
- MyTerm 不解密 Termius Vault；Termius 密碼需要重新輸入或依未來的官方匯出方式遷移。
- 1.0.1 起，主機／群組刪除會以通過端對端驗證的加密刪除標記同步；套用遠端刪除前會先建立本機還原備份。
- 1.0.0 不會自動送出 `sudo`／`su` 密碼，需在已辨識的安全提示中按按鈕或快捷鍵。

更多信任邊界與儲存方式請見 [SECURITY.md](SECURITY.md) 及 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 已驗證版本

MyTerm 1.0.0（Build `20260810141610`）已完成：

- 278 項本機自動測試與 9 項 Firestore Security Rules 測試。
- 兩台 Mac 的 Google 登入、同步密語復原、端對端加密主機與密碼同步。
- 使用另一台 Mac 同步而來的密碼實際建立 SSH 連線。
- Sparkle 下載、Ed25519 驗證、替換、重啟、離線失敗及竄改拒絕測試。
- GitHub Release → GitHub Actions → Cloudflare Pages 自動部署與外部下載驗證。

正式更新來源為 <https://mtus.lieniapp.work/appcast.xml>。
