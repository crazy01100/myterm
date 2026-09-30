# 安全維護與發布驗證

**繁體中文** | [English](SECURITY_MAINTENANCE.en.md)

本指南說明相依套件維護與發布驗證。App 的資料保護界線見 [安全設計](SECURITY.md)，建置與發布程序見 [開發指南](DEVELOPMENT.md)。

## 相依警示與處理

啟用 GitHub 的 dependency graph、Dependabot alerts，並確認維護者已訂閱安全警示與 Actions 失敗通知。首次啟用時主動檢查既有警示；收到新版本不代表應自動合併或發布。

`.github/dependabot.yml` 提供每週一的 Swift、npm、GitHub Actions 與驗簽 Python 套件更新提案。日常監測 `MyTerm security monitor`（security-checks.yml）每天台北時間 09:23 及手動執行，檢查來源與最新正式 Release；`MyTerm release security gate`（security-gate.yml）則在 PR／main 推送檢查來源，維持中高風險阻擋。排程可能延遲，不保證準時。

日常監測的成功表示掃描與 Issue 處理完成，不代表沒有風險。有風險時以 Issue 記錄公告、元件、版本、影響範圍、上游修補資訊及例外期限；同一公告／元件／範圍沿用同一 Issue，沒有變化就不重複寫入。重要變更追加紀錄；只有完整成功掃描確認不再命中時才關閉，再次命中會重新開啟。人工作業的 Issue 不由工具管理，人工關閉仍命中的自動 Issue 不等於接受風險，下次會重新開啟。

只有查詢、測試、報告或 Issue 寫入等運作異常才使日常監測 Fail；即使連續相同故障也不能顯示成功。來源安全門檻是另一個 workflow，發現未處理風險仍會阻擋，不能把它解讀成監測故障。未知適用範圍記為待確認風險，不宣稱安全。

Issue 寫入權限只供 `crazy01100/myterm` 預設分支的排程／手動監測，PR 無此權限；fork 不會自動執行此監測 job。工具預設拒絕公開庫寫入，本庫 workflow 以 `--allow-public` 明確允許已審閱的公開公告資訊。紀錄只包含公開公告、相依版本與接受狀態，不包含主機、憑證或使用者資料。`scanStatus` 與 `lastSuccessfulScanAt` 記錄掃描健康；前次成功距今超過 48 小時會在下一次檢查提示。排程完全不執行時無法靠自己即時報警。上游版本資訊仍保存在掃描報告；沒有命中的一般新版由 Dependabot 提案追蹤，不為每個新版建立風險 Issue。

```sh
./scripts/project-python.sh scripts/security-audit.py --output build/security-report.json
./scripts/project-python.sh scripts/security-audit.py --include-release OWNER/REPOSITORY --output build/security-report.json
```

需要已登入且有適當讀取權限的 `gh`、Python 3.12 以上、Node.js 24 LTS及 npm。只查詢公開公告與必要來源／版本資訊，不讀取本機雲端設定或簽章私鑰。`Config/Security/native-components.json` 將 libsodium 版本綁定到 swift-sodium revision；更新 wrapper 後必須重新核對實際 XCFramework header。上游修復版以 commit 公告的 Vendor，使用 commit ancestry 判斷，不捏造版本號。

新增中高風險、未知適用範圍或查詢錯誤會阻擋發布前檢查；最新已發布 App 的舊漏洞仍列在監測報告，但不阻擋用已修復來源建立後續更新。例外只可使用 `Config/Security/exceptions.json` 明確列出的公告、元件、版本及 development scope，附接受人、理由與期限；最長 31 天，逾期自動恢復阻擋。不因屬於 devDependency 就整類忽略。


`security-audit.py --monitor` 只在掃描運作異常時回傳失敗；風險清單仍完整保存在報告。未加 `--monitor` 的發布前檢查維持未處理風險阻擋。自行發行者應建立自己的風險追蹤流程。未知新漏洞、私人測試證據與使用者資料不屬於自動公開範圍，通報方式見 [安全設計](SECURITY.md)。


發布安全門檻以失敗的檢查結果表示來源不符合政策；它不等於 GitHub 已強制設定分支保護。分支保護須由維護者在 GitHub 另外設定並核對，不因 workflow 存在或儲存庫改為公開就視為已啟用；維護者不得合併未通過檢查的變更，本機發布入口亦會重新檢查。

Issue 內文只保留公告連結、元件、受影響範圍、目前版本、版本比對、對應分支的修補版本及掃描時間；不重複加入監測正常提醒、公告連結或通用建議。時間以 `YYYY-MM-DD HH:mm:ss（UTC+8）` 顯示，內部報告仍保留帶時區的原始時間。npm 公告按實際受影響版本範圍對應 GitHub Advisory 的修補版本；不同 major 並存時逐分支列出。上游未提供與資料待確認分開表示，查詢失敗仍屬運作錯誤。

