# MyTerm 系統架構

**繁體中文** | [English](ARCHITECTURE.en.md)

本文說明 MyTerm 目前的公開系統架構、資料流及安全邊界。實作與部署細節以儲存庫中的程式碼及設定為準。

## 架構總覽

```text
┌──────────────────────────── MyTerm.app ────────────────────────────┐
│ SwiftUI / AppKit                                                   │
│  ├─ 主機與多階層群組管理       ├─ 設定、匯入／匯出與快捷鍵          │
│  ├─ SSH / Terminal / Serial    ├─ 雙欄 SFTP                        │
│  └─ SSH 連線稽核 Logs（本機優先、可選加密同步）                   │
│                                                                    │
│ 系統服務                                                           │
│  ├─ /usr/bin/ssh + PTY          ├─ macOS Keychain                  │
│  ├─ App 專用 known_hosts        ├─ Application Support 本機資料    │
│  └─ Sparkle 更新器              └─ 選用的端對端加密同步             │
└────────────────────────────────────────────────────────────────────┘
             ├─ Google 登入（選用） ── HTTPS ──▶ Google OAuth
             │                                  │
             │                                  ▼
             │                         Firebase Authentication
             │                                  │ Firebase ID token
             │                                  ▼（僅啟用同步後讀寫）
             │                         Cloud Firestore（只保存密文）
             │
             └─ App 更新 ──────────── HTTPS ──▶ mtus.lieniapp.work
                                                │ Sparkle appcast
                                                ▼
                                      GitHub Release 安裝包
```

MyTerm 的核心功能不依賴雲端。登入 Google 時會經過 Google OAuth 與 Firebase Authentication 建立雲端帳號身分；只有使用者另外啟用同步後，MyTerm 才會使用 Firebase ID token 存取 Cloud Firestore，並初始化主機資料與已結束 Logs 的跨裝置同步流程。

官方 App、純本機原始碼建置與自行建置同步後端的設定邊界，以及 Firebase／Google Cloud 前置作業，見 [Firebase 自架同步設定](FIREBASE_SETUP.md)。

## App 元件

### 使用者介面

