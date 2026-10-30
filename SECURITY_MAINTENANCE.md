# 安全維護與發布驗證

**繁體中文** | [English](SECURITY_MAINTENANCE.en.md)

本指南說明相依套件維護與發布驗證。App 的資料保護界線見 [安全設計](SECURITY.md)，建置與發布程序見 [開發指南](DEVELOPMENT.md)。

## 相依警示與處理

啟用 GitHub 的 dependency graph、Dependabot alerts，並確認維護者已訂閱安全警示與 Actions 失敗通知。首次啟用時主動檢查既有警示；收到新版本不代表應自動合併或發布。

`.github/dependabot.yml` 提供每週一的 Swift、npm、GitHub Actions 與驗簽 Python 套件更新提案。日常監測 `MyTerm security monitor`（security-checks.yml）每12小時（台北時間09:23、21:23）及手動執行，檢查來源與最新正式 Release；`MyTerm release security gate`（security-gate.yml）則在 PR／main 推送完整掃描，保留原有 App／Swift／Vendor、根 npm、Python 驗簽與 pip／certifi、Actions 本體公告的中高風險及未知適用性阻擋。排程可能延遲，不保證準時。

日常監測的成功表示掃描與 Issue 處理完成，不代表沒有風險。有風險時以 Issue 記錄公告、元件、版本、影響範圍、上游修補資訊及例外期限；同一公告／元件／範圍沿用同一 Issue，沒有變化就不重複寫入。重要變更追加紀錄；只有完整成功掃描確認不再命中時才關閉，再次命中會重新開啟。人工作業的 Issue 不由工具管理，人工關閉仍命中的自動 Issue 不等於接受風險，下次會重新開啟。

只有工具準備、查詢、報告或 Issue 寫入等運作異常才使日常監測 Fail；即使連續相同故障也不能顯示成功。來源安全門檻是另一個 workflow，在原有合併範圍發現未處理風險仍會阻擋，不能把它解讀成監測故障。未知適用範圍記為待確認風險，不宣稱安全。

Issue 寫入權限只供 `crazy01100/myterm` 預設分支的排程／手動監測，PR 無此權限；fork 不會自動執行此監測 job。工具預設拒絕公開庫寫入，本庫 workflow 以 `--allow-public` 明確允許已審閱的公開公告資訊。紀錄只包含公開公告、相依版本與接受狀態，不包含主機、憑證或使用者資料。`scanStatus` 與 `lastSuccessfulScanAt` 記錄掃描健康；前次成功距今超過 48 小時會在下一次檢查提示。排程完全不執行時無法靠自己即時報警。上游版本資訊仍保存在掃描報告；沒有命中的一般新版由 Dependabot 提案追蹤，不為每個新版建立風險 Issue。

npm 相依同時比對 `npm audit` 與 GitHub Advisory Database：以鎖檔內所有套件／版本分批查詢公開公告，再按公告與元件合併。這可補足兩個資料來源更新時間不同造成的漏報；不限近期公告。任一批次失敗仍視為掃描不完整，不能據此解除 Issue。

```sh
./scripts/project-python.sh scripts/security-audit.py --output build/security-report.json
./scripts/project-python.sh scripts/security-audit.py --include-release OWNER/REPOSITORY --output build/security-report.json
```

需要已登入且有適當讀取權限的 `gh`、Python 3.12 以上、Node.js 24 LTS及 npm。只查詢公開公告與必要來源／版本資訊，不讀取本機雲端設定或簽章私鑰。`Config/Security/native-components.json` 將 libsodium 版本綁定到 swift-sodium revision；更新 wrapper 後必須重新核對實際 XCFramework header。上游修復版以 commit 公告的 Vendor，使用 commit ancestry 判斷，不捏造版本號。

未完成用途評估的中高風險、未知適用範圍或查詢錯誤會阻擋發布前檢查；已審工具風險依下述長期發布分類核對，不以Issue數量直接決定是否發布。最新已發布 App 的舊漏洞仍列在監測報告，但不阻擋用已修復來源建立後續更新。一般期限例外只可使用 `Config/Security/exceptions.json` 明確列出的公告、元件、版本及 development scope，附接受人、理由與期限；最長 31 天，逾期自動恢復阻擋。不因屬於 devDependency 就整類忽略。


`security-audit.py --monitor` 只在掃描運作異常時回傳失敗；風險清單仍完整保存在報告。不加用途旗標的安全檢查保留原完整風險門檻；正式入口以`--release-stage candidate|publish|deploy`啟用下述用途分類。`--merge-gate` 只供 PR／main 合併檢查：擴充工具／內附相依的風險與待審官方公告持續告警並另列修補待辦，尚不增加自動合併阻擋。所有必要查詢失敗或覆蓋不足仍阻擋；同一公告若也命中原有 collector，原有結果照舊阻擋。此分工不表示風險已接受或修復，不改 Issue 結案條件，也不授權發布／部署。監測、合併與發布用途旗標互斥，發布與部署入口不得使用 `--merge-gate`。自行發行者應建立自己的風險追蹤流程。未知新漏洞、私人測試證據與使用者資料不屬於自動公開範圍，通報方式見 [安全設計](SECURITY.md)。


發布安全門檻以失敗的檢查結果表示來源不符合政策；它不等於 GitHub 已強制設定分支保護。分支保護須由維護者在 GitHub 另外設定並核對，不因 workflow 存在或儲存庫改為公開就視為已啟用；維護者不得合併未通過檢查的變更，本機發布入口亦會重新檢查。

