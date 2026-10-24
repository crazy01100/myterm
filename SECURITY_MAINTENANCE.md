# 安全維護與發布驗證

**繁體中文** | [English](SECURITY_MAINTENANCE.en.md)

本指南說明相依套件維護與發布驗證。App 的資料保護界線見 [安全設計](SECURITY.md)，建置與發布程序見 [開發指南](DEVELOPMENT.md)。

## 相依警示與處理

啟用 GitHub 的 dependency graph、Dependabot alerts，並確認維護者已訂閱安全警示與 Actions 失敗通知。首次啟用時主動檢查既有警示；收到新版本不代表應自動合併或發布。

`.github/dependabot.yml` 提供每週一的 Swift、npm、GitHub Actions 與驗簽 Python 套件更新提案。日常監測 `MyTerm security monitor`（security-checks.yml）每天台北時間 09:23 及手動執行，檢查來源與最新正式 Release；`MyTerm release security gate`（security-gate.yml）則在 PR／main 推送檢查來源，維持中高風險阻擋。排程可能延遲，不保證準時。

日常監測的成功表示掃描與 Issue 處理完成，不代表沒有風險。有風險時以 Issue 記錄公告、元件、版本、影響範圍、上游修補資訊及例外期限；同一公告／元件／範圍沿用同一 Issue，沒有變化就不重複寫入。重要變更追加紀錄；只有完整成功掃描確認不再命中時才關閉，再次命中會重新開啟。人工作業的 Issue 不由工具管理，人工關閉仍命中的自動 Issue 不等於接受風險，下次會重新開啟。

只有查詢、測試、報告或 Issue 寫入等運作異常才使日常監測 Fail；即使連續相同故障也不能顯示成功。來源安全門檻是另一個 workflow，發現未處理風險仍會阻擋，不能把它解讀成監測故障。未知適用範圍記為待確認風險，不宣稱安全。

Issue 寫入權限只供 `crazy01100/myterm` 預設分支的排程／手動監測，PR 無此權限；fork 不會自動執行此監測 job。工具預設拒絕公開庫寫入，本庫 workflow 以 `--allow-public` 明確允許已審閱的公開公告資訊。紀錄只包含公開公告、相依版本與接受狀態，不包含主機、憑證或使用者資料。`scanStatus` 與 `lastSuccessfulScanAt` 記錄掃描健康；前次成功距今超過 48 小時會在下一次檢查提示。排程完全不執行時無法靠自己即時報警。上游版本資訊仍保存在掃描報告；沒有命中的一般新版由 Dependabot 提案追蹤，不為每個新版建立風險 Issue。

npm 相依同時比對 `npm audit` 與 GitHub Advisory Database：以鎖檔內所有套件／版本分批查詢公開公告，再按公告與元件合併。這可補足兩個資料來源更新時間不同造成的漏報；不限近期公告。任一批次失敗仍視為掃描不完整，不能據此解除 Issue。

```sh
./scripts/project-python.sh scripts/security-audit.py --output build/security-report.json
./scripts/project-python.sh scripts/security-audit.py --include-release OWNER/REPOSITORY --output build/security-report.json
```

需要已登入且有適當讀取權限的 `gh`、Python 3.12 以上、Node.js 24 LTS及 npm。只查詢公開公告與必要來源／版本資訊，不讀取本機雲端設定或簽章私鑰。`Config/Security/native-components.json` 將 libsodium 版本綁定到 swift-sodium revision；更新 wrapper 後必須重新核對實際 XCFramework header。上游修復版以 commit 公告的 Vendor，使用 commit ancestry 判斷，不捏造版本號。

新增中高風險、未知適用範圍或查詢錯誤會阻擋發布前檢查；最新已發布 App 的舊漏洞仍列在監測報告，但不阻擋用已修復來源建立後續更新。一般期限例外只可使用 `Config/Security/exceptions.json` 明確列出的公告、元件、版本及 development scope，附接受人、理由與期限；最長 31 天，逾期自動恢復阻擋。不因屬於 devDependency 就整類忽略。


`security-audit.py --monitor` 只在掃描運作異常時回傳失敗；風險清單仍完整保存在報告。未加 `--monitor` 的發布前檢查維持未處理風險阻擋。自行發行者應建立自己的風險追蹤流程。未知新漏洞、私人測試證據與使用者資料不屬於自動公開範圍，通報方式見 [安全設計](SECURITY.md)。


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

Firebase CLI 固定為 `15.34.0`，上游已原生支援安全版本的 `stream-json`、`stream-chain` 與 `csv-parse`；舊的來源改寫補丁、postinstall 及這兩項專用覆寫已退役。安裝使用 `npm ci` 驗證鎖檔及套件完整性；`scripts/verify-firebase-tools.cjs` 在 wrapper 啟動與 CI 中唯讀核對 CLI 精確版本、manifest／lockfile 與實際解析到的三項串流相依。此檢查不驗證每份已安裝來源的雜湊，也不取代完整性安裝、安全掃描與消費端測試。回歸涵蓋真實 Auth JSON／CSV 和 DatabaseImporter（攔截傳輸）、分段資料、Next.js 管線語意、過深輸入拒絕，以及缺漏／過期／巢狀相依漂移。命令 allow-list 與其他仍必要的 npm overrides 保留。間接相依的安全修正優先在原相容範圍更新鎖檔，不為解決可相容更新的告警新增覆寫。

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


### Issue #43 條件式風險接受