- `Sources/MySSHClient/Views`：主機庫、平台徽章、編輯器、終端機、Serial、SFTP、連線稽核 Logs 與設定畫面。
- `Sources/MySSHClient/Views/AppVisualTheme.swift`：主視窗 chrome、側欄、內容底、卡片、選取、滑過與邊界的集中式語意色彩來源；每個角色都有成對的淺色／深色值，需要跨 SwiftUI／AppKit 邊界時由同一來源提供 `Color` 與 `NSColor`，避免不同畫面各自硬編碼而漂移。
- `Sources/MySSHClient/Views/TerminalOutputTheme.swift`：終端專用背景、一般文字、caret、selection 與明暗 16 色 ANSI 預設色盤。`TerminalContainerView` 只在建立畫面或外觀改變時安裝色盤並清除 SwiftTerm 顏色快取，不重建 Session／PTY 或改寫輸出。既有 ANSI 索引文字同步換色，保留粗體及黑／白端點語意；明確選用 `.xterm` 策略，將擴展索引 16～255 固定為標準色塊／灰階，不使用 SwiftTerm 預設的 `base16Lab` 隨主題衍生擴展色；true-color RGB 保留原值。OSC 可暫時覆寫色盤，OSC 104／soft reset 還原已安裝主題；下次外觀切換重新套用該模式的預設色盤。任意應用自訂前景／背景配對不保證符合預設背景上的對比目標。
- `TerminalMessageHighlight.swift` 提供兩項顯示政策：`TerminalNeutralContrast` 在 attributes 快取前對低於 4.5:1 的 neutral ANSI 前景（0／7／8／15）依實際背景補償；`TerminalMessageHighlight` 在既有 renderer 建立行內容時只查看前 48 個 cell，回傳一個行首標籤範圍及明暗專用字色。標籤分色可覆蓋該標籤原本 ANSI／RGB 字色，後方內容不變；selection 優先。wrapped continuation、alternate buffer、明確底色、conceal／inverse／dim 標籤不匹配；黑白補償也排除 conceal／inverse／dim，RGB 與擴展色不補償。不儲存輸出、不改 parser／buffer／PTY，沒有額外 stream buffer 或全 scrollback 掃描。開關以通道各自的 UserDefaults 保存，既有分頁同步更新。
- `Vendor/SwiftTerm` 保存固定 upstream revision 的 library runtime、MIT 授權與 library-only manifest；macOS renderer 只有兩個預設 nil 的可選 hook：前景配對轉換與行範圍高亮。MyTerm 的套用入口會使現有顏色／行繪製快取失效；沒有更換繪圖後端或修改輸入／選取幾何。上游來源、局部差異及升級核對流程見 `Vendor/SwiftTerm/UPSTREAM.md`。
- `Sources/MySSHClient/MySSHClientApp.swift`：App 進入點、設定視窗、選單與整體生命週期。
- App 外觀以深海軍藍框架、霧藍內容層與抬升卡片建立一致層級，沿用既有「自動、淺色、深色」偏好，不新增每台主機的獨立主題。Terminal canvas／ANSI、平台 Logo，以及成功、警告、錯誤與取消狀態保留各自的專用色彩與文字／圖示語意，不由通用色票覆蓋。
- SwiftUI 負責狀態、macOS 原生 toolbar 中的單一工作區列與主要 App 外殼；隱藏原生文字標題及 toolbar 的共享膠囊背景，但保留系統視窗拖動、縮放與全螢幕行為。工作區分頁與內容畫布分屬 toolbar／content view hierarchy，因此以輕量 AppKit frame reader 將兩者矩形及滑鼠事件統一成視窗左上座標；同一套座標供分頁重排、四向合併預覽及窗格拖回拆分使用，不依賴固定 toolbar 高度。Terminal 工作區以 AppKit 原生分割容器作為界線清楚的 native island，處理穩定 pane hosting、live divider tracking、macOS 游標與終端機尺寸調整。主視窗提供較大的預設尺寸並保留可縮放能力。
- 主機庫左側只保留 Known Hosts 與 Logs 兩個功能入口；所有主機、分類與未分類主機都在右側內容區瀏覽，分類 breadcrumb 固定以可返回根頁面的「所有主機」開頭。主機庫、SFTP 主機選擇器及兩側檔案列表共用一致的互動原則：滑鼠移入提供視覺回饋、單擊立即選取、雙擊才進入分類／資料夾或建立連線。「所有主機」內容區另允許把主機拖到分類卡片；放手只建立確認請求，確認後才由 `HostStore` 寫入，群組內頁與左側功能列不接收投放。

### 主機與本機資料