`security-risk-context.py` 從鎖檔收集相依路徑，並讀取 `Config/Security/impact-assessments.json` 的逐案原始碼／輸入條件審查。實際影響分為「已確認受影響」「已確認不受影響」「待確認」，呈現簡短依據、範圍與公開來源。相依路徑不是函式可達性證明；這不是每次掃描都能自動完成的通用漏洞分析。評估綁定公告、版本及相關來源檔案雜湊；變更後回到待確認。歷史評估只在明確對應的原掃描時間套用並標示基準，不因目前來源修復而改寫當時結論。影響評估不自動豁免既有發布安全門檻。

`security-issue-format.py` 保留機器可讀的公開欄位快照與原始掃描／解除時間。手動監測可選擇 `refresh_issue_format` 整理既有 Bot Issue；純格式變更不追加風險變更留言、不重開已關閉 Issue。人工留言及未知的人工正文內容保留；無法可靠解析者列為待人工處理。真正風險變更時保留前次紀錄，完整成功掃描才可解除。

## 更新分組與支援期限

每週的 GitHub Actions 與 Python 驗證工具 minor／patch 版本提案各自分組，major 更新個別審查；分組不是自動合併，也不免除相容性與安全驗證。

每次維護須核對套件、工具及其執行環境的官方支援狀態，不主動採用或繼續依賴已 EoL／EoS 的版本。沒有已知漏洞不等於仍受支援；沒有正式支援期限的元件，記錄上游維護狀態及查核依據，不自行捏造期限。發現已終止支援時優先規劃受支援替代環境，驗證後遷移；若確實無法立即移除，明確記錄影響與期限並取得接受，不默默忽略。