目前決策為 **revision 7／retired（官方公告撤回）**；revision 7 僅經維護者核准擴充 Python 工具與 CI 的政策來源指紋，原退役決策與撤回證據不變。維護者於 2026-10-24 明確核准退役提案 `issue43-withdrawal-retirement-1`，提案 SHA-256 為 `c979cbc420118841efdd8306681356da605bb038c71872425b752417a3cbc0f9`。GitHub Advisory Database 於 2026-10-23 20:53:02（UTC+8）撤回 [GHSA-vfj7-8cjw-p6xm](https://github.com/advisories/GHSA-vfj7-8cjw-p6xm)，理由是不具實際可利用性。這是官方撤回，不是套件修補、風險展延或本專案的實際可利用性測試結論。

`Config/Security/conditional-acceptances.json` 保留原 revision 5 的基準、接受紀錄與原期限歷史，另記錄退役核准、官方摘要及政策執行來源。歷次 revision 1–5 與 PR Review 可由 Git 歷史追溯；不改寫當時的風險判斷。`accepted=false` 與 `retirementVerified=true` 明確區分「沒有風險豁免」和「已核對撤回」。其他漏洞仍依普通安全門檻與最長 31 天例外規則。

每項開發／維護開始、跨日恢復、Firebase 使用、發布準備、Draft 公開及重部署仍由共用入口重新查詢官方撤回證據，核對公告身分、內容摘要與政策執行來源；不執行 npm 套件、不沿用舊通過收據。已退役的歷史依賴鎖檔／Rules 指紋不再限制無關更新，但修改退役驗證器、相關安全入口或政策仍須重新審閱。公告恢復有效、撤回內容改變、證據缺少或來源失敗時停止並重評，不自動恢復接受或把查無資料當成安全。新公告包含 braces 的新風險照常阻擋。

```sh
./scripts/project-python.sh scripts/security-conditional-risk.py \
  --purpose development --task TASK_ID \
  --output docs/TASK_ID-conditional-review.json
```

purpose 包含 development、firebase、ci、monitor、release、publish、redeploy；用途欄位不是豁免。發布與重部署仍需獨立授權。既有 wrapper 命令限制、loopback 模擬器與大括號路徑防護保留；不因此開放未審查的輸入或直接 CLI 使用。json-ptr 與其他 EoL／EoS 個案決策不變。

PR 的決策須與受審 base 相同，否則須取得當前精確 head 的維護者 Review。其他作者 PR 使用原生 APPROVED；指定維護者本人建立、同庫且目標 main 的 PR 使用 `MYTERM-CONDITIONAL-REVIEW-V1` 正式 COMMENTED Review。核准身分固定為 crazy01100／43394184／User，紀錄綁定 PR、完整 head/base、revision 與政策原始 bytes SHA-256；退役使用 `action=retire` 及撤回專用聲明，不能用舊的接受風險聲明取代。撤銷、過期、PENDING、格式錯誤或普通留言均不接受，後續 Review 不會讓舊核准自動復活。

CI 與合併前均唯讀重查完整 PR／Review，核對本機政策等於遠端精確 head，並在官方查詢後再核對來源及 Review。退役不能提早成功而跳過審閱。精確 Review 不代表完整 CI 已通過，也不能代替第二人審查或阻止帳號擁有者另行繞過；`mergeAuthorized=false` 保留。必須使用正常、精確 head 的合併流程，不使用 admin 略過。

監測對 npm 舊資料中的撤回公告，必須取得身分與元件相符、日期有效的官方撤回證據才排除目前 finding，並記錄 `withdrawnAdvisories`；npm 原始計數保留來源意義。缺漏或錯誤仍使掃描失敗。Issue #43 不因漏列或退役自動關閉：先完成核准、main 安全檢查／完整監測／CodeQL，重新核對官方撤回，再以「官方公告撤回／不再適用」人工結案並保留歷史。若公告再次有效，正常監測可重新開啟告警。

前置檢查失敗時保存 preflight 與條件複核證據；有診斷檔不代表完整掃描成功。`test_conditional_risk.py` 等政策案例只用 mock／stub；完整開發工具回歸含既有漏洞案例，仍須該次任務明確授權。不得恢復 Daybreak 或已終止的實際可利用性計劃。

## Python 安裝工具與憑證信任

開發工具由 `Config/Security/python-tools.json` 固定 pip 26.2.2、certifi 2026.10.19、官方 wheel URL／SHA-256 及 CA 檔摘要。這處理 [GHSA-6q48-6c7w-9gw2](https://github.com/advisories/GHSA-6q48-6c7w-9gw2) 的憑證信任事件；沒有 CVE 不代表不需追蹤。pip 內附 certifi 與獨立 certifi 分開核對，單獨安裝 certifi 不能替換舊 pip 的內附副本。

`python-toolchain.py setup` 先取得並核對所有精確 wheel，才建立／更新 `.build/python-runtime` 與 `.build/security-tools`；種子 pip 只用 no-index／no-deps 安裝已驗證的本機 wheel，不先做一般網路下載。兩個環境各自核對 pip、內附／獨立 certifi 與 CA 摘要。既有 venv 原地更新，只有明確 `setup --rebuild` 才清空重建；失敗即停止，不使用不完整環境。不要在其他程序仍使用該環境時重建，也不要搬動 venv 而忽略絕對 shebang。

`setup-security-tools.sh` 共用上述流程，再從明確官方 index 以 require-hashes／wheel-only 安裝原有驗簽相依；不使用私人 pip 設定，不修改系統 Python 或共用解譯器。`security-python.sh` 每次驗證工具與 CA 並設定子程序的 SSL_CERT_FILE；一般 `project-python.sh` 仍只選解譯器，不承諾改變任意第三方程式的信任邏輯。安全掃描與退役公告查詢直接使用 helper 建立的明確 certifi SSLContext，不合併舊預設 OpenSSL CA 檔。自訂企業 CA 不會自動加入，需求須另行審查；不能停用驗證來修復連線。

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