- `HostStore` 保存主機及多階層群組，負責以交易式操作驗證並移動主機分類，並使用獨立的 `HostConnectionRecencyIndex` 排列主機庫卡片；本機資料檔權限都限制為目前使用者。分類移動保留主機 UUID，只更新 `groupID` 與 `updatedAt`，所以密碼、平台及最近連線關聯不變。「所有主機」內容區只在目前可見、未進入分類且沒有待確認搬移時啟用 `HostLibraryDragMonitor`；主機頁被 Terminal 等功能遮住、切入分類或開啟確認時會停止追蹤，避免不可見卡片攔截其他畫面的拖曳。啟用時 monitor 在目前視窗追蹤由主機卡片開始的拖曳，並把游標位置直接和 SwiftUI 回報的完整分類卡矩形比對；一般單擊、雙擊與右鍵仍由卡片本身處理。Monitor 的 AppKit 資源生命週期與 SwiftUI 拖曳狀態分離：視窗拆除、Coordinator 釋放或重新安裝 monitor 時只移除事件 token 與內部追蹤，不回寫已進入銷毀流程的 SwiftUI state；只有畫面存活期間的使用者取消才通知 SwiftUI 清除拖曳狀態。
- `LocalSecretVaultStore` 將登入狀態、同步 Master Key 與主機密碼保存於同一個 AES-GCM 本機保管庫；只有一把隨機根金鑰留在 macOS Keychain。正式、development 與 update-lab 通道使用不同保管庫根金鑰；只有 production 可執行早期正式 session 的相容遷移，隔離通道不讀取 production 的舊 refresh token。
- `KeychainStore` 仍以主機 UUID 定位密碼，但只操作統一保管庫，主機資料本身不含密碼。
- `KnownHostsStore` 管理 MyTerm 專用 SSH 信任檔；使用者另可手動載入本機 `~/.ssh/known_hosts` 快照。
- `AppShortcutStore` 保存只在 MyTerm 內生效的快捷鍵設定。
- 字體縮放快捷鍵整合於相同 store；預設放大的 equals／plus 及數字鍵盤別名使用同一事件匹配與衝突規則，停用或自訂後釋放預設別名。新增縮放動作透過一次性遷移補入未占用的預設組合，保留既有自訂與停用；單項恢復預設也會檢查衝突。
- `TerminalWorkspaceCollection` 保存執行期間的視覺分頁順序、作用中窗格、分割方向與比例；每個工作區的不變條件限制為一或兩個 Terminal session，並負責把雙窗格中的任一 session 拆回獨立分頁及收斂原工作區。
- `TerminalSessionPresentation` 保存不依賴 SwiftUI 或 SwiftTerm 的執行期顯示規則：把 Session 狀態映射為分頁連線燈、依基礎名稱配置不受排序／合併影響的同名 Session 編號，並以 Session UUID 集合聚合背景 Workspace 的未讀輸出。編號與未讀狀態只存在程序記憶體，不改寫主機名稱、Logs、同步或匯出資料。
- `ConnectionAuditStore` 以獨立 versioned 文件保存互動式 SSH 的主機快照、帳號端點、來源裝置快照、開始／驗證／結束時間與結構化結果。連線開始時已知的平台直接進入快照；若尚未知，該 Terminal Session 後續辨識出的第一個平台可補寫同一筆紀錄，之後不再覆寫，也不會由目前 `HostStore` 動態回填其他歷史紀錄。保存工作在背景序列佇列執行，最多保留 30 天與 5,000 筆；損壞檔案會先隔離備份，App 仍可從空紀錄啟動。這份資料不併入 `HostStore` 或主機匯出。
- `AutomaticConnectionAuditSyncStore` 在啟用既有同步且 Master Key 可用時，獨立協調 Logs 的下載、去重、加密上傳與到期整理。進行中的連線只留在來源裝置；完成、失敗、取消或啟動恢復為未完整結束後，才將不可變的最終紀錄交給 `ConnectionAuditSyncCodec` 加密並透過 `FirestoreConnectionAuditBackend` 寫入專用集合。網路工作不位於 PTY、鍵盤或終端輸出路徑。

### 連線與終端機