Python 工具最低 3.12，CI 使用 3.12，管理腳本統一由 `scripts/project-python.sh` 選擇執行環境。版本門檻本身不會追蹤未來EoL；每次相依維護仍須查核生命週期。詳見 [工具環境](DEVELOPMENT.md#python-runtime)。

## 安全 Issue 的修正摘要

結案時以「後續維護者能否理解修正方式與驗證依據」判斷是否補寫摘要。在任務已授權的 Issue 更新範圍內，先讀取正文與既有留言，再依下列原則處理：

- 單純升級套件，且提交／PR 與掃描結果已足以追溯時，可沿用既有紀錄，不重複留言；僅缺追蹤連結時，補上連結即可。
- 涉及相容補丁、自訂程式或設定、功能限制、暫時例外或補償措施、回退或移除條件時，補一則簡短摘要。相同提交與結果已有充分說明時不重複追加；重要結果改變時再補充。
- 摘要說明處理方式與必要原因、實際驗證結果及提交／PR／CI 連結，以及尚存限制與後續動作。只寫已確認的事實，明確區分已修復、僅緩解與接受期限例外；修正來源不等於所有使用者裝置已更新。
- 完成必要的遠端驗證後、向使用者宣告結案前核對摘要。若監測已自動關閉 Issue，可直接在已關閉的 Issue 補寫，不必重新開啟。保留原告警、解除紀錄及歷史；寫入後讀回核對。
- 不貼完整測試日誌、憑證、私人端點或無關內部討論。這是維護者追蹤紀錄，不放入一般使用者更新說明。

摘要由處理修正的維護者或代理依實際證據撰寫；自動掃描的解除紀錄只代表其檢查範圍內不再命中，不能代替修正經過。此判斷不改變原有掃描、例外或 Issue 關閉條件。

## 開發工具的相容性覆寫

目前的 npm overrides 分別維持 Firebase CSV 串流、PubSub trace-context propagator、Gaxios CommonJS UUID 與 qs API。版本精確固定；`Tests/Security/development-tools.test.cjs` 和 Firestore Emulator 測試驗證實際使用路徑。上層相依允許安全版本後應移除覆寫，至少每月重新審閱，不能持續累積無人維護的強制版本。

`scripts/firebase-tools.sh` 僅允許 Firestore Rules／indexes 部署、`demo-myterm` 的本機 Auth／Firestore Emulator 與基本登入／專案查詢。部署須明確提供 `--project` 和 Firestore `--only`；Emulator 只接受 loopback 設定，`emulators:exec` 只執行本專案固定的 Rules 測試。Auth 匯入、Hosting、替代設定檔與任意 Emulator 子命令均拒絕。這是專案入口限制，不能阻止本機擁有者直接執行 `node_modules` 中的 CLI。

Firebase CLI 固定為 `15.31.0`，上游已原生支援安全版本的 `stream-json`、`stream-chain` 與 `csv-parse`；舊的來源改寫補丁、postinstall 及這兩項專用覆寫已退役。安裝使用 `npm ci` 驗證鎖檔及套件完整性；`scripts/verify-firebase-tools.cjs` 在 wrapper 啟動與 CI 中唯讀核對 CLI 精確版本、manifest／lockfile 與實際解析到的三項串流相依。此檢查不驗證每份已安裝來源的雜湊，也不取代完整性安裝、安全掃描與消費端測試。回歸涵蓋真實 Auth JSON／CSV 和 DatabaseImporter（攔截傳輸）、分段資料、Next.js 管線語意、過深輸入拒絕，以及缺漏／過期／巢狀相依漂移。命令 allow-list 與其他仍必要的 npm overrides 保留。間接相依的安全修正優先在原相容範圍更新鎖檔，不為解決可相容更新的告警新增覆寫。

## 公開金鑰發布驗證

首次使用：

```sh
./scripts/setup-security-tools.sh
./scripts/security-python.sh -m unittest discover -s Tests/Security -v
```

安裝位置為可重建的 `.build/security-tools`，使用 Python venv、精確套件版本、wheel 雜湊與 `--require-hashes`；不執行來源套件的建置腳本。支援 Python 3.12 以上。正式簽章材料仍只由原發布流程使用，CI 只需要公開金鑰。

```sh
./scripts/security-python.sh scripts/verify-signed-release.py \
  --assets /path/to/assets \
  --public-key-file /path/to/trusted-public-key.txt \
  --base-url https://updates.example.org \
  --version X.Y.Z --build BUILD --commit SOURCE_COMMIT
```

公鑰檔只包含 Base64 的 32-byte Ed25519 公鑰。它必須由可信設定或已審閱來源提供，不能信任下載資產自帶的金鑰。公開來源發行者另設定 `MYTERM_SPARKLE_PUBLIC_KEY_FILE` 與自己的 `MYTERM_UPDATE_BASE_URL`；一般無更新服務的自用 App 不需這套發布工具。

驗證順序為：完整 feed 簽章／原始位元組長度 → 單一 item 的版本、Build、平台、URL → ZIP 與 release notes 簽章 → 已簽署的來源 commit／相依清單 → 五項資產與 checksum／manifest 一致性。驗簽在 ZIP 解壓與網站部署之前。檢查後部署同一組 bytes，複製後再次驗證，不重新下載替代資產。

`bind-release-metadata.py` 只在最終 feed 簽章之前加入來源 commit、相依清單與 release notes 簽章。不得修改已發布的已簽署 feed。新流程會拒絕缺少這些簽署欄位的舊資產；若要重新部署舊版，需另行審查原資產與相容處理，不得加入跳過驗簽選項。

## 安全測試與 App 更新

```sh
./scripts/project-python.sh scripts/run-isolated-tests.py
./scripts/run-sftp-security-tests.sh
```

完整測試在新的暫存來源副本中執行，只注入測試用 Application Support 路徑，保留原受測邏輯並使用測試專用 Keychain service。`run-tests.sh` 是底層測試入口，不應直接在有正式資料的 Mac 上執行；這不代表 AppPaths 的所有既有獨立測試入口已改成隔離。新的 SFTP 安全套件只使用本機假伺服器和暫存資料，不使用真實主機或憑證。

高風險適用公告應優先判斷與準備修復，不能等待例行每週更新。Sparkle 的修復必須透過重新建置、簽署及發布的 App 更新送達使用者；改鎖定檔或 appcast 不會修復已安裝的 framework。若更新信任鏈本身失效，應評估獨立驗證的手動交付途徑。

發布前的測試、驗簽與維護證據保存在計劃／CI／安全 Issue；一般更新視窗不顯示「驗證與維護」工作紀錄。更新說明仍保留直接影響使用者的安全修正、限制與必要操作，內容規範見[開發指南](DEVELOPMENT.md)。

## 部署權限與環境

公開前應核對 main 的必要安全檢查、禁止 force push／刪除與 fork PR 執行核准政策。更新站 workflow 的原庫／main 限制與 production 綁定只是來源層的條件；管理員仍須設定環境 reviewer、可部署 refs 及環境 Secrets，完成實際部署核准驗收。repository 層級的 Cloudflare Secrets 未移除前，不把 environment 綁定當成憑證隔離。詳細步驟與改回私人前的方案檢查見 [開發指南](DEVELOPMENT.md#正式部署保護)。

新產生的更新說明連結同時包含相同的 `length` 與 `sparkle:length`，相容舊版及 Sparkle 2.10 的讀取方式。驗證器保留已簽署歷史格式的驗證，但任一長度不符或兩欄矛盾即拒絕。簽署工具只能取自 framework 版本符合 `Package.resolved` 的 SwiftPM artifact，不能因舊快取存在而混用工具。
