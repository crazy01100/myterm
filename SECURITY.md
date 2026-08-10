# MyTerm 安全設計

## 本機機密資料

- 每台主機的密碼分別保存為 macOS Keychain 的 generic-password 項目。
- Keychain 存取屬性為 `WhenUnlockedThisDeviceOnly`，不會透過備份遷移到其他裝置。
- 主機資料檔不包含密碼，並以僅擁有者可讀寫的 `0600` 權限保存。
- App 不會把已儲存密碼複製到剪貼簿，也不會記錄終端機輸出。
- 使用密碼驗證時，只在第一次 SSH `password:` 提示自動填入。一次嘗試後永久消耗該回呼，後續 sudo 或應用程式提示不會再收到登入密碼。
- 沒有 Keychain 密碼的主機，只在 SSH 登入密碼提示後暫時追蹤輸入。必須等本機 `/usr/bin/ssh` 透過權限 `0600` 的私人診斷檔回報 `Authenticated ... using "password"`，才詢問是否保存。再次出現登入提示時會清除失敗嘗試，再擷取下一次輸入。
- OpenSSH 診斷資料不包含密碼，並在驗證、取消或工作階段結束後刪除。暫存密碼在被替換、拒絕保存、成功保存、取消或斷線時清除。
- `keyboard-interactive` 成功時不詢問保存，因為輸入可能是 OTP 或不可重用的驗證挑戰。臨時使用者名稱也不會綁定到原主機帳號的 Keychain 項目。
- 只有工作階段帳號與主機資料中非空白的預設帳號一致時，才使用已儲存密碼；臨時切換帳號不會收到其他帳號的密碼。
- 手動「填入密碼」只把密碼位元組送入該分頁的 pseudo-terminal，隨後立即清除暫存可變緩衝區。
- 本機 Terminal 固定執行 `/bin/zsh`，只取得 SSH 共用的允許環境變數，另外加入 `SHELL=/bin/zsh`。
- 主機平台辨識只檢查已顯示給使用者且有大小上限的終端機輸出，不會暗中執行 `cat /etc/os-release` 等指令；只有找到明確標記才保存平台家族。
- Serial 只接受實際存在的 `/dev/cu.*` 或 `/dev/tty.*` 字元裝置。選項以程式參數傳給固定的 `/bin/stty` 與 `/usr/bin/screen`，不經過 Shell 字串插值。
- 版本 0.1 資料遷移保留主機 UUID，使 Keychain 關聯繼續有效，並在替換資料格式前建立僅擁有者可讀的備份。
- 更名為 MyTerm 時刻意保留原 Bundle ID、Keychain service 與 Application Support 目錄，使既有密碼仍對應相同 UUID。
- 刪除密碼時鎖定精確的 Keychain persistent reference。若舊項目屬於不相容的歷史程式簽章，不會阻止刪除主機資料；MyTerm 會顯示 service 與 account 供人工清理，不會假裝已刪除密碼。
- schema 3 多階層群組遷移會先建立權限 `0600` 的備份；遺失父群組或循環關係會修復到根層級，不刪除主機或群組。
- 只有使用者按下「載入」或「同步」時才讀取 `~/.ssh/known_hosts`。匯入的信任快照與顯示索引保存在獨立的僅擁有者可讀檔案，不安裝監視器或背景同步。
- 不解密或擷取 Termius vault 資料庫。密碼遷移必須依賴官方明文匯出，否則由使用者重新輸入。
- MyTerm 與 Termius 主機資料匯入限制檔案大小與筆數，驗證群組階層及欄位、預覽衝突、配置新的主機 UUID，並在套用前建立權限 `0600` 的 Inventory 備份。
- 自訂匯入會先過濾勾選項目再分析衝突。只建立實際接受主機所需的上層群組；跳過或無效資料不留下空群組。
- MyTerm 匯出採明確允許欄位的格式，不包含 Keychain 密碼、私鑰內容、passphrase、Token 或本機私鑰路徑。匯出的 JSON 仍是明文，可能包含主機位址、帳號與備註，使用者必須自行保管。

## SSH 信任

- 連線使用系統 `/usr/bin/ssh`，不自行實作加密協定。
- 主機金鑰保存在 App 專用、權限 `0600` 的 `known_hosts`。
- `StrictHostKeyChecking=ask` 要求確認新主機，並阻擋已改變的金鑰。
- 系統預設模式沿用目前 OpenSSH 的演算法政策。
- RSA 相容與自訂演算法只以單一主機連線的程序參數生效，不修改 `~/.ssh/config` 或全域政策。

## 目前已知限制

- 自動填入只適用於設定為密碼驗證的工作階段第一次密碼提示。惡意端點若已通過主機金鑰驗證，仍位於該次連線的憑證信任範圍內。
- 手動填入無法證明提示來源；只有在確定連到正確主機且畫面確實是密碼提示時才使用。
- App 只把私鑰路徑當作主機設定保存，不會複製私鑰內容。
- 開發版本目前採 ad-hoc 簽署；提供給其他 Mac 使用前需要 Apple Developer ID 簽署與公證。
- sudo 提示自動辨識刻意延後，以便搭配提示來源與明確確認進行安全設計。
- 平台辨識採保守的 best-effort；畫面沒有明確作業系統或網路設備標記時會維持通用圖示。
- Serial 可能因轉接器中斷、被其他程式占用或 macOS／驅動權限而失敗。目前尚無實體 USB Serial 裝置完成全流程硬體驗證。
- 跨裝置同步為預設關閉的選用功能。啟用後，主機、群組與 Keychain 密碼只會以逐筆端對端加密密文傳送至 Firebase；Master Key 與解密後密碼只保存在各台 Mac 的 ThisDeviceOnly Keychain。私鑰檔案、私鑰路徑與 known_hosts 不同步；詳細限制與驗收進度見 [同步計劃](docs/SYNC_IMPLEMENTATION_PLAN.md)。