- SSH 使用 macOS 內建 `/usr/bin/ssh`，MyTerm 建立 pseudo-terminal 並顯示互動畫面。
- 互動式 SSH Session 以 OpenSSH 的私人 verbose log 建立結構化連線階段；`SSHConnectionLogParser` 支援 CR／LF／CRLF，verbose debug 只供內部分類，使用者可見與可複製內容僅保留 allow-list 的繁體中文摘要及非 debug OpenSSH 原始錯誤，並遮蔽本機路徑／代理程式資訊。只有 OpenSSH 回報實際驗證成功後，Session 才進入 connected，並更新該主機在本機的最近成功連線時間；失敗、取消或只建立分頁不更新。已停止的 SSH 可由失敗畫面按鈕或作用中終端的 Enter 走同一個原位重試入口：保留 `TerminalSession`、SwiftTerm view、工作區與正常 scrollback，重建 PTY、OpenSSH 參數、短期診斷檔、parser 及密碼提示狀態；遠端 shell 狀態不在本機恢復範圍。成功後會釋放連線診斷記憶體，異常退出遺留的短期記錄則於下次 App 啟動清理。
- `SessionManager` 保有 Terminal process 生命週期，並把 Session 組成可拖曳重排的工作區；它同時管理執行期同名編號及背景輸出未讀集合。`LoginAwareTerminalView` 只在真正送入 renderer 的程序輸出邊界回報活動；目前可見 Workspace 的輸出不建立提示，背景 Workspace 只在第一次由已讀轉為未讀時發布狀態，避免大量輸出反覆重繪 toolbar，切回後清除該 Workspace 的 child 狀態。它也把每次 process attempt 的開始、OpenSSH 真實驗證成功、失敗、取消與結束事件送入 `ConnectionAuditStore`。同一窗格原位重連會沿用 pane session ID，但 `ConnectionAuditIndex` 只把進行中的同 ID attempt 視為冪等；上一筆已最終化後的重連會建立新的 record UUID，因此 Logs 與加密同步仍是逐次連線紀錄。把分頁拖入內容區時，一般優先以前一個工作區為合併目標，第一個分頁則使用後一個工作區，可合併為左右或上下雙窗格。把窗格標題列拖回頂部分頁列則可拆開；合併、拆分、切換方向與調整比例都不重建底層 process，也不新增稽核紀錄。
- `TerminalWorkspaceSplitContainer` 為每個執行中 Session 保留穩定的 pane host；原生 `NSSplitView` 在拖曳期間直接更新 child view frame，完成拖曳後才把最終比例同步回 `TerminalWorkspaceCollection`，避免每個滑鼠事件都發布整個 SwiftUI 工作區狀態。分隔線的 25%～75% 邊界由 split view 強持有的獨立 `NSSplitViewDelegate` proxy 提供；delegate 不指回 split view 自身，避免 AppKit 在驗證側邊欄選單 action 時形成 responder 查詢遞迴。
- `TerminalContainerView`／`LoginAwareTerminalView` 保留 SwiftTerm 的原生 terminal buffer 與 TUI mouse reporting：遠端滑鼠模式關閉時，一般及持續輸出不會清除使用者已建立的本機 selection；Vim、tmux 等程式啟用 mouse reporting 後，普通點擊、拖曳與滾輪仍完整送往遠端，Shift＋拖曳沿用 SwiftTerm 的本機選取。終端內容區使用 I-beam，滾動期間暫時隱藏系統指標以避免箭頭／I-beam 交替；文字 caret 以 steady 形狀顯示，遠端同一批 hide/show 只套用最後可見狀態。預設 Vim 未啟用 mouse reporting 時的 alternate-buffer 滾輪 fallback 以 display link 逐幀傳送方向步驟並合併中間回應；實體鍵盤、一般 shell scrollback 與已啟用的遠端滑鼠回報不經此路徑。
- 系統預設模式沿用 OpenSSH 的現代演算法政策；RSA 相容與自訂選項只套用至指定主機。
- 本機 Terminal 執行 `/bin/zsh` login shell，起始目錄為目前使用者家目錄。
- `TerminalSession.terminalFontSize` 只在該 Session 執行期間保存 10～32 點的字體大小，預設 14 點；縮放入口確認該 terminal 確實擁有鍵盤焦點且沒有 modal／sheet，再交由 `TerminalFontSizePolicy` 計算。`TerminalContainerView` 只在大小改變時透過 `TerminalFontZoom.swift` 更新字體：同步暫用零尺寸以略過 SwiftTerm font setter 附帶的 soft reset，再恢復原 frame，沿一般視窗 resize 路徑通知 PTY 行列數，保留 process、游標模式與 scrollback。字體更新會清除當下 selection，後續選取依新字體座標建立；大小不寫入主機、Logs、同步或匯出，也不跨 App 重啟保存。
- Serial 驗證並連接 `/dev/cu.*` 或 `/dev/tty.*`，參數直接傳給固定系統程式，不經 Shell 字串插值。
- SFTP 實作檔案瀏覽、傳輸、覆蓋確認與基本檔案管理；本機 FileManager attributes 與遠端 SFTP v3 attributes 已取得的 POSIX permissions 會交由共用 `SFTPPermissionMode` 格式化成 symbolic／八進位權限，列表不會為每個項目增加額外 `stat` 或 SFTP request。視覺化權限矩陣與八進位輸入使用同一狀態，最後仍透過既有本機／遠端 chmod 流程套用，成功後重新載入實際 attributes，未知權限不套用預設值。本機與遠端檔案拖放使用 App bundle 明確宣告、符合 `public.data` 的私有資料型別，候選與發布驗證會拒絕缺少宣告的封裝。主機庫分類移動則完全在目前 MyTerm 視窗內依滑鼠事件與卡片矩形處理，不建立可供其他 App 傳入的拖放 payload。認證設定沿用相同主機資料與本機加密保管庫邊界。本機瀏覽器會解析可導覽的符號連結，因此 OneDrive 等 File Provider 目錄可留在 MyTerm 內操作。
- SFTP 路徑使用響應式 breadcrumb：空間足夠時顯示完整層級，空間不足時保留前後關鍵目錄並以 `…` 選單收合中段，不使用會遮住文字的水平捲軸。
- 平台辨識先被動解析終端機輸出；仍未知的平台可在不執行遠端修改的前提下，以背景 SSH probe 讀取作業系統資訊。辨識結果保存於主機資料，供主機庫、SFTP 選擇器、連線分頁與終端機窗格共用 SVG 平台徽章；同一 Terminal Session 對應的 Logs 快照若仍未知，也會只補寫第一次可信結果。

