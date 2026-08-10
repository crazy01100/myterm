# MyTerm 實作計劃

## 產品基準

- 只支援 macOS 26。
- 只支援 Apple Silicon（`arm64`）。
- 使用原生 SwiftUI 管理主機，並以 AppKit 嵌入終端機。
- 使用系統 OpenSSH 傳輸與 macOS Keychain 保存機密資料。
- 不提供密碼到期提醒。
- 第一個正式版本不自動偵測並送出 sudo 密碼。
- Firebase 跨裝置同步為選用功能；不登入時仍可完整使用本機功能。

## 里程碑

1. **基礎架構** — Swift package、macOS App 進入點與固定版本的終端機相依套件。
2. **主機管理** — 建立、編輯、刪除、群組、搜尋與本機保存。
3. **安全性** — Keychain、App 專用 `known_hosts`、嚴格主機金鑰驗證與僅限擁有者的資料檔。
4. **SSH** — 密碼、私鑰檔與 Agent／config 驗證；系統預設、RSA 相容與自訂演算法。
5. **終端機流程** — 互動式 xterm／VT100、同視窗 SSH 與本機 zsh 分頁、關閉／中斷與安全手動填入密碼。
6. **驗證** — 核心自我測試、arm64 Release 建置、簽章、封裝與 UI 基本測試。新舊 SSH 伺服器的即時測試仍依賴可用測試主機。
7. **版本 0.2** — 名稱與使用者名稱改為選填、正式群組、安全舊資料遷移與每次連線臨時切換帳號。
8. **版本 0.3** — 僅顯示群組的導覽列、自適應主機卡片、同視窗連線分頁與本機 Terminal。
9. **版本 0.4** — 簡化主機操作、現代化終端機外觀與正式 App 圖示。
10. **版本 0.5** — MyTerm 品牌、原生主題設定與手動匯入／同步 `known_hosts`。
11. **版本 0.6** — `Control-D` 關閉連線、保守的主機平台徽章與同視窗 Serial 連線。
12. **版本 0.7** — 多階層群組與可復原的精確 Keychain 項目清理。
13. **版本 0.8** — 可預覽的 MyTerm JSON 匯入／匯出、Termius 主機資料匯入、衝突政策與匯入前自動備份。
14. **版本 0.8.1** — 可搜尋及個別勾選的主機匯入，只建立實際需要的群組階層。
15. **版本 0.9** — 經 OpenSSH 驗證成功後詢問保存第一次登入密碼、失敗嘗試替換與排除 OTP keyboard-interactive。
16. **版本 0.9.1** — 正確處理含空格的 Application Support 路徑，讓 SSH 主機指紋可跨工作階段重用。
17. **版本 0.10** — MyTerm 專用快捷鍵的記錄、停用、重設、衝突防止與終端機／連線／分頁操作。
18. **版本 0.10.1** — 密碼提示閘門，避免快捷鍵或按鈕在一般 Shell、改密碼、確認或 OTP 提示時送出 Keychain 密碼。
19. **版本 0.11 進行中** — Firebase 設定、選用帳號、端對端加密、儲存庫安全與正式發布架構；真實登入／恢復／登出、加密核心、本機保管庫、一次性復原金鑰、雲端封套、主機／群組／Keychain 密碼密文傳輸、revision 防覆寫規則、同步基線、空白與非空白 Mac 合併，以及前景事件驅動的自動同步已完成。介面收斂為單一同步開關；輸入密語後自動完成全部設定與驗證才會啟用。兩端同一筆同時修改時採最後確認上傳者為準；Firebase 在五分鐘內剛更新則顯示「不更新／更新並同步」。主機／群組刪除同步仍未開放。
20. **同步測試版驗收** — 以兩台 Mac 驗證統一開關、密碼首次上傳／下載、90 天輪替後更新、驗證方式切換 tombstone、離線恢復與 100 台主機壓力。
21. **版本 1.0 免費發布** — 本機 ARM 建置、ad-hoc 簽署、Sparkle 安全更新、GitHub Releases 與 Cloudflare Pages；Developer ID 與公證是日後可選升級。

詳細進度與驗收證據記錄於：

- [Firebase 從零設定說明書](docs/FIREBASE_SETUP_GUIDE.md)
- [跨裝置同步執行計劃](docs/SYNC_IMPLEMENTATION_PLAN.md)
- [自動發布計劃](docs/RELEASE_AUTOMATION_PLAN.md)
- [雲端同步與發布總覽](docs/README.md)

## 目前開發環境需求

目前已安裝 Command Line Tools 26.6，編譯器與 macOS SDK 版本一致。Apple Software Update 曾在新版介面旁留下 2024 年的 `PackageDescription` 與 `PackagePlugin` arm64 私有介面；若 SwiftPM 出現未定義符號，需依 `README.md` 的系統管理員指令停用舊介面，或安裝完整的最新版 Xcode，之後 SwiftPM 才能正確編譯 package manifest 與 plugin。