Issue 內文只保留公告連結、元件、受影響範圍、目前版本、版本比對、對應分支的修補版本及掃描時間；不重複加入監測正常提醒、公告連結或通用建議。時間以 `YYYY-MM-DD HH:mm:ss（UTC+8）` 顯示，內部報告仍保留帶時區的原始時間。npm 公告按實際受影響版本範圍對應 GitHub Advisory 的修補版本；不同 major 並存時逐分支列出。上游未提供與資料待確認分開表示，查詢失敗仍屬運作錯誤。

`security-risk-context.py` 從鎖檔收集相依路徑，並讀取 `Config/Security/impact-assessments.json` 的逐案原始碼／輸入條件審查。實際影響分為「已確認受影響」「已確認不受影響」「待確認」，呈現簡短依據、範圍與公開來源。相依路徑不是函式可達性證明；這不是每次掃描都能自動完成的通用漏洞分析。評估綁定公告、版本及相關來源檔案雜湊；變更後回到待確認。歷史評估只在明確對應的原掃描時間套用並標示基準，不因目前來源修復而改寫當時結論。影響評估不自動豁免既有發布安全門檻。

`security-issue-format.py` 保留機器可讀的公開欄位快照與原始掃描／解除時間。手動監測可選擇 `refresh_issue_format` 整理既有 Bot Issue；純格式變更不追加風險變更留言、不重開已關閉 Issue。人工留言及未知的人工正文內容保留；無法可靠解析者列為待人工處理。真正風險變更時保留前次紀錄，完整成功掃描才可解除。

## 更新分組與支援期限

每週的 GitHub Actions 與 Python 驗證工具 minor／patch 版本提案各自分組，major 更新個別審查；分組不是自動合併，也不免除相容性與安全驗證。

大原則是**避免所有 EoL／EoS 相依**。每次維護須核對套件、工具及執行環境的官方支援狀態；每次發現停止支援或維護的元件，都逐項評估版本、引入路徑、實際用途／輸入、是否隨 App 發布、已知漏洞及適用條件，以及升級／移除／替換的相容性風險與維護成本。沒有已知漏洞不等於仍受支援，上游仍使用也不等於安全背書；無正式期限者記錄維護狀態與依據，不捏造日期。

優先採用受支援版本或上游修正。若評估後建議保留，須由維護者明確確認並記錄套件／版本／範圍、日期、理由、處理決策及重新評估條件，不把單一決策擴大為所有停止維護元件的豁免。每次再次發現時核對這些條件；事實未變可引用既有決策，不因同一警告反覆要求展延或追加替換測試。版本、用途、暴露範圍、漏洞或上游方案改變時，重新評估。

支援狀態的保留決策與漏洞例外分開處理，可依個案採用重新評估條件而非反覆期限展延。它不改變安全掃描、Issue 追蹤及發布 gate，也不自動接受未來漏洞；一般已命中漏洞的期限例外仍遵守 `Config/Security/exceptions.json` 的原有接受及最長 31 天規則；Issue #43 的條件式個案依下述官方撤回決策退役，json-ptr 的保留決策不構成該漏洞接受。