## 資料保存位置

| 資料 | 保存位置 | 是否跨裝置 |
|---|---|---|
| 主機與群組 | Application Support 內的權限限制檔案 | 啟用同步時，以密文同步 |
| 主機最近成功連線時間 | Application Support 內權限 `0600` 的獨立檔案；只含主機 UUID 與時間 | 不同步、不匯出 |
| SSH 連線稽核 Logs | Application Support 內權限 `0600` 的 `connection-audit-log.json`；包含連線當下的主機、帳號端點、來源裝置、時間及結果，最多 30 天與 5,000 筆 | 啟用同步時，只把已結束紀錄以密文同步；不匯出 |
| 主機密碼 | AES-GCM 本機保管庫；根金鑰為 `WhenUnlockedThisDeviceOnly` Keychain 項目 | 啟用同步時再端對端加密；目的 Mac 解密後寫入其本機保管庫 |
| Master Key、登入狀態 | 與主機密碼共用本機保管庫及單一 Keychain 根金鑰 | 不直接同步 |
| 私鑰檔案與路徑 | 使用者指定的本機位置／本機設定 | 不同步 |
| MyTerm `known_hosts` | 各台 Mac 的 Application Support | 不同步 |
| SSH 連線暫存診斷 | Application Support 內權限 `0600` 的短期檔案；成功、失敗或關閉後刪除，異常退出殘留於下次啟動清理 | 不同步 |
| 匯出檔 | 使用者選擇的位置 | 不由 MyTerm 自動同步 |

正式 App 顯示名稱已改為 MyTerm，但正式 Bundle ID、Keychain service 與既有 Application Support 識別字保留舊名稱，以維持早期版本升級後的資料與密碼關聯。`MyTerm Dev.app` 則使用獨立 Bundle ID、Application Support 目錄與本機保管庫 Keychain service，開發驗收不得讀寫正式資料或繼承正式 Google session；若舊版 Dev 曾誤匯入正式 session，新版會在隔離通道內執行一次清理，之後 Dev 自行建立的登入可正常保留。

## 端對端加密同步

