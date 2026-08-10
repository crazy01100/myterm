# MyTerm Sparkle 更新簽章金鑰保管與復原

最後更新：2026-08-10  
狀態：R3 已完成正式初始化、加密備份與隔離還原簽署驗證

## 安全原則

- 正式 Keychain account 固定為 `MyTerm.Release.ed25519`。
- 私鑰只存在登入 Keychain，以及使用 AES-256 加密的備份磁碟映像。
- 公鑰與公鑰 SHA-256 不是秘密，可以保存在專案與發布紀錄。
- 私鑰文字、備份密碼與解密後檔案不得貼入對話、Git、GitHub、Cloudflare 或 Firebase。
- 沒有 Apple Developer ID 作為後備信任時，遺失這把金鑰可能讓既有 MyTerm 無法安全接受後續更新。

## 正式建立順序

標準建議是在產生金鑰前準備兩個互相獨立、且不在 MyTerm 專案內的備份目的地，例如：

1. 一個只在備份時連接的外接磁碟。
2. 另一個不同的離線媒體，或獨立雲端中的 AES-256 加密映像。

不把「同一台 Mac 的兩個資料夾」視為兩份災難復原備份。

### 目前個人使用決策

2026-08-10 使用者確認目前沒有私人外接設備，兩個 OneDrive 也不是私人帳號，因此選擇：

- 正式原始金鑰：這台 Mac 的登入 Keychain。
- 唯一外部備份：iCloud Drive 內的 AES-256 加密磁碟映像。

這符合目前個人專案的便利性需求，但低於兩個獨立備份的標準：若 Mac 與 iCloud 帳號同時無法取用，可能失去更新信任根。這是已知並接受的取捨；未來取得私人外接設備時，應再增加第二份備份。

### 2026-08-10 驗證紀錄

- 正式 Keychain account：`MyTerm.Release.ed25519`。
- 公鑰 SHA-256：`bbf8cf94fa2ce3e7dc1ff6b21e50f472c8dad7b79c6ebd40e9c02e7ee686baae`。
- iCloud AES-256 備份 SHA-256：`fa480590428e8d3c05caedea3832c5a4c70e35617fb472096c779a0e320451e9`。
- 備份權限：僅目前 macOS 使用者可讀寫。
- 已以一次性隔離 Keychain account 真實還原私鑰、公鑰比對、簽署測試檔並驗章成功；測試 account 與暫存明文均已清除。
- MyTerm 0.13.0 Build `20260810050000` 已嵌入相同公鑰；本機更新實驗室已通過，尚未設定正式公開 feed。

目前可用單一步驟在本機 Terminal 執行：

```sh
cd /path/to/MySSHClient
./scripts/initialize-sparkle-signing-key.sh \
  "$HOME/Library/Mobile Documents/com~apple~CloudDocs/MyTerm 安全備份/MyTerm-Sparkle-Key-Backup.dmg"
```

建立加密映像時由 macOS 直接詢問密碼。密碼不可只保存在同一台 Mac 上，也不可放入本專案。

## 真實還原簽署測試

若日後增加另一份備份，也必須各自執行：

```sh
./scripts/verify-sparkle-key-backup.sh /備份/絕對路徑/MyTerm-Sparkle-Key-Backup-1.dmg
```

驗證程序會：

1. 以唯讀方式解鎖 AES-256 映像。
2. 將私鑰匯入一次性的隔離 Keychain account。
3. 比對還原後的公鑰。
4. 真正簽署一個測試檔並重新驗章。
5. 刪除一次性 Keychain 項目與所有測試檔。

目前 R3 以 iCloud 備份通過作為完成條件，並保留「增加第二份獨立備份」為後續安全強化項目。

## 遺失或外洩

- 遺失其中一份備份：停止發布新版本，立即從仍可信的備份建立新的第二份備份並重新驗證。
- 懷疑私鑰外洩：立即停止發布與更新站部署；不要自行換鑰。先查核 Sparkle 當時版本的官方輪替條件，再決定是否必須發布遷移版本。
- Keychain 與全部備份都遺失：不要以新金鑰假裝可以延續原更新鏈；既有 ad-hoc 版本沒有 Developer ID 後備信任，可能需要使用者重新手動安裝新的信任根版本。
