# MyTerm Firebase 與 Google 登入設定手冊

最後更新：2026-08-08

這份手冊只涵蓋「不綁信用卡、不加入 Apple Developer Program」的同步開發路徑。MyTerm 不登入也能完整使用；登入與同步永遠是選用功能。

## 0. 已確認的架構

```text
MyTerm
  └─ 系統預設瀏覽器
       └─ Google 桌面 OAuth 2.0（PKCE + state）
            └─ 127.0.0.1 隨機連接埠回呼
                 └─ Firebase Auth REST
                      └─ Firebase UID + ID token
                           └─ Firestore REST + Security Rules
```

採用桌面 OAuth 而不是 GoogleSignIn macOS SDK，是為了避免該 SDK 對正式 Apple 憑證與 Keychain access group 的要求。Google 官方仍支援 macOS 桌面 App 使用 loopback IP 回呼，並建議搭配 PKCE；Firebase Auth REST 可將 Google ID token 換成 Firebase ID token 與 refresh token。Firestore REST 接受 Firebase ID token，並套用 Firestore Security Rules。

官方來源：

- [Google：iOS 與桌面 App OAuth 2.0](https://developers.google.com/identity/protocols/oauth2/native-app)
- [Google：桌面 App 的 loopback 回呼仍受支援](https://developers.google.com/identity/protocols/oauth2/resources/loopback-migration)
- [Google：OAuth 2.0 最佳實務](https://developers.google.com/identity/protocols/oauth2/resources/best-practices)
- [Firebase Auth REST](https://firebase.google.com/docs/reference/rest/auth)
- [Firestore REST 驗證與 Security Rules](https://firebase.google.com/docs/firestore/use-rest-api)

## 1. 費用界線

目前固定維持 Firebase **Spark 免費方案**，不連結 Cloud Billing 帳戶。

| 項目 | 現階段費用 | 限制與處理方式 |
|---|---:|---|
| Google 社群登入 | NT$0 | Spark 可用；一般社群登入每日 3,000 位活躍使用者，遠高於個人用途。 |
| Firebase Authentication | NT$0 | 不使用電話簡訊驗證。 |
| Cloud Firestore | NT$0 | 每日 50,000 讀取、20,000 寫入、20,000 刪除；1 GiB 儲存、每月 10 GiB外傳。 |
| Firebase Emulator | NT$0 | 只在本機執行。 |
| Firebase Analytics | 不使用 | 已關閉。 |
| Cloud Functions／Storage | 不使用 | 不建立、不升級 Blaze。 |

Spark 超過免費額度時會暫停對應服務，不會自動產生帳單。只有主動連結 Cloud Billing 帳戶、升級 Blaze，或啟用要求計費的 Google Cloud 服務，才可能開始計費。

官方來源：[Firebase 方案與計費](https://firebase.google.com/docs/projects/billing/firebase-pricing-plans)、[Firestore 免費額度](https://firebase.google.com/docs/firestore/pricing)、[Firebase Authentication](https://firebase.google.com/docs/auth)。

## 2. 已完成事項

| 項目 | 狀態 | 紀錄 |
|---|---|---|
| Firebase 專案 | 已完成 | Project ID：`myterm-59a95` |
| Analytics | 已完成 | 已關閉 |
| Firestore | 已完成 | `(default)`、`asia-east1`、Production mode |
| macOS App 登錄 | 已完成 | Bundle ID：`tw.local.MySSHClient` |
| 本機設定檔 | 已完成 | `Config/Local/GoogleService-Info.plist`，已排除版本控制；目前不打包進 App |
| Emulator 與規則測試 | 已完成 | 本人固定封套與嚴格加密主機／群組／密碼紀錄放行；匿名、跨 UID、明文欄位、不支援類型、直接刪除與超大資料拒絕，共 9 組測試通過並已部署 |
| Apple 登入 | 已移除 | 不再需要 Apple App ID、Services ID、`.p8` 或付費會員 |
| Firebase Apple SDK | 已移除 | Auth 與 Firestore 改走 REST，不要求 Keychain Sharing capability |

## 3. 下一個需要在 Firebase Console 完成的動作

### 3.1 啟用 Google 登入提供者

1. 開啟 Firebase Console 的 `myterm-59a95`。
2. 進入「Build」→「Authentication」。
3. 若尚未啟用 Authentication，按「開始使用」。
4. 開啟「Sign-in method／登入方式」。
5. 選擇 **Google**。
6. 啟用開關。
7. 選擇專案支援電子郵件。
8. 儲存。

不要啟用電話、Email/Password、Anonymous 或 Apple；第一版只使用 Google。

### 3.2 建立桌面 OAuth Client

1. 從同一專案進入 [Google Auth Platform](https://console.cloud.google.com/auth/overview)。
2. 打開專案選擇器後先切到「全部」，搜尋完整 Project ID `myterm-59a95`；它第一次進入 Google Cloud Console 時不一定會列在「近期專案」。
3. 若「全部」仍找不到，確認右上角 Google 帳號與 Firebase Console 建立專案時使用的帳號相同，或在 Firebase「專案設定」→「使用者和權限」確認該帳號具有權限。不要按「新增專案」，也不要改選其他現有專案。
4. 也可直接開啟 `https://console.cloud.google.com/auth/overview?project=myterm-59a95`；若顯示沒有權限，代表目前 Google 帳號不正確或尚未加入該專案。
5. 確認目前專案是 `myterm-59a95`。
6. 在「Audience／目標對象」選擇 External；測試階段可維持 Testing。
7. 在「Branding／品牌」填入 App 名稱 `MyTerm`、支援電子郵件與開發者聯絡信箱。
8. 在「Data Access／資料存取」只保留基本身分範圍：`openid`、`email`、`profile`。
9. 前往「Clients／用戶端」→「Create client」。
10. Application type 選 **Desktop app**。
11. 名稱填 `MyTerm macOS`。
12. 建立後下載 OAuth 用戶端 JSON。不要把 JSON 內容貼到對話或提交 Git。

把下載檔重新命名為 `GoogleOAuthClient.json`，放到 `Config/Local/GoogleOAuthClient.json`。不需要手動複製 Client ID、Client Secret 或 Firebase API Key。於專案目錄執行：

```bash
./scripts/configure-cloud.sh
```

腳本會從既有的 `Config/Local/GoogleService-Info.plist` 與 OAuth JSON 讀取配對設定，產生權限為 `0600`、且被 Git 忽略的 `Config/Local/MyTermCloudConfig.plist`。Client Secret 不透過命令列參數傳入，避免留在 shell history 或程序列表。

Google 官方將桌面 App 的 `client_secret` 列為可選欄位，但此專案建立的 Desktop Client 在實際 token 交換時明確要求它。桌面 App 無法真正保密內嵌的 client secret，因此它不能取代 PKCE，也不是 Firebase 管理密鑰；下載檔仍只保存在被 Git 忽略的本機目錄。登入流程繼續強制使用 PKCE、`state`、系統瀏覽器與 `127.0.0.1` 隨機連接埠；禁止使用內嵌 WebView、固定驗證碼或手動複製回呼碼。

只使用 `openid`、`email`、`profile` 基本身分範圍，不讀取 Gmail、Drive、Calendar 或其他 Google 資料。這可避開敏感／受限 scope 的完整驗證與年度安全評估；個人用途少於 100 位使用者也可維持未驗證測試模式。若未來希望登入畫面正式顯示 MyTerm 名稱與 Logo，再處理較輕量的品牌驗證。

### 3.3 尚未完成前不要做的事

- 不把真實主機資料寫進 Firestore。
- 不在 Console 臨時放寬 Rules。
- 不連結 Cloud Billing 帳戶。
- 不啟用 Identity Platform 升級、Cloud Functions、Cloud Run、Storage、Phone Auth 或 App Hosting。
- 不建立服務帳號 JSON 私鑰。
- 不加入 Apple Developer Program。

## 4. 本機開發工具

| 工具 | 固定版本 | 用途 |
|---|---:|---|
| Firebase CLI | `15.26.0` | Emulator、規則測試與日後部署 |
| `@firebase/rules-unit-testing` | `5.0.1` | 驗證 Security Rules |
| Firebase JavaScript SDK | `12.17.1` | 只供測試，不包入 MyTerm App |
| OpenJDK | `21.0.12` | Firestore Emulator |

常用命令：

```bash
npm run test:firestore-rules
npm run emulators
```

目前不要執行 `npm run deploy:firestore`。只有 UID 規則、資料格式與 Emulator 測試完整後才部署正式 Rules。

## 5. Security Rules 推進順序

1. 保持 `allow read, write: if false;`。
2. 完成 Google 登入與 Firebase ID token 交換，但不寫入真實資料。
3. 在 Emulator 建立 `users/{uid}` 擁有者規則。
4. 測試匿名拒絕、本人允許、跨 UID 拒絕。
5. 限制欄位、型別、單筆大小與批次數量。
6. 確認雲端只會看到密文後，才部署正式規則。

## 6. 進度表

| 編號 | 狀態 | 任務 | 驗收方式 |
|---|---|---|---|
| F0.1 | 已完成 | 建立 Spark 專案並關閉 Analytics | Console 確認 |
| F0.2 | 已完成 | 建立台灣區 Firestore | `asia-east1` |
| F0.3 | 已完成 | 登錄 macOS App | plist 與 Bundle ID 驗證 |
| F0.4 | 已完成 | 建立拒絕優先 Emulator 測試 | 3 組規則測試通過 |
| F0.5 | 已完成 | 移除 Apple 登入與 Apple SDK 依賴 | 程式、測試、文件與 Release 建置通過；設定檔預設不打包 |
| F0.6 | 已完成 | 啟用 Firebase Google provider | 2026-08-08：使用者確認第 3 節完成 |
| F0.7 | 已完成 | 建立 Google Desktop OAuth Client | 2026-08-08：配對 OAuth JSON 已通過同專案驗證，來源檔與產生設定皆為 `0600`，Release 建置通過 |
| F0.8 | 已完成 | 實作 PKCE、state、nonce 與 loopback listener | RFC 7636 向量、127.0.0.1 與錯誤 state 拒絕測試通過 |
| F0.9 | 已完成 | 交換 Firebase token 並安全保存 refresh token | 2026-08-08：真實登入、新程序 Keychain 恢復與登出清除均通過；登出後 Keychain 查無 Firebase session，且同步全程關閉 |
| F0.10 | 尚未開始 | 實作 Firestore REST backend | Emulator 整合測試 |

所有 F0 安全驗收完成前，不上傳任何真實主機或密碼資料。