`AutomaticSyncCoordinator` 是日常同步排程入口，先由 `VaultSetupStore.prepareForAutomaticSync` 在帳號還原後初始化既有本機保管庫，不依賴 Settings scene 出現。協調層並行呼叫獨立的 metadata／password 及 Logs worker，等待兩部分結果；衝突等待確認不阻止 Logs，但不能算整輪成功。主機／密碼及 Logs 仍保留原有加密與資料集合。

AppKit 作用中／非作用中事件控制唯一的前景 5 分鐘同步週期，另接受啟動、喚醒、本機變動及過期 Logs 頁面的要求。本機變動合併約 1.2 秒；執行中合併下一輪要求，不反覆延後目前工作。暫時失敗等待既有週期或明確的回前景／喚醒／手動入口，不設短間隔退避計時器；失敗後的一般資料／狀態變更不會形成緊密重試。整輪 120 秒逾時只取消並等待兩 worker 釋放，不另排重試。停用／帳號變更取消舊世代；worker 在網路回應與本機套用邊界檢查取消，舊世代不能發布新帳號的成功結果。

`CloudAccountStore` 的登入還原使用 single-flight 任務與 initial／retryableFailure／blocked／restored 狀態；只有暫時網路或服務錯誤可在後續同步週期再試。`SyncSettingsStore.sessionRecoveryEnabled` 記住最後已知帳號的同步啟用選擇，即使登入暫時不可用也能決定是否允許恢復；它不會在未登入時啟用資料同步。協調層於五分鐘、回前景、喚醒或手動要求時先執行符合條件的登入恢復，成功後接續同步；availability 回呼不會遞迴發出登入請求。主動登出、停用、無憑證或永久失效不進行週期性登入恢復；啟動時原有的單次 session 還原不依賴同步啟用。Google ID Token 更新沿用共用單一更新任務；登入世代檢查拒絕登出後才到達的舊回應。

`ConnectionAuditStore` 保留尚未保存的修訂，即使下載紀錄已在記憶體去重也能重試磁碟寫入；Logs worker 等待 `persistForSync` 成功才標記完成。各 worker 與整輪成功時間按帳號摘要保存於通道專用 UserDefaults；設定的日常同步區只顯示整體狀態與單一整輪成功時間，不列分項明細。取消、部分失敗與尚未成功不能當作全部完成。`SyncDiagnosticsJournal` 只在本機保存 allow-list 的有界同步執行事件，不加入同步資料或既有連線稽核；設定內的診斷工具預設收合。

同步是選用功能，資料流如下：

1. 使用者以 Google Desktop OAuth 登入；PKCE、state、nonce 與只監聽 `127.0.0.1` 的暫時回呼降低授權碼攔截風險。
2. 使用者輸入同步密語。MyTerm 以 Argon2id 派生保護金鑰，用來解開或建立 Master Key 封套。
3. 每筆主機、群組、密碼與已結束 Logs 資料使用 AES-256-GCM 加密；Logs 的主機、帳號、位址、來源裝置、時間與結果都位於密文內。
4. Firebase Authentication 限制帳號身分；Firestore Security Rules 只允許目前 UID 存取符合格式的密文路徑。
5. 另一台 Mac 使用相同帳號與同步密語解開 Master Key，再將密碼寫入該台 Mac 的本機加密保管庫。
6. 主機、群組及分類關聯以加密 metadata revision 同步；「立即同步」只觸發目前裝置的上傳與拉取。其他 Mac 於自行同步、回到前景或前景定期事件時拉取，不使用跨裝置 UI 即時推播。

Firestore 不保存明文主機內容、Logs 內容、來源裝置名稱、同步密語、Master Key 或解密後密碼。復原金鑰是使用者遺失同步密語時的獨立復原途徑，MyTerm 不代為保存其明文。

主機與群組刪除會以帶有 revision、裝置識別與 AES-256-GCM 驗證的 tombstone 傳播；遠端刪除套用前會先建立本機還原備份。