Python 工具最低 3.12，CI 使用 3.12，管理腳本統一由 `scripts/project-python.sh` 選擇執行環境。版本門檻本身不會追蹤未來EoL；每次相依維護仍須查核生命週期。詳見 [工具環境](DEVELOPMENT.md#python-runtime)。

### 已評估保留：json-ptr 3.1.1

- **決策日期／確認者**：2026-10-01，由專案維護者明確確認。
- **範圍與用途**：目前 `firebase-tools 15.34.0 → exegesis 4.3.0 → json-ptr 3.1.1`；主要供本機 Auth Emulator 解析 API 規格與 JSON 參照。Firebase 共用模組亦可能載入它；不封裝於 MyTerm App，不參與正式 App 的 Google 登入或同步。
- **查核依據**：[npm 已標示停止維護](https://www.npmjs.com/package/json-ptr)。2026-10-01 的 GitHub Advisory 版本比對及 npm audit 未命中 3.1.1；歷史[高風險](https://github.com/advisories/GHSA-x5r6-x823-9848)／[另一筆高風險紀錄](https://github.com/advisories/GHSA-rrqv-vjrw-hrcr)與[中風險](https://github.com/advisories/GHSA-8gwj-8hxc-285w)公告分別在 2.1.0 與 3.0.0 修補。查核當時最新版 Firebase CLI 15.32.1 仍有這條相依，未找到官方針對停止維護狀態的明確安全背書。
- **處理決策與理由**：保留官方相依組合；目前沒有確認到急迫漏洞，自行替換會增加相容性與後續維護負擔。不替換、不加入自訂相容層，也不進行替換原型或小範圍測試；不設定反覆展延期限。停止維護狀態仍保留，不標示為已修復或受支援。
- **2026-10-05重新核對**：Firebase CLI15.32.1的Auth Emulator入口來源及exegesis／json-ptr版本未變，用途及暴露範圍相同，沿用既有保留決策，未進行替換測試。
- **2026-10-13重新核對**：Firebase CLI15.33.0的Auth Emulator相關來源與15.32.1相同，仍依賴exegesis4.3.0／json-ptr3.1.1；用途及暴露範圍不變，沿用既有保留決策，未進行替換測試。
- **2026-10-20重新核對**：Firebase CLI15.34.0仍使用exegesis4.3.0／json-ptr3.1.1；Auth解析入口相同，utils僅將電話號碼前綴判斷改為startsWith。用途及本機暴露範圍不變，沿用既有保留決策，不進行替換測試。
- **持續追蹤**：沿用既有漏洞監測；發現影響目前版本的新公告、實際相容性問題、上游移除／替代方案，或套件版本、使用方式、暴露範圍改變時重新評估。本決策不豁免新告警或發布安全門檻。

## 安全 Issue 的修正摘要

結案時以「後續維護者能否理解修正方式與驗證依據」判斷是否補寫摘要。在任務已授權的 Issue 更新範圍內，先讀取正文與既有留言，再依下列原則處理：

- 單純升級套件，且提交／PR 與掃描結果已足以追溯時，可沿用既有紀錄，不重複留言；僅缺追蹤連結時，補上連結即可。
- 涉及相容補丁、自訂程式或設定、功能限制、暫時例外或補償措施、回退或移除條件時，補一則簡短摘要。相同提交與結果已有充分說明時不重複追加；重要結果改變時再補充。
- 摘要說明處理方式與必要原因、實際驗證結果及提交／PR／CI 連結，以及尚存限制與後續動作。只寫已確認的事實，明確區分已修復、僅緩解與接受期限例外；修正來源不等於所有使用者裝置已更新。
- 完成必要的遠端驗證後、向使用者宣告結案前核對摘要。若監測已自動關閉 Issue，可直接在已關閉的 Issue 補寫，不必重新開啟。保留原告警、解除紀錄及歷史；寫入後讀回核對。
- 不貼完整測試日誌、憑證、私人端點或無關內部討論。這是維護者追蹤紀錄，不放入一般使用者更新說明。

摘要由處理修正的維護者或代理依實際證據撰寫；自動掃描的解除紀錄只代表其檢查範圍內不再命中，不能代替修正經過。此判斷不改變原有掃描、例外或 Issue 關閉條件。

## 開發工具的相容性覆寫

目前 npm overrides 包含 PubSub trace-context propagator、Gaxios CommonJS UUID、qs、`@grpc/grpc-js 1.14.5`及 `glob 13.0.6`。gRPC 統一修補 Firebase／Google gax 的受影響分支；glob 取代已停止免費維護的 10.x，適用於 Firebase 檔案搜尋及其壓縮、清理、controller 載入相依。版本精確固定，測試涵蓋實際消費端、loopback gRPC 與隔離 Firestore Emulator；`firebase-glob.test.cjs` 驗證隱藏檔、排除規則、符號連結、同步／非同步／串流及暫存檔案操作。上層相依允許受支援且安全的版本後應移除覆寫，至少每月重新審閱。

`scripts/firebase-tools.sh` 僅允許 Firestore Rules／indexes 部署、`demo-myterm` 的本機 Auth／Firestore Emulator 與基本登入／專案查詢。部署須明確提供 `--project` 和 Firestore `--only`；Emulator 只接受 loopback 設定，`emulators:exec` 只執行本專案固定的 Rules 測試。Auth 匯入、Hosting、替代設定檔與任意 Emulator 子命令均拒絕。這是專案入口限制，不能阻止本機擁有者直接執行 `node_modules` 中的 CLI。

Firebase CLI 固定為 `15.34.1`，上游已原生支援安全版本的 `stream-json`、`stream-chain` 與 `csv-parse`；舊的來源改寫補丁、postinstall 及這兩項專用覆寫已退役。安裝使用 `npm ci` 驗證鎖檔及套件完整性；`scripts/verify-firebase-tools.cjs` 在 wrapper 啟動與 CI 中唯讀核對 CLI 精確版本、manifest／lockfile 與實際解析到的三項串流相依。此檢查不驗證每份已安裝來源的雜湊，也不取代完整性安裝、安全掃描與消費端測試。回歸涵蓋真實 Auth JSON／CSV 和 DatabaseImporter（攔截傳輸）、分段資料、Next.js 管線語意、過深輸入拒絕，以及缺漏／過期／巢狀相依漂移。命令 allow-list 與其他仍必要的 npm overrides 保留。間接相依的安全修正優先在原相容範圍更新鎖檔，不為解決可相容更新的告警新增覆寫。

`compression 1.8.2`與`proxy-addr 2.0.8`以父套件原相容範圍更新鎖檔，沒有新增覆寫。`firebase-http-dependencies.test.cjs`涵蓋gzip／deflate／Brotli回應中止後資源釋放、真實superstatic壓縮／非壓縮回應，以及Firebase與MCP使用的Express 4／5代理信任子網和loopback HTTP正反例。兩項只屬開發工具；Hosting入口限制不代替相依修補。

`@modelcontextprotocol/sdk 1.32.1`、`hono 4.13.11`及`@hono/node-server 2.1.3`沿父套件相容範圍鎖定，不新增覆寫。SDK 1.x仍在官方bug／security維護期，本輪不遷移至2.x。Firebase MCP使用SDK Server，具備stdio及可選HTTP/SSE模式；專案wrapper拒絕mcp及experimental:mcp，正常允許用途不啟動這些入口。Firebase未設定實驗taskStore，未使用SDK HTTP/OAuth client、bearer middleware或Hono serveStatic；OneMcpServer使用Firebase自身apiv2.Client。這些來源判斷不涵蓋直接繞過wrapper或其他獨立MCP應用。

SDK更新修正tasks的session綁定及HTTP/OAuth跨來源redirect政策；不設定`redirectPolicy: 'follow'`恢復舊行為。GHSA-46jr-4wx8-v453與GHSA-rvq5-wwqv-78pq的新保護選項預設關閉：未來若允許HTTP MCP，須另外限制工具輸入元素（`maxToolInputElements`）與request body；採用SDK bearer驗證時須同時設定`expectedResource`及由verifier回傳`AuthInfo.resource`。不得把單純升級宣稱為所有HTTP用法已受保護。先前OAuth issuer／expectedIssuer與舊憑證界線亦維持。

Hono與Node adapter的serveStatic重複路徑解碼修正一併納入；不啟用`allowPercentInPath`回退。`firebase-mcp-sdk.test.cjs`保留合成Server／stdio握手、工具列舉及OAuth issuer檢查；`test_firebase_policy.py`明確驗證MCP命令與別名被拒絕。各公告的來源綁定評估保留在`Config/Security/impact-assessments.json`；歷史版本命中不等於已證明可利用，既有風險判定不因這些說明降低。

`ip-address 10.7.4`與`stream-json 3.7.0`分別在父相依`^10.2.0`／`^3.6.0`範圍更新鎖檔，沒有新增override或來源相容層。前者由MCP的express-rate-limit引入；正常IPv4、IPv6子網及IPv4-mapped位址沿真實ipKeyGenerator驗證。後者沿用Firebase的Auth、DatabaseImporter及Next.js管線回歸；CLI橋接沒有使用公告所指FlexAssembler規則filter。這些來源範圍不是漏洞豁免，不涵蓋繞過wrapper的獨立用途；修復依官方版本、相容回歸及完整掃描確認。兩者只屬開發工具，不隨App封裝。

`body-parser` 的 1.x／2.x 分支分別鎖定 1.20.9／2.4.0，`fast-uri` 鎖定 3.1.9，`undici` 保留相容的 6.29.1／8.12.2，`zod` 鎖定 4.6.6；不跨主要版本替換。body-parser 2.4.0 要求的 `content-type 2.1.0` 與 `qs 6.16.1` 一併更新，其中 qs 沿用既有精確 override。兩條 Express 分支的壓縮 JSON／表單解析、Undici HTTP 解碼及 Zod 一般輸入驗證納入相容性回歸。以上只屬開發工具，不隨 App 封裝；一般使用流程的驗證不是實際可利用性判定。

### 保留的 braces 入口防護

`braces 3.0.3` 仍由開發工具使用；GHSA-vfj7-8cjw-p6xm 已由官方撤回，並非發布修補版。Firestore Emulator 經 chokidar 監看規則檔；專案 wrapper 在啟動前拒絕規則檔路徑、專案目錄或符號連結解析後路徑含 `{`／`}`，避免將這類輸入交給 brace 展開。一般規則檔熱重載保留。此限制只涵蓋專案入口，不修補套件，也不能阻止本機使用者繞過 wrapper 或在檢查後更改檔案／設定。

[Issue #43](https://github.com/crazy01100/myterm/issues/43) 已在核准的撤回退役變更完成 main 驗證與結案摘要後，以官方撤回理由關閉。原 2026-10-19 期限與歷次風險接受保留為歷史，不展延、不新增漏洞豁免。

Firebase CLI 15.34.0 已移除未使用的 `proxy-agent`、`universal-analytics` 與 `@apphosting/common`；鎖檔中原先經由 PAC 代理引入的 `get-uri`／`basic-ftp` 等相依也已移除。原 get-uri 專用覆寫及其 FTP 消費端測試因此退役，不重新加入套件來維持舊測試。`firebase-removed-dependencies.test.cjs` 驗證鎖檔各層、已安裝套件解析與上游宣告均未重新引入該鏈。其他仍適用的安全覆寫與測試保留；歷史 basic-ftp 影響評估不改寫成當時未受影響。這些開發工具不屬於 MyTerm SFTP。


### Issue #43 條件式風險接受（歷史，停止專屬追蹤）

目前決策為 **revision 7／retired（官方公告撤回）**；revision 7 僅經維護者核准擴充 Python 工具與 CI 的政策來源指紋，原退役決策與撤回證據不變。維護者於 2026-10-24 明確核准退役提案 `issue43-withdrawal-retirement-1`，提案 SHA-256 為 `c979cbc420118841efdd8306681356da605bb038c71872425b752417a3cbc0f9`。GitHub Advisory Database 於 2026-10-23 20:53:02（UTC+8）撤回 [GHSA-vfj7-8cjw-p6xm](https://github.com/advisories/GHSA-vfj7-8cjw-p6xm)，理由是不具實際可利用性。這是官方撤回，不是套件修補、風險展延或本專案的實際可利用性測試結論。

`Config/Security/conditional-acceptances.json` 保留原 revision 5 的基準、接受紀錄與原期限歷史，另記錄退役核准、官方摘要及政策執行來源。歷次 revision 1–5 與 PR Review 可由 Git 歷史追溯；不改寫當時的風險判斷。`accepted=false` 與 `retirementVerified=true` 明確區分「沒有風險豁免」和「已核對撤回」。其他漏洞仍依普通安全門檻與最長 31 天例外規則。

### 通用政策來源審閱

日常入口使用 `Config/Security/source-review.json` 與 `security-source-review.py` 核對政策契約及 Git checkout 身分，不再逐檔要求人工指紋核准。一般程式、測試、文件與公告游標修改沿 Git／CI 審查；已結案個案不再專屬查詢，歷史資料保留。新的安全公告另案處理，不恢復已終止測試。

來源核對不等於漏洞掃描、環境完整性或風險接受。本機允許未提交修改以進行開發；CI 要求原儲存庫、受支援事件、乾淨 checkout 與事件 commit 一致。PR 可先執行唯讀驗證，但不得寫入監測 Issue。合併依原有 collector 風險門檻，擴充風險另行告警；發布／部署依長期用途分類判定，保留原始風險與當次必要證據。所有必要查詢失敗與覆蓋缺口仍阻擋，不以取消人工指紋迴圈放行。

```sh
./scripts/project-python.sh scripts/security-source-review.py \
  --purpose development --task TASK_ID \
  --output docs/TASK_ID-source-review.json
```

涉及安全設定、信任、權限、豁免、gate 或其執行入口的修改，在最終 PR 集中審閱一次；比較 head／base 的受保護檔案樹，包含刪除、改名與權限變更。一般文件、測試與公告游標不單獨要求政策核准。自建 PR 使用 `MYTERM-POLICY-REVIEW-V2`、`action=approve-policy`，綁定維護者身分、精確 head／base 與政策原始內容摘要；撤銷或 head／base 改變必須重核。唯讀 CI 可先完成測試，政策核准是獨立的合併前必要條件。成功仍回報 `mergeAuthorized=false`；必要 CI／CodeQL、討論與分支保護不得略過。

### 工具清冊、覆蓋與公告追蹤

初始公告游標尚未審閱時，即使 feed 未變，也列出來源、當次觀測筆數與待審狀態；不把上千則歷史版本新聞全部灌入 Issue。來源查詢失敗不得移除先前待審項目，完整指紋留在受審設定與報告中。公告／覆蓋 Issue 寫入後讀回核對內容與狀態，讀回不符或失敗不能產生成功通知收據。

日常排程只執行可信工具準備、公告查詢與通知，不執行完整固定回歸；PR／main CI與發布仍保留原測試門檻。套件查詢依實際collector分群，OSV及npm的GitHub補充來源各自保存結果；單群失敗不丟棄其他群的風險，整體仍標示不完整。`packageMonitoring`列每群身分摘要、origin、查詢狀態與數量，與原生／供應商覆蓋分開；套件查完不等於無漏洞或全部供應鏈已掃描。未啟用的gcloud、Pillow、Termius不執行查詢或安裝，沒有套件身分的App／JAR另沿既有供應商公告查核。

本計劃不新增外部監測服務；深層AST分析、Go SDK／govulncheck與完整子庫反向還原不是日常監測前置條件。已有靜態證據保留，具體新告警需要時才另行評估。

執行環境核心另由`security-runtime-advisories.py`查核：Node.js按同一官方提交的逐檔公告清單及Git blob核對，不依賴可能落後的彙整index；CPython以當次解譯器身分與版本對應官方release commit，再查OSV的commit公告。原始查詢與環境origin獨立保存，未知版本／格式、缺檔或分頁不完整均阻擋。此對應不證明下游廠商補丁、原生庫或無CVE新聞已涵蓋，也不單獨授予自動結案資格。

`toolchain-inventory.json` 列出專案實際用途：App 相依、根 npm、獨立 npm、Node、專案 Python／pip／CA／驗簽套件、部署工具、Actions、Firestore 與 Rules 使用的 Java，以及專案 GitHub CLI。舊 platform collector 僅保留 gh。OS 更新與整個 runner 映像不查詢、不通知、不建立 Issue、不阻擋；系統名稱／架構只供選擇封裝與相容性診斷。未使用的 gcloud、Pillow、Termius 不為監測而安裝。僅可載入或由監測自己 import 的內附庫，先列用途未確認候選；SQLite 兩筆保留於 candidateFindings，不冒稱已修復，也不充當全專案阻擋。

`inventoryComplete`只表示清冊成功；`checksComplete`要求對應資料源、相同身份／環境及有效時間。Firestore及四個精確Actions的有限供應商證據決策不接受已知漏洞，報告保留`allDependenciesScanned=false`；runner Node不等於setup-node安裝的Node。本機、CI及部署結果不能互相代證。

套件與OpenSSL查詢分開執行；一個資料源失敗仍保留其他結果，但整體失敗不轉成通過。只有來源政策已驗證的預設分支監測，才可把已完成查詢的風險加入Issue；部分掃描不可解除舊告警、移除未驗證版本或降低嚴重度。解除需要同環境／origin與明確closure eligibility，供應商未覆蓋區域不得以空結果結案。

`security-vendor-notices.py` 追蹤專案工具官方 feed 的 URL／內容摘要；無 CVE 或同 URL 修改仍可列待確認。Firestore 使用精確 JAR 與 Firebase 倉庫安全公告，不查雲端產品功能／IAM 公告，也不偽造 Maven 子相依查詢。公告游標是日常審閱紀錄，不是風險例外或人工 revision；feed 消失不代表解除。`sync-security-monitor-status.py` 分開呈現必要覆蓋缺口與相關公告，且寫入後讀回；一般新聞的相關性需審閱，不能僅憑沒有 CVE 宣告安全。

`security-monitor-health.yml`每12小時（台灣10:17、22:17）及手動執行，不依賴npm／完整回歸。唯讀健康核對不以舊成功遮蔽最新失敗；超過24小時未完成有效掃描列延遲，48小時列過期。保留報告及`security-monitor-receipt.json`須綁定同一run／attempt／commit與報告hash，風險及公告兩種Issue寫入都成功才有完整收據；風險筆數本身不代表監測故障。

`sync-security-health.py`在已核准來源、原庫預設分支排程／手動情境維護獨立健康Issue，使用固定狀態文字及公開run連結。相同故障24小時內不重複留言，持續故障每天至多提醒一次；恢復及復發沿同一紀錄，留言重試去重並讀回核對。不關閉或忽略漏洞Issue。公告／覆蓋Issue的重要變更也用去重留言通知。這只證明GitHub寫入完成，實際郵件接收仍須核對個人訂閱設定；不新增外部服務，整個GitHub或全部排程停擺時仍無跨平台通知保證。

一般31天例外、EoL／EoS逐項評估及json-ptr既有決策不變。未解除告警不因來源指紋核准、工具升級或供應商界線被忽略。

## Python 安裝工具與憑證信任

開發工具由 `Config/Security/python-tools.json` 固定 pip 26.2.2（內附 certifi 2026.10.19）、獨立 certifi 2026.10.23，以及各自官方 wheel URL／SHA-256 與 CA 檔摘要。這處理 [GHSA-6q48-6c7w-9gw2](https://github.com/advisories/GHSA-6q48-6c7w-9gw2) 的憑證信任事件；沒有 CVE 不代表不需追蹤。pip 內附 certifi 與獨立 certifi 分開核對，單獨安裝 certifi 不能替換舊 pip 的內附副本。兩份官方 CA 不要求版本或內容相同，但各來源必須符合自己的固定版本與摘要；互換、漂移或未知來源均拒絕。專案 HTTPS 明確使用獨立 certifi，pip 維持離線安裝，內附舊元件仍受監測。certifi 2026.10.23 並未移除所有後續公告涉及的信任根，不能代替 CPython 的中繼金鑰修補。

`python-toolchain.py setup` 先取得並核對所有精確 wheel，才建立／更新 `.build/python-runtime` 與 `.build/security-tools`；種子 pip 只用 no-index／no-deps 安裝已驗證的本機 wheel，不先做一般網路下載。兩個環境各自核對 pip、內附／獨立 certifi 與 CA 摘要。既有 venv 原地更新，只有明確 `setup --rebuild` 才清空重建；失敗即停止，不使用不完整環境。不要在其他程序仍使用該環境時重建，也不要搬動 venv 而忽略絕對 shebang。

`setup-security-tools.sh` 共用上述流程，再下載固定官方 wheel、核對 hash 後離線安裝原有驗簽相依；不使用私人 pip 設定，不修改系統 Python 或共用解譯器。`security-python.sh` 每次驗證工具與 CA 並設定子程序的 SSL_CERT_FILE；一般 `project-python.sh` 仍只選解譯器，不承諾改變任意第三方程式的信任邏輯。安全掃描與退役公告查詢直接使用 helper 建立的明確 certifi SSLContext，不合併舊預設 OpenSSL CA 檔。自訂企業 CA 不會自動加入，需求須另行審查；不能停用驗證來修復連線。

gate／monitor／deploy 在 Python 網路作業前先準備可信工具，並記錄 bootstrap 前置狀態與實際盤點；前置失敗不代表完成掃描。盤點包含來源固定版本、當次兩個受管環境的 pip／內附及獨立 certifi，以及實際存在的 uv 套件；ensurepip 種子另列為重建來源，不視為目前執行 pip。它不掃描整台 Mac、系統全部套件或其他工具的所有內附相依。

監測把實際內附 certifi 對應到 PyPI 公告，按 GHSA／OSV 別名去重並合併仍受影響副本；來源 pins 及實際版本均查詢。缺少環境、必要元件、不可讀資料或宣稱修正版但 CA 內容不符時，不得回報完整成功。版本命中保留為版本命中，不宣稱利用已確認。公開報告只顯示 local checkout／current CI runner 與環境角色；CI 的成功不代表另一台 Mac 已更新。本機入口自行重核，未修正者不能繼續相關網路作業。

pip（MIT）與 certifi／CA 資料（MPL-2.0）的原始授權隨套件保留；它們不隨 MyTerm App 封裝。本流程不變更 App、資料格式或已簽署資產，也不取消其他安全門檻。

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

### CI 驗證分流

scripts/security-test-profile.py依PR的base/head、push的before/after或監測目前commit的第一父提交計算實際Git差異。只有明列政策／格式／入口／文件／mock測試的新增或修改，才執行run-policy-tests.py的純政策套件；套件鎖檔、Rules、App、刪除、改名、未知檔案或空差異仍選原完整驗證，比較失敗直接停止。環境旗標／PR標籤不能指定分流。完整漏洞案例保留不變，純政策報告明列未執行；一般相依公告掃描及CodeQL不省略。變更分流本身亦須維護者審查，不能視作防止有寫入權限者改程式的邊界。


GitHub CLI與內附Go模組：監測／發布入口使用 `Config/Security/github-cli.json` 固定的專案CLI；不依賴PATH中的舊副本。官方封裝hash與安裝manifest逐次核對，Go建置資料列出的父模組、子模組與stdlib各自查OSV；無法解析或套件替換來源不明即保留覆蓋缺口。Go公告的package／symbol限制仍需適用性判讀，版本命中不宣稱可利用，也不因父工具已修補就關閉未知子相依告警。全域 CLI 與 OS 更新不納入此監測。


### pip 精確封裝適用性

`security-pip-applicability.py`只判斷已審閱的三筆setuptools子集公告，以及一筆msgpack C解碼器公告。固定官方pip wheel未包含前者受影響的setuptools實作，也只包含msgpack純Python實作；每次比對公告條件、msgpack官方修補身分、兩個受管環境及完整vendor來源。新增原生模組、外部套件、路徑hook或來源漂移均保留待審。原始版本命中保存於`rawFindings`，具體證據另存`applicabilityReviews`，不修改官方嚴重度或授予例外。未驗證的環境不借用本機結果。通過gate前及Issue寫入前重新驗證，既有Issue不因這項分類自動以版本修復關閉；仍須同範圍與main驗證後維護。其他風險按上述合併／發布用途處理；必要覆蓋缺口仍阻擋。

`security-supplier-notices.py` 查詢實際部署工具與 Rules JDK 的官方公告。JDK 身分來自所選工具的 release metadata；已知命中即使查詢失敗仍保留，但不宣稱查詢完整。公告內容變化進入正常待審紀錄，不要求新 revision。供應商證據有限與元件風險分開，不能因此自動解除告警；沒有 OS／runner 映像接受基準。

### 專案 Java 信任清單處置

`Config/Security/java-trust.json` 僅處理 CVE-2026-114820 的[官方根憑證移除建議](https://ops.java/emudhra)。本機與 Linux CI 分別核對完整官方 JDK，再產生固定的預設 `cacerts`；四類指定根均須不存在，且其他憑證不變。未修改全域 CA，未停用 TLS 驗證，也未把較窄的信任清單當作任何風險例外。受該 CA 簽發的連線可能被拒絕，不能為通過測試自行加回。

當次 `supplierNotices.remediations` 保存實際信任清單、來源、平台／版本、公告內容與環境證據；gate／Issue 寫入前再核對實際檔案。只有這筆措施驗證完整時不再列為未處理命中；已知公告及原 Issue 歷史保留。初次結案仍須本機、CI、main及正式監測證據與維護摘要，有限供應商覆蓋本身不授予自動結案。Java內容／政策漂移、身分不符或查詢失敗不得沿用解除證據；操作停止並保留待審。官方新公告仍進一般審閱流程。

未來官方封裝若完整納入措施，應先核對四類根及其餘信任差異，再以一般維護PR替換衍生流程；不能僅因版號變大便退役此措施。日常公告游標是審閱紀錄，不改變此信任政策，也不需要逐次revision核准。

Issue 發布器接受已盤點的 OpenJDK 官方日期公告網址；其他主機、無關路徑、query 與 fragment 仍拒絕。相同環境／工具來源的版本先合併再比較，首次與後續寫入使用相同格式，避免重複通知或遺失版本觀測；這不改變漏洞判定或解除條件。

同一監測工作續跑可能保留多份同名成果；健康檢查與前次報告恢復依建立時間選取，不以成果 ID 或 API 順序當作新舊依據。健康判定仍嚴格綁定當次 run／attempt／commit／報告雜湊，證據不符不退回舊成功。GitHub 寫入請求至少間隔一秒；限流或其他寫入失敗仍明確標為未完成，後續掃描／授權續跑透過既有去重補齊，不盲目重送可能已成功的 POST。

### 專案 Python 的 OpenSSL 供應商修補

`security-openssl-supplier.py` 只核對兩個受管 Python 環境實際載入的 OpenSSL。Linux 記錄程序映射、檔案內容與所屬套件完整版本；`Config/Security/openssl-supplier.json` 固定官方 HTTPS checksum 清單核對的封裝、函式庫及安全修補紀錄摘要。每次比對官方封裝內的逐 CVE 修補紀錄及目前 OpenSSL CNA，不能用上游版號、映像清單或僅有套件名稱推定已修補。此流程不安裝套件、不掃描 OS 或其他 runner 軟體。

原命中保存在 `rawFindings`，精確供應商修補另存 `supplierFixReviews`；gate 與 Issue 寫入前重新核對。只有同一公告、所有相關環境／origin 與函式庫內容均驗證完整，才可依已修補解除對應 Issue，並保留維護摘要。公告變動、來源不符、缺證據或查詢失敗均保留風險與阻擋；非此精確封裝、未驗證環境與其他原生函式庫不借用此判定。這不是漏洞例外，發布／部署與其他風險門檻不變。

已核准的完整Linux安全流程使用同版本官方OpenSSL的專案隔離副本，目的是消除runner同版號卻內容不同的來源不確定性；不把runner雜湊加進信任表。固定deb／兩份函式庫／修補紀錄雜湊不變。準備只寫入專案`.build`，不以dpkg安裝，不改系統CA／套件；原生系統來源仍須原本的精確核對。所有45筆公告仍逐筆比對目前CNA，任何變化都保留待審。來源選擇變數不是gate豁免，三個完整流程必須選用，獨立健康流程維持無套件準備。

### 精確平台／封裝不適用的結案

`security-project-applicability.py` 處理明列的已審範圍：CPython 的 Windows 限定 mimetypes 公告、固定官方 GitHub CLI 未編入的 OpenPGP 公告、upload-artifact 精確 lodash 子集不含受影響實作的兩則公告，以及下述精確 C／HTML 函式子集。`Config/Security/project-applicability.json` 綁定官方公告內容、資產與受審來源圖；`Config/Security/applicability/` 保存必要的公開來源證據。這不涵蓋只有輸入受限、未找到呼叫或背景行為未明的其他版本命中。

- msgpack `GHSA-j586-36cw-2gc2`：固定 pip wheel 與兩個受管環境都沒有受影響的 C／Cython 解碼器。每次核對完整官方修補檔身分、純 Python 子集及所有 vendor 來源；外部原生模組／路徑 hook 或來源變化即拒絕。這筆新公告不借用舊 msgpack 公告的內容摘要。
- Go `GO-2026-6860`／`GO-2026-6866`：固定 gh 的已審引入圖使用 HTML tokenizer，未使用公告的 Parse／Render。每次驗證當次平台官方資產、x/net 版本與來源圖，再解析 Go 函式表（含 inline 名稱）；缺漏／未知表格式、受影響函式或任何身分漂移均保留阻擋。不安裝 Go 或執行漏洞輸入，也不把整個 x/net 說成已修補。

每次核對兩個受管解譯器的實際平台、官方 CLI／Action 內容及公告，並在 gate／Issue 寫入前重驗。原始版本命中保留在 `rawFindings`；`projectApplicabilityReviews` 記錄被排除的命中，`projectApplicabilityProofs` 另保留當次來源證據，供核對仍開啟的歷史 Issue。所有舊環境／origin 必須被明確覆蓋；版本已更新而不再命中，也不能單靠空清單結案。

正式 main 監測驗證後，符合者以「不適用」及 `not_planned` 結案，保留原始嚴重度、理由與歷史，不寫成套件已修補或風險例外。相同條件不重開、不另建同筆；證據失效且仍有查證命中時，只重新開啟由這套機制結案的原 Issue。其他人工結案／撤回紀錄不改行為，部分掃描不得結案。新平台、資產、受影響程式或公告條件須重新評估；一般套件更新、其他風險與發布門檻仍獨立處理。

### 限定專案使用流程的不適用判定

已審的未使用功能或不成立的觸發前提，可由 `security-usage-applicability.py` 產生可重驗證據。判定同時綁定官方公告、精確工具封裝、完整入口與實際專案流程；工作流程新增／變更、工具或版本漂移、公告條件修改、任一來源缺漏均不排除。只限制攻擊面而未排除前提的風險仍保留，不能因子套件已有 patch 或未找到一次呼叫就結案。手動在專案標準流程外使用工具不受此限定結論涵蓋。

GitHub Issue 明列目前判定、原因及使用範圍；符合條件時以不適用結案，保留原始嚴重度與版本紀錄。證據變動且重新命中時重開同一筆，不藉關閉或刪除告警掩蓋風險。這不是套件修補或風險豁免；有實際相關路徑且尚無修補的項目維持原門檻。

Undici `GHSA-2m5v-pch6-74hx` 的判定只涵蓋未使用函式型 `tls.checkServerIdentity` 的固定 npm／Actions 入口；`GHSA-9fm3-97px-rjf6` 只涵蓋未使用 WebSocket 的相同精確工具。`GHSA-qrxm-fqhp-jwvm` 只對標準 npm 安裝流程成立：`ci --ignore-scripts` 不會啟動唯一 Undici 消費者 node-gyp 的下載路徑，直接執行 node-gyp 或更改安裝選項不在此範圍。Actions 的真實 HTTPS／XML 路徑不能借用這個 npm 判定；四筆尚待上游修補的 Actions 告警仍保留；是否阻擋發布另由下述用途分類判斷，不能稱為不適用。官方 parent 更新後仍須驗證實際內附版本。


## 發布風險分類與交付完成

`security-release-policy.py`與`Config/Security/release-decisions.json`分離監測結果及發布影響。此流程適用後續版本，不限定某個App版號，不每31天展延。每次必須取得當次有效證據；相同公告、工具封裝、用途、輸入與權限條件成立時沿用分類。來源雜湊是機器核對證據，不是新的人工revision流程；無關App程式或文件變更不要求重新接受風險。

- App實際使用風險、發布內容／簽章、憑證、更新信任或必要安全判斷完整性受影響時仍阻擋；未知風險與必要查詢／覆蓋失敗也不自動放行。
- 已審且影響限於工具可用性、或必要交付判斷有充分獨立驗證的風險，可以保留告警而不阻擋該用途。四筆Actions HTTP／XML公告逐一綁定官方內容、精確封裝及受審消費路徑；這不是套件已修補或不適用，原嚴重度、findings與Issue保持不變。實際工作失敗仍不能通過。
- 回應錯置的`GHSA-35p6-xmwp-9g52`屬完整性風險。upload-artifact只傳遞診斷資料；正式資產來自本機簽署及獨立驗簽。公開／部署前獨立讀取相同commit的main gate、四語言CodeQL分析與可讀成果，核對正式監測run／attempt／commit／收據。另從GitHub執行日誌取得掃描程序輸出的`MYTERM_SECURITY_REPORT_SHA256`，比對artifact內實際報告；只比對同一壓縮檔內的hash不算充分證據。任何替換或缺漏均停止。
- 公告發布影響審閱與維護待辦分開。已核對的Node24.22.2公告不要求目前工具用途立即升級；Firebase15.34.2所述body-parser修補需每次確認實際1.20.9／2.4.0已滿足。兩則公告仍保留追蹤；新公告或內容變動不能借用已審結論。

真正需要暫時越過仍屬阻擋的風險，才走`exceptions.json`既有明確接受及最長31天流程；不能把臨時例外改名而永久化。正常發布分類不使用該期限。新增實質安全影響、信任／權限或門檻變更集中在最終政策PR審閱；一般跨版本驗證不逐次要求人工授權。套件／環境更新仍依已核准範圍辦理。

候選建置檢查當次來源／工具，公開入口`publish-release.sh`重新下載Draft五項資產並驗簽，再執行發布分類及遠端完整性檢查；部署在資產驗簽與網站準備後、取得Cloudflare憑證前執行同一政策。各階段不能提前宣稱尚未完成的檢查通過。掃描只接受本程序收集的報告，不能拿外部JSON當放行證明。

功能修正、Dev驗收、安全維護子項與正式交付分別記錄。只有Release公開、部署、外部資產核對、使用者Sparkle更新驗收及標準清理全數完成，版本才可結案；保留的工具Issue不因此被關閉，也不把尚未發布的版本標為完成。

公開／重部署直接使用驗簽程序輸出的相依清單，另以delivery-app範圍查詢；重部署舊tag不能借用目前來源的較新修補結果。
