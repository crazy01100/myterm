# MyTerm 端對端加密格式與安全紀錄

最後更新：2026-08-09

## 目前邊界

本文件記錄已完成並通過本機測試的加密核心。Firestore 允許登入者存取自己 UID 下固定的 `vaultKeys/current` 加密封套，以及 `vault/{recordUUID}` 下嚴格限定格式的主機／群組／密碼密文；額外明文欄位、跨 UID、直接刪除及其他所有路徑仍拒絕。設定頁使用單一、預設關閉且綁定 Firebase UID 的同步開關。

## 相依套件

- Argon2id 實作：`swift-sodium 0.11.0`
- 固定 revision：`cfd195c76882aa9b997560ca7cb95d72fbf5db00`
- 底層函式庫：libsodium；套件包含 Apple ARM64 XCFramework
- 授權：ISC
- 選用理由：不自行實作密碼雜湊；套件支援 macOS、ARM64 與 Xcode 26，並直接提供 libsodium `crypto_pwhash` 的 Argon2id v1.3 API。
- 版本固定位置：`Package.swift` 與 `Package.resolved`

官方參考：

- [swift-sodium](https://github.com/jedisct1/swift-sodium)
- [libsodium password hashing](https://doc.libsodium.org/password_hashing/default_phf)
- [RFC 9106 Argon2](https://www.rfc-editor.org/rfc/rfc9106/)
- [CryptoKit AES.GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm)

## 金鑰階層

1. 每個 Firebase UID 產生一把 256 位元 Master Key。
2. Master Key 以 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 保存於本機 Keychain，不直接上傳。
3. 每筆紀錄以 HKDF-SHA256 從 Master Key 衍生 256 位元專用金鑰。
4. 紀錄以 CryptoKit AES-256-GCM 加密，每次使用新的 96 位元 nonce。
5. Firebase 只會取得密文、nonce、authentication tag 與版本／衝突處理所需的非機密中繼資料。

## 紀錄格式 v1

AAD 使用長度前綴的二進位格式，不使用可能有鍵值排序差異的 JSON。AAD 綁定：

- Firebase UID
- Record UUID
- Record Type
- Format Version
- Key Version
- Revision
- Modified Device UUID
- Deleted flag

因此密文被搬到其他帳號、改成其他類型、偽造版本、revision、裝置或刪除標記時，都會驗證失敗。`modifiedAt` 目前只用於顯示與排序，不納入 v1 AAD；未來 Firestore timestamp 正規化完成後再評估格式升級。

## 同步密語封套

- 演算法：Argon2id v1.3
- Salt：每個封套隨機 16 bytes
- Output：32 bytes
- Operations Limit：3
- Memory Limit：64 MiB
- 封裝：AES-256-GCM

這組參數採 RFC 9106 的 64 MiB 方向，並明確存入封套，避免 libsodium 未來預設值改變而無法復原。App 只接受受限範圍的雲端參數，防止惡意封套要求極端記憶體或運算量造成阻斷服務。

## 復原金鑰封套

- 復原金鑰：系統安全亂數產生 256 bits
- 顯示格式：`MYTERM-R1-` 加 Base64URL
- 包裝金鑰：HKDF-SHA256，使用每個封套獨立的 16-byte salt
- 封裝：AES-256-GCM

目前已完成產生、解析、封裝、錯誤金鑰拒絕、一次性顯示，以及缺少本機 Master Key 時以同步密語或復原金鑰重建 Keychain 的介面與測試。使用者必須明確確認已保存；若離開畫面而未確認，MyTerm 不會再次顯示舊金鑰，只能在本機 Master Key 仍存在時產生新金鑰並使舊復原封套失效。

加密封套會保存在 Application Support 的 `Sync` 目錄，以 Firebase UID 的 SHA-256 作為檔名且權限為 `0600`。本機 JSON 只包含密文、nonce、驗證標籤、公開 KDF 參數與版本，不包含同步密語、復原金鑰或 Master Key 明文。

## 已通過的安全測試

- 固定 v1 AES-GCM ciphertext 與 authentication tag 測試向量。
- 正確資料往返解密。
- 不同 Firebase UID 拒絕。
- 密文竄改拒絕。
- 偽造 deletion flag 拒絕。
- Master Key Keychain 往返、ThisDeviceOnly 屬性與刪除。
- 正確／錯誤同步密語。
- 正確／錯誤復原金鑰。
- JSON 封套不包含 Master Key 或復原金鑰明文。
- 超大或不支援的 Argon2id 參數在配置記憶體前拒絕。
- 本機封套檔案權限為 `0600`，不包含同步密語或復原金鑰明文。
- 未確認的復原金鑰重新產生後，舊金鑰無法解開新的復原封套。
- 錯誤同步密語或復原金鑰不會在乾淨裝置的 Keychain 留下 Master Key。
- 正確同步密語與復原金鑰都能還原完全相同且具 ThisDeviceOnly 屬性的 Master Key。
- Firestore REST 請求固定使用本人 UID 路徑與 Firebase ID token，封套往返不含同步密語或復原金鑰明文。
- 主機與群組在上傳格式產生前即以個別衍生金鑰加密；Firestore 請求不含主機名稱、IP、使用者名稱、備註或私鑰路徑明文。
- 私鑰驗證方式可同步，但本機私鑰檔案路徑刻意不跨裝置；另一台 Mac 必須自行選擇本機金鑰。
- Firestore 主機／群組傳輸支援每頁 100 筆的有界分頁、64 KiB 密文上限與加密 tombstone。
- Security Rules 共 9 組 Emulator 測試，涵蓋本人主機／群組／密碼密文讀寫、跨 UID、明文額外欄位、不支援類型、錯誤版本／大小、revision 逐次加一及直接刪除拒絕。
- Keychain 密碼使用獨立衍生金鑰逐筆 AES-GCM 加密；本機同步基線只保存以 Master Key 衍生的 HMAC-SHA256 摘要，不保存可供離線猜測的無金鑰密碼雜湊或明文。目的 Mac 解密後只寫入 ThisDeviceOnly Keychain。
- 主機改用私鑰或 Agent 時，舊密碼紀錄會改寫為經 AAD 驗證的空密文 tombstone；重新改回密碼時以下一個 revision 建立新密文。
- 首次同步預覽只讀取資料；相同 UUID 但內容不同、雲端 tombstone 對上仍存在的本機資料，以及類型不一致，一律列為衝突而不猜測覆蓋方向。
- 兩端內容完全相同後，本機可保存 `0600` 同步基線。基線只有 Firebase UID 雜湊、逐筆內容雜湊、密文紀錄雜湊、revision、隨機裝置 ID 與建立時間，不含主機名稱、位址、帳號、備註、密碼或私鑰路徑。
- Firestore 規則要求主機／群組從 revision 1 建立，更新只能為目前 revision + 1，且不能在原文件上改變 record type、key version 或 format version。
- 手動同步採本機現況、Firebase 現況與同步基線三方比較。只有雲端仍等於基線、本機內容雜湊已改變時才允許上傳；只有本機仍等於基線、Firebase 單方面新增或修改時才允許下載合併。兩端皆變、任何一端刪除或未知 UUID 同時存在時全部停止。
- 每筆成功上傳後立即解密驗證並原子更新 `0600` 本機基線。若網路寫入成功後 App 在基線落盤前中斷，只有相同裝置、恰好下一個 revision 且解密內容等於目前本機時，才允許修復基線而不重複上傳。
- 預覽會拒絕重複 UUID、遺失上層群組、循環群組及指向不存在群組的雲端主機；比較私鑰型主機時忽略只屬於本機的私鑰路徑。
- 空雲端初始化在上傳前重新讀取 Firebase；每筆文件使用 `currentDocument.exists=false` 的建立前置條件，避免預覽後另一台裝置寫入時被覆蓋。完成後會重新下載、解密並要求全部紀錄與本機相同。
- 每台 Mac 使用隨機 UUID 作為同步裝置識別，不取用硬體序號或帳號資訊；檔案權限為 `0600`，且只在使用者確認初始化時才建立。
- 空白 Mac 還原只接受本機沒有任何主機／群組、預覽全部為下載且沒有衝突的情況；套用前重新讀取 Firebase，要求每筆密文與預覽完全相同。
- 還原前會在 `Sync Backups` 建立權限 `0600` 的本機 inventory 備份；解密結果再次拒絕重複 UUID、同層重名群組、循環階層、遺失群組及任何私鑰路徑後才原子寫入。
- 非空白資料下載合併會在套用前重新確認 Firebase 密文與預覽完全相同，建立同樣的 `0600` 本機備份，再原子寫入。密碼與 Keychain 完全不參與；私鑰型主機若已有本機路徑會保留該路徑，雲端值永遠不會覆蓋它。合併後才更新本機基線，若中途中斷，下次預覽只會提出可驗證的基線修復。
- 空白裝置還原會以剛驗證的 Firebase 快照立即建立同步基線，避免使用者第一次儲存主機時因缺少共同版本而產生假衝突。早期開發版若已還原但沒有基線，只能經使用者明確確認，以 Firebase 現況建立共同起點；動作不覆蓋任一端，本機差異會保留並重新分類為待上傳變更。

## 尚未完成與已知限制

- 尚未進行獨立安全審查。
- Swift `String` 無法保證原始同步密語的所有記憶體副本立即清零；傳入 libsodium 的 byte buffer 會在使用後清零。未來 UI 應縮短密語生命週期且不得記錄。
- AEAD 可偵測竄改；Firestore revision 規則與本機同步基線可阻止一般舊版覆寫並偵測同 revision 密文變化。完整的離線 rollback／conflict 選擇仍需在持續同步協調器中完成。
- 真正兩台獨立 Mac 的同步密語復原、主機資料往返、基線與衝突已完成人工驗收；統一開關與密碼往返仍待本版驗收。
- 空雲端初始上傳與 revision 2 手動更新已完成真實 Firebase 往返驗收。
- 空白 Mac 的雲端下載套用已完成，尚待真正第二台 Mac 人工驗收。
- 本機已有資料時的安全單向下載合併已完成；持續同步、rollback、刪除與衝突選擇尚未完成。
- 主機／群組刪除同步仍安全停用；密碼不再使用時已有獨立 tombstone 流程。