Logs 使用 `users/<UID>/connectionLogs/<record UUID>` 的獨立不可變文件，不沿用主機 metadata snapshot 或 tombstone。每次同步先取 Firestore HTTP 回應的伺服器時間，排除超過 30 天的本機資料，再上傳尚未存在的最終紀錄並整理過期密文；因此離線裝置重新上線也不能復活到期紀錄。介面不提供單筆刪除或清除全部，雲端刪除權限只供這項固定期限整理使用。

## SSH 密碼流程

- 已保存的 SSH 登入密碼只在設定帳號一致且第一次登入 `password:` 提示時自動送入 PTY。
- 未保存密碼時，MyTerm 暫存該次輸入；只有 OpenSSH 診斷資料確認以 `password` 成功驗證後，才詢問是否保存。若已保存的第一次自動嘗試失敗，後續登入提示改為擷取使用者手動輸入，仍須通過相同 OpenSSH 證據才可詢問取代舊值。
- 強制改密碼使用獨立狀態機：只有先辨識目前密碼提示，才私下擷取新密碼與確認值；兩次輸入必須以固定時間比較一致，且遠端明確回報更新成功後，才詢問是否覆寫本機保管庫。候選值在失敗、取消、不一致、拒絕保存或工作階段清理時覆寫並釋放。
- `keyboard-interactive` 不會被當成可保存密碼，避免誤存 OTP 或一次性挑戰。
- `sudo`／`su` 等後續提示與 SSH 登入回呼分離；MyTerm 只允許使用者在已辨識提示中手動一鍵填入。

## 更新與發布

```text
開發 Mac
  └─ 測試、arm64 Release 建置、固定本機發行憑證簽署、Sparkle Ed25519 簽署
       └─ 私人 GitHub Draft Release
            └─ 人工核對並發布
                 └─ GitHub Actions
                      ├─ 下載並驗證五個 Release Assets
                      ├─ Direct Upload 至 Cloudflare Pages
                      └─ 從外部重新驗證網站、appcast、ZIP 與安全標頭
```

- GitHub Releases 保存正式 ZIP、`appcast.xml`、更新說明、校驗碼與 manifest。
- Cloudflare Pages 提供安裝頁、更新說明與 Sparkle feed；不需要 Cloudflare Worker。
- Sparkle 以 App 內嵌的 Ed25519 公鑰驗證更新。修改過、錯誤簽章或下載不完整的封裝會被拒絕。
- MyTerm 自有的 SVG 平台圖示由建置腳本放入標準 `Contents/Resources/PlatformIcons`，執行期只從 `Bundle.main` 載入，不使用會嵌入建置機 fallback 路徑的 executable-target `Bundle.module`。候選 App、封裝 ZIP、GitHub 回下載資產與 Cloudflare 部署前會共同驗證圖示內容並拒絕不安全的 MyTerm SwiftPM resource accessor。
- Sparkle 不要求 App 路徑名稱必須是 `/Applications`，但會拒絕從 App Translocation、唯讀映像、暫時位置或無法替換 App 的位置更新。正式安裝一律先將 `MyTerm.app` 移到「應用程式」資料夾；專案 `build/` 內的 App 只供開發測試。
- 目前未使用 Apple Developer ID，因此第一次手動下載可能需要 macOS 使用者確認。零費用自簽憑證無法取得 Apple Team ID，Keychain 仍可能把每次建置視為新的程式身分；本機機密集中於單一加密保管庫與單一 Keychain 根金鑰，使更新後的驗證不會隨主機數量增加。這不會取代 Sparkle 的更新簽章驗證。

## 儲存庫結構

| 路徑 | 用途 |
|---|---|
| `Sources/MySSHClient` | App 原始碼 |
| `Sources/MySSHClient/Resources/PlatformIcons` | 內建作業系統與設備平台 SVG 徽章 |
| `SelfTests`、`Tests` | 核心、加密、OAuth 與 Firestore Rules 測試 |
| `Resources` | App 圖示、Info.plist 與測試資源 |
| `Config` | 可公開的設定範例與 Sparkle 公鑰 |
| `scripts` | 建置、測試、封裝、發布與驗證工具 |
| `.github/workflows` | GitHub Release 發布後的 Cloudflare 自動部署 |
| `update-site` | Cloudflare Pages 靜態網站來源 |
| `firebase.json`、`firestore.rules` | Firebase Emulator 與正式安全規則 |

`build/`、SwiftPM 快取、`node_modules/`、本機 Firebase 設定、OAuth secret、使用者匯出資料及內部計劃紀錄均不屬於公開原始碼。

## 目前限制

- 只支援 macOS 26 與 Apple Silicon arm64。
- 私鑰、私鑰路徑及 `known_hosts` 不跨裝置同步。
- `sudo`／`su` 需要按鈕或快捷鍵，不會自動送出密碼。
- Logs 只記錄由主機庫建立的互動式 SSH 連線中繼資料；不包含本機 Terminal、SFTP、Serial、輸入命令或終端機輸出，也無法補回功能啟用前的歷史紀錄。跨裝置只同步已結束紀錄，不顯示其他裝置的連線中狀態或即時計時。
- 跨裝置同步由 App 啟動、回到前景、喚醒、本機可同步資料變動、過期 Logs 頁面及前景定期事件觸發，不使用常駐推播；另一台 Mac 的變更會在下一次同步觸發時套用。App 關閉、睡眠或不在作用中時沒有常駐輪詢保證。
- 目前未使用 Apple Developer ID 與公證，第一次安裝可能出現 macOS 無法驗證開發者的提示。

## 安全控制元件

`SFTPCancellation` 在協定初始化之前保存由 lock 保護的取消動作。Transport 以非阻塞 pipe 與單調時鐘期限進行 poll；取消不等待序列操作鎖，也不在進行中的操作仍持有 descriptor 時關閉／重用它。Browser 的 generation 核對避免舊連線覆寫目前狀態。

`dependency-inventory.py` 讀取 Swift 鎖定檔、Vendor revision 與已審閱的 native binary 資訊；`bind-release-metadata.py` 在簽署前把相依清單與來源 commit 綁入 feed。`verify-signed-release.py` 使用可信公鑰驗證原始 feed bytes 後才信任 URL 或解壓 ZIP，並核對更新說明及五項發布資產。`security-audit.py` 另行檢查目前來源與已發布相依；簽章證明來源，不保證沒有漏洞。操作需求見 [安全維護指南](SECURITY_MAINTENANCE.md)。

私人安全監測以 `sync-security-issues.py` 將完整成功掃描映射至 bot 所建立的私人 Issue，依公告／元件／範圍去重；只在預設分支排程／手動工作授予 issues:write。監測成功與風險是否存在分離；PR／發布的安全門檻獨立保留阻擋條件。

`render-release-notes.py` 是私人／公開發布共用的更新說明 HTML 產生器，保留文字 escaping 與原段落內容，統一版本標題。專用 release-notes.css 只負責窄幅深淺色呈現；HTML 仍在既有流程中簽署並驗證，不包含網站導覽。

Firebase 開發工具的 `stream-json` 相容性由 `scripts/patch-firebase-stream-json.py` 負責，npm 安裝時套用、CLI wrapper 啟動前驗證固定版本與檔案雜湊；相容補丁只轉接 Node 串流介面，不改 App 資料流。套件自身的深度限制與專案命令範圍限制共同保留，細節見 [安全維護指南](SECURITY_MAINTENANCE.md)。

`scripts/project-python.sh` 是管理／測試／發布腳本的 Python 選擇入口，接受明確指定的受支援執行檔、專案隔離環境或 PATH；拒絕低於3.12，不覆蓋系統Python。`setup-security-tools.sh` 使用相同選擇建立獨立驗簽venv；此工具環境不隨App封裝。

`scripts/project-node.sh` 選擇Node 24 LTS並提供npm入口，Firebase子程序及npm稽核使用同一環境；不更動全域Node或App執行期。
