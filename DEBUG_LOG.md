# 2026-10-23 — 0.1.52 第二轮 CI 两红：`getAllTasks` 在当前 SDK 无 async 重载（CI 修复轮二）

- **现象**：提交 d22ba7c 的完整 CI（run 39871049020）：signer-tests ✓；swift-regression ✗ 与 build-package ✗ 同一处编译错误——`UpdateIPADownloader.swift:544` 的 `await session.getAllTasks()` 报 `missing argument for parameter 'completionHandler'`，545 行连带类型推断超时；build-package 的守卫断言与变异本轮全过，倒在编译步（exit 65），不是守卫。
- **根因**：第 1 项新代码误以为 `URLSession.getAllTasks()` 有 async 重载；当前 SDK（Xcode 26.5）只有 completionHandler 形态。首轮 CI 里该文件先倒在静态 handler 的并发声明、build-package 先倒在守卫变异，这处错误被两层遮蔽，直到本轮才暴露——「守卫 PASS ≠ 能编译」（AGENTS.md §5）的又一实例。全仓 grep 确认 `getAllTasks` 仅此一处使用，其余 `await session.*` 均为 `data(for:)` 真 async API，无同族漏网。
- **修复**：改用 `withCheckedContinuation` 包 completionHandler 形态，返回值显式标注 `[URLSessionTask]`（同时消除 545 行的推断爆炸）；与同文件 `adoptExistingTasks()` 的 completion 形态一致；未新增并发盒。
- **涉及文件**：`Seal/Infrastructure/UpdateIPADownloader.swift`、本条（另顺带回填 0.1.51 第三轮条目的 run 号）。
- **验证状态**：待本地全量守卫复跑与 CI 第三轮复跑后补记。

# 2026-10-23 — 0.1.52 首轮 CI 两红：静态 handler 并发声明＋三处守卫变异失效（CI 修复轮）

- **现象**：提交 ce5575a 的完整 CI（run 39808799088）：signer-tests ✓；swift-regression ✗（编译错误 1 处）；build-package ✗（守卫变异自检失败 3 条）。
- **根因**：① `UpdateDownloadSessionController.backgroundCompletionHandler` 是可变静态变量，Swift 6 完整并发档下裸 `static var` 直接判不安全——实现本体有静态锁保护、类注释也写了依据，但声明没按仓内既有形态标注。② 三条变异问题同属「锚点/判据没跟上本批代码形态」：证书页变异锚点仍写旧的 `account.certificateSerialNumber ?? ""` 取源（第 5 项已改走 `effectiveSerial`）；R134① 变异锚点仍是不带 alert 的旧 update 形态（第 3 项 R137 已给终态 update 加 `alertConfiguration`）；R125 判据对 KeychainVault 整文件 `in` 查 `kSecMatchLimitAll`，第 7 项新增的 `allKeyedSecrets()` 带来第二处同字面量，变异改掉 `loadAllSecrets` 那处后整文件仍命中 ⇒ 漏网（R71③ 同族重复字面量陷阱）。
- **修复**：① 声明改 `nonisolated(unsafe) private static var` 并补理由注释（读写只在 backgroundHandlerLock 临界区内，锁即依据）。② 两处变异锚点迁移到现行代码原文，不变量不变，并给 R134① 锚点留迁移注记。③ R125 判据改按 `loadAllSecrets` 函数段（section 起止标记）钉 `kSecMatchLimitAll`，加注释记明同族陷阱。
- **涉及文件**：`Seal/Infrastructure/UpdateIPADownloader.swift`、`Scripts/verify-release-safety.py`、本条。
- **验证状态**：本地全量守卫复跑（工作目录写死为本批工作树）：892 项断言＋651 条变异全部 PASS；靶向复核另含 651 锚点全在位、受牵连 26 条变异全被抓。待 CI 第二轮复跑。

# 2026-10-22 — 日志页工具栏邮件按钮图标与另两钮不对齐（0.1.52）

- **现象**：日志页工具栏三个按钮（删除 trash、导出 square.and.arrow.up、邮件 envelope）同为 16 号字，但 envelope 天生宽扁（约 21×12），与另两个近方形符号（约 14×17）高度明显不对齐。
- **根因**：符号本身宽高比差异，非字号/frame 问题——三钮字号 16、36×36 frame 一致，只有 envelope 的字形轮廓矮。
- **修复**：`LogViewerView.swift:75` 邮件按钮 SF 符号 `envelope` → `paperplane`（近方形约 17×17，同字号直接对齐）；字号、accentColor、36×36 frame、accessibilityLabel「邮件发送日志」、emailLogs 动作全部未动，仅此一处字符串。
- **涉及文件**：`Seal/Features/Settings/LogViewerView.swift`。
- **验证状态**：守卫无钉住该符号的断言（已 grep 确认）；真机目测三钮高度对齐即可。

# 2026-10-22 — 更新下载改造：后台会话＋断点续传＋进度节流＋SHA256 校验下沉（0.1.52 第 1 项）

- **现象**：更新 IPA 下载走前台 URLSession，切后台/进程被挂起即断；失败一律删档重来，弱网大包（27MB+）体验差；进度回调每块数据起一个无结构 Task 洪泛 UI；SHA256 校验只在 View 层、下载器本身不设防。
- **根因**：`UpdateIPADownloader` 用 `URLSessionConfiguration.default` + async `download(for:delegate:)`（前台模型，无 resumeData 概念），错误分支统一删文件；旧 `ProgressDownloadDelegate.didWriteData` 无节流；校验逻辑放错层（View 抓校验文件，下载器调用方若换人即裸奔）。
- **修复**：改为单例后台会话控制器（identifier `eu.seal.update-ipa-download`，永不 invalidate；进程被杀后凭 pending 记录接管在途任务/找回已完成文件；AppDelegate 转发点经 `SealAppDelegate` 接线 `handleEventsForBackgroundURLSession`），delegate 事件经既有 `ContinuationBox` 桥回 async（未新增并发盒）；resumeData 按源 URL 摘要持久化、失败/取消（含切网络）优先续传、续传失效自动回退全新一次，判据抽纯函数 `UpdateDownloadResumePolicy`；进度经 `UpdateDownloadProgressPolicy`（150ms/256KB）+ NSLock 持有者节流合并、终态必达；SHA256 校验下沉进下载器，落盘后流式校验（复用 `AppFileStore.streamingSHA256` 与 `UpdateChecker` 解析/比对），不符删文件抛 ImportFailure `SEAL-UPDATE-DL-506`（顺延 501–505），View 只保留版本交叉校验与 nil 资产 fail closed。
- **涉及文件**：`Seal/Infrastructure/UpdateIPADownloader.swift`、`Seal/Features/UpdateNoticeView.swift`、`Seal/App/SealApp.swift`、新增 `SealTests/Update/UpdateDownloadPolicyTests.swift`（14 条）、`Scripts/verify-release-safety.py`（R138；R107②/R122 钉子随形态迁移）。
- **验证状态**：本地守卫 892 项断言 0 失败（含 R138 与 R107②/R122 新锚点变异自检）；Swift 编译与单测待 CI；真机待验：下载中切后台/锁屏后续传完成、飞行模式切换后续传、故意损坏 IPA 时 506 拦截不进安装。另：AGENTS.md 第 6 节「更新链路只校验 tag 与版本串」已与代码不符，本批同步修订。

# 2026-10-22 — 更新连点 3 次 0 秒 SEAL-SIGN-404：入口无就绪门＋待更新记录被自注册误删（0.1.52 第 2 项）

- **现象**：更新导入完成后在更新抽屉点「签名并更新」连败 3 次、每次 0 秒、均为 SEAL-SIGN-404（log-46，2026-10-22 19:16:08–09 三条轮次总结），随后一次成功。
- **根因**：两段叠加。① 入口无就绪门：`signAndInstall` 只查一次记录即终态抛错，且单签/批量两条外层重试都不认 404。② 待更新记录可被 `SelfAppRegistrar.cleanupDuplicateSealRecords` 误删：2026-10-09 重设计后待更新记录是独立新记录（新 UUID、`replacesInstalledAppID` 指向已安装记录、只带指纹），而自注册的待更新保护仍判已安装记录的 `hasPendingSelfUpdateSource`（恒 false），版本一致分支随即把待更新记录当「重复 Seal」连文件删除；该清理每次回前台都会跑，且删除决定用的是函数开头快照。记录被删后签名抽屉靠旧快照回落继续放行点击。本次具体哪次自注册触发删除，现存日志因环形缓冲淘汰 OP 明细无法证明（证据缺口如实记录）。
- **修复**：① `SigningCoordinator` 新增纯函数 `SignRecordReadinessPolicy`（最多 4 次查询、退避 250/500/1000ms、最坏 1.75s、仅查不到时付出，首命中零新增等待）＋ `fetchRecordForSigning` 就绪门，终态仍抛原 404 并新增「应用记录缺失诊断」日志（appID 前缀＋现存 Seal 记录清单）；平行入口 `installSignedArtifact`（SEAL-INSTALL-719）一并接入、诊断码参数化不串码。② 根因侧：新增同源纯判据 `SelfAppPendingUpdateProtection`（`isSeal && replacesInstalledAppID != nil`；指纹刻意不设必要条件——同指纹导入会把指纹置 nil 而链接仍在），重复清理豁免待更新记录连同文件、删除决定改按执行时刻重取的现行记录（重取失败整轮不删）；保护分支旧标志原样保留＋其后加现行模型分支，两记录并存时只回补已安装快照、绝不覆盖/代结算待更新源。③ `AppSigningSheet` 加 `isWorkingRecordMissing`：记录消失即关抽屉、点击瞬间再校验、主按钮同步禁用。
- **涉及文件**：`Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Core/Renewal/SelfAppIdentity.swift`、`Seal/Core/Renewal/SelfAppRegistrar.swift`、`Seal/Features/Apps/AppSigningSheet.swift`、新增 `SealTests/Signing/Sign404RecordReadinessPolicyTests.swift`（6 条）与 `SealTests/Renewal/SelfAppRegistrarPendingUpdateProtectionTests.swift`（4 条）、`Scripts/verify-release-safety.py`（R139/R140）、`docs/qa/log-code-index.md`（补登 SEAL-SIGN-404/SEAL-INSTALL-719）。
- **验证状态**：本地守卫 892 项 0 失败；待 CI swift-regression 与真机回归（导入后切后台回前台再点签名并更新，应不再 0 秒 404；抽屉外删掉待更新记录，抽屉应自动关闭）。

# 2026-10-22 — 冷启动点续签通知无结果抽屉＋列表点不动；抽屉交接改呈现仲裁（0.1.52 第 4＋9 项）

- **现象**：log-47 冷启动轮：快捷指令续签在后台完成并持久化结果（RENEW-023），点通知进 App 后没有结果抽屉，已安装列表点任何 App 都没反应；暖启动轮（20:42）则正常。同轮日志里 RENEW-024（恢复消费）与 023 同一秒出现在后台进程内。
- **根因**：① 结果恢复无呈现授权判据：`AppsViewModel.load()` 无条件 `restorePendingBatchResultIfNeeded()`，且批量收尾在发完成通知前就把 `isBackgroundBatchRefresh` 复位，后台进程内任何一次 `load()` 都会把刚持久化的结果当场恢复消费，前台再无可弹之物。② 假呈现锁死列表：恢复后呈现标志被误报为「已呈现」，`openApp` 被 ready 载荷优先逻辑吞掉、操作抽屉绑定又被假状态锁住，而载荷只在结果抽屉真正关闭时才清——抽屉从未真弹 ⇒ 永久点不动（与同秒的 SEAL-INSTALL-707 无关，707 只是设备清单不可用警告）。③ 抽屉交接本无仲裁：跨流程交接靠 250ms 硬等＋onChange 强清＋绑定门禁三层补丁。
- **修复**：新增纯状态机 `SheetArbiter`（同一时刻只许一张在场，交接＝请求→关当前→关闭完成事件→开下一张）与 `BatchResultRestorePolicy` 路由：后台进程只登记「待呈现」（新标志 `hasPendingBatchResultAwaitingPresentation`、不写 024、不清载荷），呈现必须经呈现层 flush 的一次性授权令牌；删除 250ms 硬等与两处强清补丁；批量结果撞操作抽屉只排队不关结果（新操作无权替用户消费未看过的结果）；返回值改诚实三连判。结算语义与 R12/R17 锚点逐字未动。视觉零改动（只改绑定来源/时机，detents/字号/颜色/文案未动）。
- **涉及文件**：新增 `Seal/Core/Renewal/SheetArbitration.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Apps/AppsRootView.swift`、新增 `SealTests/Renewal/SheetArbitrationTests.swift` 与 `BatchResultPresentationDecouplingTests.swift`、`Scripts/verify-release-safety.py`（R141）。
- **验证状态**：本地守卫 892 项 0 失败；待 CI 与真机回归（冷启动点续签通知应弹结果抽屉；结果待呈现时列表可正常点开操作抽屉）。关联发现（未改，列报告待拍板）：更新抽屉与应用页抽屉不在同一仲裁域；`AppSigningSheet`/`ImportConfirmationView` 各有一份 220ms 硬等平行实现；RootTabView 有根层版强清外观抽屉。

# 2026-10-22 — 签名证书页「已安装应用」恒空/整区不渲染＋详情页悬空判据（0.1.52 第 5 项）

- **现象**：签名证书页「本机已安装 App」区域恒显「暂无」或整区不出现；Apple ID 删除确认的关联应用计数在删号重加后算成 0（任务书指名的 CertificatesRootView 只有转发，区域本体在 SigningCertificateSettingsView）。
- **根因**：三层叠加。① 区域级遮蔽：本地扫描非 nil（真机常态）时只显示 `locallyVisibleApps`，已算好的记录口径列表（certificateApps/installedApps）被整体丢弃，严判据（序列号归一匹配＋belongsInInstalledList＋设备清单/同团队兜底）任一不成立即恒空。② 序列号取错源：区域与硬门只认 `certificateSerialNumber`，健康口径是 `selected ?? certificate ?? secret`，切证书只写 selected，区域拿旧/空序列号比对（空串归一为 "0" 恒不命中）。③ 同族裸判据：CertificatesRootView 删除计数与 AppleAccountDetailView 四处裸比 `accountID`，命中悬空 UUID 陷阱（删号保留绑定、重加换新 UUID ⇒ 恒不命中）。当次实际触发点日志无记录，需真机三场景回归区分（从未切证书/切过证书/删号重加）。
- **修复**：新增纯函数 `CertificateInstalledAppsPolicy`（三级取源逐级跳空白＋组合判定四态），区域七处判据统一走 `effectiveCertificateSerialNumber`、硬门同步；本地分支为空时先回落 installedApps、再回落 certificateApps，全空才「暂无」；`nonLocalCertificates` 追加 effective 归一化排除。裸判据改走 `AppleAccountAppNamePolicy.isAccountMatch`（绑定仍在只认 UUID；悬空/未绑定按签名 Team 分流，与 validateAccountAndTeam 同口径）；SettingsViewModel 撤销清理的 `isLocalCertificate` 调用点同步喂三级取源副本。页面视觉零改动（文案/字号/颜色/结构逐字未动；回落时标题保持原样未改「签名记录」，待裁决）。
- **涉及文件**：`Seal/Features/Settings/SigningCertificateSettingsView.swift`、`Seal/Features/Settings/AppleAccountDetailView.swift`、`Seal/Features/Settings/CertificatesRootView.swift`、`Seal/Features/Settings/SettingsViewModel.swift`（仅 isLocalCertificate 取源一处）、新增 `SealTests/Settings/CertificateInstalledAppsPolicyTests.swift` 等 24 条、`Scripts/verify-release-safety.py`（R142）。
- **验证状态**：本地守卫 892 项 0 失败；待 CI 与真机三场景回归。

# 2026-10-22 — anisette 全灭被误报为 Apple 服务失败：SEAL-NET-102 → SEAL-ANI-116（0.1.52 第 6 项）

- **现象**：log-46 20:06:48 续签失败，17 台 anisette 候选全部 URLError(-1004)（本机网络不可达），用户侧却报 SEAL-NET-102「与 Apple 开发者服务的请求没有完成」，归因指错方向。
- **根因**：`AnisetteClient.fetchRemote/resync` 全灭终局抛裸 URLError、无 anisette 来源标记（AnisetteV3Error 只承载 provisioning 语义）；FailureClassifier 与各入口的失败工厂都只有一条 isNetworkError 判据，裸 -1004 必然被吞成 NET-101/102。
- **修复**：全灭终局且末错为网络错误时才打标记 `AnisetteAllServersNetworkFailure`（单台失败仍内部换台、非网络终局原样上抛）；`AppleServiceFailurePolicy` 新增纯函数 `transportAttribution(for:)`（先判标记含 underlying 递归、再判 isNetworkError）与新码 **SEAL-ANI-116**（ANI 家族顺延、error_catalog 复跑确认唯一；title「暂时连不上网络」、reason 只讲服务全连不上/当前网络暂时不可用、recovery「检查网络连接后稍后重试」，全文不提 Apple 服务）；全部归类入口前置 anisette 分支（FailureClassifier、ApplePortalSigningService.make、AppleAccountClient 三处、SettingsViewModel 兜底一处，下标顺序由 R143② 钉住），裸网络错误仍保留 NET-102 原文案。
- **涉及文件**：`Seal/Infrastructure/Accounts/AnisetteClient.swift`、`Seal/Core/Accounts/AppleServiceFailurePolicy.swift`、`Seal/Core/Import/FailureClassifier.swift`、`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、`Seal/Infrastructure/Accounts/AppleAccountClient.swift`、`Seal/Features/Settings/SettingsViewModel.swift`（仅兜底一处）、新增 `SealTests/Accounts/AnisetteFailureAttributionTests.swift`（7 条）、`ApplePortalSigningAnisetteAttributionTests.swift`、`AppleAccountClientAnisetteAttributionTests.swift`（6 条）、`Scripts/verify-release-safety.py`（R143）、`docs/qa/log-code-index.md` 与错误码清单（新码入册）。
- **验证状态**：本地守卫 892 项 0 失败；待 CI 与真机断网回归（飞行模式下续签应报「暂时连不上网络」而非 Apple 服务失败）。

# 2026-10-22 — Apple ID 凭据会丢：UUID 键悬空＋删记录真删＋100b 错误级刷屏（0.1.52 第 7 项）

- **现象**：log-46 一天内 SEAL-INVENTORY-100b 出现 20 次且成对刷屏；凭据在记录重建/删号重加后丢失，用户被反复要求重新登录。
- **根因**：secret 以随机 UUID（记录 id）为钥匙串查找键，记录重建/迁移即悬空；删记录连带真删 secret；缺失以错误级 INVENTORY-100/100a/100b 三码在三处库存同步抛出，无自愈、无节流。
- **修复**：查找键改登录 ID 归一化（新类型 AccountIdentity：邮箱 trim+小写、手机号去空格/横线并 +86 归一；dsid/accountIdentifier 仍保留在内容里）；Keychain 主存＋Application Support AES-GCM 加密保险库双写（口令经 HKDF 派生），load miss 时保险库回填自愈（`loadAllSecrets` 同步签名与原实现逐字保留以守 R125，合并版另设 `loadAllSecretsIncludingVault()`，消费方切换列待拍板）；保险库可导出/导入（口令加密文件、无 iCloud）；永不自动删——删记录与保存回滚改 detach，缺失标「待恢复」（页面级提示＋每账号每进程一条信息级日志，新码 SEAL-KEYCHAIN-005），INVENTORY-100/100a/100b 删除；写后回读验证（失败 SEAL-KEYCHAIN-004），保险库导出/导入失败 SEAL-KEYCHAIN-006；存量 secret 按旧 UUID 键扫描迁移（Team 校验、旧项保留）；重加同号按登录 ID 接回旧 secret 与证书材料。
- **涉及文件**：`Seal/Infrastructure/Security/KeychainVault.swift`、新增 `Seal/Infrastructure/Security/CredentialVault.swift`、`Seal/Core/Accounts/AccountSecret.swift`、新增 `Seal/Core/Accounts/CredentialRecoveryPolicy.swift`、`Seal/Features/Settings/SettingsViewModel.swift`（三处库存段落＋接回/detach）、新增 CredentialVault 相关单测 16 条、`Scripts/verify-release-safety.py`（R144；R67/R68 注释同步 0.1.52 口径）、`docs/qa/log-code-index.md`（三码移入「已从源码移除」、新码入册）与错误码清单再生成。
- **验证状态**：本地守卫 892 项 0 失败（R125 已回绿）；待 CI 与真机回归（删号重加同号应接回凭据不重登；杀进程重开库存同步不再刷 100b）。待拍板：保险库口令 UI 形态、R125 两消费方是否切合并版、HKDF→PBKDF2 强度升级。

# 2026-10-22 — 日志同内容同秒刷屏＋环形 1000 条一天丢 7066 条（0.1.52 第 8 项）

- **现象**：log-46/47 头部自述一天丢弃 7066 条；样本里证书解析三件套同秒重复 3 遍、SELF-113 同结算 2 次、anisette 成功类 2 遍、100b 成对。盘点显示高条数主要来自「单点转发、全量放大」入口（AltSign relay 占 63.6%/89.7%、anisette trace 23.7%/4.4%），逐个压产生点压不住。
- **根因**：`SealLogStore.append` 无条件入队、无合并；环形上限 1000 对全量转发量级太小，签名全程的关键过程留不住。
- **修复**：存储层按脱敏后 `(category, level, code, message)` 原值同键在 120 秒窗口内合并计数（导出呈现 ×N 后缀；零归一化——不 trim/不折行/不剥数字，宁可不合不可误合）；逐项结果类（带 operationResult/operationSummary）永不合并，由 `LogDedupPolicy` 纯函数判据＋单测钉住；容量 1000→3000（常量 `defaultMaximumEntries`，导出头部文案自动同步）；重脱敏路径保留 repeatCount 防 ×N 丢失。本项未新增日志码。
- **涉及文件**：`Seal/Infrastructure/Diagnostics/SealLogStore.swift`、`Seal/Core/Diagnostics/SealLogEntry.swift`、新增 LogDedup 单测、`Scripts/verify-release-safety.py`（R145）、`AGENTS.md` 与 `docs/qa/logging-standard.md`、`docs/qa/device-regression-checklist.md`（容量口径同步 3000）。
- **验证状态**：本地守卫 892 项 0 失败；待 CI 与真机回归（重复操作后导出日志应见 ×N 合并、头部条数 3000）。新发现（未改）：日志页列表不显示 ×N 与导出不一致（UI 项待拍板）；Minimuxer 每条日志强制全量 flush、容量 ×3 后落盘成本放大；entries() 全量重脱敏在 30+ 调用点重复跑。

# 2026-10-22 — 灵动岛配对三态：码出现不弹展开、输码途中会被本地计时器收掉（0.1.52）

- **现象**：MJ 反馈（pending 第 1 条）：配对码出现后灵动岛不是持久展开，要手动点开岛、再点按才能跳回 Seal；配对完成也要手动展开才看得到。
- **根因**：不在渲染、在呈现机制。① `PairingLiveActivityController.showCode` 用的是**静默 `update`**（无 `AlertConfiguration`）——用户此刻在系统设置页，静默更新只换紧凑态内容，系统不会主动把展开态弹出来；② code 阶段同时设了 `staleDate = now + 180s` 并 `scheduleDismiss` 排了本地到期收尾，输码窗口一长（或叠加 preparing 阶段 210 秒到期）活动会被本地计时器 `finish()` 收掉；③ paired 终态的 `update` 同样不带 alert，展开呈现没有保证（R134 只解决了「后台提交时机」）。系统边界：App 不能强制灵动岛常开，能做的是在码到达与配对成功两个时点用带 `AlertConfiguration` 的 update 让系统主动弹出展开态。
- **修复**：`showCode` 改带 `AlertConfiguration`（title「Seal 配对码」、body 带六码）的 update、`staleDate: nil`、摘掉 code 阶段的 dismiss 计时与 `expiresAt`（删除 `codeLifetime` 常量）——活动活到配对出结果为止（成功 `markPaired`／失败 `markFailed`／配对会话自身 180 秒超时走失败终局，不会无限残留），preparing 阶段行为不动。`endWithResult` 加 `alertConfiguration` 参数（默认 nil），仅 `markPaired` 传 `pairedAlertConfiguration`（body「配对成功，点击返回 Seal」），失败态不传、呈现行为原样；终态「先 update 送达、再 end + .after(30s)」的既有顺序保留。Widget 仅 `statusText` 的 paired 文案「配对完成」→「配对成功」一处字符串，视图结构/字号/颜色一行未动；paired 的 detail 本就是「点击返回 Seal」、整岛 `widgetURL` 本就指向 `PairingDeepLink`，均核实未改。
- **涉及文件**：`Seal/Infrastructure/Pairing/PairingLiveActivityController.swift`、`SealLiveActivity/PairingLiveActivityWidget.swift`、`Scripts/verify-release-safety.py`（R134① 钉子字符串随 update 调用形态更新；新增 R137①② 与 3 条变异）、`project.yml`（MARKETING_VERSION 0.1.51→0.1.52，主 App 与 LiveActivity 扩展同步）、`RELEASE_NOTES.md`、`DEBUG_LOG.md`。
- **验证状态**：本地守卫断言（pre-push-check 口径、指向本工作副本）结果见本批实现报告；Swift 编译待 CI。真机回归点：开始配对后切到设置页等码，码到时岛应自动弹出展开；输码停留超过 3 分钟岛不得消失；配对成功后岛应弹出展开显示「配对成功 · 点击返回 Seal」，点岛回 Seal；失败态呈现与旧版一致。

# 2026-10-22 — 0.1.51 第三轮 CI 两红：错误码清单行号未随存活判定同步 + 两条超时单测与 CI 调度赛跑

- **现象**：`edb2142` 的完整 CI（run 39755876377）：signer-tests 绿；build-package 倒在「Audit source error identifiers」步——清单再生成后 `git diff --exit-code` 非空（135 处）；swift-regression 倒在测试步——`DeviceProfileCleanerTests` 两条 `timedOutNativeProfileCall*` 各报 3 个 issue，其余 1072 条测试全过、UI 测试全过。
- **根因**：① 存活判定逐条判定（`800fa1b`）给 `AppsViewModel.swift` 净增 15 行，该文件内全部错误码位置整体下移 +15；`docs/qa/generated/error-code-inventory.json` 是生成物，本批改源码时漏了再生成，审计步（再生成 + diff 核对）必然报红。上一批（`a289b76`）有同步生成、本批漏了。② 两条单测用「预算 0.01 秒 vs `Thread.sleep(0.15)`」的墙钟赛跑断言超时语义，只留 140 毫秒绝对余量；`HardTimeout` 的定时器是 `.utility` 优先级的 detached 任务，CI runner 高负载下被饿死超过 140 毫秒 ⇒ 工作先返回、结果成 `.completed`，闸门/租约按「已完成」正常放行，断言全灭。生产代码（`DeviceProfileCleaner`/`HardTimeout`/`OperationCoordinator`/闸门）自上一轮全绿（`f39fff7`）后未动过——是测试在赌调度精度，不是生产回归。
- **修复**：① 用 `Scripts/error_code_inventory.py` 再生成清单：本地逐行核对恰 135 行变化、全部为 `AppsViewModel.swift` 的 `"line": +15`、零其他变化，与 CI 日志里的 diff 吻合；生成器幂等。② 两条单测改用 `NativeCallLatch`（`NSCondition` 门闩）：门闩打开前工作不可能返回，超时结论与调度速度无关；放行后的闸门重开改为轮询等待（上限约 10 秒），租约等待上限 2 秒 → 10 秒。断言守的契约不变（FFI 未返回前闸门/设备租约保持占用、返回后由迟到完成回调放行）；生产代码一行未动。
- **涉及文件**：`SealTests/Installation/DeviceProfileCleanerTests.swift`、`docs/qa/generated/error-code-inventory.json`、`DEBUG_LOG.md`。
- **验证状态**：本地审计链全过（审计单测 20 项 + `error_catalog validate` 15 条 + help-index 再生成无变化 + 清单再生成幂等）；守卫本地复跑 870 项断言 + 638 项变异全过（0 失败）；Swift 编译与单测待 CI 复跑（run 待填）。**回填（2026-10-23）**：最终提交 8e64fe1 的完整 CI run 39764284510 三 job 全绿，产物 build 143，Release v0.1.51 已发布。

# 2026-10-22 — 合并推送首轮 CI 两处红：缓存单测漏改 .value + 标记函数局部量与 R71③ 守卫重名

- **现象**：合并提交 `800fa1b` 的完整 CI（run 39752263845）两 job 红：swift-regression 编译失败（`SealTests/Signing/PortalReadCacheTests.swift:87`：`LegacyBox<[ALTTeam]>` 没有 `first`）；build-package 的守卫变异检查报 R71③ 未被抓（「Guard failed mutation check: R71③」）。
- **根因**：① LegacyBox 修复只改了三个服务调用点，漏了 0.1.51 同批新增的缓存单测调用点——守卫是纯文本断言、不编译测试 target，只有 swift-regression 能暴露（AGENTS.md §5 的老教训：守卫全绿 ≠ 能编译）。② 存活判定条目里 `reconcileInstalledAppsFromMarkers` 的局部量沿用了 `missingOnDevice` 命名；R71③ 的断言是文件级字面匹配（靠 `missingOnDevice.append(app)` 是否还在判定「先问完再动手」有没有被变异破坏），标记函数里的同名 append 把设备核验函数里被变异删掉的那处遮蔽了，变异检测静默失效。
- **修复**：单测改取 `fresh?.value.first`；标记函数局部量改名 `markerMissingApps`，并在代码处写明禁与设备核验函数重名的注释；R136① 断言补入单测调用点字面与对应变异（③），以后这类漏改在守卫层就能报红。
- **涉及文件**：`Seal/Features/Apps/AppsViewModel.swift`、`SealTests/Signing/PortalReadCacheTests.swift`、`Scripts/verify-release-safety.py`（R136① 扩展 + 变异③）、`DEBUG_LOG.md`。
- **验证状态**：本地断言 870 项 0 失败；R71③、R135（2 条）、R136（3 条）变异逐条抽查均被抓（各恰 1 条失败）；Swift 编译待 CI 复跑——run 39755876377 已证：单测编译通过（`.value` 修复生效、测试实际跑完）、build-package 守卫步通过；该 run 的两处新红（清单行号未同步、计时单测赛跑）见上一条。

# 2026-10-22 — 已安装列表标记回退全有全无：快照不可用 + 混批记录时本机一条都判定不了

- **现象**：`refreshInstalledApps` 的本机判定链为「LaunchServices 快照 →（快照不可用时）标记回退」。标记回退 `reconcileInstalledAppsFromMarkers` 原是全有全无：整批记录只要混进一条没有当前版标记（v2）的记录（旧版 Seal 装的、其他工具签后找回的），整批都不用标记判定、直接返回未完成。于是快照不可用 + 混批记录时，本机流程一条都判不了，只能等设备隧道核验；隧道不通（没开 WiFi/LocalDevVPN）时，已在外部卸载的 App 会一直留在已安装列表里。
- **根因**：旧版 Seal 用全 App 共用一个 UTI、其他工具签的 App 没有 Seal 标记，所以「整批都带 v2 标记」曾被当作使用标记判定的前提；但 v2 标记是逐 App 注入的，这个前提对单条记录并不成立——全有全无把单条证据的可用性错误地绑成了整批属性。
- **修复**：`reconcileInstalledAppsFromMarkers` 改为逐条判定：带 v2 标记的记录各自查 `SealInstalledAppMarker.isDeclared`，标记已不被声明即单独标缺失；无 v2 标记的记录不参与本段，计入未判定数，返回 `isComplete == (undecidedCount == 0)`，未判定记录留给既有设备核验兜底。快照仍是第一权威、入口仍只有 `refreshInstalledApps` 一条流程，不新建平行判定路径；设备会话冲突时仍整段不落判定（与旧语义一致）。同批核查：`ProfileValidated` 信号已在记录恢复的信任门（`InstalledRecordRecoveryPolicy`）中使用，展示层没有同时列侧载与 App Store 应用的位置，本次不硬加展示分组。
- **上游对照**：标记机制本身即 SideStore 式 per-App UTI（其 `io.sidestore.Installed.*` 对应 Seal 的 `com.mjorb.seal.installed.*`）；SideStore 只用它维护自家数据库，Seal 用作认领后记录的存活证据之一，编排为 Seal 自有。
- **涉及文件**：`Seal/Features/Apps/AppsViewModel.swift`、`Scripts/verify-release-safety.py`（新增 R135① 与 2 条变异）、`RELEASE_NOTES.md`、`DEBUG_LOG.md`。
- **验证状态**：本地守卫断言 870 项 0 失败（与同批 R136 合计）；R135 两条变异内存抽查均被抓（各恰 1 条失败）；`git diff --check` 通过。Swift 编译待 CI；真机回归点：混批记录下断开设备隧道、外部卸载一个带 v2 标记的 App，打开已安装列表应能将其标为已卸载，其余记录不受影响。**推送**：2026-10-22 MJ 指示与 0.1.51 的 CI 编译修复（`d3234eb`）放一起推、同一轮 CI 一并验证；修复专用的旧 CI run 由 workflow 并发组（cancel-in-progress）在新推送时自动取消。

# 2026-10-22 — 灵动岛配对完成仍看不到（终态提交时机与 App 前后台错位）

- **现象**：今早 5694084 修过一轮（完成态随 end 一并提交 + .after 收起、保留 15 秒），build 138 真机配对成功后，MJ 仍反馈灵动岛没有「配对完成」的显示（2026-10-22 16:04 报，16:11 拍板修并并入本批）。
- **根因**：不在渲染、而在时机。用户在系统设置里完成配对时 Seal 在后台，`PhonePairingHost` 无后台执行窗口（无 `beginBackgroundTask`），`.completed` 之后的「导入凭证 → `markPaired` 提交完成态」要等用户切回 Seal 才真正执行；那时 App 已回前台，ActivityKit 对前台应用的活动更新不做灵动岛展开呈现，只剩紧凑区一个小绿勾，且 15 秒后按 `.after` 收起，用户感知等于没显示。能否看到取决于导入与用户切回的赛跑，结果不稳定。另外旧代码终态只靠 `end` 的附带内容、没有先经一次正式 `update` 送达；成功路径也无日志，事后无法定案提交没提交、何时提交。
- **修复**：① `handlePhonePairingEvent` 的完成/失败两个入口先申请 `beginBackgroundTask("Seal Pairing Completion")`，让导入与终态提交在后台执行时间里做完（用户还在设置页时岛就展开）；`finishPhonePairing` 在 `markPairingPaired`/`markPairingFailed` 后 `await pairingLiveActivity.awaitPendingOperation()`，确认提交已交给系统才返回、调用方才结束后台任务。② 控制器 `endWithResult` 改为先 `update(content)` 正式送达终态、再 `end(content, .after)` 收起；完成态保留 15 秒 → 30 秒。③ 终态提交完成后经 `logStore` 写一条日志（「已向灵动岛提交「配对完成」状态」/失败同理），下次可直接定案。
- **上游对照**：SideStore 的配对走外置 LocalDevVPN、无自有配对 Live Activity，**无对应实现可跟**，属 Seal 自有呈现链路修复。
- **涉及文件**：`Seal/Infrastructure/Pairing/PairingLiveActivityController.swift`、`Seal/Features/Settings/SettingsViewModel.swift`、`Scripts/verify-release-safety.py`（新增 R134 与 4 条变异）、`RELEASE_NOTES.md`、`docs/qa/generated/error-code-inventory.json`（生成器再生成）、`DEBUG_LOG.md`。
- **验证状态**：本地守卫断言与 R134 变异抽查结果见本批推送记录；Swift 编译待 CI；真机回归点：系统设置内完成配对后不切回 Seal，灵动岛应展开显示「配对完成」约 30 秒。

# 2026-10-22 — 门户 listTeams 一轮重复发 2–4 次；签名中途弹 2FA 码已作废且验证后不续跑

- **现象**：① 真机日志（Seal-log-43/45，构建 138）里一次单 App 签名/续签要发 2–4 次 `listTeams`，每次往返 10–21 秒：会话验证 1 次、签名主流程冷拉 1 次，涉及证书决策时证书/库存服务再各拉 1 次。② 签名中途会话失效走已保存密码恢复登录时，Apple 要求双重认证并向手机推送验证码，但签名路径按纪律不能输码，用户看到「弹码了却没有入口」；点恢复去账号页重新验证成功后，原签名也不自动继续，要手动重发。
- **根因**：① Team 缓存只有 `ApplePortalSigningService` 私有一份，且 `ensureCurrentSession` 的 bypass 实时结果**不回填**（旧实现只在 `bypassCache == false` 时写缓存），主流程紧接着必然冷拉；证书（`ApplePortalCertificateService.context()`）与库存（`ApplePortalInventoryService.fetchInventoryOnce`）两个服务各自无缓存、每次现拉。② 签名恢复登录的验证码闭包写死 `{ nil }`（仓库纪律：签名页不做验证码路径），Apple 一要求 2FA 登录即中止，那条推送码是给这次已中止登录发的、随即作废；失败页恢复按钮只负责跳账号页并 dismiss 签名页，验证成功与原签名之间没有任何接线。
- **修复**：① 团队缓存抽成跨服务共享的 `PortalTeamCache`（键=账号 identifier，新鲜度/TTL 仍只有 `isPortalReadCacheFresh` 一份，5 分钟）：签名服务 `fetchTeams` 成功即回填（**含 bypass 的验证结果**，bypass 只管读不用旧缓存）；证书/库存服务取 Team 先查同一份缓存，`SigningCoordinator` 四处实例化与 `SettingsViewModel` 都把签名服务那份缓存传进去。**没省的**：会话验证的 bypass 实时请求本身（会话有效性闸门）、撤销决策的最新证书清单（仍逐次真拉，只省为拿 Team 标识的往返）。② A 方案（MJ 拍板）：输码入口仍只在账号验证页；`SEAL-AUTH-101a` 文案改清「签名中弹出的码已作废、重新登录会发新码、验证成功后签名自动继续」；失败页跳走前由 `AppsViewModel.stashInterruptedSigningForReauthentication` 存下失败会话（判据 `ImportFailure.isTwoFactorInterruption`：错误码或 `.enterNewVerificationCode` 动作，其他失败不存），`SettingsViewModel.persistAuthenticatedAccount` 落库后发 `.sealAccountReverified`（带 accountID），AppsViewModel 只在「验证的是当初签名用的那个账号、且当前没有别的签名在跑」时，用最新账号/App 记录重建会话、切回应用页自动续跑；用户手动开新签名会清掉待续存档。批量续签不走单签会话，不在此列。
- **上游对照**：AltStore/SideStore 每次操作现拉团队列表、无跨服务缓存，2FA 中断后亦无自动续跑——**不跟（上游没有）**，属 Seal 自研的流程编排；会话恢复与 2FA 纪律仍沿 2026-10-20 台账条（不自动提交 2FA、验证码只在账号表单输）。结论已同步 `docs/upstream-alignment.md`。
- **涉及文件**：新增 `Seal/Infrastructure/Signing/PortalTeamCache.swift`、`SealTests/Signing/SigningReauthenticationResumeTests.swift`；改 `Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、`ApplePortalCertificateService.swift`、`ApplePortalInventoryService.swift`、`Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Core/Signing/SigningSession.swift`、`Seal/Infrastructure/Accounts/AppleAuthenticationDiagnosis.swift`、`Seal/Features/Apps/{AppsViewModel,SigningProgressView}.swift`、`Seal/Features/Settings/{SettingsViewModel,LogViewerView}.swift`、`Seal/App/RootTabView.swift`、`SealTests/Signing/PortalReadCacheTests.swift`、`SealTests/Accounts/AppleAuthenticationDiagnosisTests.swift`、`Scripts/verify-release-safety.py`（R112③a 更新、新增 R112③d 与 R133 及 4 条变异）、`docs/qa/generated/error-code-inventory.json`（生成器再生成）、`docs/upstream-alignment.md`、`DEBUG_LOG.md`。
- **验证状态**：本地守卫全量（断言模式）866 项 0 失败；错误目录校验 15 条通过、help-index 无变化；`error_code_inventory` 单测 11 项通过，生成清单已同步（CI 会 `git diff --exit-code` 核对）。Swift 编译与真机回归（101a 续跑、慢网络下 listTeams 次数）待 CI/真机验证，未推送，等 MJ 看 diff 拍板。**续记（同日）**：该批已推送（提交 `a289b76`），首次完整 CI（run 39746927442）红——`PortalTeamCache.cachedTeams` 直接返回 non-Sendable 的 `[ALTTeam]?` 跨 actor 被 Swift 6 严格并发拒绝，签名/证书/库存三处调用点编译失败（swift-regression、build-package 两 job 失败、publish-release 跳过）。已按门户既有 `LegacyBox` 套路修复：缓存读出改为返回 `LegacyBox<[ALTTeam]>?`、三处调用点取 `.value`（存入方向值刚由调用方自己的 Box 产生、不受影响）；守卫新增 R136① 与 2 条变异，推送版守卫 869 项 0 失败、变异抽查均被抓。修复按「编译失败立马推」单独推送，待 CI 复跑。

# 2026-10-22 — 多个账号在换 Xcode token 步被 Apple 回 -80046（登录身份路线跟随 iLoader 改走 Mac 身份）

- **现象**：多个此前正常登录过的 Apple ID 同日突然无法在 Seal 里使用：日志（`Seal-log_45`，构建 0.1.50 (137)）显示 anisette 与 SRP 登录全程成功（ADI 复用命中、dsid 与登录 token 均已拿到），死在随后换 Xcode token 的 apptokens 步，Apple 回 `ec=-80046 / hsc=400`，弹窗原文为 "This action cannot be completed at this time"。同一批账号在 iLoader 下登录、签名均正常。
- **根因**：Seal 的登录身份策略停留在 2026-10-16 跟随当时 isideload 得出的结论：默认服务器 `ani.jkcoxson.com`（Windows 身份）、把公共服务器的 Mac 身份归一化改写为 Windows iTunes 身份串、GSA 请求的 User-Agent 写死为 Windows 时代的值。上游现已反向：isideload 删除了 `client_info_to_use` 归一化（`get_client_info` 原样采用服务器返回值），iLoader 2.4.0 把默认服务器改为 `mac-ani.jkcoxson.com`（Mac 身份）并移除 legacy Windows 服务器。Windows 身份这条线现被 Apple 在 apptokens 步拒绝——与 10-17 的 `-80045` 同族、换了关口；且 mac-ani 的 `<MacBookPro13,3>` 身份正中旧归一化名单，即便手动换服务器也会被改写回 Windows。
- **修复**：① 服务器目录：`jkcoxson-mac` 提为首选，删除 `jkcoxson`（`ani.jkcoxson.com`）与 `sidestore-win` 两台 Windows 身份服务器；已保存选择指向被删 id 时，由 `AnisetteServerStore` 新增的一次性迁移清掉，落回新默认。② `AnisetteClient.authenticationClientInfo` 删除归一化改写，服务器 `client_info` 与 `user_agent` 原样直传（UA 为空时仍用既有兜底值）。③ `ALTAnisetteData` 新增 `userAgent` 字段（NSSecureCoding 与 JSON 均向后兼容，旧数据解码为空串），在取 headers 时随 anisette 数据一并穿线；`ALTAppleAPI+Authentication` 的 SRP/complete 与 `/auth` 两处请求头改用数据自带的 UA（空串回退旧值），保证 `X-Mme-Client-Info` 与 User-Agent 是同一台「机器」的一对。
- **上游对照**：**跟** iLoader 2.4.0 / isideload 现行实现（2026-10-22 MJ 定：Seal 的登录/anisette/身份路线以后跟随 iLoader，上游变了 Seal 跟着变）；对照结论已同步写入 `docs/upstream-alignment.md` 台账。
- **涉及文件**：`Seal/Core/Accounts/AnisetteServer.swift`、`Seal/Infrastructure/Accounts/AnisetteClient.swift`、`Seal/Infrastructure/Accounts/AnisetteServerStore.swift`、`upstream/AltSign/Sources/Model/ALTAnisetteData.swift`、`upstream/AltSign/Sources/ALTAppleAPI+Authentication.swift`、`SealTests/Accounts/AnisetteV3ClientTests.swift`、`docs/upstream-alignment.md`、`DEBUG_LOG.md`。
- **验证状态**：本地 `Scripts/pre-push-check.py` 838 项断言 0 失败（本地仅作推前预检，验收以 CI 为准）；Swift 编译与真机登录回归待 CI/Fast 出包后验证。注意：存量用户换身份后 ADI 身份戳不匹配，首次登录会作废旧 ADI 重新 provisioning、可能再过一次 2FA——这是既有身份戳机制的预期行为，不是回归。

# 2026-10-22 — 添加 Apple ID 在 Anisette provisioning 阶段长时间转圈

- **现象**：最新版本添加 Apple ID 长时间显示等待，最终失败或需要用户取消。
- **日志定位**：`Seal-log(43)` 中没有出现 Anisette 就绪、SRP 登录或团队查询；每次都停在远程 Anisette provisioning。首选服务器收到 `GiveStartProvisioningData` 后，Apple provisioning 请求没有及时返回；随后多个公共服务器超时、WebSocket 返回 `Timeout` 或断连。日志里的服务器表也没有 SideStore 当前正式列表新增的 `new.ani.sidestore.io`、`win.ani.sidestore.io`、`mac-ani.jkcoxson.com` 和 `omni.ethxn.xyz`。其中返回 `<MacBookPro13,3>` 的服务未命中原身份归一化前缀。
- **根因**：构造 Apple provisioning 请求时未设置 `URLRequest.timeoutInterval`，默认请求可等待约 60 秒；所谓 120 秒回退预算只在每台服务器开始前检查，单个请求卡住期间不会生效。过期的静态服务器目录又缺少当前上游新增的候选；同时 `<MacBookPro13,3>` 没被现有公共服务器身份策略识别。
- **修复**：对 Apple provisioning HTTP 请求明确设置 20 秒超时，使失败及时返回并进入服务器回退；保留现有服务器与已保存账号/设备标识，补入 SideStore 当前正式目录新增的服务；把日志所见的 `<MacBookPro13,3>` 加入已有身份归一化规则，并移除 StikStore 的错误“Windows”标签。
- **上游对照**：跟随 SideStore 官方 `anisette-servers/servers.json`，将最新提供的新端点作为新增候选；未替换或删除用户已有服务器选择。
- **涉及文件**：`Seal/Core/Accounts/AnisetteServer.swift`、`Seal/Infrastructure/Accounts/AnisetteClient.swift`。
- **验证状态**：日志确认失败发生在 Apple 密码认证之前；已查询 SideStore 官方服务器目录，并检查 `new.ani.sidestore.io` 返回客户端身份、`win.ani.sidestore.io` 当前返回 HTTP 502（该端点保留为回退）。`git diff --check` 通过。Windows 无 Xcode；尚未进行云 CI 或真机登录回归，因此尚无实机成功证据。

# 2026-10-22 — 配对实时活动的完成态可能尚未送达就开始收起

- **现象**：手机配对码在系统设置中确认完成后，灵动岛没有显示“配对完成”。
- **根因**：完成态更新排在正在执行的配对码更新后面，但本地 6 秒倒计时从排队时就开始；更新延迟时，完成态可见时间被压缩甚至错过。结束态也依赖应用进程中的计时任务收尾。
- **修复**：完成态保留时间延长到 15 秒；等待前序 ActivityKit 操作完成后，直接向系统提交最终内容和 `.after` 收起策略，再启动本地句柄清理计时。这样完成态不与 Seal 前台任务争用计时，并由 ActivityKit 按截止时间收起。
- **涉及文件**：`Seal/Infrastructure/Pairing/PairingLiveActivityController.swift`、`DEBUG_LOG.md`。
- **验证状态**：已检查状态更新与结束调用按同一 Activity 顺序串行；Windows 本机未运行 Swift 编译或 CI，灵动岛四态及完成态可见时间仍需云 CI 和真机确认。

# 2026-10-22 — 批量续签挡住独立操作，设备恢复资料没有写入数据库

- **现象**：批量续签期间，其他 App 的签名/续签入口被界面状态整体挡住；Seal 重装后扫描找回的侧载 App 资料不完整，IPA 状态与续签信息重启后丢失。
- **根因**：批量任务状态被当成全局互斥；单项续签没有进入已有的应用级协调器。设备恢复记录的 `installedFingerprint`、`needsIPAImport`、`importWarnings` 只在 Swift 模型中存在，Core Data 写入与读取漏掉这些字段；恢复时还曾把 profile 授权证书误记成实际签名证书。证书页只接受带 Seal 阳性对照的完整本机快照；本机 LaunchServices 已扫到侧载 App、但完整清单校验未通过时，页面只尝试配对扫描，离线状态下不会展示已扫到的 App。
- **修复**：单项操作与批量续签可同时运行；用已有协调器只串行同一 App，独立 App 并行。Core Data 补存恢复所需字段并迁移旧库；profile 授权证书继续作为 profile 身份保存，不伪装成实际签名证书；扫描恢复的 App 可保留 profile-only 续签依据，并明确缺 IPA 时需重新导入 IPA 才能完整重签。证书页直接展示本机扫描到的同团队侧载 App 与能由签名记录精确关联的 App，并读取系统图标；“同团队”和“证书记录”分开展示，不把团队关系误说成具体证书签名。
- **上游对照**：SideStore 的 `PipelineRunner` 用任务组并发运行各 App 的续签管线；Seal 对齐按 App 并行，不把批次包装成全局锁。设备原生服务只协调自身调用。
- **涉及文件**：`Seal/Application/OperationCoordinator.swift`、`Seal/Core/Renewal/RenewalCoordinator.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Core/Apps/AppRecord.swift`、`Seal/Core/Recovery/AppRecordRecovery.swift`、`Seal/Core/Recovery/InstalledRecordRecoveryPolicy.swift`、`Seal/Infrastructure/Persistence/CoreDataAppStore.swift`、`Seal/Infrastructure/Persistence/CoreDataModel.swift`、`Seal/Features/Settings/SigningCertificateSettingsView.swift`、`Seal/Core/Signing/CertificateRevocationImpact.swift` 及对应测试、源码守卫。
- **验证状态**：CI `39683610145` 后，`39690032492` 的签名器测试通过；Swift 回归指出两个未标明账号范围的操作不能假定互不相关，已修正该分流。CI `39692756426` 的 Swift 回归与签名器测试通过，862 项源码断言通过；625 项变异自检有三个旧锚点未跟随证书页本机清单和设备写入边界，已对齐，并补强设备写入延期条件的断言。完整 CI 待再次验证；未在 Windows 本机运行 Swift 测试或源码守卫。

# 2026-10-22 — 发布守卫变异检查使用了过时的 R84⑦ 错误前缀

- **现象**：CI `39695039538` 的 Swift 回归、签名器测试和 862 项源码断言通过；两条 R84⑦ 变异检查却报告守卫失败，IPA 构建未启动。
- **根因**：R84⑦ 源码断言的错误说明已扩展为“list reconciliation may read during other work”，两条变异样本还在用旧说明作为预期前缀。变异确实触发了正确断言，但前缀对不上，守卫把它误报为变异未拦截。
- **修复**：两条变异检查统一匹配当前 R84⑦ 断言的稳定前缀；没有增加业务锁或新的操作限制。
- **涉及文件**：`Scripts/verify-release-safety.py`、`DEBUG_LOG.md`。
- **验证状态**：CI `39695039538` 中 Swift 回归与签名器测试通过，守卫因预期前缀过时失败；本修订尚待云 CI 验证。

# 2026-10-22 — 错误帮助索引未与目录源同步

- **现象**：CI `39697024070` 的 Swift 回归、签名器测试、862 项源码断言和 625 项变异检查均通过；错误帮助的 9 个测试和 15 条目录校验也通过，但构建在生成文件差异检查处停止。
- **根因**：错误目录源已更新旧版续签错误的说明，提交时遗漏了 `docs/error-catalog/generated/help-index.json` 的再生成结果。
- **修复**：用项目生成器更新帮助索引并提交；应用逻辑没有增加锁或限制。
- **涉及文件**：`docs/error-catalog/generated/help-index.json`、`DEBUG_LOG.md`。
- **验证状态**：生成结果与当前错误目录源一致；完整 CI 待重新运行，未在本机运行测试或发布守卫。

# 2026-10-22 — 更新包已有字节时仍显示“正在连接”

- **现象**：更新抽屉的安装包大小未知时，字节数已增加但进度区域还显示“正在连接”；下载完成进入校验后，晚到的回调还可能把界面改回下载状态。
- **根因**：无总大小时界面只按百分比是否存在来决定连接/下载样式；进度回调只核对下载代际，没有确认界面仍处于下载阶段。
- **修复**：收到任何字节后都显示“正在下载”；仍用实际字节数，无总大小时显示不定进度。回调只更新下载中的状态，不能覆盖校验或终态。
- **涉及文件**：`Seal/Features/UpdateNoticeView.swift`。
- **验证状态**：等待完整 CI 编译和回归。

# 2026-10-22 — 续签被跨服务闸门拦截，设备记录恢复与更新等待态不清楚

- **现象**：0.1.47/0.1.48 的设备日志反复出现 `SEAL-OP-001`，提示描述文件服务被安装清单扫描占用；更新抽屉显示 `0 B / 26 MB` 和一条空进度线，看不出仍在连接更新源；Seal 重装后已安装侧载记录缺少本机展示资料。
- **根因**：安装代理与 misagent 描述文件服务共用了同一查询闸门，互不冲突的读取会挡住续签。应用列表的设备扫描入口还在读取前检查全局设备忙状态，导致本可独立执行的清单读取被跳过。更新抽屉在收到首个字节前使用无确定进度的线性样式。
- **修复**：按 InstallationProxy 与 misagent 拆分各自的原生调用闸门；两个服务可以并行，同一服务的不可取消原生调用仍等其真实结束。设备清单读取不再被全局忙状态提前拒绝；完成清单读取后，只有需要变更已安装记录时才等待应用安装写入结束，避免把安装中的 App 误判为已卸载。本机 LaunchServices 与设备安装清单并行合并，补回应用名称、版本、团队、可确认的 profile 信息和图标；配对维护或描述文件维护不会再挡住本机已安装列表。前台事务冲突时改为可取消地等前一笔写入结束，不因固定 30 秒到期而直接丢弃请求。单个服务请求超时不再顺带作废共享 RSD 缓存；确认连接失败时仍由原有恢复路径重建。更新首字节到达前显示动态连接提示，之后只显示 URLSession 回报的真实进度。
- **上游对照**：SideStore 的刷新流程不使用 Seal 的本机安装恢复链路；对齐其按实际应用身份更新状态的做法。Seal 保留本机和设备两种清单来源，并按具体设备服务分别调度；不引入整个应用共用的忙碌锁。
- **涉及文件**：`Seal/Application/OperationCoordinator.swift`、`Seal/Core/Apps/InstalledAppRefreshProbePolicy.swift`、`Seal/Core/Apps/InstalledAppScanner.swift`、`Seal/Core/Recovery/AppRecordRecovery.swift`、`Seal/Core/Recovery/InstalledRecordRecoveryPolicy.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/UpdateNoticeView.swift`、`Seal/Infrastructure/Installation/DeviceInstalledAppScanner.swift`、`Seal/Infrastructure/Installation/DeviceProfileCleaner.swift`、`Seal/Infrastructure/Installation/DeviceProfileInspector.swift`、`Seal/Infrastructure/Renewal/ProfileOnlyProvisioningProfileInstaller.swift`、`Seal/Infrastructure/UpdateIPADownloader.swift`、RustBridge 安装/描述文件服务、对应回归测试和源码守卫。
- **验证状态**：未在 Windows 运行 Swift 编译、回归测试或源码守卫；源码守卫 Python 语法解析通过。完整 Swift 回归、守卫、签名器测试和 IPA 构建等待 CI；设备列表恢复与续签并行仍需真机确认。

# 2026-10-22 — CI 守卫的设备调用锚点未跟随有界等待参数

- **现象**：CI `39658250271` 的 Swift 回归与签名器测试通过，但 `build-package` 在发布守卫失败；守卫报告 R116 源码断言失败及 4 个变异锚点缺失。
- **根因**：本批把设备查询改为显式传入 `waitForAvailability`，原守卫仍匹配未带此参数的旧调用文本；预热调用也由单行改成多行，R116 断言和变异样本仍匹配旧格式。实际业务源码与本次排队逻辑检查无关，失败发生在 IPA 构建前。
- **修复**：R116 断言限定在 `prewarmProfileService` 函数体内检查 `markTaintOnFailure: false`；变异样本改为替换这条参数。设备描述文件引用查询、安装后核验和证书引用查询的变异锚点同步到带 `waitForAvailability` 的现有调用形态。
- **涉及文件**：`Scripts/verify-release-safety.py`、`DEBUG_LOG.md`。
- **验证状态**：CI `39658250271` 中 Swift 回归和签名器测试通过，发布守卫失败；上述守卫修订尚未由 CI 验证，需重新推送并等待完整 CI。

# 2026-10-22 — 前台设备事务被扫描冷却误拒绝，配对活动属性超限

- **现象**：真机 0.1.47 日志中，续签已确认走“仅更新描述文件”，随后多次报 `SEAL-OP-001`，提示设备描述文件服务被清单扫描或维护占用；配对码活动创建失败，系统日志明确报 ActivityAttributes 超过最大载荷，配对码退回系统通知。
- **根因**：签名/续签/证书引用查询复用的 `InstalledAppRefreshProbeGate` 对扫描超时后的冷却窗口采取 fail-fast；事务协调器看不到这个冷却，profile 探测立即返回 busy。扫描也可能在前台事务等待期间再次尝试获取探测闸门。灵动岛则把小图 PNG 序列化进 `ActivityAttributes`，实际请求超过 ActivityKit 限制。
- **修复**：前台设备操作改为有界等待扫描和 20 秒恢复冷却；等待者存在时清单扫描让路。若设备协调器中的配对重置暂时冲突，原生读请求也排队等待而非立即报错；后台保活探测则 fail-fast 让位，不抢占前台事务。保持单飞和 FFI 真正结束前不释放锁、不重置会话。灵动岛属性仅保存设备名，扩展从自己的 Asset Catalog 读取 72×72 图标，并继续解码旧版属性以兼容已有活动。
- **上游对照**：SideStore profile-only 刷新直接注入 profile，不做 Seal 的设备扫描；Seal 保留共享设备会话的单飞安全边界，只改变前台操作与低优先级扫描的排队顺序。
- **边界**：日志中的 Apple `3022`（证书配额达到上限）与 `SEAL-INVENTORY-100b`（对应 Apple ID 本机凭据不存在）是独立问题，不属于设备扫描冷却或灵动岛载荷修复。
- **涉及文件**：`Seal/Core/Apps/InstalledAppRefreshProbePolicy.swift`、`Seal/Application/OperationCoordinator.swift`、`Seal/Infrastructure/Installation/DeviceProfileCleaner.swift`、`Seal/Infrastructure/Installation/DeviceProfileInspector.swift`、`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`、`Seal/Infrastructure/Renewal/ProfileOnlyProvisioningProfileInstaller.swift`、`Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Features/Settings/SettingsViewModel.swift`、`Shared/PairingActivityAttributes.swift`、`Seal/Infrastructure/Pairing/PairingLiveActivityController.swift`、`SealLiveActivity/PairingLiveActivityWidget.swift`、对应回归测试、`Scripts/verify-release-safety.py`、`RELEASE_NOTES.md`、`docs/upstream-alignment.md`、`project.yml`。
- **验证状态**：已补共享闸门优先级、事务租约等待和旧活动属性兼容回归用例；未在 Windows 运行 Swift 编译/测试或静态守卫，等待推送后的完整 CI；灵动岛显示和真机续签交接仍需设备回归。

# 2026-10-21 — CI 变异自检的预期错误标签落后于断言文案

- **现象**：CI `39614648750` 的源码断言通过，但两条变异自检报错：图标写回代际门被移除、阳性对照设备查询参数被改写后，变异没有被识别。
- **根因**：变异确实触发了对应守卫；但变异表里的 `expected` 前缀仍是旧文案，与当前 `check()` 的错误标签不一致，导致自检把已发现的违规误报为变异未命中。
- **修复**：将两条变异的预期标签同步为当前断言标签，保护条件和业务代码不变。
- **涉及文件**：`Scripts/verify-release-safety.py`、`DEBUG_LOG.md`。
- **验证状态**：根据 CI `39614648750` 的 862 项源码断言和 618 项变异自检日志定位；尚未重新由 CI 验证，等待推送后的完整 CI。

# 2026-10-21 — 设备图标恢复在闭包中同步读取 actor 文件存储

- **现象**：CI `39597872847` 的 Swift 回归编译失败，`AppRecordRecovery.recoverMissingIcons` 在 `contains` 的同步闭包中调用 actor 隔离的 `AppFileStore.read(relativePath:)`。
- **根因**：为修复已安装 App 图标的恢复路径，新增了文件可读性探测；但 `Array.contains` 的闭包不能 `await` actor 方法，CI 严格并发编译拒绝该调用。
- **修复**：改为在异步循环中逐个读取候选图标路径，找到一个可读文件后立即停止；缺图标判断语义不变，仍由已有 `AppRecordRecoveryTests` 覆盖。
- **涉及文件**：`Seal/Core/Recovery/AppRecordRecovery.swift`、`DEBUG_LOG.md`。
- **验证状态**：CI 编译诊断已定位并修正；等待重新运行 Swift 回归。

# 2026-10-21 — 图标加载旧任务可在新列表之后覆盖状态

- **现象**：已安装列表刷新期间，较早一轮图标加载可能在较新一轮开始后才返回，覆盖新列表的图标缓存。
- **根因**：代际检查与 `MainActor` 写入分开执行；两步之间新一轮加载可能递增代际，使旧任务仍写入过期图标。
- **修复**：把代际检查与图标缓存写入放进同一个 `MainActor.run` 原子区间；旧代际直接丢弃结果。
- **涉及文件**：`Seal/Features/Apps/AppsViewModel.swift`、`DEBUG_LOG.md`。
- **验证状态**：静态检查通过；等待 CI Swift 回归与构建验证。

# 2026-10-21 — CI 守卫取片段时错误依赖已剥除的注释

- **现象**：CI `39606768687` 在 `build-package` 守卫步骤抛出 `section end marker not found`，静态检查没有运行到后续断言。
- **根因**：`cleaner_source` 在截取函数前先剥除了注释，结束标记却选用了函数间的文档注释，因此标记永远不存在。
- **修复**：结束标记改为下一个真实函数声明，继续只检查维护期设备探测函数本体。
- **涉及文件**：`Scripts/verify-release-safety.py`、`DEBUG_LOG.md`。
- **验证状态**：已对照源文件确认两个函数边界；等待本轮 CI 结束后重新推送验证。

# 2026-10-21 — 后台启动注册任务的空结果缺少类型上下文

- **现象**：CI `39606768687` 的 Swift 回归编译失败，`AppContainer` 启动注册任务的 `return nil` 无法推断类型。
- **根因**：异步加载启动元数据后，`Task` 初始化没有显式结果类型，而闭包存在可选返回路径；下游赋值点未能为该闭包提供足够的推断上下文。
- **修复**：声明任务为 `Task<SelfAppRegistrar?, Never>`，使成功读取和元数据缺失两条路径类型一致。
- **涉及文件**：`Seal/Application/AppContainer.swift`、`DEBUG_LOG.md`。
- **验证状态**：编译诊断已定位并修正；等待 CI Swift 回归验证。

# 2026-10-21 — App 替换持久化回归用例修改不可变名称

- **现象**：CI `39609111268` 的 Swift 回归编译失败，替换提交测试试图直接修改 `AppRecord.name`。
- **根因**：`AppRecord.name` 是不可变 `let`；测试要覆盖同一 ID 的名称替换，却复制现有值后原地赋名。
- **修复**：使用相同 ID 和新名称重建记录，再设置可变安装状态，保留测试意图并符合模型约束。
- **涉及文件**：`SealTests/Persistence/CoreDataAppStoreTests.swift`、`DEBUG_LOG.md`。
- **验证状态**：CI 编译诊断已定位并修正；等待 CI Swift 回归验证。

# 2026-10-21 — 静态守卫断言与变异锚点未覆盖当前设备路径

- **现象**：CI `39609111268` 的变异自检未能发现部分保护条件被破坏，另有两个基线断言不符合当前实现。
- **根因**：图标写回现在只有一处原子代际门；设备探测有同名调用，旧变异锚误改共享包装而非目标函数；设备扫描快照和格式变化也让 Bundle ID 检查过度依赖空白形式。
- **修复**：将守卫计数改为实际门数，缩小片段边界，改用空白无关的调用匹配；变异锚定目标探测调用，并分别检查缺失对照时 fail-closed、设备门闩迟到回调释放和 provider 禁用条件。
- **涉及文件**：`Scripts/verify-release-safety.py`、`DEBUG_LOG.md`。
- **验证状态**：静态断言和变异锚点已按源码收紧；等待 CI 守卫验证。

# 2026-10-21 — 设备扫描与描述文件并发修复的 Swift 回归编译失败

- **现象**：CI `39595526309` 的 Swift 回归未能编译：扫描器实例方法调用静态 profile 摘要方法；设备维护闭包把非逃逸回调传给原生异步执行器；描述文件检查的 `@Sendable` 工作闭包捕获非 `Sendable` 的 `FileManager` 实例。
- **根因**：共享设备 FFI 执行器会在原生调用晚于 Swift 等待返回时执行完成回调，因此回调确实需要逃逸；清理操作也需要将该回调沿维护租约闭包继续传递。扫描器的 `readProfileSummaries` 已是静态方法，调用点遗漏 `Self.`。`FileManager` 引用被闭包捕获，触发 Swift 6 严格并发检查。
- **修复**：扫描器使用 `Self.readProfileSummaries()`；将原生完成回调及维护闭包的回调参数明确标为 `@escaping @Sendable`；在原生工作闭包内直接访问 `FileManager.default`，不捕获管理器实例。
- **涉及文件**：`Seal/Infrastructure/Installation/DeviceInstalledAppScanner.swift`、`Seal/Infrastructure/Installation/DeviceProfileCleaner.swift`、`Seal/Infrastructure/Installation/DeviceProfileInspector.swift`、`DEBUG_LOG.md`。
- **验证状态**：根因由 CI Swift 编译诊断定位，改动后已做差异与空白检查；尚未由 CI 重新编译，等待下一轮 Swift 回归。

# 2026-10-21 — CI 静态守卫未跟上设备单飞封装

- **现象**：CI `39587187268`、`39587359644`、`39588014206`、`39588262215`、`39588505991` 的 `build-package` 依次在静态守卫或变异自检失败，均发生在 IPA 构建之前；已发现锚点和调用模型过期、断言顺序错误，以及一条 R130 变异样本锚点过期。
- **根因**：R10 仍以已提前创建的 `OperationCoordinator` 作为 AppContainer 安装通道块的结束标记；证书清理守卫仍要求旧的单行 `referencedCertificateSerials()` 声明，并把 `BlockingCall.bounded` / 不取消超时的责任错误地算在调用点。当前实现已将设备原生操作集中到 `DeviceProfileNativeCall.perform`，由共享闸门持有设备租约并等待不可取消的 FFI 真正返回。Seal 更新身份断言放在 `apps_vm` 读取之前，触发 Python 局部变量未绑定错误。R126 守卫仍引用旧的单行 `isInstalled` 签名和局部 `probeGate`，而实际实现将 gate 独立为 `InstalledAppRefreshProbeGate` actor。R130 变异样本仍在续签调用点寻找 `onWorkNeverStarted`，实际释放动作已封装在共享设备调用执行器中。
- **修复**：AppContainer 范围改为其后的设备扫描器初始化为边界。证书清理守卫分别钉住调用点使用共享执行器和查询预算、以及执行器内部有界等待/不取消 FFI/超时后保留闸门与设备租约；增加变异样本，防止调用点绕过共享闸门或把超时改为取消。Seal 更新身份断言移至 `apps_vm` 加载之后。R126 改为检查多行方法声明、独立 gate actor 的迟到完成 ID 核验，以及验证器的 gate 和设备 lease 在原生工作结束时释放；同步更新三条变异样本的真实源文件和表达式。R130 改为检查续签调用点传递完成回调，并通过变异确认“原生任务未启动”时共享执行器仍会释放业务租约。
- **涉及文件**：`Scripts/verify-release-safety.py`、`DEBUG_LOG.md`。
- **验证状态**：CI `39588505991` 已确认主体守卫通过，但 R130 变异锚点过期；按项目纪律未在本地运行源码守卫。守卫变异修正需新的 CI 验证。

# 2026-10-21 — 描述文件服务忙碌日志使用不存在的操作枚举

- **现象**：CI `39588505991` 的 Swift 回归在编译 `MinimuxerInstallChannel.swift` 时失败，提示 `FailureOperation` 没有 `renewal` 成员。
- **根因**：`FailureOperation` 的合法值为 `renew`；`renewal` 是其他模型中的事件分类，不能用于 `ImportFailure.operation`。
- **修复**：描述文件服务忙碌错误改用 `FailureOperation.renew`，保留“续签期间设备服务被占用”的语义。
- **涉及文件**：`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`、`Scripts/verify-release-safety.py`、`DEBUG_LOG.md`。
- **验证状态**：由 CI 编译错误与 `FailureOperation` 声明确认根因；源码及 R130 守卫变异已修正，等待新的 CI 编译和守卫验证。

# 2026-10-21 — Apple ID 被握手错误误标为凭据失效

- **现象**：登录过的 Apple ID 在签名/续签遇到设备环境握手失败后会被持久化为“需要重新验证”；用户会误以为本地账号凭据丢失，并被引导再次登录。Apple 要求 2FA 时则仍需在账号认证流程输入验证码。
- **根因**：`ApplePortalSigningService` 把 AltSign 的 `authenticationHandshakeFailed` 转成 `SEAL-AUTH-102e`；`AppleServiceFailurePolicy` 之前用 `SEAL-AUTH-102` 前缀识别错误凭据，错误地把设备环境/握手故障也归成 `.credentialsRejected`。证书请求 `102c` 本身也可能是限流或会话状态，不能据此断定密码错误。
- **修复**：凭据失效改为显式码集合，只包含 `102`、`102a`、`102b`、`102d`；`102c` 与 `102e` 保持账号状态。握手失败出口现在明确标记 `.authenticationHandshakeRejected`，并提示检查系统时间和 Anisette 环境。新增策略回归覆盖并更新 R40 源码守卫及变异样本。
- **上游对照**：SideStore 的 SideSign 将 `incorrectCredentials` 和 `authenticationHandshakeFailed` 分别建模；Seal 按这两种错误的语义分类，不再按编号前缀推断。
- **边界**：Apple 的 2FA 挑战是服务端身份验证要求，已保存的密码/会话不能绕过；签名或续签遇到会话恢复时，验证码仍由用户在账号认证流程输入。旧版本已经写入 `.credentialsRejected` 的账号记录不带原始错误码，无法安全判断它是密码真错还是旧版误标；本修复不会自动清除此类状态，以免掩盖真实凭据拒绝。
- **涉及文件**：`Seal/Core/Accounts/AppleServiceFailurePolicy.swift`、`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、`SealTests/Accounts/AppleServiceFailurePolicyTests.swift`、`Scripts/verify-release-safety.py`、`docs/error-catalog/auth.json`、生成的错误帮助索引与错误码清单、`docs/upstream-alignment.md`、`RELEASE_NOTES.md`。
- **验证状态**：源码差异审查、错误目录生成、错误码清单生成与 `git diff --check` 通过；未运行 Swift 构建、测试或源码守卫，也未推送 CI。依项目纪律，Swift 编译与回归需交 CI；真机需覆盖有效密码下的 Anisette 握手失败不会改账号状态，以及明确 incorrect-credentials 仍能要求重新验证。

# 2026-10-21 — 设备记录恢复在资源冲突后丢失重试

- **现象**：设备记录恢复任务遇到正在运行的清单扫描、维护任务或其他操作后会跳过；当前刷新只检查“任务已启动”便清除待重试状态，释放设备/维护资源后没有统一续跑通知。另一个启动窗口是记录恢复已经报出设备清单不可用，但列表中仍有其他 App 记录时，后续自动刷新不会再次尝试。证书页回退到配对设备扫描时若碰上签名/安装占用，也不会在事务结束后补查。
- **根因**：`MaintenanceGate.tryAcquire()` 对任何活动租约都非阻塞地返回 `nil`；`restoreRecordsIfIdle()` 原先把“未执行”“扫描来源不可用”和“成功但无变化”折叠成 `false`。`scheduleInstalledRecordRecovery()` 又只在扫描类型冲突时拒绝启动，没把 gate 的其他阻塞纳入调度状态。`OperationCoordinator` 与维护作业结束时没有通知待处理的清单刷新。
- **修复**：恢复结果区分跳过、中途取消、来源不可用、失败和完成；待办只在完成或失败结算后清除。设备/维护租约释放后检查并续跑待处理的列表刷新或记录恢复。清单扫描冲突时合并一次刷新，维护恢复不在任何操作租约或其他维护任务期间启动；证书页只在设备写事务释放时重试一次，不会因离线扫描完成而自循环。无可用设备来源时保留记录并等待下次前台/手动刷新，不伪造卸载状态。
- **边界**：LocalDevVPN / 配对设备不可用时，系统没有可靠的通道就绪通知；恢复任务会在前台刷新时重试，不能在通道未开启时声称设备清单已同步。
- **涉及文件**：`Seal/Application/OperationCoordinator.swift`、`Seal/Application/AppContainer.swift`、`Seal/Core/Maintenance/AppMaintenanceJob.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Settings/SigningCertificateSettingsView.swift`、`RELEASE_NOTES.md`。
- **验证状态**：仅逐段核对控制流与回调时序，并运行 `git diff --check`；未运行 Swift 构建、测试或源码守卫，未推送 CI。仍需 CI 编译，以及真机验证清单扫描与维护任务交错后自动补跑、VPN 未就绪时保留记录、通道恢复后前台刷新补回应用。

# 2026-10-21 — 证书清理与安装验收还有设备 FFI 绕过单飞闸门

- **现象**：设备安装清单已和 profile 查询共用单飞闸门，但证书自动清理与安装结果核验仍存在另一条 `Provision.dumpProfiles` / `Minimuxer.isAppInstalled` 直连路径；在扫描、续签或安装交错时，仍可能并发访问同一设备服务。
- **根因**：`SigningCoordinator.autoCleanOrphanCertificatesIfPossible` 漏传协调器；`MinimuxerInstallChannel.probeInstalled` 用独立 `offThread` 超时，没有占用共享闸门。描述文件清理重试调用 `Provision.resetProvider()` 也只替换 Swift provider，不能废弃 Rust RemotePairing 会话。
- **修复**：证书引用读取与安装后逐项核验改用共享设备 FFI 执行器；协调器将原生调用与正在结束的父设备事务关联，超时或取消后租约保留到同步 FFI 真正返回。清理重试仅在前次原生调用已结束后定向废弃 RemotePairing RSD 缓存，不重置整条配对/安装通道。补回归覆盖：超时期间扫描仍互斥，同时导入和其他账号操作仍可并行。
- **涉及文件**：`Seal/Application/OperationCoordinator.swift`、`Seal/Infrastructure/Installation/DeviceProfileCleaner.swift`、`Seal/Infrastructure/Installation/DeviceProfileInspector.swift`、`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`、`Seal/Infrastructure/Renewal/ProfileOnlyProvisioningProfileInstaller.swift`、`Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Application/AppContainer.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`SealTests/Installation/DeviceProfileCleanerTests.swift`、`docs/upstream-alignment.md`、`RELEASE_NOTES.md`。
- **验证状态**：源码逐点核对并添加回归用例；依项目纪律未在 Windows 运行 Swift 构建、测试或源码守卫，未推送 CI。需 CI 编译/测试，并真机覆盖设备扫描、证书自动清理、profile-only 续签、安装后核验同时触发和原生 FFI 超时后的恢复。

# 2026-10-21 — 设备清单重试被全局租约误挡与证书 profile 查询未单飞

- **现象**：前台操作期间触发的设备记录恢复可能不再补跑；证书关联分析与安装清单扫描可能同时调用 `Provision.dumpProfiles`，造成设备查询互相干扰。
- **根因**：扫回调度检查了 `hasActiveLease`，把无冲突的账号、导入和资料编辑也当成设备忙；证书页的 profile 引用读取没有进入已安装清单共用的设备探测闸门。
- **修复**：扫回调度只检查 `scanningDeviceInventory` 的真实冲突，并在扫描期间收到新的显式刷新请求时合并补跑一次。证书 profile 引用读取现在与清单扫描共享单飞闸门和设备读租约；同步 FFI 超时后直到迟到调用真正完成才释放资源。增加回归用例覆盖设备读取之间互斥、与账号/导入并行。
- **边界**：离线完整清单仍依赖系统可读的 LaunchServices 私有枚举；若系统两种枚举都不可用，则需要 LocalDevVPN 配对通道读取 installation proxy。两种来源都不可用时只能保留未知状态，不能可靠判断卸载；不伪造“已同步”。后台旧描述文件清理现与前台设备扫描共享单飞闸门和设备租约；还需真机验证维护任务与扫描交错时的实际恢复结果。
- **涉及文件**：`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Infrastructure/Installation/DeviceProfileInspector.swift`、`Seal/Features/Settings/SettingsViewModel.swift`、`SealTests/ApplicationOperationCoordinatorTests.swift`、`RELEASE_NOTES.md`、`docs/upstream-alignment.md`。
- **验证状态**：只做源码审查并添加回归测试，未运行 Swift 构建/测试/守卫，未推送 CI。需 CI 编译回归；真机覆盖离线本机清单、VPN 扫回、证书页与列表同时读取，以及账号/导入操作与设备扫回并行。

# 2026-10-21 — 启动时设备扫回过早与设备清单查询缺少写事务互斥

- **现象**：Seal 启动时 LocalDevVPN 未就绪，设备侧载 App 扫回失败；用户稍后连接隧道并刷新已安装列表，仍不会补回缺失记录。安装代理/描述文件清单查询也可能在同步 FFI 尚未结束时与签名、安装或续签共用设备会话。
- **根因**：完整记录恢复只接在启动关键维护路径，前台列表刷新只对账现有记录，没有重新调用恢复入口；设备扫描虽对读查询做单飞，但没有在 `OperationCoordinator` 中声明与设备写操作共享的资源，因而读写仍可能竞态。
- **修复**：启动扫回可能早于 VPN；回到前台或手动刷新时，单飞地在后台重试恢复，包括本地部分记录仍在的情况；只有记录或图标实际恢复才重载列表，不阻塞刷新手势。安装代理、profile 枚举和逐项设备核验持有 `scanningDeviceInventory` 租约；签名、安装、续签和配对重置在该租约释放前不能开始，原生超时调用仍运行时租约保持到迟到完成回调。导入、本地资料编辑及账号操作不被该设备读租约锁住。
- **上游对照**：SideStore 将托管 App 状态持久化，并在设备管理操作中按设备阶段调度；Seal 保留本地 LaunchServices 离线核验，同时补上通道恢复后的记录扫回重试和与设备写事务的窄资源互斥，不增加第二套安装记录来源。
- **涉及文件**：`Seal/Application/OperationCoordinator.swift`、`Seal/Application/AppContainer.swift`、`Seal/Core/Apps/InstalledAppRefreshProbePolicy.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Apps/InstalledAppDeviceVerifier.swift`、`Seal/Infrastructure/Installation/DeviceInstalledAppScanner.swift`、`SealTests/ApplicationOperationCoordinatorTests.swift`、`RELEASE_NOTES.md`、`docs/upstream-alignment.md`。
- **验证状态**：新增租约并发回归用例；未运行 Swift 构建、测试或源码守卫，未推送 CI。需 CI 编译/回归，并真机验证启动时 VPN 未就绪、随后连接并刷新可补回记录；扫描超时后签名不与迟到 FFI 重叠；本地导入和账号操作仍可用。

# 2026-10-21 — 设备清单双源合并与超时查询串行化

- **现象**：部分已安装 App 不进入清单，扫描超时后继续发起的逐项查询会与原生设备查询重叠；断开配对通道时，旧记录无法被真实核验。
- **根因**：LaunchServices 全量扫描选择“包含 Seal 的第一个结果”后立即返回，第二个 selector 独有的 App 被遗漏；`Provision.dumpProfiles`、`Minimuxer.installedApplications` 与 `isAppInstalled` 各自有独立闸门，同步 FFI 超时又不能取消原调用，因此串行路径超时后仍可能叠加下一次设备查询。
- **修复**：本机清单合并 `allInstalledApplications` 和 `allApplications` 两源并按归一化 Bundle ID 去重；两源都不可读，或只能读到一个且缺少 Seal 阳性对照时，均返回不可用，不伪装为空清单/完整清单。设备端 profile、完整应用清单和逐项核验共用同一单飞闸门；原生调用迟到完成前不释放，超时后冷却。生产设备清单读取失败时本轮保留现有记录，不再紧接着逐应用探测；设备确认卸载仍只在完整可信快照中执行。
- **边界**：LaunchServices 本机枚举不依赖 Wi-Fi / LocalDevVPN；两种本机枚举都不可用时，完整设备快照需要已配对的 installation proxy 通道。所有来源都不可用时不能可靠地区分“已卸载”和“暂时无法读取”，Seal 保留当前记录并等待可读来源恢复。
- **上游对照**：SideStore 将托管 App 状态和图标按应用持久化；Seal 保留逐 App UTI 离线核验，并把两个本机枚举入口合并。SideStore 没有卸载重装后的私有 LaunchServices 扫描实现。
- **涉及文件**：`Seal/Core/Apps/InstalledAppScanner.swift`、`Seal/Core/Apps/InstalledAppRefreshProbePolicy.swift`、`Seal/Features/Apps/InstalledAppDeviceVerifier.swift`、`Seal/Infrastructure/Installation/DeviceInstalledAppScanner.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`docs/upstream-alignment.md`、`RELEASE_NOTES.md`。
- **验证状态**：未运行 Swift 构建、测试或静态守卫；只做源码审查。需 CI 编译/回归，并在真机覆盖两种 LaunchServices 来源互补、Wi-Fi/LocalDevVPN 断开、原生清单超时后再次刷新及确认卸载同步。

# 2026-10-21 — 续签设备 FFI 超时后的事务长期占用

- **现象**：描述文件续签的设备调用超时后，后续续签项仍等待设备租约，整批任务和同设备操作迟迟不返回；取消已安装清单检查后，旧查询仍可能与新查询叠加。
- **根因**：① `SigningCertificateSettingsView` 在“等待安装确认”状态下每 2 秒重新读取签名身份、本机私钥和事务文件；这是无终止条件的轮询，且每轮都重新触发页面状态更新。② 启动自注册清除旧待安装标记时提前发通知，整个自注册结束后又发一次，导致列表和证书状态重复重载。③ `ProfileOnlyProvisioningProfileInstaller.installAndVerify` 在 `isBusy` 为真时无限轮询。同步设备 FFI 超时后不能取消，installer 为保护共享 misagent 正确保留 `isBusy`，但队列没有区分“正常执行中”和“超时后原生调用仍在后台”，后继续签就会无限等并继续持有前台批次租约。④ `InstalledAppDeviceVerifier` 的取消处理器在 FFI 未结束时就清闸门，20 秒冷却后可能叠加同一设备会话上的第二个查询。⑤ profile-only 准入前额外 dump 旧描述文件只生成诊断、不是安全边界；超时后 FFI 仍会运行并与注入读回争用设备服务。⑥ `AppContainer.live()` 在 MainActor 同步读取 Seal 自注册元数据，其中包含 CMS 签名、profile 和扩展解析，可能使启动 UI 暂时无响应。`OperationCoordinator` 旧单租约还把互不冲突的账号、导入和应用资料操作一并串行化。
- **修复**：移除 2 秒轮询，安装确认只由启动对账完成通知刷新，保留手动检查按钮；并发刷新带代次，只允许最新读取结果发布。自注册中途不再发状态通知，只在完整对账返回后发一次。原生 profile 调用仍未结束时，排队续签项立即以 `SEAL-PROFILE-357` 失败返回并释放前台事务，不并发访问设备；原生调用真正返回后再释放 installer 租约。已安装清单查询用带 UUID 的租约，正常完成时释放，取消/超时后只由原生调用完成回调释放；未启动的工作也有单独结算，旧查询不能释放新租约。移除 profile-only 注入前的冗余设备清单 dump，保留写入后的逐份读回确认。自注册 CMS/profile 读取移到 utility 后台任务，页面主线程只组装轻量展示元数据。操作协调改为账号、应用和资源范围的并发租约；共享安装设备的操作仍串行。移除过时的 363 前置查询守卫与孤儿核验实现。
- **上游对照**：SideStore `RefreshAppOperation` 直接获取并注入新 profile，不枚举旧 profile 清单作为准入条件；Seal 保留自己的注入后精确读回边界，并在超时后维持共享设备互斥。
- **涉及文件**：`Seal/Core/Concurrency/HardTimeout.swift`、`Seal/Infrastructure/Installation/BlockingCall.swift`、`Seal/Features/Apps/InstalledAppDeviceVerifier.swift`、`Seal/Infrastructure/Renewal/ProfileOnlyProvisioningProfileInstaller.swift`、`Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Core/Renewal/SelfAppMetadata.swift`、`Seal/Application/AppContainer.swift`、`Seal/Core/Maintenance/AppMaintenanceJob.swift`、`Seal/Infrastructure/Installation/DeviceProfileInspector.swift`、对应 `SealTests/**`、`Scripts/verify-release-safety.py`、`docs/error-catalog/profile.json`、`docs/qa/log-code-index.md`、`docs/upstream-alignment.md`、`RELEASE_NOTES.md`。
- **验证状态**：源码与差异仍在审查；未运行 Swift 测试、静态守卫或 CI。需 CI 编译和回归；真机应覆盖单项续签、批量多个 profile-only 项、取消设备清单检查、原生 profile FFI 超时后独立账号操作仍可继续。

# 2026-10-21 — 自更新结算、证书页阻塞、更新大小与设备扫描并发

- **现象**：Seal 从应用内更新后停在待安装列表；签名证书页反复显示等待确认并拖慢其他操作；更新下载没有 MB 总量；离线扫回的已安装 App 缺图标；导入、证书等无关事务互相等待。
- **根因**：① 自替换已确认新运行身份后，记录提交仍要求旧 Seal 行存在；设备卸载对账可能先删旧行，导致 `AppStoreError.invalidConfiguration`，自替换事务重复留在待结算态。队列成功状态又早于持久化记录写入。② 证书页私钥判定重复逐账号读 Keychain，再在 MainActor 解析 P12；应用列表的证书派生状态和证书清理分析也在主线程解析 P12。全局证书布尔状态同时挡住不同 Apple ID 的操作。复查还发现证书清理分析的设备 profile 引用查询直接运行同步 `Provision.dumpProfiles`，未设硬等待上限；共享 Apple Portal actor 也串行解析所有本机 P12，慢解析会排队其他账号查询。③ 更新资产页只提供 URL，不提供大小；GitHub 下载响应无 Content-Length 时 UI 只能不确定显示。④ 图标读取被排在 profile dump 与 installation proxy 之后。⑤ `OperationCoordinator` 单全局租约把独立工作也串行化。
- **上游对照**：SideStore 将已安装 App 和图标缓存按应用持久化，进度按 Bundle ID 管理；其卸载对账仅在 App 管理事务期间跳过。SideStore 没有 Seal 这种设备扫描恢复路径。本地图标改为设备通道之外先从 LaunchServices 扫描；同一物理设备上的原生安装命令仍串行。
- **修复**：缺失前驱时原子提交已确认的替换记录；若本地 Seal 行全部缺失则从正在运行的 Bundle 重建；只有 AppStore 成功提交后才结算批量成功。证书私钥检查改为一次 Keychain 全量枚举并将所有页面的 P12 解析移出主线程，派生结果带代次保护；去掉跨账号全局门。证书 profile 引用扫描改为 15 秒有界后台 FFI，未知仍按不可核验处理，并由底层工作完成后清理临时目录；Apple Portal actor 把历史 P12 解析放到 utility 任务，避免同 actor 的其他账号请求排队。更新检查读取 GitHub Release API 的 IPA `size`，进度回调缺 Content-Length 时使用可信资产大小，并保留 Release 页面回退。已知记录的图标恢复先于 profile/设备请求，图标枚举覆盖 LaunchServices 两个 selector。`OperationCoordinator` 改为应用/账号/资源冲突租约；签名、续签和 installd 保持设备互斥，互不冲突的本地导入、应用资料与账号范围工作可并行。
- **回归覆盖**：缺失旧记录时自更新仍结算为已安装；不同账号证书操作与设备列表扫描不互相阻塞；Release API IPA 大小正确读取并过滤非 GitHub 资产；profile 与设备清单不可用时，已知记录图标仍会保存。
- **涉及文件**：`Seal/Application/OperationCoordinator.swift`、`Seal/Core/Apps/InstalledAppScanner.swift`、`Seal/Core/Recovery/AppRecordRecovery.swift`、`Seal/Core/Renewal/SelfAppRegistrar.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Settings/SettingsViewModel.swift`、`Seal/Infrastructure/Installation/DeviceInstalledAppScanner.swift`、`Seal/Infrastructure/UpdateChecker.swift`、`Seal/Infrastructure/UpdateIPADownloader.swift`、`Seal/Features/UpdateNoticeView.swift`、对应 `SealTests/**`、`docs/upstream-alignment.md`、`project.yml`、`RELEASE_NOTES.md`。
- **验证状态**：只完成源码差异审查；遵循仓库规则，未在 Windows 本地运行 Swift 构建、测试或守卫。需 CI 编译/回归，并在真机检查更新实际 MB 进度、无 VPN 图标恢复、自更新后列表转正、证书页不再轮询及独立操作并行。签名/续签与安装仍需真机覆盖 Apple Portal 和设备 FFI。

# 2026-10-21 — 证书撤销选择抽屉过长、CI 变异守卫锚点过期

- **现象**：签名恢复时的“选择要撤销的证书”抽屉每张证书占用多行，证书较多时需要长距离滚动；CI `39555150272` 的源码守卫在 Swift 回归和签名器测试通过后失败，未进入 IPA 构建。
- **根因**：证书行重复展示当前账号已有的 Team ID，并将证书用途、日期、序列号和影响数分散为多行；R71③ 变异锚点仍按旧缩进匹配，R88④ 的守卫范围又包含后续的另一个 `return false`，把错误改动漏检。
- **修复**：抽屉 detent 设为屏幕高度的 56%，由内容区独立滚动；证书行压成紧凑的名称/状态、有效期与序列号尾号、本机影响数三行；推荐证书置顶，默认最多展示三张，其余按需展开。R71③ 更新为当前源码缩进；R88④ 限定检查阳性对照失败分支本身。
- **涉及文件**：`Seal/Features/Apps/CertificateSacrificePickerView.swift`、`Scripts/verify-release-safety.py`、`RELEASE_NOTES.md`、`DEBUG_LOG.md`。
- **验证状态**：完整 CI `39557606872` 的 `build-package`、`swift-regression`、`signer-tests` 全部通过；发布 IPA 为 0.1.46 / Build 114，SHA-256 已核对，桌面副本位于 `Seal-IPA`。还需真机检查抽屉 56% 高度、展开全部证书后的选择与确认流程。

# 2026-10-21 — 配对灵动岛提前结束并静默回退通知

- **现象**：手机配对没有持续显示在灵动岛，后来只看到系统通知；诊断日志没有对应的 ActivityKit 创建/更新失败原因。
- **根因**：准备态 Live Activity 只保留 60 秒，而底层手机配对等待窗口是 180 秒；活动先被本地计时结束后，配对码到达时 `showCode` 因活动句柄缺失直接返回 `false`，调用方转发系统通知。配对码格式错误、状态不匹配及活动被并发替换也有静默返回分支。IPA 守卫只在扩展存在时检查它，缺失扩展的包也能通过。
- **证据**：`Seal-log(39).txt` 的签名记录显示 Seal 的 `SealLiveActivity.appex` 被送入签名，并且本机描述文件续签覆盖主 App 与 `.LiveActivity` 两个目标；这排除了该次 Seal 内部签名链路漏签扩展。`Seal-log(37/38).txt` 记录了手机配对入口，但没有 ActivityKit 回退原因，与静默分支一致。专用小图文件本身为清晰的 72×72 蓝底白色 Seal 标志。
- **修复**：准备态延长至配对服务 180 秒等待窗口之外；包内缺扩展、系统禁用、ActivityKit 创建失败、配对码无效、活动丢失/状态错配或更新期间被替换时分别记录原因。IPA 验证改为强制要求 `SealLiveActivity.appex`，并核验 `com.apple.widgetkit-extension` 扩展类型。
- **同批修复**：启动列表首次读取移到关键维护之后；本机完整快照与远程设备核验统一先做 Seal 阳性对照、收集完全部缺失项后才修改记录，避免不可信清单删记录；设备操作互斥的等待后检查改为非重复守卫形式，保持变异检查能锁定入口闸门。
- **限制**：用户在 iOS 设置关闭 Seal 实时活动时，系统仍会拒绝创建；应用不能绕过系统开关，只能明确记录原因并使用通知回退。部分电脑签名器在显式描述文件模式会删除 `PlugIns`，移除 Live Activity 扩展；Seal 的 IPA 守卫只能确认发布产物签名前带有扩展，不能控制外部签名器处理后的安装包。需使用能签扩展的签名器和对应描述文件。
- **涉及文件**：`Seal/Infrastructure/Pairing/PhonePairingHost.swift`、`Seal/Infrastructure/Pairing/PairingLiveActivityController.swift`、`SealTests/Pairing/PhonePairingPresentationPolicyTests.swift`、`Scripts/verify-ipa.sh`、`Scripts/verify-release-safety.py`、`Seal/Features/Apps/AppsRootView.swift`、`Seal/Features/Apps/AppsViewModel.swift`。
- **验证状态**：完整 CI `39557606872` 全部通过，CI IPA 已核实含 `SealLiveActivity.appex`。尚未真机验证配对等待超过 60 秒、系统禁用时的日志和电脑签名后的实际包；若外部签名器删除扩展，Seal 运行时无法恢复该扩展。

# 2026-10-21 — 诊断日志耗时精度在落盘后丢失

- **现象**：操作摘要刚生成时按真实起止时间计算耗时，写入后日志页重载会出现秒数偏差。
- **根因**：`SealLogStore` 用 `JSONEncoder.DateEncodingStrategy.iso8601` 持久化日期，而轮次摘要把耗时临时从解码后的 `startedAt` / `endedAt` 重算；该日期格式不保存亚秒，重载后最多损失近 1 秒。旧摘要文字本身已有“共用/共计 x 秒”，旧解析器却忽略它，又回退到只精确到秒的标题时间。
- **修复**：摘要增加独立的 `measuredDuration` 数值字段并持久化；批量、单项签名/续签与安装用单调时钟测量；Seal 自更新把事务开始与新进程核验时的系统运行时长随事务保存，跨进程计算仍用单调时钟；读取旧摘要时从原摘要文字恢复耗时（兼容分钟和小数秒），并在日志脱敏重建时保留该值。
- **涉及文件**：`Seal/Core/Renewal/RenewalRoundSummary.swift`、`Seal/Core/Renewal/RenewalCoordinator.swift`、`Seal/Core/Renewal/SelfReplacementTransaction.swift`、`Seal/Core/Renewal/SelfReplacementTransactionStore.swift`、`Seal/Core/Renewal/SelfReplacementCoordinator.swift`、`Seal/Core/Renewal/SelfAppRegistrar.swift`、`Seal/Core/Diagnostics/LogViewerPolicy.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Infrastructure/Diagnostics/SealLogStore.swift`。
- **验证状态**：完成源码与差异审查；未运行构建、测试或守卫，Windows 无 Swift/Xcode 工具链。需 CI 编译，并以含小数耗时的摘要完成落盘、重载后检查 UI 与导出一致。

# 2026-10-21 — SideStore UTI 对照、离线卸载对账与证书安装清单

- **现象**：卸载 App 后 Seal 仍将记录留在“已安装”；证书页可能显示“本机安装清单暂不可用”。
- **根因**：Seal 给所有重签 App 声明同一个 `com.mjorb.seal.installed-app` UTI，无法按 App 判定卸载；本机扫描第一个 LaunchServices selector 返回空数组或漏掉当前 Seal 时，原逻辑不会尝试第二个 selector；证书页只读本机扫描，未接设备 installation proxy 完整清单。
- **上游对照**：SideStore 按重签 Bundle ID 生成独立 `io.sidestore.Installed.<bundleID>` UTI，并由 `UTType.isDeclared` 清理卸载后的托管记录；Seal 沿用逐 App 标记，保留本地 IPA，不照搬删除记录。
- **修复**：新签 App 添加独立 UTI；安装后从待安装 IPA 的主 `Info.plist` 确认该 UTI 确实存在，再持久化标记版本，避免旧缓存 IPA 或仅更新描述文件被误记成新标记。新标记记录可在离线时直接核对卸载。LaunchServices 会尝试两种枚举方法并优先采用包含当前 Seal 的结果，让旧记录也能用本机完整清单核验；清单不可用时，新标记记录可逐项离线核验，旧记录继续走设备清单，不把无新标记误判为未安装。已安装列表与证书页共用 installation proxy 的完整用户 App 清单并要求 Seal 阳性对照。
- **涉及文件**：`Seal/Core/Apps/SealInstalledAppMarker.swift`、`Seal/Core/Apps/InstalledAppScanner.swift`、`Seal/Core/Apps/AppRecord.swift`、`Seal/Infrastructure/Signing/SigningWorkspace.swift`、`Seal/Infrastructure/Persistence/CoreDataModel.swift`、`Seal/Infrastructure/Persistence/CoreDataAppStore.swift`、`Seal/Infrastructure/Installation/DeviceInstalledAppScanner.swift`、`Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Core/Renewal/SelfAppRegistrar.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Settings/SettingsViewModel.swift`、`Seal/Features/Settings/SigningCertificateSettingsView.swift`、`Seal/Application/AppContainer.swift`、`docs/upstream-alignment.md`。
- **验证状态**：未运行构建、测试或源码守卫；需 CI 编译验证 Core Data 轻量迁移和 Swift 6 并发，真机验证离线卸载、已安装列表状态转换及证书页设备清单回退。

# 2026-10-21 — Seal 更新后旧版本行要手动刷新才消失

- **现象**：Seal 更新到新版本并重新打开后，已安装列表仍显示“新版本 → 旧版本”和“旧版本”；手动下拉刷新后才恢复。
- **根因**：启动 `.task` 与 `scenePhase == .active` 可并发调用 `syncSelfRecordOnLaunch()`；`SelfAppRegistrar.ensureRegistered()` 的防重入分支直接返回，第二个调用仍被维护层当作同步完成并发布刷新通知，可能在记录版本对账完成前加载旧快照。首屏列表加载还排在维护与队列恢复之后。
- **修复**：并发自注册改为共享并等待同一个任务；首轮自注册和证书快照完成后立即重载应用列表，启动维护后的最终重载继续保留。
- **涉及文件**：`Seal/Core/Renewal/SelfAppRegistrar.swift`、`Seal/Features/Apps/AppsRootView.swift`。
- **验证状态**：本机 Windows 无 Swift/Xcode；未运行测试或源码守卫。需 CI 编译回归，并在真机更新后冷启动确认旧版本标记自动消失。

# 2026-10-21 — 证书关联守卫的变异检查必须限定函数体

- **现象**：CI `39543784879` 的 `Check release safety invariants` 因两条证书关联变异检查未触发而失败。
- **根因**：静态检查在整个 `CertificateRevocationImpact.swift` 中搜索表达式；其他函数恰好也有相同表达式，导致目标实现被删改时仍被旁边函数的文本“代过”。第二条变异还命中了更早的同名调用。
- **修复**：静态检查改为分别检查 `associatedApps` 和 `installedAppsAssociated` 函数体；第二条变异锚点包含目标函数签名，确保只改到已安装 App 关联路径。生产证书关联逻辑不变。
- **涉及文件**：`Scripts/verify-release-safety.py`、`DEBUG_LOG.md`。
- **验证状态**：本机不运行源码守卫；该 CI 的守卫门已失败，Swift 回归仍在运行。修复提交后由新一轮 CI 验证守卫的变异自检与全套门。

# 2026-10-21 — 离线卸载对账、账号应用归属、操作日志保留与配对灵动岛

- **现象**：未连接 Wi-Fi / LocalDevVPN 时卸载的 App 仍显示在 Seal 的已安装列表；重新添加 Apple ID 后证书页和批量续签漏掉原账号下已签名的 App；操作日志偶尔消失，自更新显示成没有 App 名的“安装”；设备配对时 Live Activity 未出现并退回系统通知。
- **根因**：已安装清单依赖远程设备会话，失败时安全地保留旧状态；本机 LaunchServices 扫描还要求列表必须包含 Seal 自身，系统未列出调用方时会丢弃可用快照。证书归属依赖随机本地 account UUID 和仅顶层保存的 serial，无法承接重建账号 UUID 或 target-only 签名数据。日志环形缓冲按时间一律淘汰旧记录，操作结果与异步 flush 共享写入窗口；自替换成功日志没有人类可见摘要。启动时异步清理遗留 Live Activity 与用户创建新活动没有串行化，ActivityKit 创建/更新失败也被静默转换为通知回退。
- **修复**：LaunchServices 非空快照即用于本机卸载对账（空结果或扫描失败仍走设备核验、不会批量误删）；扫描图标时复用 `allInstalledApplications` / `allApplications` 兼容入口。证书关联按归一化 serial + Team 匹配，不要求随机 account UUID；续签证据允许 serial 保存在同 Team signing target，同时仍要求其余持久化签名身份。日志容量优先保留最终签名/续签/安装结果、操作结果立即原子落盘；Seal 自替换结算日志显示为“更新 · Seal”并使用事务起止时间。配对活动清理与创建共用串行任务，ActivityKit 未启用、创建失败或更新后被回收时记录可诊断原因；设备页、指南和活动预备态共用开发者模式配对文案。日志页工具栏按钮去掉圆形玻璃背景，邮件收件人改为用户指定地址。
- **涉及文件**：`Seal/Core/Apps/InstalledAppRefreshProbePolicy.swift`、`Seal/Core/Apps/InstalledAppScanner.swift`、`Seal/Core/Apps/AppRecord.swift`、`Seal/Core/Signing/CertificateRevocationImpact.swift`、`Seal/Core/Diagnostics/LogViewerPolicy.swift`、`Seal/Core/Renewal/RenewalRoundSummary.swift`、`Seal/Core/Renewal/SelfAppRegistrar.swift`、`Seal/Core/Renewal/SelfReplacementCoordinator.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Settings/SettingsViewModel.swift`、`Seal/Features/Settings/SigningCertificateSettingsView.swift`、`Seal/Features/Settings/PairingSettingsView.swift`、`Seal/Features/Settings/SigningAndRenewalGuideView.swift`、`Seal/Features/Settings/LogViewerView.swift`、`Seal/Infrastructure/Diagnostics/SealLogStore.swift`、`Seal/Infrastructure/Pairing/PairingLiveActivityController.swift`、`Shared/PairingActivityAttributes.swift`、对应 `SealTests/**`、`docs/upstream-alignment.md`。
- **回归覆盖**：本机快照未包含 Seal / 空快照策略；账号重建且证书只记于 target 时的证书关联；target-only 证书证据进入续签队列；容量淘汰优先级和结果立即持久化；Seal 更新摘要名称/耗时；配对文案一致性；自替换结算写入带 Seal 更新摘要的日志。
- **验证状态**：按用户和项目约定，未运行 Swift/Xcode 编译、测试或源码守卫；本机 Windows 无法完成 iOS 编译。需 CI 编译及真机确认 LaunchServices 清单、离线卸载对账、续签队列、ActivityKit 系统可用性/图标和日志持久化。系统关闭实时活动时仍会回退系统通知，日志会明确记录此原因。

# 2026-10-21 — CI 105 守卫变异定位错误的资源副本与互斥锚点

- **现象**：CI `39526715221` 的 Swift/UI 回归与签名器测试通过；发布安全守卫仍因 R84⑦ 变异锚点缺失、R119④ 变异未触发而失败。
- **根因**：R84⑦ 的互斥判断位于解释性注释之后，变异锚点错误地假定它紧跟 `installedRecords`。R119④ 对 `project.yml` 的变异替换了 Seal 主 target 的重复 PNG 资源行，Live Activity target 的真实资源行仍存在，因而没有破坏守卫目标。
- **修复**：R84⑦ 锚定互斥注释后的唯一 guard；从 Seal 主 target 移除不再使用的原始 PNG 副本，只由 Live Activity target 保留回退 PNG；变异失败信息附上文件与锚点，方便定位后续误配。
- **涉及文件**：`Scripts/verify-release-safety.py`、`project.yml`、`DEBUG_LOG.md`。
- **验证状态**：本机未运行源码守卫或测试。修复后需重新推送 CI；Swift/UI 与签名器在该轮已通过，只有守卫需重验，构建 job 尚未执行。

# 2026-10-21 — CI 守卫未对齐灵动岛小图资源与变异锚点

- **现象**：CI `39523900134` 的 Swift 回归与签名器通过，但 `build-package` 在 R119④ 及证书页、已安装页两个守卫变异检查失败。
- **根因**：灵动岛路径仍在运行时把主图标缩到 96 px，未使用 24pt 图标对应的 72 px @3x 专用资源；R119④ 断言检查的主 App 资源读取方式与现有路径不一致。证书页与设备核验变异测试使用全文件首个匹配，改到另一处同名调用后没有破坏目标判据，属于变异锚点不唯一。
- **修复**：新增从 Seal 正式图标等比例高质量缩出的 `SealBrandIconSmall` 72×72 @3x 资源，分别加入主 App 与 Live Activity 资源目录；控制器从主 App 图像集读取小图数据传给活动，扩展优先使用同一小图。守卫改为检查专用资源；证书关联与设备核验守卫/变异锚点分别限定到对应函数体。
- **涉及文件**：`Seal/Infrastructure/Pairing/PairingLiveActivityController.swift`、`SealLiveActivity/PairingLiveActivityWidget.swift`、两份 `SealBrandIconSmall.imageset`、`Scripts/verify-release-safety.py`、`DEBUG_LOG.md`。
- **验证状态**：本地确认两份 PNG 均为 72×72；按项目纪律不在本机运行源码守卫或 Swift 测试。修复后重新推送完整 CI，之后再发布更新源。

# 2026-10-21 — 已安装列表、证书在用状态、日志和更新完成态不同步

- **现象**：卸载的应用在重开 Seal 后仍留在已安装列表；证书页可能把已卸载 App 标成“本机已安装 App 在用”；Seal 更新后旧版本标签需手动刷新；诊断日志最多显示 20 条但没有说明，且缺少直接邮件发送入口；应用覆盖更新和普通安装共用“安装”标题；灵动岛图标灰色或模糊；签名/续签操作抽屉可上拉改变高度。
- **根因**：已安装列表只靠需要 Wi-Fi/LocalDevVPN 的设备核验；证书页用持久化 AppRecord 状态推断实时安装；自记录变更通知只刷新证书快照、不重载 App 列表；日志 UI 按 20 条截取而未解释，Mail composer 未接入；更新日志没有独立 operation 类型；Live Activity 控制器从主 App Asset Catalog 读取扩展资源名，实际拿不到数据且 32/24 px 输出过小；两个操作抽屉同时声明固定高度和 `.large` detent。
- **修复**：用 LaunchServices 本机快照同步已安装状态；区分清单读取失败与成功空清单，并要求运行中的 Seal 作为阳性对照，失败时回退原设备核验。事务期间延后刷新，结束后补做。证书页将本机安装 ID 与签名证书关联共同判定，未知时不允许撤销。Seal 自身记录变更与回前台时重载记录。日志页解释 20/1000 条规则，并增加预填收件人的原生邮件草稿与分享回退；更新操作独立归类，成功标记使用 `✓`。将正式图标按比例导出为专用 72×72 @3x 小图，主 App 将其随配对活动传给扩展。操作抽屉移除 `.large` detent，内容区保持滚动。
- **连接引导**：Seal 启动时后台调用 `LocalDevVPNOnDemandActivator.probeTunnel()`，尝试触发已配置的按需隧道；失败页提示连接同一 Wi-Fi 与 LocalDevVPN，提供 `localdevvpn://enable?scheme=seal` 深链，返回时走既有诊断回调。iOS 加入 Wi-Fi 要求用户明确授权，不能静默切网。
- **上游对照**：本批只改变列表同步、证书状态展示、日志分类和 UI，不改变签名/续签判定、Apple 请求、签名材料或安装事务；`docs/upstream-alignment.md` 已核对，SideStore/AltStore 没有等价的本机 LaunchServices 清单 UI 判据，未引入第二套签名/续签流程。
- **回归覆盖**：增加本机清单阳性对照、Bundle ID 归一化、证书关联必须匹配实时安装快照、设备清单未知不得显示“无影响”、更新操作类型测试；原有日志最近 20 条测试继续覆盖展示上限。
- **涉及文件**：`Seal/Core/Apps/InstalledAppScanner.swift`、`Seal/Core/Apps/InstalledAppRefreshProbePolicy.swift`、`Seal/Core/Signing/CertificateRevocationImpact.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Apps/AppsRootView.swift`、`Seal/Features/Settings/SigningCertificateSettingsView.swift`、`Seal/Features/Settings/LogViewerView.swift`、`Seal/Features/Settings/PairingSettingsView.swift`、`Seal/Core/Renewal/RenewalRoundSummary.swift`、`Seal/Core/Diagnostics/LogViewerPolicy.swift`、`Seal/Infrastructure/Pairing/PairingLiveActivityController.swift`、`SealTests/InstalledApps/InstalledAppRefreshProbePolicyTests.swift`、`SealTests/Settings/CertificateRevocationImpactTests.swift`、`SealTests/Diagnostics/LogRoundTests.swift`、`docs/upstream-alignment.md`、`project.yml`、`RELEASE_NOTES.md`、`DEBUG_LOG.md`。
- **CI 回归发现的编译问题**：SwiftUI `openURL` 的 completion 参数是 `Bool`，不能按 `OpenURLAction.Result` 匹配；改为 `false` 时跳转 App Store。`MFMailComposeViewControllerDelegate` 回调在当前 SDK 为主线程隔离，但协议导入仍是非隔离要求；Coordinator 使用 `@MainActor` 并对该 conformance 标记 `@preconcurrency`。
- **验证状态**：本机 Windows 无 Swift/Xcode；未本地运行测试或源码守卫。修改后按项目流程由 iOS CI 编译与回归；需要真机确认 LaunchServices 返回实装应用、邮件草稿附件、LocalDevVPN 深链回跳及灵动岛渲染。

# 2026-10-21 — CI 错误码清单未随源代码更新

- **现象**：CI `39469835734` 第 2 次尝试的 Swift/UI 回归与签名器测试通过；`build-package` 在 `Audit source error identifiers` 因生成清单与仓库版本不一致失败。
- **根因**：本批新增/调整的结构化错误引用改变了错误码出现次数和源码行号，`docs/qa/generated/error-code-inventory.json` 尚未重新生成。
- **修复**：按 CI 使用的命令重新生成 `docs/qa/generated/error-code-inventory.json`，更新错误码位置与统计。
- **涉及文件**：`docs/qa/generated/error-code-inventory.json`、`DEBUG_LOG.md`。
- **验证状态**：生成器输出 433 个标识符、843 个出现位置；当前 CI 的 Swift/UI 与签名器测试通过，构建守卫只因清单不同步失败。更新清单后需完整 CI 验证。

# 2026-10-21 — CI 安全守卫 R24 未登记新增的会话预检重试

- **现象**：CI `39463871785` 第 2 次尝试的 `build-package` 在 R24 失败：`withSessionRecovery` 调用数为 10，守卫仍要求 9。
- **根因**：本批新增签名/续签前的只读 Apple ID 会话核验，并正确通过 `withSessionRecovery(..., retriesOnTimeout: true)`；R24 逐操作列表和调用点总数未登记这条新读路径。
- **修复**：R24 明确点名“验证 Apple ID 会话”这一只读预检，并将核验后的调用点数更新为 10；保留原有九项 Portal 操作各自的断言。
- **涉及文件**：`Scripts/verify-release-safety.py`、`DEBUG_LOG.md`。
- **验证状态**：本机按项目规则不运行源码守卫；本轮签名器通过，R24 失败，Swift/UI 回归仍运行。补充断言后需 CI 验证。

# 2026-10-21 — CI 测试失败：图标样本 PNG 无效，导入抽屉覆盖子控件标识

- **现象**：CI `39460933848` 的 Swift/UI 回归中，图标解码用例因 PNG IDAT CRC 错误返回 `nil`；导入忙碌态 UI 用例找不到 `import-confirmation-dismiss-progress`。
- **根因**：图标用例内嵌的 1×1 PNG 数据本身损坏，不是 LaunchServices 解码器失败。导入抽屉把 `.accessibilityIdentifier("import-confirmation")` 直接挂在自定义抽屉根视图上，SwiftUI 测试树将根标识传播到 footer 按钮，遮住了按钮自己的稳定标识。
- **修复**：用 `UIGraphicsImageRenderer` 生成有效 PNG 测试样本；将导入抽屉显式设为 `.accessibilityElement(children: .contain)`，保留抽屉容器与按钮各自的无障碍标识。
- **涉及文件**：`SealTests/Recovery/InstalledAppScannerTests.swift`、`Seal/Features/Import/ImportConfirmationView.swift`、`DEBUG_LOG.md`。
- **验证状态**：本轮签名器测试通过；CI 跑到 Swift/UI 回归时上述两个测试失败，安全守卫仍运行。Windows 无 Swift/Xcode，修复提交后需重新跑 CI。

# 2026-10-21 — CI 编译失败：日志工具栏引用不存在的 glassButton

- **现象**：CI `39459487200` 的 `swift-regression` 编译 `LogViewerView.swift:53` 时失败，错误为 `some View` 没有 `glassButton` 成员。
- **根因**：日志工具栏调用了仓库中未定义的修饰符；现有玻璃表面入口是 `glassSurface(cornerRadius:)`，它已处理 iOS 26 系统玻璃与旧系统回退。
- **修复**：删除两处未定义调用，改用现有 `glassSurface(cornerRadius: 18)`，保持 36pt 工具栏按钮的圆形外观。
- **涉及文件**：`Seal/Features/Settings/LogViewerView.swift`、`DEBUG_LOG.md`。
- **验证状态**：本轮签名器测试通过；Swift/UI 回归因缺少修饰符导致编译失败，构建安全守卫仍运行。Windows 无 Swift/Xcode，修复提交后需重新跑 CI。

# 2026-10-21 — CI 编译失败：InstallFailureSettingsRoute switch 缺少返回值

- **现象**：CI `39457230977` 的 `swift-regression` 在编译 `InstallFailureSettingsRoute.swift:42–46` 时失败，未执行测试。
- **根因**：`route(for:)` 在前面执行了验证码路由判断后，末尾的 `switch` 不再是函数唯一表达式；分支只写枚举表达式，没有显式 `return`，因此每个成员及 `nil` 都失去返回类型上下文。
- **修复**：给每个 `failure.route` 分支补显式 `return`，保留现有导航映射与验证码优先路由。
- **涉及文件**：`Seal/Features/Settings/InstallFailureSettingsRoute.swift`、`DEBUG_LOG.md`。
- **验证状态**：本轮签名器测试通过；Swift/UI 回归因该编译错误失败，构建安全守卫仍运行。Windows 无 Swift/Xcode，修复提交后需重新跑 CI。

# 2026-10-21 — CI 编译失败：MainActor.run 闭包参数标签与 guard 语法

- **现象**：CI `39453521987` 与 `39455566660` 的 `swift-regression` 都在编译 `SigningCoordinator.swift:360` 时失败，测试未执行。
- **根因**：`MainActor.run` 的首个参数是 `resultType`，直接写 `MainActor.run({ ... })` 会把闭包传给错误参数而无法推断 `T`。仅改成尾随闭包后，在 `guard` 的逗号条件列表里又无法被正确解析。
- **修复**：显式使用 `MainActor.run(body: { ... })`，匹配当前 Swift 并发 API 的参数标签并保持 `guard` 语法明确；不改变 Seal 当前 Team / Bundle ID 身份核验逻辑。
- **涉及文件**：`Seal/Core/Signing/SigningCoordinator.swift`、`DEBUG_LOG.md`。
- **验证状态**：两轮完整 CI 的签名器测试通过；Swift/UI 回归均因该调用语法失败，构建安全守卫仍在运行；Windows 无 Swift/Xcode。显式 `body:` 修复提交后需重新跑 CI，未发布。

# 2026-10-20 — 批量续签误纳入设备扫回的第三方应用

- **现象**：重装 Seal 后由设备扫描恢复的第三方应用仍显示在“已安装”列表，但批量续签会把它们放入续签队列，并因缺 IPA 显示需要处理。
- **根因**：`RefreshPlanner.makeQueue` 只按 `belongsInInstalledList` 筛选；扫描恢复记录带有设备实际安装状态和 Apple 描述文件授权信息，却没有 Seal 签名提交时记录的实际证书序列号、签名设备标识。
- **修复**：新增 Seal 续签管理资格判据：Seal 自身，或同时具有映射 Bundle ID、Team ID、实际证书序列号、签名设备标识和 profile 到期时间的持久化签名记录。规划队列时先按该判据过滤；不依赖当前账号 UUID，因此原账号已删除但签名证据仍在的项目会留在队列并显示恢复账号操作。设备扫回应用仍按 `belongsInInstalledList` 留在已安装列表。
- **图标恢复**：设备扫描确认候选记录后，使用 LaunchServices 应用代理的 `iconDataForVariant:` 读取候选图标，只查询本轮扫回的 Bundle ID；将可解码图像写入对应 `Apps/<记录 ID>/Icon.png` 并保存 `iconRelativePath`。同时为已安装列表中图标路径缺失、文件丢失或不可读的记录补取图标，不要求本地 IPA；已有可读图标和手动选图不覆盖。补图标计入恢复摘要，启动维护在图标变更后重新加载应用记录。接口或数据格式不支持时只缺图标，不阻断记录恢复；之后重新导入 IPA 仍可用 IPA 图标补齐。
- **上游对照**：按 AltStore / SideStore 的管理列表边界，只续签 Seal 能确认归属的记录；见 `docs/upstream-alignment.md`。
- **回归覆盖**：更新续签规划测试，验证无签名证据的设备恢复记录仍属于已安装列表但不进入续签队列；缺少账号但保留完整 Seal 签名证据时仍显示为待处理。新增恢复集成用例，验证新扫回记录和已有无 IPA 记录都能从设备读取图标并持久化。
- **涉及文件**：`Seal/Core/Apps/AppRecord.swift`、`Seal/Core/Apps/InstalledAppScanner.swift`、`Seal/Core/Renewal/RefreshPlanner.swift`、`Seal/Core/Recovery/AppRecordRecovery.swift`、`Seal/Core/Recovery/InstalledRecordRecoveryPolicy.swift`、`Seal/Core/Maintenance/AppMaintenanceJob.swift`、`Seal/Infrastructure/Installation/DeviceInstalledAppScanner.swift`、`Seal/Infrastructure/Storage/AppFileStore.swift`、`SealTests/Renewal/RefreshPlannerTests.swift`、`SealTests/Renewal/PredictiveRenewalPolicyTests.swift`、`SealTests/Recovery/AppRecordRecoveryTests.swift`、`SealTests/Recovery/InstalledRecordRecoveryPolicyTests.swift`、`SealTests/Recovery/InstalledAppScannerTests.swift`、`docs/upstream-alignment.md`。
- **验证状态**：本机 Windows 无 Swift/Xcode；未运行测试或源码守卫，未推送、未启动 CI。图标读取走 iOS LaunchServices 私有接口，需在 iOS 17.4+ 真机确认能返回可解码数据；不可用时记录恢复仍继续，图标保留默认占位。

# 2026-10-20 — Apple ID 会话过期后没有接入已保存凭据恢复

- **现象**：Seal 更新后遇到 Apple 会话失效时，仍要求用户到「我的」重新验证；用户担心 Apple ID 登录资料在更新、签名或续签后丢失。
- **根因**：Apple ID 记录保存在应用容器，密码、authToken 与证书 P12 保存在系统 Keychain；`AccountSecret.password` 已加密保存，但 `AppleAccountClient.reauthenticate` 与 `AccountSecret.withNewSession` 没有生产调用点。签名 / 描述文件续签的只读 Team 请求在会话失效后仅退避并向上报错，没有尝试恢复已保存会话；团队查询还有 5 分钟缓存，可能把旧会话误判为有效；部分证书状态页还把会话失效误显示成证书无效。
- **修复**：签名、Seal/应用续签、Apple 证书与 App ID 同步及证书维护共用门户会话预检。预检绕过团队缓存，只读 Team 查询确认旧会话持续失效后，才用 Keychain 中已保存密码重新认证；验证仍是原 Apple ID 和原 Team 后，把新 token 写回 Keychain，并保留全部 P12、证书序列号和密码。2FA 不在签名/续签流程中等待验证码；Apple 要求验证码时，恢复按钮直达已有的账号验证表单。用户输入 Apple 六位码后，同一 Apple ID + Team 会合并到原账号记录、保留签名证书并更新会话。会话失效改为证书状态未知，不伪报证书无效。有效会话也会把遗留的瞬态 `needsVerification` 状态恢复为已验证。
- **上游对照**：AltStore / SideStore 未接入 1100 自动登录；Seal 按用户要求采用“Keychain 保存密码 + 只读校验后恢复”的路径，并避免重放已经进行过门户写入的签名事务。见 `docs/upstream-alignment.md`。
- **回归覆盖**：扩展重认证材料测试，核验新 token 与已保存密码更新时历史证书 P12 仍完整保留；新增 Team 列表缓存绕过测试；新增 2FA 失败必须打开账号验证表单的路由测试。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、`Seal/Infrastructure/Accounts/AppleAccountClient.swift`、`Seal/Infrastructure/Accounts/AppleAuthenticationDiagnosis.swift`、`Seal/Core/Accounts/AccountSecret.swift`、`Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Features/Settings/SettingsViewModel.swift`、`Seal/Features/Settings/InstallFailureSettingsRoute.swift`、`Seal/Features/Apps/SigningProgressView.swift`、`Seal/Application/AppContainer.swift`、`SealTests/Signing/SigningCertificateMaterialPolicyTests.swift`、`SealTests/Signing/PortalReadCacheTests.swift`、`SealTests/Settings/InstallFailureSettingsRouteTests.swift`、`SealTests/Accounts/AppleAuthenticationDiagnosisTests.swift`、`docs/upstream-alignment.md`。
- **验证状态**：本机 Windows 无 Swift/Xcode；未运行测试、源码守卫或 CI，未推送。需要 CI 编译回归及真机验证 1100 恢复、2FA 回退、签名/描述文件续签和 P12 保留。

# 2026-10-20 — Seal 更新身份丢失数据、启动状态未刷新与结果抽屉卡住

- **现象**：Seal 自更新重新签名安装后 Apple ID 列表丢失；重开后仍显示旧版本和“本机无私钥”，需要手动刷新；快捷指令续签完成后结果抽屉迟迟不显示，页面操作似乎被占用。更新下载缺少进度条；手动检查已是最新时无反馈。
- **根因**：① Seal 自更新只约束 Team ID，未核验目标 Bundle ID，且当前运行身份读取失败时会跳过约束；跨 Team 或 Bundle ID 的覆盖会改变 iOS 应用容器 / Keychain 访问组，既有账号与本机数据无法迁移。② 启动时自身记录、证书快照、设置和列表加载存在顺序空隙；③ 前台对快捷指令结果的打开请求在批次尚未结束时就被清除，之后没有可靠重试；④ 更新下载仅在服务器提供总长度时显示确定进度，缺少可见的进度条框架；⑤ 最新版本分支没有弹出确认。
- **修复**：Seal 自更新要求当前运行 Team ID、Bundle ID 可读，且签名账号 Team 与目标 Bundle ID都和运行包一致；同 Team 账号可用时自动沿用，否则阻止跨团队覆盖。新进程启动先同步自身记录并重载证书/账号快照，再加载设置与列表。快捷指令结果请求只有在抽屉成功呈现后才清除，批次结束后再发通知重试呈现。更新下载始终显示线性进度条；检查更新弹出“已是最新版本”。日志界面改为白底、最近 20 条终态结果和单行展示；“签名”“手动续签”“快捷指令续签”分别标记，标题右侧显示状态；成功标记为绿色、失败标记为红色 ×、未执行为橙色，有效期日期用中性色；总耗时按真实起止时间显示到 0.1 秒，失败详情可复制，原始错误不再单独重复显示。本机证书存在时隐藏其他证书及 Apple 服务器标签。新增 `SEAL-SELF-116`（运行身份无法读取）与 `SEAL-SELF-117`（更新包 Bundle ID 不一致）。
- **上游对照**：SideStore 的 `ResignAppOperation` 使用 `targetBundleIdentifier` 作为实际签名目标，并在重签 SideStore 自身时更新其证书材料；Seal 保留该身份驱动做法，同时在覆盖安装前增加当前运行 Team ID / Bundle ID 一致性门槛。详情见 `docs/upstream-alignment.md`。
- **涉及文件**：`Seal/Features/UpdateNoticeView.swift`、`Seal/Features/Settings/AboutView.swift`、`Seal/Features/Settings/SigningCertificateSettingsView.swift`、`Seal/Features/Settings/SettingsViewModel.swift`、`Seal/Features/Settings/LogViewerView.swift`、`Seal/Features/Apps/AppsRootView.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Core/Signing/SigningCoordinator.swift`、`project.yml`、`RELEASE_NOTES.md`、`docs/upstream-alignment.md`、`docs/qa/generated/error-code-inventory.json`。
- **验证状态**：未运行 Swift/Xcode、测试或源码守卫；未推送、未启动 CI。仅做本地源码与差异审查；完整 CI 和真机确认待后续执行。

# 2026-10-20 — 导入提交卡住时无法离开进度抽屉

- **现象**：IPA 文件/数据库提交卡住时，用户无法切换页面或操作其他功能。
- **根因**：导入提交阶段禁用了主操作和取消按钮，同时禁止下滑关闭；模态抽屉因此没有退出入口。
- **修复**：增加“收起并继续”按钮，只收起进度抽屉，当前导入事务继续完成或失败结算；不取消文件/数据库事务，也不放开设备写操作的串行保护。
- **涉及文件**：`Seal/Features/Import/ImportConfirmationView.swift`、`Seal/Features/Apps/AppsRootView.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`SealTests/Import/ImportProgressDismissalTests.swift`、`SealUITests/ImportFlowUITests.swift`。
- **验证状态**：新增模型与 UI 回归用例，分别验证收起后事务状态保留、用户可切换到「我的」；等待 iOS CI 编译和运行。

# 2026-10-20 — CI 修正日志结果文案的 Swift 编译错误

- **现象**：提交 `0e76a9f` 的 Swift 回归在编译 `LogViewerView.swift` 时失败，报告 `itemResultText` 缺少返回值。
- **根因**：多分支 `switch` 作为普通语句使用时，后三个单行分支没有显式 `return`；该函数不是 switch 表达式。
- **修复**：为失败、未执行和待确认分支补上显式返回，保持文案不变。
- **验证状态**：CI 首错已定位并修正；本地未运行 Swift/Xcode 测试，等待当前构建任务结束后推送并由新 CI 验证。

# 2026-10-20 — Seal 续签状态闪烁与操作日志卡片

- **现象**：Seal 描述文件续签后切换页面，列表短暂显示黄色“安装结果待确认”；诊断日志把轮次摘要和逐 App 技术明细混成大段文本，难以快速确认成功、失败、有效期和耗时。
- **根因**：① 列表把 Seal 暂态 `.awaitingVerification` 一律当成待确认安装，即使该状态没有真实设备安装尝试 ID；② 日志页直接显示拼接消息，没有消费已有的结构化续签轮次结果；③ 批次含“本轮未执行”项目时被标为 `.notFinal`，导致已经结束的部分结果整条被隐藏。
- **修复**：将安装反馈判据集中为纯展示策略：Seal 仅在存在 `installAttemptID` 时显示真实待确认，普通暂态不显示；失败与设备不可用提示保留。日志结果持久化结构化轮次，使用原生 SwiftUI 卡片显示记录时间、操作来源、App 名、结果、描述文件有效期和总耗时；隐藏与汇总重复的逐 App 续签诊断行。无待核验项目的部分结果按失败/未执行展示；Seal 自替换仍等待新进程核验，不提前报成功。兼容解析升级前的轮次文本。
- **涉及文件**：`Seal/Features/Apps/AppPresentation.swift`、`Seal/Features/Apps/ImportedAppRow.swift`、`Seal/Features/Apps/AppDetailView.swift`、`Seal/Core/Diagnostics/SealLogEntry.swift`、`Seal/Core/Diagnostics/LogViewerPolicy.swift`、`Seal/Core/Renewal/RenewalRoundSummary.swift`、`Seal/Core/Renewal/RenewalCoordinator.swift`、`Seal/Infrastructure/Diagnostics/SealLogStore.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Settings/LogViewerView.swift`、`SealTests/Apps/AppPresentationTests.swift`、`SealTests/Diagnostics/LogRoundTests.swift`。
- **验证状态**：补充了 Seal 暂态/真实安装尝试及部分续签轮次的回归用例；CI run `39409594293` 的 Swift 回归在编译 `itemResultText` 时发现缺少显式返回，修正与后续验证见紧邻台账条目。未在本机运行测试；真机确认待后续。

# 2026-10-20 — CI 错误码清单未随源码行号更新

- **现象**：静态安全守卫通过后，`build-package` 的 `Audit source error identifiers` 因生成文件 diff 失败。
- **根因**：前面的 Swift 源码修复改变了错误码出现位置，生成清单仍记录旧行号；错误码集合本身未变化。
- **修复**：执行工作流同一生成命令 `python Scripts/error_code_inventory.py --root . --output docs/qa/generated/error-code-inventory.json`，更新 431 个标识符的 835 个位置记录。
- **验证状态**：静态守卫已通过；Swift 回归仍在执行，更新生成清单后等待 CI 再验证。

# 2026-10-20 — CI 静态守卫误拒绝设备白名单清理

- **现象**：新 CI 的 Swift 回归、签名器测试通过，但 `build-package` 的 `R91⑨b` 失败。
- **根因**：签名路径新增主 App 和扩展的 `UISupportedDevices` 清理条件后，旧守卫仍要求 `purpose == .signing` 只出现两次；这两处清理只改变 IPA 设备白名单，不改变 App/扩展目标集合。
- **修复**：守卫现在精确允许瘦身、归一化和两处设备白名单清理；现有变异检查仍会拦住把目标筛选/映射步骤包入 `purpose` 的改动。
- **验证状态**：更新守卫后，CI 静态安全守卫通过；同一构建任务随后在生成的错误码清单 diff 失败，详见紧邻台账条目。未在本地运行守卫。

# 2026-10-20 — Seal 内日志页仅显示最近 20 条签名续签安装结果

- **需求**：Seal 内日志页只显示签名、续签、安装的成功与失败结果，最多最新 20 条；完整 `Seal-log.txt` 继续供开发者排障。
- **根因**：日志页之前直接呈现普通事件与诊断事件，操作进度、账号/系统事件和最终结果混在一起；单靠日志分类无法区分过程与终态。
- **修复**：日志事件增加可选终态字段；单项签名/续签、批量续签逐项结果、保存签名包安装与迟到安装结算明确写入成功/失败。页面按终态筛选、倒序取 20 条并显示结果标签；兼容升级前可识别的错误与成功结果。导出文件仍由完整日志缓冲生成。
- **涉及文件**：`Seal/Core/Diagnostics/SealLogEntry.swift`、`Seal/Core/Diagnostics/LogViewerPolicy.swift`、`Seal/Infrastructure/Diagnostics/SealLogStore.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Core/Renewal/RenewalCoordinator.swift`、`Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Core/Renewal/SelfAppRegistrar.swift`、`Seal/Features/Settings/LogViewerView.swift`、`SealTests/Diagnostics/LogRoundTests.swift`。
- **验证状态**：前两轮 CI 编译发现批量轮次 `append` 参数表达式及颜色 `switch` 漏处理 `.notFinal`，均已修复；最近一轮 Swift 回归和签名器测试通过，静态守卫误拒绝另一项合法改动，见紧邻台账条目。无需本地 Swift/Xcode 验证。

# 2026-10-20 — profile-only 结算、灵动岛图标、日志列表与 IPA 型号白名单

- **现象**：描述文件续签已由设备逐份读回确认，但已安装列表继续显示“安装结果待确认”；灵动岛展开态仍显示灰色图标；日志页只呈现续签轮次；Apple ID 的已签名 App 信息难读且按名称排序；歌一刀在 iPhone 上签名后仍被安装服务以设备型号不匹配拒绝。
- **根因**：① profile-only 路径提交了 pending 快照，却没有把安装记录状态从 `.awaitingVerification` 结算为 `.installed`；② 现有日志没有记录 Widget 对图片资源的运行时解析结果，虽然扩展资源已打包，实际读取仍落到灰色占位；③ 页面解析文本轮次并截取前 50 轮，普通事件日志不进入列表；④ App ID 行按名称排序且头部同时展示有效数与新建额度；⑤ 歌一刀虽声明 iPhone+iPad，`UISupportedDevices` 却只有 iPad 型号，导致 iPhone 安装被系统拒绝。
- **修复**：profile-only 确认后统一提交快照并将 `AppRecord.state` 与 `signedArtifactStatus` 设为 `.installed`；开始 Live Activity 时从主 App 的正式 `SealBrandIcon` 取最多 32px 图像并随静态 attributes 传给 Widget，必要时缩至 24px，保持 ActivityKit 数据限制内并保留扩展资源回退；日志页改为直接显示最近最多 1000 条事件并按时间倒序滚动；Apple ID 页面改成简短名额说明、按有效期升序、24 小时内日期标红；完整签名前从主 App 和 `.appex` 的 Info.plist 移除 App Store thinning 的 `UISupportedDevices`，保持设备系列、最低系统版本、架构和权限原样。若真实架构或系统版本不兼容，仍由 iOS 系统拒绝。
- **上游对照**：SideStore `RefreshAppOperation` 注入新 profiles 后更新已安装记录；上游不维护 `UISupportedDevices` 型号拒绝分支。Seal 保持设备安装服务的真实兼容判定，但不把 App Store 型号白名单带进自签产物。对照记录追加在 `docs/upstream-alignment.md`。
- **回归覆盖**：profile-only 续签从 `.awaitingVerification` 提交后转为已安装；IPA 主包与扩展移除型号白名单并保留 `UIDeviceFamily` / `MinimumOSVersion`；日志选择策略覆盖 1005 条混合普通与错误事件并只呈现最新 1000 条；Apple ID 过期排序与 24 小时标红；Live Activity 属性图标编码及旧活动无图标数据的兼容。
- **涉及文件**：`Seal/Core/Renewal/ProfileOnlyRenewalRecordUpdater.swift`、`Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Infrastructure/Signing/SigningWorkspace.swift`、`Seal/Features/Settings/LogViewerView.swift`、`Seal/Features/Settings/SettingsViewModel.swift`、`Seal/Core/Diagnostics/LogViewerPolicy.swift`、`Seal/Features/Settings/AppleAccountDetailView.swift`、`Shared/PairingActivityAttributes.swift`、`Seal/Infrastructure/Pairing/PairingLiveActivityController.swift`、`SealLiveActivity/PairingLiveActivityWidget.swift`、`SealTests/`、`Scripts/verify-release-safety.py`、`docs/upstream-alignment.md`。
- **验证状态**：新增 Swift 回归测试并更新 R123 源码守卫；未在 Windows 本机运行 Swift/Xcode 或守卫。待 CI 编译/回归以及真机重新开始一轮配对、profile-only 续签和歌一刀当前设备安装验证；尚未推送。

# 2026-10-20 — CI 对齐 IPA 路径与更新抽屉源码守卫

- **现象**：CI run `39377682080` 的 release-safety guard 有两项源码断言失败，并报告三个 mutation anchor missing。
- **根因与修复**：R121 仍假定 ZIP 路径解码写在 `IPAParserService`，而实现已抽到 `IPAArchivePathPolicy` 并由导入、签名解包共用；R120 仍匹配独立 About sheet、旧 `updateNotice` 属性和固定 `.large` detent，而当前实现由 `UpdatePresentationCoordinator` 统一呈现，About 页请求同一 coordinator，drawer 按内容测量并受 `.large` 上限约束。更新守卫本体与变异锚点，让它们验证当前真实链路。
- **验证状态**：Swift 回归和签名器测试已通过；CI 因 R120/R121 源码守卫及旧变异锚点失败。守卫修正待新 CI 验证；本地不运行源码守卫。

# 2026-10-20 — CI 修正重导入覆盖回归测试的草稿类型

- **现象**：CI run `39376489641` 编译回归测试时，`InstalledRecordRecoveryPolicyTests.swift` 把 `InstalledAppDraft` 传给只接受 profile `Draft` 的 `makeRecord(..., installedOnDevice:)` 重载，类型不匹配。
- **根因与修复**：该用例的草稿来自已安装设备清单，且测试夹具已标记为 profile validated；应调用接收 `InstalledAppDraft` 的记录恢复重载。保留重导入后命中原记录的断言，删除不适用的 `installedOnDevice` 参数。
- **验证状态**：之前的签名器测试通过；本次 Swift 回归在该编译错误处失败。修复待后续 CI 验证；本地不运行 Swift/Xcode 或源码守卫。

# 2026-10-20 — CI 修正 Apple ID 到期日展示编译错误

- **现象**：修复 AltSign 重复静态链接后，CI run `39375671383` 的 Swift 回归继续报错：`AppleAccountDetailView.swift:445` 对非 Optional `Date` 使用 `if let`。
- **根因与修复**：`SigningTargetRecord.profileExpirationDate` 定义为必填 `Date`；页面逻辑误把它当成可选值。精确匹配目标后直接返回其有效期即可；缺少签名目标的 fallback 仍按原顺序查本地 App 记录与 Apple 返回值。
- **验证状态**：签名器测试通过；Swift 回归失败已定位并修正，等待新 CI 编译验证。包构建 job 尚未结束；本地不运行 Swift/Xcode 或源码守卫。

# 2026-10-20 — CI 修正 AltSign 静态库重复链接

- **现象**：CI `swift-regression` 在 SwiftPM/Xcode 构建阶段以 exit 65 失败，提示 `AltSign-Static` 同时由 `SealTests` 和 `Seal` 静态链接，导致库代码重复。
- **根因与修复**：为直接测试 `ALTAppID` JSON 日期解析而给 `SealTests` 新增了 AltSign 静态产品依赖；`SealTests` 本来依赖 `Seal`，而 `Seal` 已链接该产品。移除测试 target 上重复的 AltSign 链接，保留回归用例和 `import AltSign`，避免重复打包同一静态库。
- **验证状态**：签名器测试已通过；当前 CI 的 Swift 回归失败已定位，修复待下一次 CI 验证。构建/发布 job 尚未结束；本地不运行 Swift/Xcode 或源码守卫。

# 2026-10-20 — 日志排障规范与 CI 发布门

- **需求**：用户要求日志内容按企业级规范设计，明确应记录什么、开发者如何定位错误，以及是否记录每次点击。
- **结论**：日志是本地排障事件流，不是点击遥测。记录有业务结果的操作开始/结束、关键状态与路线决策、外部边界结果/耗时、重试/取消/恢复和失败诊断；不记录页面导航、键盘输入、重复进度回调或每次轮询。导出需包含构建标识、稳定错误码、操作时间和脱敏底层原因；用户反馈附操作名称与大致时间。
- **修改**：新增 `docs/qa/logging-standard.md` 规定记录边界、字段、级别、脱敏和排查顺序；日志页增加导出与错误码使用指引。现有 `SealLogEntry` 仍以文本为主，`ImportFailure.diagnosticID` 尚未贯穿全部日志，文档将其明确列为按主链路增量接入的缺口，不声称已完成结构化关联。
- **CI 安全门**：用户当前提供的项目规则要求 push 只跑 CI、发布仅由人工 dispatch 显式触发；检查发现 `ios.yml` 仍会在 push 全绿后自动发布并同步官网。已恢复手动发布门，同步调整发布守卫与 `AGENTS.md`，让本次 push 不会触发 Release 或官网同步。
- **验证状态**：待 CI 执行工作流守卫、Swift 回归、签名器测试与 IPA 构建；本机 Windows 不运行 Swift/Xcode 或发布守卫。源码 ZIP 备份留在工作区，不纳入提交。

# 2026-10-20 — 重装恢复、IPA 路径、Apple App ID、缓存清理与 Seal 续签闭环

- **现象**：Seal 重装后扫回的已安装 App 缺少身份资料，重导入原 IPA 被当成 Bundle ID 冲突；部分 ZIP 路径的 IPA 在导入阶段找不到主程序；Apple ID 已签名 App 列表漏掉 Apple 返回的 App ID/名称；缓存清理后签名工作区仍占用统计空间；Seal 已完成本机接管后仍反复完整重签。
- **根因与修复**：① 多份设备描述文件匹配同一应用时，旧恢复逻辑把精确 App ID profile 与覆盖范围更广的 wildcard profile 一起算成歧义；现在优先精确 profile，再对剩余候选按 Team 及每个字段分别求一致值。映射 Bundle ID 可还原并命中重导入覆盖策略，不会从不同 profile 拼出一份虚构身份。② IPA 解析器与签名解包器原先独立选择 ZIP 路径编码；现在共用 `IPAArchivePathPolicy`，依据 `CFBundleExecutable` 是否命中选择同一编码，并限制预读 Info.plist 的实际解压字节数。③ Apple 返回的 `expirationDate` 在日志中的 JSON 响应是 ISO-8601 字符串，AltSign 的 `ALTAppID` 只尝试 `Date` cast，导致日期变成 nil；App ID 同步和页面随后又把 nil 当成过期而过滤。现在 AltSign 同时解析 plist Date 与 JSON ISO-8601 字符串，Seal 保留 Apple 未给日期的 App ID，名称/门户 App ID 使用 Apple 原值，签名身份和有效期优先用本地真实 profile。④ 统计把 `Caches/Seal` 全部计入临时缓存，清理只删 `Temp`；设置清理现在清同一缓存根，安装后清理按 app ID 只删当前工作区和共享暂存区。⑤ 自替换确认和运行包对账只写 `signedArtifactStatus`，没有把 `AppRecord.state` 从 `.signed` 转成 `.installed`；准入因此以“缺少已安装产物”持续回落。Log34 先报本机无私钥，之后又报本机有私钥但仍选完整重签；这说明钥匙获取与续签准入状态是两个问题。现在确认运行中的 Seal 后恢复 `.installed`，新结算也同步写状态；不放宽身份、扩展或待更新源准入。
- **设备兼容与样本复核**：当前源码没有按 `UIDeviceFamily`、`UISupportedDevices` 或最低系统版本在签名前拦截的逻辑；已提供的歌一刀 IPA 声明 `UIDeviceFamily = [1, 2]`、最低系统版本 14.0。直接检查 ZIP 中心目录发现包内路径是 UTF-8 但未设置 UTF-8 标志，Info.plist 指定的中文主程序条目实际存在且路径字节吻合；`Seal-log(34)` 没有导入失败码或设备族拒绝记录。因此没有证据支持设备族规则导致失败，iOS 负责最终安装兼容性判断。其他导入失败也未出现在该日志，仍需对应 IPA 和失败提示才能定根因。
- **回归覆盖**：精确 profile 优先于 wildcard；同 Team 多个精确 profile 只恢复彼此一致的字段，并可按原始 Bundle ID 命中重导入覆盖记录。Seal 启动对账与自替换结算把 `.signed` 变为 `.installed` 并允许 live identity 走 profile-only；Apple JSON ISO-8601 到期日解析、nil 到期 App ID 保留、门户名称/ID/日期回显；清理统计中的 Signing/Exports 缓存，并验证安装后只清当前 app 工作区。中文 ZIP 未标 UTF-8 用例继续覆盖导入与解包共享策略，另覆盖没有 UTF-8 Archive 时的默认路径选择。
- **涉及文件**：`Seal/Core/Recovery/InstalledRecordRecoveryPolicy.swift`、`Seal/Core/Import/IPAParserService.swift`、`Seal/Core/Import/IPAArchivePathPolicy.swift`、`Seal/Infrastructure/Signing/SigningWorkspace.swift`、`upstream/AltSign/Sources/Model/ALTAppID.swift`、`Seal/Core/Renewal/SelfAppRegistrar.swift`、`Seal/Infrastructure/Signing/ApplePortalInventoryService.swift`、`Seal/Features/Settings/AppleAccountDetailView.swift`、`Seal/Infrastructure/Storage/AppFileStore.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`project.yml`、`docs/upstream-alignment.md` 与对应测试。
- **验证状态**：回归用例已补；本机 Windows 无 Swift/Xcode 工具链，不运行本地测试；`git diff --check` 已通过，待 CI 验证。指定 IPA 的实际导入和设备续签仍待真机复验。

# 2026-10-20 更新检查优先级与抽屉按内容适配

- **现象**：启动 Seal 后有新版时不会稳定自动弹出；“关于 Seal”页有独立检查状态，和启动更新抽屉不是同一条呈现链路；更新抽屉高度固定，短内容留白、长内容可能占满屏幕并影响操作区。
- **根因**：启动检查等待页面与签名/导入状态，检查结果还可能在 sheet 真正呈现前被记录为已通知；About 页另有独立状态。更新抽屉虽复用 `SealDrawer`，但 sheet 高度仍使用固定大尺寸。
- **修复**：新增共享更新协调器，启动和 About 共用检查状态与抽屉；只在抽屉实际出现后记录版本，失败时前台退避重试。更新抽屉优先于外观设置呈现并隐藏底部标签栏；基于共享抽屉的标题、内容和 footer 实测高度选择 detent，超出屏幕上限时保留滚动内容区。
- **涉及文件**：`Seal/Infrastructure/UpdateChecker.swift`、`Seal/Infrastructure/UpdatePresentationCoordinator.swift`、`Seal/DesignSystem/SealDrawer.swift`、`Seal/Features/UpdateNoticeView.swift`、`Seal/Features/Settings/AboutView.swift`、`Seal/Features/Settings/SettingsRootView.swift`、`Seal/App/RootTabView.swift`、`project.yml`、`RELEASE_NOTES.md`。
- **验证状态**：`git diff --check` 通过，旧启动检查状态和 `.suppressed` 引用已清除；本机 Windows 不支持 Swift/Xcode 编译，待 CI 验证。真机自动弹出、抽屉高度与滚动仍待验收。

# 2026-10-20 CI 全绿后自动发布 Release

- **需求**：用户明确要求当前成功构建要发布，今后完整 CI 通过后自动发布。
- **修改**：`ios.yml` 的发布 job 在 `build-package`、`swift-regression`、`signer-tests` 全部成功后由 push 自动触发；手动 dispatch 仍需 `publish_release=true`。同一版本 tag 已存在时明确失败并要求 bump 版本，避免重复发布。`ios-release.yml` 快速发布档仍为手动触发。
- **守卫与项目约定**：发布安全守卫现在分别钉住完整 CI push 自动发布、dispatch 显式开关、快速档手动门及重复 tag 拒绝；同步更新 `AGENTS.md`。
- **验证状态**：待 CI 运行安全守卫、变异自检、构建、Swift 回归、签名器测试，并在全绿后自动发布 v0.1.39；本机不运行发布守卫或 Xcode 测试。

# 2026-10-20 Seal 重装后重复完整接管与灵动岛图标读取

- **现象**：Seal 已完成本机证书接管后，卸载重装再续签仍可能再次完整重签；灵动岛品牌位仍显示灰色占位。
- **根因**：首次接管判定本身不是“首次安装”标记，而是按当前账号 UUID 从 Keychain 读取匹配 P12。`Accounts.json` 与 `Seal.sqlite` 都位于应用容器；卸载后重加 Apple ID 会生成新 UUID，旧 Keychain secret 仍可能留在同一访问组，却不会出现在当前账号列表中。`SigningCoordinator` 和证书页因此都把已有本机证书判成缺失。另，0.1.37 IPA 中扩展含 `SealBrandIcon.png` 和 `Assets.car`；Widget 原先优先直接解码 PNG 文件，资源实际存在但仍可走到不稳定的运行期图像路径。
- **修复**：`KeychainVault.loadAllSecrets()` 枚举当前应用可读的账号条目；续签预测/执行与证书页都按 Seal 运行签名者的序列号验证 P12，旧 UUID 不再导致重复接管。灵动岛图标改为优先从扩展 Asset Catalog 加载，原始 PNG 仍作回退。新增两条纯策略回归用例覆盖旧 UUID 下有/无匹配私钥；发布守卫 R125 钉住全量查询及两个消费点，R119 加入 Asset Catalog 优先级检查。
- **上游对照**：SideStore 的 profile-only refresh 依据已安装应用签名身份，不要求本地 P12；Seal 保留首次接管的一次完整重签，只修正重装后账号 UUID 索引丢失造成的假阴性，详见 `docs/upstream-alignment.md`。
- **涉及文件**：`Seal/Infrastructure/Security/KeychainVault.swift`、`Seal/Core/Renewal/SelfSigningIdentity.swift`、`Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Features/Settings/SettingsViewModel.swift`、`SealLiveActivity/PairingLiveActivityWidget.swift`、对应回归测试、发布守卫、版本、`RELEASE_NOTES.md`、上游对照台账与本日志。
- **验证状态**：已检查桌面 0.1.37 IPA，扩展目录确实同时含 `SealBrandIcon.png` 与 `Assets.car`；源 PNG 正确显示 Seal 图案。CI #78 的 Swift 回归、签名器测试、发布安全守卫、错误标识审计及 IPA 构建/校验均通过；IPA 上传因远端 `project.yml` 保留 CRLF、版本生成文件名带 `\r` 失败，现将配置 blob 规范化为 LF 后重跑。图标真机显示和重装后续签仍待设备验收。

## 2026-10-20 CI 修正 About 更新抽屉编译

- **现象**：CI #74 的 `swift-regression` 在 `AboutView.swift` 报 `Expected ')' in expression list`，并连带把后续静态图标方法解析成类型外声明。
- **根因与修复**：诊断落在更新 sheet 的视图内容闭包。将尾随 `content` 闭包改为显式 `content:` 参数，保留与启动更新一致的 `UpdateNoticeView` 和大尺寸 sheet 呈现。
- **CI #75**：Swift 回归与签名器测试通过。发布守卫仍按 About 页旧式单行 `.sheet` 匹配；`R119⑤` 变异检查期望了不存在的编号，`R125①–③` 期望子编号但共用 `R125` 断言，且 R120 变异锚点也未随 sheet 语法更新。同步修改源码断言、变异锚点与预期编号。
- **CI #76**：Swift 回归、签名器测试及发布安全守卫通过；错误标识审计失败，因为改动让 `SigningCoordinator.swift` 与 `SettingsViewModel.swift` 中多处标识的行号后移。按工作流精确命令重新生成清单，现为 431 个标识、835 处。
- **CI #77**：Swift 回归、签名器测试及发布安全守卫通过；错误标识审计仍失败，远端清单 blob 保留了 Windows CRLF，而 macOS 生成器输出 LF，导致 `git diff --exit-code` 把整份文件判为变化。错误行号已对齐；上传前将日志与清单统一转为 LF。
- **CI #78**：Swift 回归、签名器测试、发布安全守卫、错误标识审计及 IPA 构建/校验通过；两个 artifact 上传步骤失败，远端 `project.yml` blob 中的 CRLF 使版本提取值带尾随 `\r`，生成 `/Seal_0.1.39\r.ipa`，与实际产物名不符。修复是将该配置 blob 统一为 LF，再重跑完整工作流。
- **验证状态**：等待 CI 验证规范化后的 IPA artifact 上传；本机没有 Swift/Xcode 工具链。

## 2026-10-20 更新抽屉改用签名抽屉容器

- **现象**：0.1.37“关于 Seal”页打开更新抽屉时，导航栏遮住抽屉标题，底部标签栏盖住下载按钮。
- **根因**：手动更新路径在 `AboutView` 内容内部用自绘 `.overlay`；系统导航栏与 Tab 栏位于它上层。启动更新虽在 `RootTabView`，也使用不同的 overlay 抽屉实现。0.1.37 只调整几何与滚动内容，没有统一呈现容器。
- **修复**：更新内容改为复用签名抽屉使用的 `SealDrawer`；手动检查与启动检查均由原生大尺寸 `.sheet` 呈现，使用同一滚动区、固定底部操作区和圆角背景。下载、验证及自动交接阶段禁止手势收起，下载取消按钮保持可用；IPA 导入等抽屉完整收起后再开始。
- **回归守卫**：更新抽屉必须实例化 `SealDrawer`；About 页和启动更新都必须用大尺寸原生 sheet 呈现。为两处旧 overlay 与私有自绘容器添加 R120 变异检查。
- **涉及文件**：`Seal/Features/UpdateNoticeView.swift`、`Seal/Features/Settings/AboutView.swift`、`Seal/App/RootTabView.swift`、`Scripts/verify-release-safety.py`、`project.yml`、`RELEASE_NOTES.md`。
- **验证状态**：待 CI 编译、Swift 回归及 R120 守卫验证；真机需确认更新抽屉与签名抽屉的层级、滚动、下载取消和下载完成交接一致。未声称已通过。

## 2026-10-20 更新下载进度、跨团队 App Group 与设备兼容性拦截

- **现象**：更新抽屉下载时没有之前设计的传输进度；0.1.36 日志中 LiveContainer 的历史 App ID 可复用且无需新建，但完整签名仍失败；“歌一刀”被签名前置检查以设备型号不匹配拒绝。
- **证据与根因**：`URLSession.download(for:)` 没有传入 `ProgressDownloadDelegate`，因此 `didWriteData` 没有绑定到该异步下载任务，进度视图一直停在初始不确定态。LiveContainer 的门户失败不是 App ID 重复/额度：Apple 拒绝 Seal 创建 IPA 原值 `group.com.SideStore.SideStore`，而本团队 App Group 列表已有团队后缀形式。另，`SigningCoordinator` 在门户请求前用 `UISupportedDevices` 和 `MinimumOSVersion` 主动拒绝签名。
- **修复**：任务调用显式传 `delegate`，抽屉显示下载百分比与容量；读取团队已有 App Group 列表，对已有本团队组原样复用，其他组映射为团队后缀并在请求 entitlements、App Group 分配、profile 校验中共用；删除按设备列表与最低系统版本提前拒签的逻辑。设备实际安装由系统裁决。
- **Seal 续签**：当前 0.1.36 源码已有按运行包真实签名者构造 Seal 实时身份的通道；同一签名证书的扩展可继承主 Team，签名者或已读 Team 不一致仍回落完整重签。本次新增同签名身份且本机私钥可用时保持 profile-only 的回归用例。`Seal-log(32)` 没有 Seal 续签操作，不能用该文件证明真机续签路径已通过。
- **灵动岛**：0.1.36 IPA 已含扩展根目录的 `SealBrandIcon.png`，当前扩展代码也直接读取该资源并请求全彩渲染；日志没有 Live Activity 资源读取或渲染记录，因此暂时无法从这份日志定位灰色占位的运行期原因，本批不把它记作已修复。
- **回归覆盖**：下载进度分数、App Group 团队映射、Seal 已接管后的 profile-only 判据；发布守卫增加进度代理绑定、设备声明不前置拦截、App Group 映射三项检查与变异。
- **涉及文件**：更新下载器与抽屉、App Group 策略及 Portal 签名服务、IPA parser 与签名协调器、续签测试、发布守卫、错误码清单、版本、更新说明、上游对齐台账。
- **CI 追修**：首轮签名器用例通过；Swift 6 回归发现 `ALTAppGroup` 模型数组被 `withSessionRecovery` 闭包捕获。第二轮改成不可变数组快照后仍失败，因为 `ALTAppGroup` 本身不符合 `Sendable`。改为跨重试边界只保留 `[String]` 组标识；需要 Apple 模型对象时在 App Group 分配操作内部重新读取，并让该操作返回 `Void`，不再将模型数组返回给外层。
- **CI 第三轮**：Swift 回归仍在运行时，构建 job 的 R24 守卫先失败：App Group 已有组读取增加了一个退避重试入口，但守卫仍固定为 8 个调用点。同步加入“读取 App Groups”的逐项断言、变异检查与 9 点计数。
- **验证状态**：Windows 工具链不支持本机 Swift/Xcode 编译，未本地运行测试或发布守卫；第三轮等待 Swift 回归结果，后续 CI 再验证 R24 更新。真实描述文件续签、下载进度和灵动岛图标仍需设备验收。

## 2026-10-19 CI 验收修正：闭包返回、守卫变异与 IPA 夹具编译

- **现象**：首轮 CI（39258430026）Swift 回归编译失败；R120 守卫变异未能触发断言。修正后第二轮 CI（39261893803）再次在 IPA 测试夹具编译失败，并发现源错误码清单中的行号已过期。
- **根因**：`ProfileOnlyRenewalPolicy.liveIdentity` 的 `allSatisfy` 闭包加入局部 `let` 后仍依赖单表达式隐式返回；R120 变异注入的 `ScrollView {}` 与守卫统计的 `ScrollView(` 形态不匹配；IPA fixture 的 ZIP 目录尾部搜索表达式过复杂，Swift 编译器无法完成类型检查；`IPAParserService.swift` 行数变化后未重生成错误码位置清单。
- **修复**：在闭包中显式 `return`；变异用例改为 `ScrollView(showsIndicators: false)` 以确实增加嵌套滚动视图；将 ZIP 目录尾部查找拆成倒序循环；使用工作流同一命令重生成 `docs/qa/generated/error-code-inventory.json`（433 个标识、839 处）。
- **CI 追修**：第三轮完整 CI（39265000490）通过。正式 Release 构建（39268452198）在 `PairingLiveActivityController.finish()` 报 Swift 6.2 数据竞争错误：主线程隔离的 `Activity` 直接传给并发的 `end()`。按同文件现有 `update()` 做法，在等待上一操作后把句柄仅传给 ActivityKit `end()`。
- **验证状态**：R120 守卫、Swift 回归、签名器测试、错误码清单审计与完整 unsigned IPA 构建均已在 CI 通过；Release 守卫及静态审计通过，但 Release 构建被上述 Swift 并发错误挡住。已修正 `end()` 调用，待下一轮 Release CI 验证。错误码清单用工作流同一命令生成（433 个标识、839 处），`git diff --check` 通过；未在本机运行 Swift/Xcode 测试或项目守卫，Release 尚未发布。

## 2026-10-19 ZIP 编码、续签实时身份与更新抽屉布局回归

- **现象**：0.1.35 的 `Seal-log(30)` 记录到设备已有当前签名私钥，但 Seal 续签仍出现完整重签；另有中文名称 IPA 提示 `CFBundleExecutable` 不存在、更新抽屉露出底部标签栏并截断长更新说明、配对灵动岛仍显示灰块图标。
- **源码根因**：① `canSafelyIdentifySigners` 允许 CMS 签名者可读但缺少 profile 的扩展目标，`ProfileOnlyRenewalPolicy.liveIdentity` 却要求每个目标必须有 Team ID，致身份构造可因空扩展 Team 失败并回落完整重签；日志未记录目标级身份，不能断言本次 Seal 的具体回落由此触发。② IPA 路径直接使用 ZIPFoundation 默认编码；用户 IPA 中中文路径以 UTF-8 存储但 ZIP UTF-8 标志位未设置，默认 CP437 路径无法匹配主程序名。③ 更新抽屉被限制在安全区几何范围、最大 700pt，更新说明又额外套 190pt 内层滚动区。④ Live Activity 只按资产目录名称创建 `Image`，设备仍显示占位图。
- **修复**：缺少 Team 的扩展只在 CMS 序列号与主程序一致时继承主 Team；已知 Team / 签名者不一致仍拒绝。IPA 全部条目路径强制按 UTF-8 解码，并通过清除 ZIP UTF-8 标志的中文可执行文件 fixture 覆盖导入路径；主程序加密检测不变。更新抽屉扩展到安全区外、提高高度并只保留主滚动区，版本标题从正文条目中过滤。灵动岛从扩展包的现有 PNG 文件资源直接加载，资产名解析保留为回退。
- **回归用例**：覆盖无 profile 扩展可沿用匹配签名者身份、已知 Team 冲突仍拒绝、ZIP UTF-8 标志缺失仍按 Info.plist 主程序导入、更新正文版本标题去重；发布守卫同步钉住路径解码、资源加载和抽屉滚动结构。
- **涉及文件**：续签策略与测试、IPA parser 与 fixture、更新内容策略和抽屉、Live Activity Widget 与扩展资源、发布守卫、版本与更新说明、上游对齐台账。
- **验证状态**：Windows 环境不运行 Swift/Xcode 测试和项目守卫；待 CI 编译、回归、守卫及真机灵动岛显示验证。日志未能确定 20:30 的 Seal 完整重签究竟由哪个实时 target 字段触发，因此修复按已证实的代码不一致补齐，不把它当作已证明的单次运行因果。

## 2026-10-19 灵动岛品牌行被胶囊遮挡及已签名 App 名称冗余

- **现象**：灵动岛配对活动的 Seal 图标显示灰色占位或未显示，品牌名称与配对状态文字挤在胶囊边缘；Apple ID 证书的已签名 App 列表每个应用名前还重复显示“应用名称”。
- **根因**：品牌行被放在灵动岛 leading/trailing 区域和紧凑胶囊里；图标资源虽已随扩展打包，图片初始化却未明确绑定扩展资源包。已签名 App 行复用了带字段标题的通用详情行。
- **修复**：把 Seal 图标、Seal 名称和配对状态合并到展开内容区底部及锁屏卡片的品牌行；胶囊仅保留配对码或状态图形。图标明确从 Live Activity 扩展自己的 `SealBrandIcon` 彩色资源加载，保留 WidgetKit 全彩渲染并增至 24 pt。已签名 App 行直接显示应用名，其他字段行不变。
- **回归守卫**：R119①–④ 检查品牌状态行的位置与内容、胶囊不再显示品牌文案、已签名 App 行没有“应用名称”标签，以及扩展资源和全彩设置仍存在。
- **涉及文件**：`SealLiveActivity/PairingLiveActivityWidget.swift`、`Seal/Features/Settings/AppleAccountDetailView.swift`、`Scripts/verify-release-safety.py`、本日志、`RELEASE_NOTES.md`。
- **验证状态**：尚未运行 Swift/Xcode 测试、发布守卫或真机检查；Windows 无 Xcode/Swift 工具链。本次仅做本地源码与 diff 检查，不推送。

## 2026-10-19 重装 Seal 后恢复的 Folia 无法通过重导入接管

- **现象**：重装 Seal 后设备扫描恢复 Folia 记录，但本地没有原始 IPA/图标；续签因缺少 IPA 失败。重新导入原始 IPA 后又生成新记录，签名时与设备上原 Folia 的 Bundle ID 冲突。
- **根因**：生产设备扫描路径的 `InstalledAppDraft` 只保存设备实际 Bundle ID；`makeRecord` 又把它同时写入原始与 mapped ID。对于 `app.folia.major.seal.<TeamID>`，导入的原始 `app.folia.major` 因而匹配不到恢复记录。旧恢复服务还把 IPA 路径记为空串，文件存在性检查会把 Documents 目录误当作 IPA，拦截同版本重导入。
- **修复**：扫描恢复草稿同时保留原始 Bundle ID；优先使用唯一匹配描述文件的 Team，否则只在后缀精确匹配本机已知 Team 时还原 `.seal.<TeamID>` / `.<TeamID>`。mapped ID 仍保持设备实际值。导入判据兼容已保存的旧恢复记录，允许原始 IPA 按可信 Team 或历史 `.seal.<TeamID>` 标记接管修复；移除列表加载中的旧并发扫描，统一由启动维护恢复。导入的 IPA 图标可通过既有替换记录映射显示在已安装列表。
- **回归用例**：覆盖 Folia 风格的已知 Team 映射 ID 还原、未知 Team 不剥离、新旧恢复记录都能被原始 IPA 接管、空 IPA 路径仍进入恢复导入；发布守卫覆盖恢复身份、存量修复和单一恢复入口。
- **涉及文件**：`Seal/Core/Recovery/InstalledRecordRecoveryPolicy.swift`、`Seal/Core/Import/ImportReplacementPolicy.swift`、`Seal/Core/Import/ImportWorkflow.swift`、`Seal/Features/Apps/AppsViewModel.swift`、相关回归测试、`Scripts/verify-release-safety.py`、`RELEASE_NOTES.md`。
- **验证状态**：尚未运行 Swift/Xcode 测试或发布守卫；Windows 无 Xcode/Swift 工具链，按项目约定交由 CI 编译和回归。本次只做本地 diff 检查，不推送。

## 2026-10-19 首次电脑签名安装后的本机私钥接管

- **现象**：电脑签名安装 Seal 后，证书页显示没有本机私钥；点击续签只更新描述文件，运行签名者与本机私钥状态一直不变，Seal 无法接管自己的证书。
- **根因**：`ProfileOnlyRenewalPolicy` 刻意允许没有本机私钥的应用走 profile-only。Seal 的运行身份可读时也使用这条通用准入，因此从未触发一次会生成本机私钥的完整签名。
- **修复**：新增纯函数 `SelfSigningBootstrapPolicy`。只有 Seal 当前运行签名者序列号可读且没有匹配的可解析 P12 时，预测侧将 Seal 从批量 profile-only 并行组排除，执行侧将其续签改为完整重签并安装；证书页仅显示“请重新签名 Seal 获取本机私钥”状态，签名身份与本机私钥匹配后隐藏自管理卡，只显示证书卡。普通应用和已接管 Seal 保留描述文件续签。
- **上游对照**：SideStore 的 `VerifyCertificateOperation(willResign: false)` 允许本地无私钥时继续核验并刷新描述文件；Seal 保留该通用机制，仅为首次本机接管增加 Seal 专属的一次完整重签。详见 `docs/upstream-alignment.md`。
- **涉及文件**：`Seal/Core/Renewal/SelfSigningIdentity.swift`、`Seal/Core/Renewal/ProfileOnlyRenewalPolicy.swift`、`Seal/Core/Signing/SigningCoordinator.swift`、证书页与展示状态、`SealTests/Settings/SelfManagementPresentationTests.swift`、`Scripts/verify-release-safety.py`、`project.yml`、`RELEASE_NOTES.md`、`docs/upstream-alignment.md`、本日志。
- **验证状态**：已添加 bootstrap 判据、证书页可见性回归用例，以及 R85/R117 源码守卫和变异用例；尚未运行 Swift/Xcode 测试、项目守卫、CI 或真机验证。当前仅做本地静态 diff 检查；本次不推送。

## 2026-10-19 更新 IPA 后恢复已安装应用图标

- **现象**：设备扫描回来的已安装记录没有可读图标时显示默认图标；重新导入 IPA 后，待签名记录有新图标，但「应用-已安装」与证书页清单仍按旧记录 ID 取图，无法恢复。
- **根因**：更新 IPA 与原已安装应用是两条记录，图标分别按记录 ID 加载；更新记录还可能继承已失效的自定义图标路径，遮住新 IPA 图标路径。
- **修复**：图标加载在首选图标路径不可读时回退到 IPA 图标路径；当已安装记录无图时，用其 `replacesInstalledAppID` 对应的待签名更新记录补图。证书页显示对应图标，无图源时显示默认 App 图标。
- **涉及文件**：`Seal/Core/Apps/AppIconDataResolver.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Settings/SettingsViewModel.swift`、`Seal/Features/Settings/SigningCertificateSettingsView.swift`、`SealTests/Apps/AppIconDataResolverTests.swift`。
- **验证状态**：已添加映射、保留已有图标和失效首选路径回退的回归用例；Windows 无 Xcode/Swift 工具链，待 CI 编译、回归和守卫验证。

## 2026-10-19 CI #57 Seal 记录回退放行不完整身份

- **现象**：CI #57 的 Swift 回归中，Seal 实时身份缺失或 Bundle ID 不匹配时，两个 `ProfileOnlyRenewalPolicyTests` 仍得到 `.eligible`，预期为完整重签；构建与签名器任务通过。
- **根因**：实时身份通道拒绝后调用通用记录判定；该判定只要求安装状态、Team、证书序列号和主 Bundle ID，没有确认 Seal 记录中的签名设备标识、目标快照与已签名产物。
- **修复**：Seal 的记录通道要求持久签名身份、已装签名产物及当前全部目标记录；缺字段时回落完整重签。实时身份完整时仍直接放行，普通应用的可清理 `Signed.ipa` 缓存规则不变。
- **涉及文件**：`Seal/Core/Renewal/ProfileOnlyRenewalPolicy.swift`、`SealTests/Renewal/ProfileOnlyRenewalPolicyTests.swift`、`Scripts/verify-release-safety.py`、`docs/upstream-alignment.md`、`RELEASE_NOTES.md`、`project.yml`。
- **验证状态**：CI #57 首次暴露；CI #58 中 Swift 回归、签名器测试通过，但 R82① 旧守卫把受限的 Seal 记录完整性分支误判为身份一刀切。CI #59 中 Swift 回归、签名器测试再次通过，守卫本身通过，但 R82④ 两个变异用例仍匹配旧错误说明；已同步预期文案，并为已签名产物门槛新增变异检查，待完整 iOS CI 重跑。Windows 无 Xcode/Swift 工具链，不在本机运行测试或项目守卫。

## 2026-10-19 14:51:16 CI #56 失败复盘：待提交签名快照未持久化

- **现象**：CI #56 的发布守卫 R82④、R85② 使用了过期断言；Swift 回归中手动签名产物安装因 `SEAL-INSTALL-719` 被拒，待提交的 profile 到期日没有进入安装校验记录。协议页 UI 回归也失败，当前改动未涉及协议页，等待本轮新 CI 判断是否复现。
- **根因**：`CoreDataAppStore` 从未编码或解码 `AppRecord.pendingSignedSnapshot`；保存后取出的记录丢失候选快照。两条守卫的生产规则已更新，但变异期望仍有一条旧文案，R85 还检查旧 Swift 绑定形式。
- **修复**：在当前 Core Data 模型增加可选快照数据字段；保存时编码、读取时解码，损坏快照按损坏记录失败；补充 SQLite 重开持久化测试，为 0.1.32 旧模型加入 V3 迁移快照和迁移回归。更新两条守卫到当前生产实现，并将主 App 和 Live Activity 版本推进到 `0.1.33`。
- **上游对照**：SideStore 在安装与续签流程中将 profile 等元数据写入应用目录，没有 Seal 的 pending → committed 快照事务；不照搬其存储形态，保留 Seal 的安装验证与两阶段提交边界。详见 `docs/upstream-alignment.md`。
- **涉及**：`Seal/Infrastructure/Persistence/CoreDataModel.swift`、`Seal/Infrastructure/Persistence/CoreDataAppStore.swift`、Core Data 持久化和迁移测试、`Scripts/verify-release-safety.py`、`docs/upstream-alignment.md`、`RELEASE_NOTES.md`、`project.yml`、本日志。
- **验证**：修复待由 GitHub CI 编译、守卫与回归测试验证；Windows 本机不运行 Swift 构建或项目守卫。之后按 CI 结果继续修复并推送。

## 2026-10-19 13:52:08 发布守卫按当前续签与标识符规则校准

- **问题**：CI #54 的 R85 旧规则修正后，快速静态检查又发现 8 项守卫仍按旧策略拦截：强制读取旧扩展分配记录、把 App Group ID 再映射、把旧设备标识当续签门槛，以及要求 Seal 记录不完整就必须重签。它们与现在按 Apple 当前状态和 IPA 实际权限续签的实现不一致。
- **修改**：更新发布守卫与对应变异用例，使共享/独立分配由 IPA 当前权限决定、profile-only 续签可从旧记录恢复目标、App Group 保留 IPA 原始值、Seal 可用实时签名身份补足记录、设备核验使用本轮设备标识。将已停用的 `SEAL-PROFILE-364` 从活动码表移到历史码表；重命名旧策略测试以准确表达当前行为。
- **验证**：发布守卫 835 项静态检查 0 失败；针对本轮修改的 10 个守卫变异均被正确拦截；Python 语法检查与 `git diff --check` 通过。Swift/Xcode 构建由 GitHub CI 验证。
- **文件**：`Scripts/verify-release-safety.py`、`SealTests/Renewal/ProfileOnlyRenewalPolicyTests.swift`、`docs/qa/log-code-index.md`、`docs/qa/generated/error-code-inventory.json`、本日志。

## 2026-10-19 13:40:19 CI 发布守卫与 Swift 编译错误修复

- **问题**：CI #54 的 `build-package` 在 Swift 编译前被发布守卫拦截。日志指向 `Scripts/verify-release-safety.py` 的 R85 检查仍要求 `localCertificateMaterialBlock()` 和错误码 `SEAL-PROFILE-364`；另一个并行测试发现两处默认参数使用 `Self.minimumFreshProfileLifetime`，Swift 报 covariant `Self` 不能用于默认值。
- **修改**：把 R85 静态检查与变异用例改为验证新规则：本机私钥仅用于状态说明；profile-only 准入不因缺少本机私钥降级；证书按 Apple 当前证书清单核验。`SEAL-PROFILE-364` 标为停用历史码。两处默认参数改为类型限定的 `ApplePortalSigningService.minimumFreshProfileLifetime`。
- **验证**：Python 守卫脚本语法检查与 `git diff --check` 通过；CI #54 的签名器测试通过，Swift 编译和发布守卫失败，修复后需再次推送触发完整 CI。
- **文件**：`Scripts/verify-release-safety.py`、`docs/qa/log-code-index.md`、本日志及续签状态文案注释。

## 2026-10-19 13:26:25 IPA 资源、标识符与更新版本规则对齐 Apple

- **问题**：Seal 对 IPA 解压总量设 8 GB 默认上限，Bundle ID / App Group ID 会被写入 Seal 自定义格式；更新版本过滤规则也需要明确按 Apple 的版本格式执行。
- **修改**：移除 IPA 解压总体积上限，不把 App Store Connect 的上传大小限制套到本地侧载；仍保留整数溢出、压缩包路径、条目数量、元数据读取及真实磁盘空间检查。移除 Bundle ID 的 Seal 前缀/扩展哈希生成；App Group ID 直接使用 IPA 声明值，不猜测并改写既有后缀。更新标签限定为三段 ASCII 数字格式，按最新正式发布及 Apple 数字版本比较，允许跨主、次版本升级且不设补丁号上限；版本比较改为字符串位数比较，避免 Int 溢出。
- **兼容性**：主 Bundle ID 使用签名面板中的实际输入；原扩展 ID 若隶属原主 ID，则保留它的后缀并映射到用户输入的主 ID；无可确认层级关系时保留原扩展 ID。旧 IPA 中已存在的标识符按原值保留，不做猜测式迁移，以免改变 App Group 容器身份。
- **涉及**：`Seal/Core/Configuration/AppConfiguration.swift`、`Seal/Core/Import/ArchiveLimits.swift`、`Seal/Core/Import/IPAParserService.swift`、`Seal/Core/Signing/BundleIDMapper.swift`、`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、`Seal/Infrastructure/Signing/SigningWorkspace.swift`、`Seal/Infrastructure/UpdateChecker.swift`、`Seal/Infrastructure/Version.swift`、相关测试、`docs/upstream-alignment.md`、`RELEASE_NOTES.md`。
- **验证**：错误码清单生成成功（434 个 ID / 840 处）；`git diff --check` 通过。当前 Windows 环境没有 Swift 编译器，Swift 测试未运行；仍需目标仓库 CI 编译和设备验证。

## 2026-10-19 12:55:16 续签准入与 Apple 实际状态对齐

- **问题**：旧续签准入把本机私钥、旧 profile UUID、旧设备 ID、历史扩展 profile 拓扑和完整 target 快照当作必须条件；并在 Apple 缺少旧 App ID 时拒绝进入标准注册流程。它们中多项是 Seal 内部快照，不是 Apple 对本轮 profile 的最终裁决。
- **修改**：`ProfileOnlyRenewalPolicy` 只保留应用 Team、当前签名证书、主 Bundle ID 和可确认扩展目标等必要身份；Team 与证书序列号字段缺失时，分别优先从当前安装身份和唯一旧主 profile 证书信息恢复。旧权限快照缺失时改从原始 IPA 重建；profile-only 按实际 entitlement 键和值重新分配可共享/需独立的扩展。Apple 当前证书清单不再包含已安装签名者时，自动切换完整签名。缺少真正无法恢复的二进制目标或原始 IPA 时仍明确失败，避免假报续签成功。
- **同处冲突处理**：策略层与协调层对 profile-only 的 Team 判定已统一优先采用当前安装身份；本机私钥提示不再宣称必定完整重签。普通 IPA 的 Mach-O 完整签名仍需要私钥，这是不同操作链路，未放宽。
- **未改范围**：完整 Mach-O 签名仍需有效私钥；Apple 返回的团队、证书、App ID、设备和 entitlement 约束仍生效。
- **涉及**：`Seal/Core/Renewal/ProfileOnlyRenewalPolicy.swift`、`Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、续签策略测试、`Seal/Features/Apps/AppDetailView.swift`、`Seal/Features/Apps/SigningProgressView.swift`、`docs/upstream-alignment.md`。
- **验证**：静态 diff / 引用检查进行中；Windows 无 Swift 编译环境，未运行 Swift 测试，需 GitHub CI 与真机 Apple ID 续签验证。

## 2026-10-19 10:59:25 更新检查、安装快照、续签分配与恢复导入修复

- **更新检查**：未认证 GitHub REST API 会被出口 IP 限流；改从公开 Releases Atom 读取最新正式发布，并按 Apple 三段数字版本比较，允许跨主、次版本更新且不限制补丁号。历史记录中的“仅当前主版本.次版本”限制已由本条覆盖。
- **签名后安装**：签名结果先保存在 `pendingSignedSnapshot`；安装校验现在用待提交快照副本核对描述文件和证书，只有安装成功才提交到已安装记录。
- **恢复记录重导入**：仅当已安装记录标记 `needsIPAImport` 时，允许用它的签名后 Bundle ID 匹配恢复记录；普通副本的原始 Bundle ID 匹配规则不变。
- **描述文件续签**：独立扩展集合从主应用与扩展的实际 profile UUID 关系推导；完整重签迁移只由目标或 profile 记录缺失/不一致触发，不再因旧策略字段缺失或不一致触发。
- **测试**：新增更新序列、恢复记录匹配、pending 快照安装及策略标签过期回归用例；Windows 环境无法本地编译 Swift，待 GitHub CI 验证。

## 2026-10-19 10:27:04 更新检查被 GitHub REST API 限流

- **现象**：0.1.29 手动检查更新显示请求次数过多，未弹出 0.1.30 更新抽屉。
- **证据与根因**：旧检查器请求未认证的 `api.github.com/releases/latest`；该接口按出口 IP 限额。复核时该 API 返回 `403 API rate limit exceeded`，而公开 Releases Atom 页可读取，v0.1.30 Release 与 IPA / SHA256 附件均存在。
- **修复**：0.1.31 改为从公开 Releases Atom 页读取版本和正文，再从 GitHub 附件页提取唯一可信 IPA 与校验文件；保留原有版本比较、域名校验和 SHA256 校验，不增加重试冷却或签名限制。
- **兼容性边界**：已安装的 0.1.29 已把 REST API 地址编译进二进制，服务器无法改写其检查地址；需要等该出口额度恢复、切换未受限网络，或手动安装修复版后，后续更新才走新链路。
- **版本与验证**：版本推进到 `0.1.31`；Windows 不执行 Swift 本地编译，待当前仓库 GitHub CI 编译与回归。

## 2026-10-19 09:49:22 CI #52 IPA 版本校验未覆盖灵动岛扩展

- **证据**：CI #52 的回归、签名器和打包任务均通过；解包其 IPA 后，主应用为 `0.1.29 (52)`，`SealLiveActivity.appex` 却为 `1.0`。
- **根因**：XcodeGen 按 `project.yml` 的 `info.properties` 重新生成扩展 Info.plist；该列表只含 `NSExtension`，没有显式列出版本键，因此扩展使用默认版本。源 `SealLiveActivity/Info.plist` 中的变量声明不能补回未列入生成属性的键。
- **修复**：在扩展生成属性中加入 `CFBundleShortVersionString` 和 `CFBundleVersion`；扩展已存在时，IPA 守卫解包双方 Info.plist 并核对营销版本与构建号，阻止版本不一致的产物通过。
- **版本与验证**：推进到 `0.1.30`；待下一轮云 CI 验证编译、回归、打包及版本一致性守卫。

## 2026-10-19 09:19:27 CI #51 夹具重复主程序条目与错误码清单行号

- **证据**：Swift 回归 968 项中 3 项失败，均在解压夹具时因 Payload/<App>.app/<Executable> 被写入两次而报 Cocoa 516；错误码清单检查另发现 AppExtensionProfileStrategy.swift 插入一行后两处引用行号仍旧。
- **根因与修复**：IPAArchiveFixture.make 在 includeInfo 分支已加入主可执行文件，includeMobileProvision 分支又重复添加；移除第二次写入，描述文件逻辑不变。重新生成 error-code-inventory.json 同步实际行号。
- **验证与版本**：0.1.29；本地差异检查通过，CI #51 的其余 965 项通过，修复后等待 CI 重跑完整回归。

## 2026-10-19 07:31:36 CI #50 共享权限比较 guard 缺少退出语句

- **证据**：swift-regression 定位 AppExtensionProfileStrategy.swift:142，guard else 记录不兼容权限后未退出当前循环迭代。
- **修复**：补 continue，保留该扩展的完整不兼容权限集合并继续比较后续权限；不把权限不兼容当作共享成功。
- **检查与版本**：定向扫描 Seal Swift 中 guard else 分支未发现另一个无退出语句的同类项；0.1.28，编译及回归仍以 CI 为准。

## 2026-10-19 07:16:27 CI #49 遗留灵动岛清理的隔离边界

- **证据**：swift-regression 定位 PairingLiveActivityController.swift:31，主线程隔离的 Activity 对象传给非隔离异步 end 接口被 Swift 6 拒绝。
- **修复**：endOrphanedActivities 不读取控制器状态，标为 nonisolated，在同一非隔离调用内枚举系统活动并结束，避免将主线程持有的活动句柄跨隔离传递；不降低并发检查、不改 UI 与状态流。
- **API 核对**：Apple ActivityKit end(_:dismissalPolicy:) 允许异步结束活动，使用 immediate 清除旧活动。https://developer.apple.com/documentation/activitykit/activity/end(_:dismissalpolicy:)
- **版本与验证**：0.1.27；待 CI 编译及真机重启后清理残留活动验证。

## 2026-10-19 06:59:26 CI #48 权限缓存跨异步闭包缺少 Sendable 键

- **证据**：swift-regression 定位 ApplePortalSigningService.swift:2648、2659，cachedEntitlements 在 updateFeatures 与 assignAppGroups 的恢复闭包之间传递有数据竞争风险。
- **根因**：缓存值已为 any Sendable，但字典键 ALTEntitlement 为公共结构且未声明 Sendable；真实定义仅含 let rawValue: String。
- **修复**：在 upstream/AltSign/Sources/ALTCapabilities.swift 为 ALTEntitlement 增加编译器检查的 Sendable 遵循，不使用 unchecked、不降低 Swift 6 并发检查、不改变权限内容。
- **版本与验证**：0.1.26；待 CI 验证权限更新与 App Groups 两个调用点编译通过。

## 2026-10-19 06:44:23 CI #47 证书恢复错误构造参数不匹配

- **证据**：swift-regression 编译定位 SigningCoordinator.swift:365，Self.failure 不接收 title 参数。
- **修复**：仅该自定义标题分支直接构造 ImportFailure，保留标题、原因、恢复建议及 SEAL-CERT-240a，不改变证书恢复处理逻辑。
- **版本与验证**：0.1.25；本地差异检查与错误码清单同步，Swift 编译待 CI。

## 2026-10-19 06:29:17 CI #46 列表状态反馈漏写返回

- **证据**：swift-regression 编译定位 ImportedAppRow.swift:219–222，sealWarning/sealDanger 与 nil 无法推断返回类型。
- **根因与修复**：installedInstallFeedback 在前置 if 后使用了未返回的 switch；补为 return switch，保持安装待确认、失败与设备不可用反馈不变。
- **验证与版本**：本地差异检查通过，版本递增为 0.1.24；Swift 编译与回归交 CI；此前扩展共享和数量动态处理改动全部保留。

## 2026-10-19 06:09:11 CI #45 三处 Swift 类型错误

- **证据**：swift-regression 日志定位 AppleAccountDetailView.swift:405 的重复 Optional 解包，以及 ApplePortalSigningService.swift:1280 的不存在类型 ALTCapabilities、:2537 的可空权限字典实参。
- **修复**：完整 App ID 读取只解包一次；按 upstream/AltSign/Sources/ALTCapabilities.swift 中真实声明使用 ALTEntitlement.applicationIdentifier；缓存未命中时使用 throwing readEntitlements 读取，不伪造空权限。
- **版本与验证**：合入待推 0.1.23；本地仅差异检查与生成错误码清单，Swift 编译交 CI。

## 2026-10-19 06:06:57 扩展数量不作固定假设

- **要求与核对**：IPA 可含零个、一个或多个扩展；实际处理遍历解析出的完整 Bundle ID 集合，不按示例中的三个扩展截断，也不新增数量上限。
- **验证补充**：参数化测试覆盖 0、1、3、9、12 个扩展，全兼容时全部共享；最后一个扩展需要额外权限时，仅它独立。测试待 CI 执行。

## 2026-10-19 06:01:03 全部应用按实际能力共享扩展描述文件

- **要求**：用户明确取消应用名称特例，含 Seal、LiveContainer 在内，能共享的全部共享。
- **证据**：LiveContainer 官方 main 的主应用 entitlements.xml 已含 LiveProcess 使用的内存、HealthKit 与 App Groups；LaunchAppExtension、ShareExtension 的声明为相同 App Groups。历史版本的 LiveProcess 特例不能替代实际 IPA 判断。
- **修复**：defaultFor 不再按 isSeal/isLiveContainer 强制独立；完整签名统一从共享策略开始，按权限键、值及 App Groups 计算不兼容扩展；旧记录只在 profile-only 续签时保留既有拓扑，完整重签重新分配并落盘。
- **验证**：增加三个 LC 扩展全部共享、仅 LiveProcess 需独立两种数据断言；保留旧独立记录续签策略测试；同步 CI 检查及变异锚点，未本地运行完整守卫。
- **版本**：0.1.23，待与 CI 修复一起推送并验证；不把上游权限相同当作真机安装已通过。

## 2026-10-19 05:51:36 后台续签快捷指令状态契约修复

- **证据**：CI #44 的 Swift 编译报告 SealRenewalIntentOutcome 不存在 accepted 成员。
- **根因**：入口已按 BackgroundRenewalAdmission.accepted 映射并反馈已接收请求，但结果枚举仍残留旧 started 命名。
- **修复**：结果枚举统一为 accepted；保留 busy、notReady 及原反馈，不把请求接收误称为续签已完成或已启动。
- **版本与验证**：版本递增至 0.1.22；待 CI 编译及快捷指令实机验收。

## 2026-10-19 05:35:55 迟到安装回调 Result 类型修复

- **证据**：CI #43 的 Swift 编译在 HardTimeout、BlockingCall、InstallChannel、MinimuxerInstallChannel 和 SigningCoordinator 报 String 不遵循 Error。
- **根因**：Result 的 Failure 泛型必须实现 Error，不能直接使用 String；回调从通用超时层贯穿安装结算，导致同根因多处编译失败。
- **修复**：共用 HardTimeout.LateCompletionError，显式遵循 Error、Sendable、CustomStringConvertible；两处错误归一化保留原字符串；所有回调签名及 HardTimeoutTests 同步。
- **版本与验证**：版本递增为 0.1.21；仅修类型契约，超时、取消、迟到成功/失败的结算流程保持现有实现，待 CI 编译和回归。

## 2026-10-19 05:21:05 导入编译与 RustBridge 源码检查修复

- **证据**：CI #42 签名器测试及完整 release safety 检查通过；iOS 编译因 ImportWorkflow.swift 第 103 行调用以右花括号收尾而级联报错；RustBridge 源码审计命中配对取消单测的 expect。
- **修复**：调用收尾改为右圆括号；existing 已在前文 guard 解包，移除重复的可选绑定并按 String 读取版本和构建号；配对单测通过 Result 和 ? 返回失败，仍保留令牌共享、取消、释放断言。
- **验证与版本**：ImportWorkflow 的快速语法解析通过；iOS 类型检查及完整回归仍交 CI；版本递增为 0.1.20。

## 2026-10-19 04:57:48 手机配对接口与 CI 自检修复

- **证据**：CI #41 的 iOS 回归编译报告 Minimuxer.swift 缺少 cancellationToken 参数。
- **根因**：RustBridge 和 Seal 的调用端已接入取消令牌，中间的 Minimuxer 封装未同步；Seal 还通过不存在的 Minimuxer.RustIdevice 路径引用底层接口。
- **修复**：Minimuxer 显式接收并转交 cancellationToken，公开现有取消令牌操作及错误类型；PhonePairingHost 统一通过 Minimuxer 封装调用。
- **CI 自检**：#41 剩余三项变异检查未捕获错误，根因是跨函数或跨构造器搜索被其它正确分支满足；改为定位 desiredFeatureKeys 并分别验证两个恢复构造器。旧恢复构造器同步补 needsIPAImport 状态及断言。
- **版本与验证**：版本递增至 0.1.19；上轮签名器测试已通过，本次接口变更待 CI 编译与真机配对验证。

## 2026-10-19 04:37:29 CI 失败修复与守卫同步

- **问题**：CI 的 iOS 编译在 `SideSign/AppBundle.swift` 因 `Any` 不满足 Swift 6 `Sendable` 失败；release safety 检查和变异样例仍引用旧实现，另有 AppRecord 参数顺序问题。
- **修复**：entitlements 直接解析为 `[String: any Sendable]`；修正恢复记录参数顺序；缺少 IPA 只在 profile-only 不可用时拦截；普通扩展默认共享、LiveContainer 独立；让守卫按当前签名、撤销恢复、注入排队和扫描链路检查。
- **版本**：主 App 与 Live Activity 的 marketing version 同步为 `0.1.18`；构建号保持现状。
- **验证**：Swift 编译、回归测试及更新后的 CI 守卫待云端构建验证；本机 Windows 无法编译 iOS 项目。

## 2026-10-19 02:33:44 全面审计代码修复批次

- **范围**：按 `D:\Seal_Develop\Research\Audits\Seal-0.1.15-20261018\run-1\REPORT-updated.md` 逐项处理 F01–F32；V01–V08 保留为需要真机、Apple 账号或系统测量的验证项，不伪称已通过。
- **签名与证书**：证书撤销恢复任务先持久化；扩展共享按权限键和值判定；Mach-O/权限解析失败明确报错；Apple 拒绝必要能力时停止签名；不再静默删目标。
- **安装、续签与恢复**：确定性设备不兼容错误只尝试一次；显式可判定时在申请 Apple 资源前拦截；profile-only 注入/读回维持设备临界区；安装超时保留 attempt 并核对迟到结果；自替换超时进入有限恢复。
- **账号、配对与页面**：认证恢复改为有界组合；配对 listener 可取消并在启动时清理孤儿活动；扩展/已签名 App 身份展示和同版本恢复按真实记录处理。
- **灵动岛资源与排版**：展开态品牌/状态改用系统 leading/trailing 区，配对正文使用 bottom 区；IPA 守卫要求 Live Activity 扩展含 `Assets.car`，避免资源目录未打包仍交付。
- **存储、更新与其他**：更新任务按 generation 隔离；下载源与导入事务关联；数据库及签名 IPA 备份可启动恢复；后台入口返回真实接纳状态；撤销、导出、图标回滚、许可清单与 CI 触发路径已逐项处理。
- **本次补缺**：SideSign 真正执行签名时改用 throwing entitlement reader，非法 plist 不再退化成空权限；增加空权限/有效权限/损坏 plist 单测。
- **版本**：主 App 与 Live Activity 的 marketing version 同步为 `0.1.17`；构建号保持现状。
- **验证状态**：错误码索引为 435 个标识符 / 846 次出现；Python 检查共 20 项通过，但本机测试未运行在隔离环境，仅作初步结果。Windows 没有 Xcode，`cargo fmt` 也未安装；Swift/Rust CI、Apple Portal 与动态岛需外部验证。未提交、未推送、未触发 CI。

## 2026-10-18 23:24:01 审计首批修复：安装拒绝分类、恢复材料与 CI 触发

- **现象**：明确的 `DeviceNotSupportedByThinning` 被当作可重试错误；撤销证书失败会从当前列表隐藏证书；CI push 路径漏掉共享模型和 Live Activity；签名包替换及 Core Data 迁移中断可能丢失恢复备份。
- **根因**：终态错误词表缺少设备不支持的安装变体；失败分支仍调用本地 dismissal；工作流路径未覆盖两个编译目录；迁移备份无条件清理且 `Signed.ipa` 替换没有启动恢复。
- **修复**：将不支持 thinning 的错误设为终态且显示设备兼容提示；撤销失败保留证书；补齐 CI 路径；迁移后验证 Core Data store，恢复失败保留备份，并在记录恢复阶段恢复/清理 Signed.ipa 事务残留。
- **涉及文件**：`.github/workflows/ios.yml`、`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`、`Seal/Features/Settings/SettingsViewModel.swift`、`Seal/Infrastructure/Persistence/CoreDataAppStore.swift`、`Seal/Infrastructure/Storage/AppFileStore.swift`、`Seal/Core/Recovery/AppRecordRecovery.swift`、对应 `SealTests`、`project.yml`、`RELEASE_NOTES.md`。
- **版本**：`0.1.16`，主 App 与 Live Activity target 同步。
- **验证**：新增终态分类与两种 Signed.ipa 中断恢复测试，并扩展 Core Data 迁移成功清理检查；`git diff --check` 通过。Windows 无法编译 Swift，CI 与真机验证待执行。

## 2026-10-18 18:28:39 Seal 自身详情缺少扩展记录

- **现象**：签名安装 Seal 后打开应用详情，扩展区域显示为空。
- **根因**：详情页只读 `AppRecord.extensions`；Seal 首次登记只沿用旧记录中的扩展，同版本启动对账也没有从运行包补回扩展。
- **修复**：读取已安装 Seal 的 `PlugIns/*.appex/Info.plist`，结合运行包签名身份生成扩展记录；首次登记和同版本对账都会写入，保留已有扩展记录 ID 与原始 Bundle ID。
- **涉及文件**：`Seal/Core/Renewal/SelfAppMetadata.swift`、`Seal/Core/Renewal/SelfAppRegistrar.swift`、`SealTests/Renewal/SelfAppRegistrarTests.swift`、`project.yml`、`RELEASE_NOTES.md`。
- **版本**：`0.1.15`，主 App 与 Live Activity target 同步。
- **验证**：新增运行包扩展读取及同版本补回单测；本机无法编译 Swift，云 CI 和实机显示待验证。

## 2026-10-18 17:50:48 灵动岛 Seal 图标使用圆角方形

- **改动**：Seal 图标维持 20pt 尺寸和全彩，增加 4pt 连续圆角裁切，外观与应用图标一致。
- **涉及文件**：`SealLiveActivity/PairingLiveActivityWidget.swift`、`RELEASE_NOTES.md`。
- **验证**：`git diff --check` 通过；最终外观待云 CI 和真机复验。

## 2026-10-18 17:46:05 灵动岛展开态顶行被胶囊遮挡

- **现象**：实机展开灵动岛时，左侧 Seal 图标和标题、右侧配对状态都被中间胶囊遮挡。
- **根因**：品牌与状态分别放在 `.leading` / `.trailing` 区域；`.belowIfTooWide` 只在内容过宽时下移，不保证顶行始终避开摄像头区域。
- **修复**：移除展开态顶部两侧区域，将图标、Seal 和状态排成一行放进 `.bottom` 区域，配对说明位于其下；紧凑态与锁屏布局不变。
- **验证**：布局按 Apple 提供的 expanded `.bottom` 区域实现；`git diff --check` 通过，Swift 编译及实机四状态遮挡检查待云 CI/设备验证。

## 2026-10-18 17:39:21 灵动岛图标在实机被系统渲染成黑灰色

- **现象**：实机上的 Seal 灵动岛图标呈黑灰色；源码中的品牌 PNG 是蓝底白色，且 `.renderingMode(.original)` 未阻止系统强调色渲染。
- **根因**：iOS 18 及以上 WidgetKit 强调色模式会重映射图像颜色；仅设置 SwiftUI 的 `.original` 没有明确声明 WidgetKit 图像应保留全彩。
- **修复**：对 iOS 18 及以上的品牌图像加 `.widgetAccentedRenderingMode(.fullColor)`，旧系统继续使用原图；未替换图片资产。
- **验证**：检查主 App 与 Live Activity 资源均为相同的彩色 PNG；Apple 文档确认 `.fullColor` 可禁止强调色模式改写图像颜色。编译和实机显示效果待云 CI 与设备复验。

## 2026-10-18 17:36:19 灵动岛配对状态无法可靠返回与收尾

- **现象**：等待配对码时点灵动岛会提前结束活动；配对完成/失败后活动句柄已丢失，点回 Seal 无法立即移除；通知回退点击不进入设备页，通知权限请求与发码存在竞态；展开态右侧状态可能被灵动岛遮挡。
- **根因**：所有状态点击都走同一无条件清理；终态结束后立即清空 Activity 句柄；通知代理只处理续签通知；Live Activity 不可用时异步请求通知权限后立刻启动配对。
- **修复**：配对中点击只导航并保留活动，成功/失败才立即结束；串行化码更新与终态结束，自动超时仍由 ActivityKit 负责；通知授权通过后才启动备用配对，通知点击通过一次性路由回设备页；统一灵动岛与锁屏的四态内容，并保留原色 Seal 图标。
- **涉及文件**：`Shared/PairingActivityAttributes.swift`、`Seal/Infrastructure/Pairing/PairingLiveActivityController.swift`、`SealLiveActivity/PairingLiveActivityWidget.swift`、`Seal/Infrastructure/Pairing/PairingCodeNotification.swift`、`Seal/Infrastructure/Notifications/SealNotificationPresenter.swift`、`Seal/Features/Settings/SettingsViewModel.swift`、`Seal/App/RootTabView.swift`、`SealTests/Pairing/PhonePairingPresentationPolicyTests.swift`、`project.yml`、`RELEASE_NOTES.md`。
- **版本**：`0.1.14`，主 App 与 Live Activity target 同步。
- **验证**：配对终态与通知路由判据新增单测；源码/差异检查通过后由 `MJorb-0.1.0` 云 CI 编译；真实设备需回归紧凑态六码、展开态四状态、锁屏、通知回退和返回收尾。

## 2026-10-18 17:03:23 待安装与已安装分页手势未驱动标签动画

- **现象**：实机横向滑动页面时，下划线没有随手指连续移动，标签颜色也没有过渡；点击标签和页面位置可能各自改变。
- **根因**：原实现用 SwiftUI 几何偏好值间接回传水平滚动位置，标签点击又直接写入动画进度，页面与指示器存在两个进度来源。
- **修复**：横向页面改用 UIKit 原生分页滚动视图，按真实 `contentOffset / pageWidth` 连续发布进度；点击标签只更新目标页，由同一分页器执行切换。分页保留原有 SwiftUI 页面、各页纵向滚动与下拉刷新，并启用系统分页吸附和边界回弹。进度状态单独观察，避免每帧手势都重建应用列表。
- **涉及文件**：`Seal/Features/Apps/NativeAppsPager.swift`、`Seal/Features/Apps/AppsRootView.swift`、`Seal/DesignSystem/CaterpillarSegmentedTabs.swift`、`project.yml`、`RELEASE_NOTES.md`、`docs/qa/generated/error-code-inventory.json`。
- **版本**：`0.1.13`，主 App 与 Live Activity target 同步。
- **验证**：错误码索引已重新生成，`git diff --check` 通过。Windows 无 Xcode，Swift 编译与实机慢拖、快滑、回弹、点击标签、纵向滚动/下拉刷新均待 GitHub CI 和真机验证。

## 2026-10-18 14:49:50 CI 错误码索引未随源代码行号更新

- **现象**：CI 的错误码审计单测通过，但生成文件对比失败，阻断打包。
- **根因**：源码行号已变化，提交中的错误码清单仍保留旧位置；本次审计发现 428 个标识、813 处引用，语义内容没有新增错误。
- **修复**：使用项目生成脚本重新生成 docs/qa/generated/error-code-inventory.json，使索引行号与当前源码一致。
- **验证**：生成器报告 428 个标识、813 处引用；git diff --check 通过；待 CI 复验。

## 2026-10-18 14:25:30 CI 中文路径回归与自保护守卫判据过期

- **现象**：CI 中中文 IPA 路径回归测试失败；自替换恢复策略测试期待旧文案；源码守卫仍要求旧的 isComplete 字面检查。
- **根因**：UTF-8 备用 Archive 已创建，但主可执行文件探测仍读取 ZIP 条目默认 CP437 路径，探测失败后退回默认解压；自保护代码已改用 canSafelyIdentifySigners，而守卫未同步这一等价且更少误拦的 CMS 签名者判据。
- **修复**：结构探测显式使用 UTF-8 解码；恢复策略测试改为当前实现文案；守卫接受完整身份检查或当前的安全签名者检查，仍要求从运行中的 Seal 读取真实 CMS 身份。
- **验证**：git diff --check 通过；Windows 无法运行 Swift 与项目守卫，待云 CI 验证。

## 2026-10-17 配对失败态破坏灵动岛信息层级

- **现象**：配对失败时，灵动岛左侧本应显示应用身份“Seal”，却显示状态文案“配对未完成”，与准备、等待和成功态不一致。
- **根因**：失败状态在构造内容状态时错误地将状态文字写入标题字段。
- **修复**：标题固定为“Seal”；右侧状态继续由 Widget 按 `.failed` 渲染“配对未完成”和红色状态图标。
- **验证**：待云 CI 编译与真机验证失败态展开、紧凑和锁屏样式。

## 2026-10-17 视觉规格分散导致页面对齐漂移

- **现象**：相同的内容卡在设置、签名、导入、续签与详情页分别手写背景、描边和圆角；抽屉标题与按钮也使用固定字号，系统大字体时容易失衡。
- **根因**：项目有颜色资产但没有统一的布局 Token 与内容卡语义组件。
- **修复**：建立 `SealLayout` 与 `SealContentCardStyle`，将 compact / standard / prominent 三种卡片、抽屉边距与主操作高度集中定义；迁移可等价替换的内容卡，并将抽屉标题和公共操作按钮改为语义动态字体。
- **验证**：已通过文本与 diff 检查；待云 CI 编译和 iPhone 小屏、大字体、深色模式真机回归。

## 2026-10-17 协议与隐私政策和真实数据流不一致

- **现象**：原文将所有数据描述为“不离开设备”、称不运营服务器并写“不会索取 Apple ID 密码”，与 Apple 认证、Anisette、GitHub 更新和应用内凭据输入的实际行为不一致；协议卡片也仍使用内容层玻璃。
- **根因**：文案未随认证、更新和权限功能演进而复核。
- **修复**：按本地实现重写两份协议，明确本地存储、Apple/Anisette/GitHub 通信、权限、导出日志和删除路径；内容卡改为实色。协议版本升为 2，使既有用户重新确认。
- **验证**：待云 CI 编译；发布前仍需开发者按实际运营主体、正式联系渠道和适用地区进行法律审阅。


## 2026-10-17 内容卡片误用 Liquid Glass

- **现象**：`glassSurface` 在 iOS 26 上把详情、签名队列和设置信息卡渲染为 Liquid Glass，内容层级会透出背景，且和主列表的实色卡混用。
- **根因**：通用修饰器把 iOS 26 的 `.glassEffect(.regular)` 同时用于内容卡和未来的浮层。
- **修复**：新增 `sealContentCard`（实色 `sealSurface` 加描边）并收敛为三档卡片规格，迁移内容卡调用；`glassSurface` 留给真正浮在内容上的导航与操作层。协议页已随协议重写一并迁移。
- **验证**：待云 CI 编译与 iOS 26 / 17.4 真机回归。

# DEBUG_LOG

> 复盘记录：现象 → 根因 → 修复 → 涉及文件 → 验证状态。新条目追加到「历史记录」顶部（最新在前）。
> 动手前先查阅下方「常犯坑位」，避免同类问题重复发生。

## 2026-10-18 16:37:26 新签名 Bundle ID 默认值与恢复逻辑统一

- **现象**：签名器曾在面板值之外隐式追加 Team 和 `.seal`；设备记录恢复又按 Seal 专属格式筛选，且本地格式校验强加了长度、段数和点号段规则，导致有效值可能被拦截或恢复记录无法关联重导 IPA。
- **修复**：新导入 IPA 的签名面板显示 `原 Bundle ID.<TeamID>` 可编辑默认值；mapper 只使用用户当前输入，不再追加或改写。覆盖更新/续签锁定已签名 ID，扩展沿用主 ID。本地校验只拦空值和 Apple 不支持字符。恢复按描述文件实际 ID 与可信 Team 识别，兼容当前 Team 后缀及历史 `.seal.<TeamID>`，其余格式不改写；不再靠 ID 前缀猜扩展。
- **涉及文件**：`Seal/Core/Signing/BundleIDPolicy.swift`、`Seal/Core/Signing/BundleIDMapper.swift`、`Seal/Features/Apps/AppSigningSheet.swift`、`Seal/Core/Recovery/InstalledRecordRecoveryPolicy.swift`、对应两份测试、`Scripts/verify-release-safety.py`、`docs/upstream-alignment.md`、`project.yml`、`RELEASE_NOTES.md`。
- **版本**：`0.1.12`。
- **验证**：`git diff --check` 通过；错误码索引重新生成（428 个标识、813 处引用）；两个构建 target 均为 `0.1.12`。Windows 无 Xcode，Swift 测试和 CI 守卫待 GitHub CI；记录恢复与重导仍需实机验证。

## 2026-10-18 14:00:24 恢复应用导入回归测试参数顺序错误

- **现象**：CI 的 Swift 测试目标报 `argument 'ipaRelativePath' must precede argument 'needsIPAImport'`，同一处初始化调用触发多条诊断。
- **根因**：新增恢复记录测试构造 `AppRecord` 时，参数顺序与其显式初始化器声明顺序不一致。
- **修复**：将 `ipaRelativePath` 移到 `needsIPAImport` 前；版本递增至 `0.1.10`。
- **涉及文件**：`SealTests/Import/ImportWorkflowTests.swift`、`project.yml`、`RELEASE_NOTES.md`。
- **验证**：`git diff --check` 待检查；Windows 本机无法编译 Swift，待 GitHub CI 重新验证测试目标与 IPA 构建。

## 2026-10-18 13:47:18 ActivityKit 新并发标注导致 Swift 编译失败

- **现象**：CI 的 Swift 回归任务在 `PairingLiveActivityController.swift:58` 报 `sending 'activity' risks causing data races`，导致 Swift 6 编译失败。
- **根因**：当前 SDK 将 `Activity.update(_:)` 标记为并发执行；`Activity` 句柄保存在主 actor 隔离的控制器中，直接传入该方法触发并发检查。
- **修复**：仅在调用 ActivityKit 更新方法前创建局部 `nonisolated(unsafe)` 别名；句柄其余读取和生命周期仍由主 actor 控制器管理。版本递增至 `0.1.9`。
- **涉及文件**：`Seal/Infrastructure/Pairing/PairingLiveActivityController.swift`、`project.yml`、`RELEASE_NOTES.md`。
- **验证**：`git diff --check` 与发布版本守卫待检查；Windows 本机无法编译 Swift，须由下一轮 GitHub CI 验证并继续实机检查灵动岛更新。

## 2026-10-18 13:32:47 SwiftUI 外观抽屉 sheet 参数顺序编译失败

- **现象**：CI 的 Swift 回归编译在 `RootTabView.swift:151` 报 `Incorrect argument label in call (have 'isPresented:_:onDismiss:', expected 'isPresented:onDismiss:content:')`。
- **根因**：`.sheet` 使用了内容闭包在前、`onDismiss` 在后的 trailing closure 写法，与当前 SwiftUI 声明的参数标签顺序不匹配。
- **修复**：改为 `.sheet(isPresented:onDismiss:) { content }`，保留主题抽屉关闭后再呈现自定义颜色窗口的行为。
- **涉及文件**：`Seal/App/RootTabView.swift`。
- **验证**：待重新运行 GitHub CI 的 Swift 回归与 IPA 构建。

## 2026-10-18 13:16:25 重装后重新导入已安装应用被版本检查拦截

- **现象**：卸载并重装 Seal 后，设备恢复的已安装应用记录没有旧版本号；重新导入原 IPA 时显示“无法确认版本”并禁用继续操作。
- **根因**：设备恢复记录没有原 IPA，版本号按设计为空；`ImportWorkflow.checkVersion` 把缺失的旧版本号与导入 IPA 自身版本无效混为一类。
- **修复**：新增“旧版本未记录”状态。旧版本为空且新 IPA 版本有效时，显示“旧版本未记录 · v…”并允许确认覆盖签名，沿用原签名 Bundle ID/团队身份；新 IPA 版本本身无效仍维持拦截，已知旧版本的降级判断不变。
- **涉及文件**：`Seal/Core/Import/ImportDraft.swift`、`Seal/Core/Import/ImportWorkflow.swift`、`Seal/Features/Import/ImportConfirmationView.swift`、`SealTests/Import/ImportWorkflowTests.swift`、`RELEASE_NOTES.md`。
- **验证**：新增回归测试覆盖恢复记录缺少版本时重新导入并保留签名身份；Windows 本机不编译 Swift，待 GitHub CI 的 `swift-regression` 与构建 job 验证。

## 2026-10-18 13:07:26 log26 八项问题处理

- **现象**：爱思安装的 Seal 无法在应用内自签覆盖；检查更新重复请求；分页标题字重闪变；自定义颜色弹层互相遮挡且拖动卡顿；签名证书页读不到当前签名者；中文 IPA 签名后被判定缺少主可执行文件；Apple ID 的已签名 App 显示 Apple 门户生成名称；灵动岛图标与状态文字显示不完整。
- **根因**：扩展的描述文件状态为 `signerIdentified` 时，旧流程把“已读出真实 CMS 签名者”误当成“签名者未知”，阻断自替换和证书保护；ZIP 中未标 UTF-8 的中文路径被默认解码成乱码；颜色预览每个拖动事件都刷新全局主题；更新缓存没有在成功结果上复用。
- **修复**：自替换与证书保护现在允许所有目标 Bundle ID/真实签名者均可确认的 `signerIdentified` 身份；待安装候选仍要求完整身份。IPA 路径优先按 UTF-8 读取。更新检查在进程内缓存成功结果并合并并发请求。取色器从主题抽屉正式关闭后才出现，取消恢复主题抽屉、完成关闭全部；预览最多每 33 ms 写入一次主题。两项分页固定中等字重。灵动岛加入 Seal 图标、修正状态/路径排版，并在活动失效时回退显示真实配对码通知。
- **签名分配说明**：log26 中 `KMusicLiveActivity` 扩展需要主 App 不具备的 `beta-reports-active` 与 App Groups，因此单独使用 App ID/描述文件是正确结果；这次保留混合共享规则，没有强行共享。该 IPA 的安装前失败点为 `SEAL-INSTALL-730` 主可执行文件路径解码/匹配失败。
- **涉及文件**：`project.yml`、`RELEASE_NOTES.md`、`Seal/App/RootTabView.swift`、`Seal/Core/Renewal/SelfReplacementCoordinator.swift`、`Seal/Core/Renewal/SelfReplacementPolicy.swift`、`Seal/Core/Renewal/SelfSigningIdentity.swift`、`Seal/Core/Signing/SigningCoordinator.swift`、`Seal/DesignSystem/CaterpillarSegmentedTabs.swift`、`Seal/Features/Apps/AppsRootView.swift`、`Seal/Features/Settings/AppleAccountDetailView.swift`、`Seal/Features/Settings/CustomAccentColorEditor.swift`、`Seal/Features/Settings/SettingsRootView.swift`、`Seal/Features/Settings/SettingsViewModel.swift`、`Seal/Infrastructure/Pairing/PairingLiveActivityController.swift`、`Seal/Infrastructure/Signing/SigningWorkspace.swift`、`Seal/Infrastructure/UpdateChecker.swift`、`SealLiveActivity/PairingLiveActivityWidget.swift`，及对应 `SealTests` 回归测试。
- **验证**：`git diff --check` 通过；补充真实签名者识别、更新缓存、UTF-8 中文 IPA 和 Apple ID 软件名称回归测试。Windows 本机未编译 Swift，也未运行 XCTest；需 GitHub CI 编译/测试，再用原始 `歌一刀` IPA 与实机验证安装、灵动岛、主题拖动和证书页面。

## 2026-10-17 Seal 与 IPA 更新链路文案和状态统一

- **现象**：更新流程把“检查失败”与“已是最新版”合并；下载/校验阶段的失败文案过度归因于网络；Seal 自更新与普通 IPA 覆盖确认共用一套冗余内容；长内容或小屏会挤压操作区。
- **修复**：检查结果区分不可用、最新版、已有更新和已提醒版本；统一启动/手动检查及延后提醒行为；更新抽屉固定操作区、滚动内容，明确展示版本差异、下载/校验/失败/重试状态；Seal 自更新确认精简并复用在线下载与“+”导入后的签名流程；普通 IPA 仍走通用覆盖确认并展示 Bundle ID；数字版本按分段比较，无法解析时不猜升降级；更新包删除需确认，更新失败保留待更新包。
- **涉及文件**：`UpdateChecker.swift`、`Version.swift`、`UpdateNoticeView.swift`、`UpdateIPADownloader.swift`、`AboutView.swift`、`RootTabView.swift`、`ImportWorkflow.swift`、`ImportDraft.swift`、`ImportConfirmationView.swift`、`AppSigningSheet.swift`、`SigningProgressView.swift`、`AppsRootView.swift`、`VersionTests.swift`、`RELEASE_NOTES.md`。
- **验证状态**：本机 Windows 无 Swift 编译器，尚未编译；待 CI 编译与 Swift 回归测试验证。尚未推送 CI。

---

## 2026-10-17 扩展描述文件按目标混合分配

- **现象**：只要一个扩展能力超出主 App，整组扩展都会各自申请 App ID/profile，兼容扩展也白占名额；续签无法准确还原“哪些扩展真正独立”。
- **根因**：原来的策略是整包二选一（全共享 / 全独立），无法表达用户确认的“兼容扩展共享，单个不兼容扩展单独处理”。
- **修复**：增加混合策略；每个不兼容或能力读取失败的扩展独立申请，其余继续使用主 profile。沿用 `signingTargets` 中每目标 profile UUID 还原实际分配；更新门户映射、签名嵌入、目标级校验、Apple 能力降级的影响范围和 profile-only 续签。补充多扩展分配与降级范围单测。
- **涉及文件**：`AppExtensionProfileStrategy.swift`、`AppRecord.swift`、`ProfileOnlyRenewalPolicy.swift`、`ApplePortalSigningService.swift`、`AppDetailView.swift`、`AppExtensionProfileStrategyTests.swift`、`docs/upstream-alignment.md`。
- **验证状态**：`git diff --check` 已通过；本机 Windows 无 Swift 编译器，测试与完整编译必须由 GitHub CI 验证；真机需测 LiveContainer 多扩展签名、名额、覆盖安装和 profile-only 续签。未推送 CI。

---

## 2026-10-17 证书名额满时逐张选择撤销，避免一次撤掉整批证书

- **现象**：签名失败页只有「撤销并继续签名」，点一次会撤销账号下所有本机没有私钥的证书；用户看不到每张证书对应的影响范围。
- **根因**：Seal 把 SideStore 的「撤销决策交给用户」简化成一个批量确认动作，确认粒度比上游更粗。
- **修复**：失败抽屉改为「查看证书并继续」；读取最新 Apple 清单后逐张展示证书与本机可确认影响，选定后再次确认；执行时重拉清单并只撤销所选证书，然后继续签名与受影响应用恢复。Seal 主程序及扩展真实签名证书都从候选中排除。失败页与列表页文案去重，撤销失败写入独立错误码与底层诊断。
- **涉及文件**：`SigningProgressView.swift`、`CertificateSacrificePickerView.swift`、`AppsViewModel.swift`、`SigningCoordinator.swift`、`CertificateCleanupPolicy.swift`、`verify-release-safety.py`、证书错误目录、`docs/upstream-alignment.md`。
- **验证状态**：Windows 无法编译 iOS Swift；CI 尚未运行。生成目录后需由 GitHub CI 编译和守卫验证，再做真机证书撤销与恢复回归。

---

## 2026-10-17 Release 目标切换到 MJorb-0.1.0

- **现象**：CI 工作流仍向旧的 `Seal-Releases` 仓库发布，Seal 内置更新检查也读取旧仓库。
- **修复**：将完整与快速 Release 工作流目标切换到 `3188447354/MJorb-0.1.0`，改用该仓库的 `GITHUB_TOKEN`；更新检查同步读取新仓库；更新守卫的变异锚点。旧仓库的历史 Release 不迁移、不修改。
- **涉及文件**：`.github/workflows/ios.yml`、`.github/workflows/ios-release.yml`、`Seal/Infrastructure/UpdateChecker.swift`、`Scripts/verify-release-safety.py`、`DEBUG_LOG.md`。
- **验证状态**：待 `git diff --check` 与公开仓库完整 CI；Windows 无 Swift 编译环境。Release 仍仅由手动工作流触发，不会因 push 自动创建。

---

## 2026-10-17 配对实时活动在应用被终止后无法按本地计时结束

- **现象**：Seal 切去系统设置后被挂起或从后台强制结束，配对码实时活动可能不会在本地设定的 3 分钟到期时立即消失。
- **根因**：本地 `Task.sleep` 依赖 Seal 进程继续运行；ActivityKit 的 `staleDate` 只把内容标记为过期，不会结束活动。
- **处理边界**：应用仍存活时现有计时会结束活动；完成与失败状态已交给系统按 dismissal date 收掉。若要在应用被终止后也精确结束，必须引入服务器经 APNs 发 ActivityKit `end`，不能伪装成本地代码已经解决。
- **涉及文件**：`PairingLiveActivityController.swift`。
- **验证状态**：Apple 文档已核对；不改当前本地实现，待决定是否建设 APNs 实时活动服务。

---

## 2026-10-17 首次使用被提前请求通知权限

- **现象**：用户同意协议后，即使实时活动可用、也没有进入配对回退路径，Seal 仍会请求通知权限。
- **根因**：`SealApp` 遗留了首次使用即申请全部通知授权的逻辑，与配对通知“仅实时活动不可用时才请求”的规则冲突。
- **修复**：删除启动时通知授权；到期提醒继续在用户主动开启提醒时申请，配对码通知只在实时活动失败后申请。
- **涉及文件**：`SealApp.swift`。
- **验证状态**：待云 CI 编译与真机确认首次进入不弹通知授权、关闭实时活动后开始配对才按需请求；未提交、未推送。

---

## 2026-10-17 配对实时活动的信息层级与紧凑态验证码

- **现象**：配对实时活动把六码同时放进展开态顶部和正文，准备态以加载圈替代可读状态；紧凑态在等待配对时没有展示验证码，锁屏又额外展示设备名，四种呈现的内容不一致。
- **根因**：初版只按 ActivityKit 区域填入通用内容，没有先定义配对流程每一状态的主信息、状态和下一步动作。
- **修复**：展开态与锁屏均固定为左侧 Seal 身份、右侧带颜色的状态、下方唯一主信息；验证码仅在等待配对时置中显示，紧凑态显示图标与六码；完成态使用绿色圆形对勾并只提示返回 Seal；准备态明确设置路径。
- **涉及文件**：`PairingLiveActivityController.swift`、`PairingLiveActivityWidget.swift`。
- **验证状态**：待云 CI 编译与真机验证展开、紧凑、最小、锁屏四形态；未提交、未推送。

---

## 2026-10-17 配对码回退通知点击后异常退出

- **现象**：实时活动不可用时，用户点配对码回退通知返回 Seal 会异常退出；成功后还会收到第二条“配对完成”通知。
- **根因**：回退通知没有自己的点击路由，通知代理只处理后台续签通知，冷启动时也没有可延后消费的导航请求；回退路径错误地把成功或失败又替换成新通知。
- **修复**：配对码通知点击先登记为待打开请求，主界面出现后安全跳转配对页；成功或失败一律清掉回退通知，不再投递第二条结果通知。
- **涉及文件**：`PairingCodeNotification.swift`、`SealNotificationPresenter.swift`、`RootTabView.swift`、`SettingsViewModel.swift`。
- **验证状态**：待云 CI 编译与真机覆盖前台点击、冷启动点击、成功和失败四条通知回退路径；未提交、未推送。

---

## 2026-10-17 应用分组标签横向挤压与下划线错位

- **现象**：待安装／已安装标签随文字和数量变化挤在左侧，下划线可能与标签不在同一列。
- **根因**：标签按自然文字宽度布局，剩余空间全部留在右侧；组件还有额外内边距，和页面内容边距叠加。
- **修复**：两项分组平分页面内容宽度；标签、触控区域与下划线使用同一套等分坐标，取消组件自身横向内边距。
- **涉及文件**：`CaterpillarSegmentedTabs.swift`。
- **验证状态**：待云 CI 编译及真机点击、手势切换、深浅色和大字号验证；未提交、未推送。

---

## 2026-10-17 配对码灵动岛未更新与分组下划线错位

- **现象**：实机开始手机配对后灵动岛不显示真实六码；配对完成卡片长期残留。应用页“待安装／已安装”下划线会与实际分页错位。
- **根因**：六码校验的原始正则多写了一个反斜杠，真实数字六码被拒绝；完成态只依赖主应用内存中的延时任务结束，Seal 被挂起后任务不会执行。分页下划线试图从 `TabView` 子页坐标推断进度，该坐标在部分 iOS 版本异步回写。
- **修复**：校正六码正则；完成或失败时调用 ActivityKit 带结束日期的 `end`，由系统负责按时收掉卡片；下划线改为只跟 `TabView` 最终 selection，点击和手势分页都落到同一标签。
- **涉及文件**：`PairingLiveActivityController.swift`、`AppsRootView.swift`。
- **验证状态**：Windows 无 Xcode；待云 CI 编译，随后真机验证六码、完成自动消失、失败自动消失、点击卡片回 Seal、两组标签点击与滑动定位。

---

---

## 2026-10-17 CI #120：本地已签名包的分组测试陈旧

- **现象**：CI #120 的发布构建和 IPA 上传成功，但 Swift 回归有一条 `AppRecordTests` 失败。
- **根因**：设备探测确认应用已删除后，记录保留可直接重装的签名 IPA；产品分组已改为“待安装”，旧测试却仍断言“待签名”。
- **修复**：测试改为验证该记录不在已安装、不在待签名、而是在待安装；签名产物继续保留。
- **涉及文件**：`AppRecordTests.swift`。
- **验证状态**：逻辑只校正既有分组契约；待下一轮云 CI 运行完整 Swift 回归。

---

---

## 2026-10-17 CI #119：身份策略测试契约与错误码清单快照

- **现象**：CI #119 的发布打包在错误码清单差异检查失败；Swift 回归同时保留了一条“旧 Mac 身份必须原样保留”的测试，与新引入的 SideInstaller 身份归一化策略互相矛盾。
- **根因**：错误码库存是受版本控制的派生快照，代码新增标识后未同步提交；测试仅改了新策略覆盖用例，遗漏了原有自建服务器用例的语义边界。
- **修复**：重新生成并提交错误码库存；把原测试明确为“仅自建服务器身份原样保留”，旧 Mac/Xcode 与 Android 的归一化仍由相邻测试覆盖。
- **涉及文件**：`error-code-inventory.json`、`AnisetteV3ClientTests.swift`。
- **验证状态**：`git diff --check` 待本次提交前执行；Windows 无 Xcode，Swift 回归仍由下一轮云 CI 验证。

---

## 2026-10-16 SideInstaller 登录策略对齐：Anisette 身份归一化

- **现象**：Seal 会把 `/v3/client_info` 返回旧 Mac/Xcode 或 Android 身份的服务器直接跳过，导致可用 Anisette 服务集合缩小；用户提供的 SideInstaller 在相同阶段能继续登录。
- **根因**：Seal 采用了早期“拒绝身份即换服务器”的推断，而当前 SideInstaller 的 isideload 已改为将这类服务器身份统一归一化为 Windows iTunes 身份，并全链路保持一致。
- **修复**：不直接替换 Rust 登录模块（Seal 的 Swift/AltSign 架构不兼容），只移植可验证的身份归一化策略；归一化结果同时用于 provisioning、ADI 身份戳和认证请求，旧不匹配 ADI 会安全重建，稳定 identifier 与已保存账号会话不动。
- **涉及文件**：`AnisetteClient.swift`、`AnisetteV3ClientTests.swift`、`AnisetteServer.swift`、`upstream-alignment.md`。
- **验证状态**：`ani.jkcoxson.com`、`ani.sidestore.io`、`ani2.stikstore.app` 的 `/v3/client_info` 均返回 HTTP 200；测试覆盖旧 Mac/Xcode、Android、自建身份和空 User-Agent。Windows 无 Xcode，待 CI 编译与真机 Apple ID 登录验证。

---

## 2026-10-16 CI #117：发布守卫误报与界面测试陈旧契约

- **现象**：CI #117 的 Swift 编译已经通过，但 `build-package` 的 R65 变异测试仍失败；`swift-regression` 又把已上线的“待安装”分组名报成界面回归。
- **根因**：R65 的变异条目仍期待已替换的旧提示文本；App Group 映射守卫查的是整个门户文件，另一处同名调用会掩盖被改坏的筛选函数。UI 测试仍断言旧“待签名”标签，与已确认的产品文案不一致。
- **修复**：变异断言统一绑定当前守卫提示，并把能力筛选校验收窄到 `filteredAppIDEntitlements`；UI 测试全面对齐“待安装”标签与页面标题，不改产品界面。
- **涉及文件**：`verify-release-safety.py`、`ImportFlowUITests.swift`、`AgreementGateUITests.swift`。
- **验证状态**：833 条静态守卫、13 条 R65 定向变异、错误码清单测试和 `git diff --check` 均通过；Windows 无 Xcode，待 CI 跑完整 Swift 回归。

---

## 2026-10-16 CI #116：R65 变异守卫失配与签名抽屉漏返回

- **现象**：CI #116 的发布守卫静态检查已通过，但 R65 的若干变异测试报告“未拦截”；Swift 回归编译同时报 `AppSigningSheet.primaryActionTitle` 缺少 `return`。
- **根因**：扩展策略规则更新后，部分变异条目仍期待旧的 R65 编号，能力过滤/App Group 映射的静态断言曾被删掉，导致变异测试没有对应的失败消息。`primaryActionTitle` 从单表达式改为多行后遗漏显式返回。
- **修复**：恢复能力过滤与 App Group 映射守卫，同步全部 R65 变异期望到新规则编号，并为 `primaryActionTitle` 增加源码与变异守卫；补回 Swift 的 `return`。
- **涉及文件**：`verify-release-safety.py`、`AppSigningSheet.swift`。
- **验证状态**：833 条静态守卫、Python 错误码测试与 `git diff --check` 通过。Windows 无 Swift/Xcode，待下一次 CI 编译验证。
## 2026-10-16 共享扩展的快速续签规则与安全守卫对齐

- **现象**：普通 IPA 已改为共享主描述文件以节省 App ID，但续签准入仍把所有“带扩展 + 共享”的完整记录视为旧产物，强制完整重签；这会让已经按新规则成功签过的应用在每次续签时失去快速续签。
- **根因**：旧迁移规则只把独立描述文件当作可信拓扑，未区分“策略字段缺失的旧记录”和“明确记录为共享、且每个目标都持久化同一主描述文件”的新记录。发布守卫 R65 同时缺少这条续签契约。
- **修复**：明确共享策略时，只有主 App、扩展快照和逐目标签名记录都指向同一主描述文件才放行 profile-only；策略缺失、扩展记录缺失或任一描述文件不一致则回落完整重签。R65 增加共享绑定解析、记录更新、快速续签正反例和能力降级范围检查，并补变异锚点。
- **涉及文件**：`ProfileOnlyRenewalPolicy.swift`、`ProfileOnlyRenewalPolicyTests.swift`、`verify-release-safety.py`。
- **验证状态**：Python 语法检查与 `git diff --check` 通过。Windows 无 Swift/Xcode，最终由 CI 编译并运行 Swift 回归测试。
## 2026-10-16 CI #114：扩展策略守卫陈旧且三个闭包遗漏返回值

- **现象**：CI #114 的 `build-package` 在发布安全守卫 R65 失败；`swift-regression` 随后报三个 `missing return`，分别在扩展策略 getter、签名抽屉的扩展摘要、以及 Apple 503 重试认证闭包。
- **根因**：R65 仍将“所有含扩展 IPA 必须独立签名”当作契约，与已确认的“普通扩展默认共享，能力不兼容时由用户明确改为独立”的产品规则冲突。三处修改把原本隐式返回的单表达式函数扩为多行后，遗漏了 Swift 要求的显式 `return`。
- **修复**：R65 与其变异锚点改为守护现行策略：普通扩展共享，Seal/LiveContainer 独立，共享能力阻塞在门户写入前以 `SEAL-PROFILE-366` 明示并在 UI 经用户确认后才独立签名；补回三个 `return`。
- **涉及文件**：`verify-release-safety.py`、`AppRecord.swift`、`AppSigningSheet.swift`、`AppleAccountClient.swift`。
- **验证状态**：`py_compile`、错误码清单测试、`git diff --check` 通过。Windows 无 Swift；完整发布守卫在本机执行超过工具单次时限，待下一次 CI 验证。

## 2026-10-16 手机配对灵动岛状态与生命周期

- **现象**：旧实现等系统交付 PIN 才创建 Live Activity，用户若已切去系统设置可能错过前台创建窗口；系统回调 `.completed` 时又先显示“配对成功”，而凭证导入失败会造成成功假象。旧活动失败时直接消失，用户看不到应回 Seal 排查的状态。
- **根因**：配对 UI 的展示时机按“有码才建”理解，却没有覆盖 ActivityKit 的前台创建约束；系统完成回调与 Seal 成功保存可用凭证被当成同一事件。
- **修复**：用户主动开始配对时只预创建一个不含假码的准备态活动；真实六码到达后更新活动，活动创建或更新不可用才走通知回退。仅在 `PairingStore.importFile` 成功后显示“配对完成”；主机失败或导入失败显示“配对未完成，返回 Seal 查看原因”，隐藏旧码并在短超时后清理。用户点回 Seal 立即关闭；前台恢复只清理已过期活动。小组件改用 Seal 的真实品牌图标，六码按 `123 456` 分组，完成/失败分别显示绿勾/红色感叹号。系统决定是否展开，代码不承诺或伪造强制展开。
- **涉及文件**：`SettingsViewModel.swift`、`PairingLiveActivityController.swift`、`PairingCodeNotification.swift`、`PairingLiveActivityWidget.swift`、`PairingActivityAttributes.swift`、`RootTabView.swift`、`project.yml`。
- **验证状态**：错误码清单测试通过，`git diff --check` 通过。Windows 无 Xcode，待云 CI 编译并在 iPhone 验证准备态、六码、完成、失败、通知回退和点按回 Seal 六条路径。

## 2026-10-16 扩展描述文件共享不得静默消耗 App ID

- **现象**：普通含扩展 IPA 的默认策略是独立描述文件；共享主描述文件遇到扩展能力高于主应用时，又自动降级为独立。用户无法得知本次会额外创建几个 App ID，免费账号容易被悄悄耗尽名额。
- **根因**：`AppExtensionProfileStrategy.defaultFor` 把“含扩展”直接判为独立；`resolvedForSigning` 把共享能力阻塞直接转换为独立策略，门户随后继续创建扩展 App ID。
- **修复**：普通 IPA 默认共享主描述文件；Seal 与 LiveContainer 固定独立。共享被扩展能力阻塞时，在门户读取或创建 App ID 前抛 `SEAL-PROFILE-366`，界面准确列出扩展与缺失能力，用户可取消，或明确选择“改为独立签名”后再次开始签名。用户选择后的策略会随成功签名记录持久化。完整签名也会在证书/App ID/描述文件操作前确认安装通道就绪；签后再次核验，设备中途断开只保留并复用已签名包重试安装，不重复签名。
- **涉及文件**：`AppExtensionProfileStrategy.swift`、`AppRecord.swift`、`ApplePortalSigningService.swift`、`AppSigningSheet.swift`、`SigningCoordinator.swift`。
- **验证状态**：单元测试覆盖默认策略、LiveContainer 例外、持久化独立策略和共享阻塞识别；`git diff --check` 待最终检查。Windows 本机无法编译 Swift，待云 CI 与含扩展真机 IPA 验证。

---

## 2026-10-16 Apple ID 登录需反复重试（构建 95）

- **现象**：双重认证输入框可以正常出现且账号最终能登录，但同一账号常需反复点“添加账号”。日志显示 GrandSlam 的 `init` 或 `complete` 随机收到 Apple 返回的 HTML `503 Service Temporarily Unavailable`。
- **根因**：Seal 的 503 退避虽会重新生成 SRP 会话，但每一轮都复用第一次取得的 `ALTAnisetteData`。其中 `X-Apple-I-MD` 是 anisette 服务签发的一次性认证数据；503 后继续用旧数据，既不能换到新的 Apple 边缘会话，也可能继续带已过时凭据，自动重试成功率低。
- **修复**：每一次完整的 503 重试都重新请求 anisette headers，再用新的 `X-Apple-I-MD`、新的 SRP 会话发起登录；保持原有 SIM resync 和退避节奏，不清除设备 identifier、ADI 或已登录账号。
- **涉及文件**：`Seal/Infrastructure/Accounts/AppleAccountClient.swift`。
- **验证状态**：构建 95 日志已确认 503 出现在 Apple GrandSlam，而不是密码或双重认证输入流程；`git diff --check` 通过。待云 CI 和真机验证自动重试后的成功率。

---

## 2026-10-16 CI #112：灵动岛 API 与空间守卫阻断打包

- **现象**：手动构建 #112 在 Swift 回归报 `ActivityContent` 的 `alertConfiguration` 为多余参数；打包门随后又报 R35「临时空间公式只许有一份」。因此本次没有生成 IPA，尚未进入 Apple ID 实机验证。
- **根因**：当前 CI 使用的 ActivityKit SDK 支持 `activity.update(_:alertConfiguration:)`，但 `ActivityContent(state:staleDate:)` 没有带 `alertConfiguration` 的初始化器。空间公式已经从 `expanded + 2 × ipa + 200MB` 校正为 `expanded + ipa + 300MB`，发布守卫却仍硬编码检查旧的 `× 2` 写法。
- **修复**：创建 Live Activity 时使用当前 SDK 支持的两参数 `ActivityContent`，配对成功的提示仍通过已有的 `update` API 发送；将 R35 守卫改为锁定新公式的唯一实现，防止恢复旧公式或复制第二份。
- **涉及文件**：`Seal/Infrastructure/Pairing/PairingLiveActivityController.swift`、`Scripts/verify-release-safety.py`。
- **验证状态**：待重新运行完整云 CI；Windows 本机无法编译 Swift，Apple ID 添加仍需通过 CI 后真机复测。

---

## 2026-10-15 Apple ID `-80045` 的真实根因：ADI 与「声明身份」不一致（构建 21）

- **现象**：构建 21 的 `SEAL-NET-503` 消失，但真机添加 Apple ID 立刻变成 `Apple.APIError -80045`（首试即现，不是重试风暴独有）。**同一台手机、同一网络下用 SideInstaller 加同一个 Apple ID 能够成功** ⇒ 排除环境 / IP 限流（日志里 2 分钟内约 10 次重试中出现过一次 Apple `429`）。
- **根因**：ADI（`adi_pb`）只对「建它时声明给 Apple 的那个客户端身份」有效，而 `remoteStore` 用的是固定钥匙串服务名、**不按服务器隔离**。构建 21 把声明身份改成了 macOS/akd，设备上却仍在复用构建 19 用 **Xcode 身份**建的那份 ADI ⇒ Apple 按「ADI 数据与声明系统不一致」回 `-80045`。项目自身的 `DEBUG_LOG`（2026-10-14）与 `isideload` 注释都记载过同一类别。
- **REA（SideInstaller 1.5.1 主二进制）**：
  - 二进制里**只有一条**非 Android 身份字面量，就是 `<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>`，**没有任何 `com.apple.dt.Xcode` 字面量**；另有 `<Pixel 7> <Android;14;UQ1A.240205.002> … com.apple.akd`（本地 provider 默认值）。
  - 它内置的 anisette 目录首条是 `https://ani.sidestore.io`（Swift 侧带名字的目录，`anisetteServerURL` 紧邻其前）；`https://ani.stikstore.app` 出现在 Rust 常量区（紧邻 `panic while revoking certificate`）⇒ 此前「默认服务器 = stikstore」是**误判**。它还内置 `https://servers.sidestore.io/servers.json` 作为运行时目录来源。
  - **逐台实测该目录 15 台服务器**：8 台（sidestore.zip、846969.xyz、npeg.us、wedotstud.io、xu30.top、ani3server.fly.dev、crystall1ne.dev、stikstore.app）返回的正是会被边缘拒掉的 Xcode 身份，3 台返回 akd/macOS 或 Windows/iTunes，其余不可达。
- **⚠️ 结论修正（同日，isideload 源码反证）**：上一条「SideInstaller 固定声明 macOS/akd、不拿服务器身份」是**误判**，已推翻。源码 `remote_v3/mod.rs:121` 注释写明「本可以硬编码，但 Apple 变化太快，不如直接从服务器取」，`:194` 把 `/v3/client_info` 返回值**原样**当 `device_description`，`grandslam.rs:220` 的 SRP 头用的就是它；`<Mac15,7> …` 那条硬编码只出现在 URL bag 一个请求（`grandslam.rs:59`，"we lie for this request"）。⇒ 真实形态是「**用服务器返回的身份 + 多服务器 failover**」：8 台 Xcode 身份服务器必 503 就换下一台，落到 `ani.sidestore.io` 的 `MacBookPro13,2 / macOS 13.1 / 22C65 / akd` 上成功。build 21/23 都固定声明 `<Mac15,7> <macOS;27.0;26A5378j>`（SideInstaller 从没用过这个身份）仍 `-80045`，与此一致。
- **修复（最终形态）**：身份**原样取服务器返回值**；返回 Xcode / Android 这类必拒身份时判为该服务器不可用、抛 `rejectedIdentity` 换下一台（复刻 SideInstaller 的 failover），绝不硬发必失败身份；默认服务器改为 `ani.sidestore.io`（SideInstaller 目录第一条 + 实测唯一可用身份），一次命中。保留身份戳 `AnisetteProvisioningState.clientInfo` + `matches()`：身份随服务器变化时自动作废重签，旧版本无戳条目（`nil`）同样自动迁移。只动 `remoteStore`，不动 `identityStore` 的本地标识（与 authToken 绑定，清了会让全部已登录账号失效）。

---

## 2026-10-15 Apple ID `SEAL-NET-503` 的真实根因：客户端身份声明为 Xcode（构建 19）

- **现象**：构建 19 的真机日志在添加账号后约 2 秒返回 `SEAL-NET-503`，连续四次，未进入密码校验之后的任何阶段。此前补上的 GrandSlam 头部、默认服务器切换都没有消除它。
- **根因**：**不是**头部缺失，也不是服务器地址。Apple 的登录边缘会直接拒掉「声明自己是 Xcode」的客户端：`X-Mme-Client-Info` 的应用标识为 `com.apple.dt.Xcode` 时，`gsa.apple.com` 在密码校验前返回 HTML 503。
  - 对照实验（直接 POST `GsService2` 的 `o=init`，合成 anisette 占位、其余字段固定，只改 `X-Mme-Client-Info`，每个身份重复 2 遍，只看边缘 HTTP 状态）：
    - `<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>` → **503 / 503**
    - `<MacBookPro18,3> <macOS;26.5.2;25F84> <com.apple.AuthKit/1 (com.apple.dt.Xcode/26.0)>` → **503 / 503**
    - `<Pixel 7> <Android;14;UQ1A.240205.002> <com.apple.AuthKit/1 (com.apple.akd/1.0)>` → **503 / 503**
    - `<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.akd/1.0)>` → **200 / 200**
    - `<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>` → **200 / 200**
    - `<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>` → **200 / 200**
  - `X-Xcode-Version` / `X-Apple-App-Info` 的有无不改变结果：同一身份加上这两个头仍是同样的 200 / 503 ⇒ 判据是客户端身份本身，不是这两个头。
  - 同一轮还测了 provisioning 用的 `GsService2/lookup`（GET）：**五种身份全部 200 且都返回 `midStartProvisioning`/`midFinishProvisioning`** ⇒ provisioning 从来不是 503 的来源，真机日志里的 `SEAL-NET-503` 只可能出在 SRP 阶段。这也解释了为什么设备上已经有可用的远程 ADI 状态：provisioning 一直成功，只有 SRP 被拒。
  - Seal 的默认服务器 `ani.stikstore.app` 的 `/v3/client_info` 返回的正是这个被拒的 Xcode 身份，而 `AnisetteV3Client` 把它原样透传成 `X-Mme-Client-Info`（`fetchHeaders` 的 `deviceDescription` 与 `appleRequest` 都取它）。这与「服务器身份必须与 Xcode 指纹一致」的旧判断正好相反——那条判断本身就是 503 的来源。
  - 参考实现（`isideload`）的做法印证了这点：`GrandSlam::fetch_url_bag` 在注释里写明「sending the android client info gets us the wrong url bag, so we lie for this request」，并把该请求的 `X-Mme-Client-Info` 固定为 `<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>`。
  - 三台公共服务器实测返回：`ani.stikstore.app` → Xcode 身份、`ani.sidestore.io` → macOS/akd 身份、`ani.jkcoxson.com` → Windows/iTunes 身份。三者硬件/系统与应用标识各不相同，因此身份**不能**依赖服务器，必须在客户端收口。
- **全项目排查**（避免「只看一处」）：所有会把身份送到 Apple 的出口都过了一遍。活路径只有一条 —— `AnisetteV3Client.fetchClientInfo` → `parseClientInfo`，`fetchHeaders` / `appleRequest` / `resync` 全部从它取值。另外三处身份字面量都在**死路径**上：`AnisetteClient.fetchLocal` 的 `<Pixel 7>`（`fetchLocalCoalesced` 无任何调用方）、`Vendor/AnisetteKit` 的 `defaultClientInfo`（`<MacBookPro18,3> … com.apple.dt.Xcode/26.0>`，只被同样无人调用的 `AnisetteDataProvider.fetchAnisetteData` 系列使用）、以及 `AnisetteDataProvider` 自己的 `X-Mme-Client-Info` 发送点。这三处都是 503 级身份，本次不动它们（改 vendor 与死代码只增加编译风险），但已记录为隐患。
- **修复**：在身份层收口，而不是逐处打补丁。`AnisetteV3Client.parseClientInfo` 解析 `/v3/client_info` 后统一过一遍 `acceptedClientInfo`：只放行「桌面系统且非 Xcode」的身份（macOS / Windows，且不含 `com.apple.dt.Xcode`），其余（Xcode、Android）一律替换为参考实现的 macOS/akd 身份 `<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>`。因为 `fetchHeaders`、`appleRequest` 以及全部门户/续签路径都从同一个 `AnisetteV3ClientInfo` 取值，这一处改动覆盖账号添加、续签、签名三条链路。没有改动 `X-Xcode-Version`、`X-Apple-App-Info`，也没有清除 `adi.pb`、设备标识或已保存账号。
- **涉及文件**：`Seal/Infrastructure/Accounts/AnisetteClient.swift`、`Seal/Core/Accounts/AnisetteServer.swift`（更正注释）、`SealTests/Accounts/AnisetteV3ClientTests.swift`。
- **验证状态**：对照实验在 Windows 本机对 `gsa.apple.com` 实打实发过请求，`X-Mme-Client-Info` 是唯一变量，每个身份重复两次、结论稳定；Swift 回归新增 `serverIdentitiesRejectedByAppleAreReplaced` 锁定该替换规则。⚠️ 探针用的是**合成 anisette**，只证明「边缘是否放行」，不证明真实 ADI 与替换后身份的兼容性；Windows 无 Xcode，仍需云 iOS CI 编译与真机复测「添加 Apple ID 走到验证码输入并完成」。

---


## 2026-10-15 Apple ID 503 的参考实现复核（构建 15）

- **现象**：构建 15 的实机日志连续记录 `SEAL-NET-503`，每次均在添加账号后的约一秒返回，尚未进入双重认证。因此此前加入的 `hsc = 409` 输入框分支没有机会执行。
- **根因**：构建 15 把当前 SideSign 的 Pixel 8 / Apple Music Android 身份与 Seal 现有的本地 CoreADI 流程混合，又将 GrandSlam 初始请求改成 Xcode/macOS User-Agent。这并不是用户提供的、已能登录的 SideInstaller 的实际协议。对照该 IPA 的可观察字符串以及它使用的 `nab138/isideload` 源码，成功路径使用 Pixel 7 Android `akd` 身份、`akd/1.0 CFNetwork/808.1.4`，可信设备走 XML plist，短信验证码走 JSON。错误组合会被 Apple 在密码验证之前以 HTML 503 拒绝。
- **修复**：以 SideInstaller/isideload 为唯一认证参考，统一本地 Anisette client info、GrandSlam User-Agent 和 `/auth` 2FA User-Agent；恢复 `/auth/verify/phone` 的 JSON PUT/POST 契约；保留先前已修复的 `hsc = 409` 已推送验证码直接展示、SIM 同步、短连接和错误分类。没有清除 `adi.pb`、设备标识或已保存账号。
- **涉及文件**：`Seal/Infrastructure/Accounts/AnisetteClient.swift`、`upstream/AltSign/Sources/ALTAppleAPI+Authentication.swift`、`docs/upstream-alignment.md`。
- **验证状态**：源代码字段已逐项对照 SideInstaller 所依赖的 isideload 当前源码以及用户提供 IPA 的静态字符串；待云 iOS CI 编译、打包后以这份失败日志对应的实机账号验证“密码 → 验证码输入 → 添加完成”。

---

## 2026-10-15 Apple ID 登录 503 与已推送验证码不出现

- **现象**：真机添加 Apple ID 时，GrandSlam 初始认证返回纯文本 `503 Service Temporarily Unavailable`；另一部分账号已收到 Apple 双重认证验证码却不显示输入框，随后报 `-22411`。切换 Wi-Fi、流量或代理均无效。
- **根因**：本地 AltSign 仍使用 Apple 已淘汰的 Android AuthKit 指纹；Apple 在 2026-10 的认证边缘对此组合拒绝。Apple 同时新增了 `Status.hsc = 409`、不再携带 `au` 的“验证码已推送”状态，旧分支把它当成无需 2FA，或再次请求验证码。原错误处理还把 GrandSlam 的 HTML 503 错归到 Anisette，遮蔽了真实认证阶段。
- **修复**：语义对齐 SideSign 已合入的认证流程：更新 Android Music 身份；每个 GrandSlam 请求使用新会话并关闭连接复用；识别 `hsc=409` 和直接 `au` 状态；验证码已推送时直接唤起 Seal 现有输入框，验证后带同一登录上下文继续认证并防止重复弹窗；可信设备与短信验证使用同一套当前协议头和请求体。503 只归类为 Apple 服务暂不可用，不再伪装成 Anisette 或网络出口故障。
- **涉及文件**：`Seal/Infrastructure/Accounts/AnisetteClient.swift`、`Seal/Infrastructure/Accounts/AppleAccountClient.swift`、`upstream/AltSign/Sources/ALTAppleAPI+Authentication.swift`、`docs/upstream-alignment.md`。
- **验证状态**：本机通过源代码差异、错误合同和静态安全检查；Windows 无 Xcode，等待完整 iOS CI 编译与真机添加 Apple ID 回归。REA 已验证对照 IPA 的包完整性；此 Windows 环境没有可用 Mach-O 深度反编译提供器，因此二进制行为仍以公开上游已合入源码为准。

---
## 2026-10-15 本地 AltSign 的 ldid 嵌套子模块未初始化

- **现象**：依赖拉取完成后，Swift 回归在编译 `native_bridge_ldid.cpp` 时失败：`plist/plist.h` 找不到；同次打包门还发现错误码清单的受管位置未随 Apple ID 修复同步更新。
- **根因**：CI 中的 C++ 编译命令已包含 ldid/libplist 头文件路径，说明路径设置不是问题。ldid 自身将 `libplist` 定义为 Git 子模块；CI 只拉取了 ldid 顶层代码，未初始化其锁定的 `libplist` 提交，因此目录实际不存在。`error-code-inventory.json` 是受管产物，新增 `SEAL-APPID-304` 出现位置和已有行号变化必须重新生成。
- **修复**：在 ldid 定位到上游锁定提交后初始化其递归子模块，保证 `libplist` 代码与 ldid 的锁定版本一致；按当前 Swift 源码重新生成错误码清单。不保留无效的 C++ 头文件路径改动。
- **涉及文件**：`.github/workflows/ios.yml`、`.github/workflows/ios-fast.yml`、`.github/workflows/ios-release.yml`、`docs/qa/generated/error-code-inventory.json`。
- **验证状态**：已从 CI 实际 clang 命令确认所有头文件搜索路径存在，并从 ldid 的锁定 Git tree 确认 `libplist` 是提交 `bdf928a…` 的子模块；等待下一次完整 iOS CI 验证 C++ 编译、Swift 回归和 IPA 打包。

---

## 2026-10-15 本地 AltSign 构建缺少锁定的原生依赖

- **现象**：切换到仓库内的 AltSign 源码后，公开 CI 在编译 `native_bridge_ldid.cpp` 时失败：`../../Dependencies/ldid/ldid.cpp` 不存在，因而没有 IPA 可供真机验证。
- **根因**：`upstream/AltSign` 作为嵌入源码树保存时未包含其 Git 子模块 `Dependencies/ldid` 和 `Dependencies/minizip-ng`。本地路径依赖让 Xcode 正确开始编译认证修复，也随之暴露了这个不完整的构建输入。
- **修复**：所有会编译 Seal 的 iOS 工作流在 checkout 后拉取 AltSign 上游记录的精确 ldid 与 minizip-ng 提交，再开始 SwiftPM/Xcode 构建；不使用浮动分支或最新版依赖。
- **涉及文件**：`.github/workflows/ios.yml`、`.github/workflows/ios-fast.yml`、`.github/workflows/ios-release.yml`。
- **验证状态**：等待新的完整公开 iOS CI；该次需通过 Swift 回归、IPA 打包和签名器测试后，才可作为本地 AltSign 修复进入 IPA 的证据。

---

## 2026-10-14 AltSign 认证修复未被 Seal 构建使用

- **现象**：认证修复均落在仓库的 `upstream/AltSign`，但 `project.yml` 仍把 Seal 的 SwiftPM 依赖锁定到远程 `sunuannian1/AltSign` 的旧 revision。此前 CI 虽然因 `upstream/AltSign/**` 变化而触发并全绿，实际解析的却是远程包，不能证明这些认证修改进入 IPA。
- **根因**：CI 触发路径与构建依赖来源不一致。把“本地源码路径改动”当作“远程 SwiftPM revision 已更新”会造成认证修复看似编译通过、实际没有随 Seal 构建的假象。
- **修复**：将 AltSign SwiftPM 依赖改为仓库内受版本控制的 `upstream/AltSign` 路径；保留同一个包名和 `AltSign-Static` 产品。后续 XcodeGen/SwiftPM 会直接编译当前仓库中的认证及 App ID 清单代码。
- **涉及文件**：`project.yml`、`upstream/AltSign/**`。
- **验证状态**：`git diff --check` 通过；下一次完整 iOS CI 必须重新解析本地包，并以该次 Swift 编译、测试和 IPA 为唯一有效验证。此前构建 7 的 IPA 仍可交付，但不作为本地 AltSign 修改已生效的证据。

---

## 2026-10-14 Apple ID -22411 与 App ID 注册额度的真机复核

- **现象**：构建 6 已对齐双重认证路径后，真机仍有部分 Apple ID 在添加后约 4–5 秒返回 `Apple.APIError -22411`；同份导出日志也记录了一次成功添加，说明不是 Seal 的全局本地拦截。签名 LiveContainer（需新建 2 个 App ID）及 StikDebug（需新建 1 个 App ID）均被 `SEAL-APPID-304` 拒绝，而门户当前只显示 8 个存活 App ID。
- **根因**：与已验证的 SideInstaller GrandSlam 实现逐项复核后，Seal 的初始 SRP 请求仍少 `X-Xcode-Version: 14.2 (14C18)` 与 `X-Apple-App-Info: com.apple.gs.xcode.auth`，且 `Accept` 为泛化的 `*/*`。这些字段与 Android ADI 的 AuthKit 请求属于同一个协议指纹，缺失时 Apple 可在验证码输入回调前以 `-22411` 拒绝。App ID 一项则是 Apple 开发者接口实际返回结果 `9120`：该限制按最近 7 天内的注册动作计数，存活列表中的 8 个不能反推出还剩 2 个名额；已删除或替换的近期注册仍可占用窗口。
- **修复**：GrandSlam 初始请求统一带上 SideInstaller 的 AuthKit Xcode/App 信息、精确 plist `Accept`，并与双重认证请求共用常量，避免后续身份漂移。`SEAL-APPID-304` 的提示改为“Apple 暂时拒绝新建 App ID”，明确区分当前列表和滚动注册额度，移除“App ID 自动过期”的错误说法。
- **涉及文件**：`upstream/AltSign/Sources/ALTAppleAPI+Authentication.swift`、`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`。
- **验证状态**：认证头已与 SideInstaller `auth_grandslam.rs` 的基础请求逐项对齐；App ID 结论来自真机日志中的“已有 8 / 需新注册 2 或 1”及上游 `9120` 映射。Windows 无 Xcode，完整 iOS CI 负责 Swift 编译与打包；真机仍需用出现 `-22411` 的账号确认是否出现验证码输入并完成添加。

---

## 2026-10-14 双重认证验证码请求在输入前被拒绝

- **现象**：另一 Apple ID 已走到双重认证，但 Seal 未展示验证码输入界面即返回 `Apple.APIError -22411`；同一日志中此前的账号可成功添加，因此不是通用的初始登录失败。
- **根因**：Seal 只将 `/auth` 的 client info 改成 Mac AuthKit，仍沿用 Developer Portal 的 `X-Xcode-Version: 26.0` 与旧的 BuddyML/XML 手机验证码请求。SideInstaller 的 isideload 对 `/auth` 验证码端点使用配套的 `14.2 (14C18)` 身份；可信设备端点用 XML plist，短信端点用 JSON + `PUT /auth/verify/phone`。身份字段和请求契约混用会被 Apple 在调用输入回调前拒绝。
- **修复**：所有双重认证请求固定使用与 Mac AuthKit 配套的 Xcode 14.2 标识；可信设备验证码请求和 GrandSlam 校验使用 XML plist；短信验证码发送/校验改为当前 `/auth/verify/phone` 的 JSON `PUT`/`POST` 协议。保持 Android ADI 仅用于 GrandSlam 校验身份，所有请求仍使用短生命周期连接。
- **涉及文件**：`upstream/AltSign/Sources/ALTAppleAPI+Authentication.swift`。
- **验证状态**：请求字段、路径、HTTP 方法和消息体逐项与 SideInstaller 的 isideload 对照；Windows 无 Xcode，云 CI 编译后需由该失败账号实机复测“出现验证码输入 → 输入验证码 → 添加完成”。

---

## 2026-10-14 Apple ID -80045 的 Anisette 认证身份不一致

- **现象**：构建 2 已修正 SIM 同步和 GrandSlam 连接复用，但真机四次添加 Apple ID 仍在 1–3 秒内返回 `Apple.APIError -80045`，尚未进入密码验证、双重认证或团队查询。
- **根因**：本地 `localODA` 生成的是 Android ADI 数据，Seal 却以 macOS `MacBookPro18,3` 作为 `X-MMe-Client-Info`，并以 Xcode/macOS User-Agent 发起 GrandSlam 请求。SideInstaller 所用 isideload 已说明 Apple 会拒绝 ADI 数据与声明系统不一致的初始登录，返回同一 `-80045`。
- **修复**：将本地 Anisette client info 改为与 Android ADI 对应的 Pixel 7 / Android 14 AuthKit 身份；将 GrandSlam User-Agent 改为匹配的 `akd/1.0 CFNetwork/808.1.4`。双重认证的 `/auth` 页面则按 SideInstaller 改用 Mac AuthKit client info（该端点会拒绝 Android 身份），验证提交仍用 Android 身份，同样使用 `akd` User-Agent。所有认证与验证码请求均改为短生命周期连接。保留现有 `adi.pb` 与设备标识；只有 Apple 明确返回“Device not provisioned”时才沿既有分支自动重新 provision。
- **涉及文件**：`Seal/Infrastructure/Accounts/AnisetteClient.swift`、`upstream/AltSign/Sources/ALTAppleAPI+Authentication.swift`。
- **验证状态**：真机构建 2 日志已证明连接隔离生效但不足以解决问题；字段组合已逐行与 SideInstaller 使用的 isideload 源码对照。Windows 无 Xcode，Swift 回归、IPA 打包和真机添加账号由下一次 CI 验证。

---

## 2026-10-14 Apple ID -80045 的 GrandSlam 连接复用

- **现象**：已正确读取 Apple 返回的 Anisette 同步指令后，真机添加 Apple ID 仍可能在密码交换前收到 `Apple.APIError -80045`。
- **根因**：Seal 复用 `ALTAppleAPI` 的长期 `URLSession` 发送全部 GrandSlam `init`/`complete` 请求。作为对照的 SideInstaller 上游实现明确禁用 GrandSlam 空闲连接复用；Apple GSA 可能拒绝同一空闲连接上的后续认证交换。
- **修复**：仅在 `sendAuthenticationRequest` 中为每个 GrandSlam 请求创建短生命周期的 ephemeral `URLSession`，请求完成即结束该会话，使每次 `init` 或 `complete` 从新连接开始。没有改变 Anisette 的设备身份、`client_info`、本地取用策略，也没有清除 `adi.pb` 或 Anisette 标识。
- **CI 守卫**：补上 `upstream/AltSign/**` 的 push 触发路径；该目录参与 Seal 编译，缺失该路径会让认证层修改不经 Swift 回归和 IPA 打包验证。
- **涉及文件**：`upstream/AltSign/Sources/ALTAppleAPI+Authentication.swift`。
- **验证状态**：已逐行对照 SideInstaller 所使用 isideload 的 `pool_max_idle_per_host(0)` 实现；`git diff --check` 与公开 iOS CI 将验证 Swift 编译和 IPA 打包，真机将复测原先失败的账号添加路径。

---

## 2026-10-14 Apple ID -80045 的 Anisette 自动同步未触发

- **现象**：构建 418 已加入 Apple 返回同步指令后的自动重试，但真机添加 Apple ID 仍收到 `SEAL-AUTH-80045`。
- **根因**：GrandSlam 协议将 `X-Apple-I-MD-DATA`（SIM）放在 `Response` 的同级响应字段；Seal 上一版错误地只从内层 `Status` 读取，导致 SIM 没有传给 Anisette 同步流程。同步是否需要应以 SIM 是否存在为准，不能只依赖部分响应才带的 `hsc=434`。
- **修复**：从 `Response` 读取 SIM，保留旧 `Status` 位置的兼容回退；收到 SIM 后即刷新 Anisette 并自动重试一次。不改客户端身份、不清除 `adi.pb` 或设备标识。
- **涉及文件**：`upstream/AltSign/Sources/ALTAppleAPI+Authentication.swift`、`Seal/Infrastructure/Accounts/AppleAccountClient.swift`。
- **验证状态**：协议字段位置已与 Blackwood 4NT GrandSlam 参考实现对照；`git diff --check` 通过。Windows 无 Xcode，完整 Swift 编译和 IPA 验证需由 iOS CI 执行，真机需复测此前失败的账号添加路径。

---

## 2026-10-13 自定义色相滑条无法在当前 SDK 编译

- **现象**：Swift 回归编译 `CustomAccentColorEditor` 时，色相滑条和色环的 `.magenta` 报 `Color has no member 'magenta'`，导致 IPA 无法产出。
- **根因**：项目当前的 SwiftUI SDK 不提供该简写颜色常量；同时主题名称映射漏掉新增的 `.custom` 枚举分支，主题测试又与既有设计系统测试重名而被 Xcode 同时编入目标。发布守卫还要求保留安装通道路由测试的回归锚点，并在关于页明确显示最低系统版本。
- **修复**：将两处洋红色节点改为等价的显式 RGB 值 `Color(red: 1, green: 0, blue: 0.5)`，补全自定义主题名称分支，并将新增主题色断言并入既有 `SealTests/DesignSystem/SealAppearanceTests.swift`；恢复通道路由测试锚点，在关于页新增“兼容性 / 最低支持 iOS 17.4”。
- **验证状态**：已由 CI 精确定位；修复后重新触发完整 Swift 回归与 IPA 打包。

---

## 2026-10-13 设置入口分散、LocalDevVPN 独立页和首启协议视觉不一致

- **现象**：根设置页混合展示大量状态、LocalDevVPN 作为独立页承接通道恢复、首启协议将协议链接和说明拆成两行并以分隔线隔开按钮；这些结构让用户难以判断入口含义，也容易把通道问题误认为账号问题。
- **修复**：重排为签名、到期提醒、管理、帮助与支持、诊断、关于六组；只有设备、外观与主题、存储与清理、关于 Seal 显示右侧摘要。移除独立 LocalDevVPN 设置页，通道恢复统一进入设备页并自动显示连接诊断。新增支持 Seal 页、关于页的状态化更新入口和法律入口。外观抽屉保留六个预设色，加入完成后才持久化的自定义 HEX 取色浮层。首启页改为单句可点协议、无分隔线抽屉，通知授权移至同意并进入主界面后。
- **验证状态**：路由回归已同步为 `.pairingDiagnostic`，协议布局测试已同步品牌文案；Windows 无 Xcode/Swift，完整 Swift 编译、测试和 IPA 打包交由本次 CI。

---

## 2026-10-13 Seal 正式版 1.0.0 被历史测试构建误判为降级

- **现象**：导入 CI #374 的 Seal `1.0.0 (359)` 到已安装 `1.3.x` 测试构建时，导入页按纯营销版本比较显示“降级”。
- **根因**：正式发布版本按产品约定从 `1.0.0` 起算，而 `1.3.x` 是此前测试序列；通用版本比较不了解这次一次性的版本序列切换。
- **修复**：只对当前运行中的 Seal 自身，且源包精确为 `1.0.0`、旧版本在 `1.3.x`、新 CI build 更高时，按正式版迁移归为升级。普通 IPA、旧 build 与后续任意真实降级仍保留二次确认。
- **验证状态**：新增 `1.3.45 (88) → 1.0.0 (359)` 导入回归测试；完整 Swift/iOS 验证交由 CI。

---

## 2026-10-13 Apple APIError -80045 被误导为凭据问题

- **现象**：添加 Apple ID 时返回 `Apple.APIError / -80045 / This action cannot be completed at this time.`。Seal 只将 503 归为 Apple 暂不可用，因而把该错误落入泛化“核对 Apple ID 与密码”。
- **外部证据**：2026-10-12 至 13 同一错误同时出现在 AltServer、Sideloadly、SideStore 与 iLoader 用户；Apple 官方状态页仍显示 Apple Account 可用。这能支持“认证/开发签名链路发生广泛临时拒绝或策略变化”，不能证明任一个账号被标记。
- **修复**：按精确域 `Apple.APIError` 与码 `-80045` 归为 `SEAL-AUTH-80045`，提示等待后重试、不连续重复登录或修改密码，并明确该错误本身不能判断账号被标记或锁定。三个账号映射入口、签名入口和通用失败入口统一使用此分类；不将账号标记为需重新验证。
- **验证状态**：新增精确命中、同码不同域排除、语义和账号状态回归测试；完整 Swift/iOS 验证待 CI。

---

## 2026-10-13 本地 Anisette 库打包失败被静默忽略

- **检查证据**：使用 REA 6.4.0 `inspect-artifact` 检查 `libCoreADI.so` 与 `libstoreservicescore.so`，两份均识别为 ELF 动态库；这只是静态清点，不证明运行时行为。现有 AnisetteKit 使用 ELF loader，打包脚本明确依赖这两份资源。
- **根因**：打包脚本的 `cp ... 2>/dev/null || true` 会掩盖复制失败，源目录缺失也仅发警告；IPA 校验只检查 Info.plist、扩展与敏感材料，未检查 Anisette 资源。
- **修复**：在 Xcode 构建前检查两份源库存在且非空；复制失败直接终止；IPA 校验要求包含两份库。不改变本地/远程 Anisette 的运行时选择。
- **验证状态**：两个 Shell 脚本的 `bash -n` 与 `git diff --check` 通过；隔离样本验证源库缺失、源库为空、IPA 分别缺少任一库时都以退出码 1 拒绝。完整 iOS 编译与运行时回归仍需 CI 和真机。

---

## 2026-10-13 iOS #370 的 R65⑤ 变异检查误报

- **现象**：提交 `7dfdea6` 的 iOS #370 在 `Check release safety invariants` 失败，未生成 IPA；公开注解只有退出码，无法直接辨认具体守卫。
- **根因**：R65⑤ 的变异预期仍是“必须把扩展拓扑委托给”，实际守卫已输出“必须**委托**给带扩展拓扑的”；变异循环用 `startswith(expected)` 匹配，故即使成功拒绝 `hasExtensions: false` 也会误报失败。
- **修复**：同步 R65⑤ 的预期前缀，保留扩展拓扑断言和变异；CI 中额外输出经过 `%`、CR、LF 转义的 GitHub error 注解，让具体失败原因可公开查看。不改签名、安装和续签行为，不跳过检查。
- **验证状态**：GitHub 已连接；读取 #370 完整日志确认唯一守卫失败为此 R65⑤ 变异匹配。已核对断言、变异锚点和预期前缀；按项目规则，完整守卫、Swift 回归和 signer 测试交由推送后的 CI，结果待回填。

---

## 2026-10-12 LiveContainer2 的 LiveProcess 虽在 IPA 内仍未被系统注册

- **现象**：LC2 的多任务小窗口调用 LiveProcess 时报告 `LiveProcess extension not found`。真机日志能证明签后 IPA 含有 `LiveProcess` target，却同时显示该 target 使用主包的描述文件；因此“扩展文件没有被删除”不是可运行性的充分条件。
- **根因**：`AppExtensionProfileStrategy` 把普通含扩展 IPA 默认设为 `sharedMainProfile`，并只在扩展的原始 entitlement 比主包多时才切换独立 profile。LiveProcess 的运行时注册还依赖该 target 自己的 App ID、profile 和 App Group 绑定，不能由“能力集合恰好被主包覆盖”推导出来。旧记录继续走 profile-only 时只更新描述文件，无法重写这个已安装的错误拓扑。
- **修复**：任何包含 `.appex` 的原始包默认并强制使用 `independentProfiles`：主包与每个扩展均建立自己的 App ID/profile，原有 Group 继续按既有确定性顺序绑定。续签准入拒绝旧的 `.sharedMainProfile` 及未记录策略的扩展包，自动回落一次完整重签覆盖安装；成功后持久化独立策略，后续续签才继续走 profile-only。实时身份快路径同样先经过该迁移闸门，不能绕过。
- **回归**：新增“普通含扩展包默认独立 profile”、“历史共享策略必须完整重签”、“缺失策略记录也必须迁移”与“实时身份不得绕过迁移”测试。CI `38210442046` 的 Swift 回归与 signer 测试已通过；其 release-safety job 失败仅因 R65 仍硬编码旧的共享默认合同。替换 CI `38212976469` 再次确认 Swift 与 signer 通过，但暴露 R65 的三个变异锚点仍使用旧断言前缀/过宽调用锚点；现已收紧并同步文案，等待下一条完整 CI。

---

## 2026-10-12 LiveContainer 扩展与 App Group 完整性

- **现象**：LiveContainer 运行时报告 `LiveProcess extension not found`；过去的签名链路仍有在扩展 App ID 或描述文件失败后移除 `.appex` 并继续打包的遗留分支。共享 profile 的判据又只看可提交的门户 feature，忽略 LiveProcess 的 `com.apple.developer.kernel.increased-memory-limit`。
- **根因**：把“可由 `updateAppId` 提交的 feature”误当成“可共用主描述文件”的能力边界。LiveProcess 因此错误共用主 profile，不能建立独立 App ID、profile 与 App Group 绑定；一旦旧降级分支被触发，profile-only 续签只能续描述文件，永远无法恢复已删二进制扩展。
- **修复**：拓扑判据读取原始且非 signer-managed entitlement，扩展存在主包未覆盖能力即使用独立 App ID/profile；门户 feature 请求仍只发送 Apple 支持的项。删除工作区删除扩展 API 和所有降级调用，任一扩展准备失败均不产出 IPA。签名后逐项核对 bundle 集；历史记录标记过已删扩展时强制完整重签，成功后才清除标记。
- **回归**：新增未映射 capability 仍触发独立 profile 的策略测试，以及历史缺扩展记录拒绝 profile-only 的策略测试。完整 iOS CI 将验证 Swift 编译、Signer、发布安全与 IPA 构建。

---

## 2026-10-12 Seal 覆盖更新已安装却永久停在待签名

- **现象**：导入 Seal IPA 后覆盖安装成功，新进程日志已记录 `SEAL-SELF-113`（运行包身份与候选一致），但应用仍在待签名页；刷新无效，再点签名又回到待签名。
- **根因**：导入路径为候选 Seal 建立带 `replacesInstalledAppID` 的新记录。该字段决定 `belongsInUnsignedList`，只有原子 `commitInstalledReplacement` 才应清除。自替换结算此前只把运行身份保存到首次取到的旧记录，普通 `save` 既未接管候选记录也未清字段；随后重复记录清理还可能删除候选，状态永远无法转正。
- **修复**：仅在新进程的 `.settle` 已确认安装分支中，查找指向当前旧 Seal 的最新导入替换记录；将真实运行身份写入该记录并通过 `commitInstalledReplacement` 原子移除旧记录、清除替换标记。未确认安装的 `.awaitNextLaunch` / `.closeAsNotInstalled` / `.requireRecovery` 均不改变。
- **回归**：新增 `confirmedImportedSealUpdatePromotesReplacementInsteadOfLeavingItUnsigned`，断言结算后只保留新 Seal 记录、替换字段为空、进入已安装列表而不在待签名列表。
- **验证状态**：完整 iOS CI `38193610140` 已通过构建、签名器边界、发布安全与 UI 回归；仅该 Swift 回归揭示重建本地 IPA 时遗漏写回已确认 profile UUID。现将已核验运行身份完整写回（UUID、到期、Team、签名目标），随后由替换 CI 验证。

## 2026-10-12 后台续签与证书轮换可能静默移除 LiveContainer 扩展

- **现象**：LiveContainer 运行时报告 `LiveProcess extension not found`，并提示重新安装且保留扩展。
- **根因**：普通单项签名默认禁止删除扩展，但 `SigningCoordinator.signAndInstall` 的默认参数却是允许；批量续签与证书轮换自动恢复没有显式覆盖该默认。若 Apple 为某个扩展创建 App ID 或生成描述文件失败，门户层会在允许降级时移除扩展并继续安装，后台路径因而可能把已安装产品替换为缺失 `LiveProcess` 的版本。
- **修复**：删除整个 `allowDroppingExtensions` 参数链及门户层物理删除扩展实现；所有单签、续签、批量续签和证书轮换都只能保留完整目标集。任一扩展无法取得正确 App ID 或描述文件时，整次签名停止，绝不安装残缺 IPA。
- **涉及文件**：`Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Core/Renewal/RenewalCoordinator.swift`、`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Scripts/tests/test_failure_contract_source.py`。
- **验证状态**：源级合同断言不再存在扩展删除入口；Windows 无 Swift/Xcode，完整 iOS CI 将编译和运行 Swift 回归。

---

## 2026-10-12 Seal 覆盖更新确认、列表可见性与单项结果日志互相打架

- **现象**：① 导入 Seal 更新包，在确认“覆盖更新”后会失败为 `SEAL-IPA-217`；② 覆盖更新签名期间，新旧两条 Seal 会同时出现在已安装列表，稍后才消失一条；③ 单独续签完成后日志出现一条新描述文件结果和一条旧格式结果。
- **根因**：① 界面专门把已安装 Seal 作为覆盖候选，但 `ImportWorkflow.commit` 又只调用刻意排除 `isSeal` 的普通覆盖校验，前后合同矛盾；② `AppRecord.belongsInInstalledList` 只在更新记录仍为 `.imported` 时排除它，签名协调器推进到 `.preflightPassed` / `.signing` 后，`isSeal` 兜底把它重新列入已安装页；③ `runSigning` 已在结果产生时写入统一的 `RenewalRoundSummary`，`dismissSigningResult` 又在关闭抽屉时写一份历史格式摘要。
- **修复**：① 仅当确认目标正是本次解析到的当前 Seal 记录时，进入既有自更新事务；普通应用仍使用严格的按 ID 覆盖复核；② 只要 `replacesInstalledAppID` 尚未由 `commitInstalledReplacement` 清空，Seal 更新记录始终留在待签名列表，设备验证成功后才原子接管；③ 关闭抽屉只做 UI 清理与后续重签调度，结果日志只在操作完成时写一次。
- **涉及文件**：`Seal/Core/Import/ImportWorkflow.swift`、`Seal/Core/Apps/AppRecord.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`SealTests/Import/ImportWorkflowTests.swift`、`SealTests/Apps/AppRecordTests.swift`、`Scripts/tests/test_failure_contract_source.py`。
- **验证状态**：两个新静态回归先红后绿；失败合同静态套件 27/27、错误码清单 11/11 与 `git diff --check` 通过。Windows 无 Swift/Xcode；覆盖 Seal 的 Swift 回归将由完整 iOS CI 编译执行。

---

## 2026-10-11 SideSign 回归测试按 Swift 6 Sendable 合同修正

- **现象**：完整 iOS CI `38138797034` 的新 SideSign 签名边界测试编译失败，错误为 `NSArray` 和 `[Any]` 不符合 Swift 6 的 `Sendable`。
- **根因**：生产接口的输入类型是 `[String: any Sendable]`，而测试试图把非 Sendable 的 Foundation 容器和 `Any` 数组直接塞入该接口；这不是签名器的运行失败，也不是可由该类型系统合法表达的描述文件值。
- **修复**：规范化器保持真实描述文件会解码出的 `[String]` 路径；删除不可表达输入的伪测试，改为验证一个合法但不受支持的 `Sendable` 标量会原样保留。这样继续验证“只排序 App Group 字符串数组、不猜测其他值”的产品合同。
- **验证状态**：已根据 CI 精确报错调整测试；待下一次完整 iOS CI 编译运行。

---

## 2026-10-11 App Group 顺序修复落在未编译签名器，删除 App ID 不是长期解法

- **复核结论**：工程 `project.yml` 的 `SideSign` 依赖实际指向 `Vendor/SideSign`；此前二进制 entitlement 排序只写进 `upstream/SideSign`，不会进入 Seal 构建产物。因此 build 171 中 LC2 恢复共享的直接原因是一次性删除并重建 App ID，而不是签名器规范化。
- **风险**：Apple 官方说明删除 App ID 会使包含它的描述文件失效。把单个 Bundle ID 和 Team ID 写死在正常签名路径中，既会破坏已有 profile，又无法覆盖其他存在同类 App Group 顺序差异的应用。
- **替换方案**：在实际构建依赖 `Vendor/SideSign` 的 `AppBundleSigner.prepare` 统一规范化 `com.apple.security.application-groups`：只接受全字符串数组、去重并排序；主包与每个扩展都经过该边界。Keychain access groups 等其他数组完全不改。门户侧继续稳定映射/排序，但二进制签名不再依赖 Apple 返回顺序。
- **续签边界**：profile-only 续签只更新描述文件、不重写二进制；历史逆序产物不会被伪称为已修复，下一次完整重签才会获得规范顺序。
- **删除**：移除 LC2 专用的一次性 `deleteAppID` 迁移，并把 R24 门户退避守卫从 9 个实际调用点调整为 8 个，同时新增禁止该硬编码迁移回归的守卫。
- **验证状态**：已新增 vendored signer 的排序/去重/类型保守/Keychain 不变测试和 profile-only 边界测试；Windows 本机没有 Swift/Xcode 工具链，Swift 测试待完整 iOS CI 编译执行。Python 语法、静态硬编码扫描、R24 调用点计数（8）与 `git diff --check` 通过。

---

## 2026-10-10 App Group 数组顺序导致多容器共享目录不一致（LiveContainer 主包 / LiveContainer2）

- **现象**：MJ 在主 LiveContainer 里把 App 转为共享 App，LiveContainer2 里看不见；LC2 提示"将 App 转换为共享 App 以在 livecontainer2 中使用"。
- **根因**：两包 `com.apple.security.application-groups` 集合相同（`group.com.SideStore.SideStore` + `group.com.rileytestut.AltStore`，映射后均带 `.seal.<teamID>`），但原包 entitlement 数组顺序相反（主包 SideStore 在前、LC2 是 AltStore 在前）。Seal 按原包顺序原样映射进描述文件并写入 Info.plist `ALTAppGroups`；运行时取第 0 个当共享目录 ⇒ 主包用 SideStore 的目录、LC2 用 AltStore 的目录，各写各读。MJ 提供的两份签名后 entitlement plist 与 Seal 免 JIT 诊断页"App Group 名"逐字证实。
- **修复（第一轮，119f1a8，未生效）**：`assignAppGroups` 对映射后的 group ID 排序 + Info.plist `ALTAppGroups` 落盘排序。真机验证失败：18:57 用 build 166 重签 LC2 后，二进制 entitlements 仍是 [AltStore, SideStore]。查日志发现两点：① 重签时 App ID 能力"已满足本次请求，跳过重复更新"，`assignAppGroups` 的排序对已存在的 App ID 无意义；② 即使 assign 跑了，Apple 的 `assignApplicationGroupToAppId.action` 不重排已有绑定；③ 实测证明 LiveContainer 读的是**二进制 entitlements 第 0 个**，不是 Info.plist `ALTAppGroups`（Info.plist 已被排序但 LC2 仍为空）。
- **修复（第二轮，真正生效）**：上游签名器 `AppBundleSigner.prepare` 在把 `matchedProfile.entitlements` 序列化写进二进制之前，对 `com.apple.security.application-groups` 数组做字母排序。不依赖 Apple 侧顺序，每次签名结果确定。安全性：iOS 只校验「二进制请求的组 ⊆ 描述文件允许的组」（集合关系），Seal 自检 `ProvisioningEntitlementValue.permits` 同样按集合实现，顺序不影响安装与运行。另在 Seal 侧加一条诊断日志（仅当排序改变顺序时）：打出"描述文件原顺序 → 排序后"，方便真机核验。`assignAppGroups` 与 Info.plist 两处排序保留，保证 Apple 侧（新 App ID）与落盘侧一致。
- **涉及文件**：`upstream/SideSign/Sources/CodeSigning/CodeSignerAPI.swift`（`prepare` 内排序）、`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`（排序生效日志）。
- **修复（第三轮，根治）**：MJ 明确要求"直接从根上排"。既然 Apple 侧 App ID 的组顺序改不了（assign 不重排），且上游签名器排序三轮均未生效，改为**删除重建 LC2 的 App ID**：下次签名 LC2 时，Seal 自动删除旧 App ID（一次性，UserDefaults 标记防重复），随后流程按新 App ID 走——`assignAppGroups` 不再被跳过，我的字母排序在全新绑定时生效，Apple 侧顺序从根上就是 [SideStore, AltStore]。涉及文件：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`（App ID 准备循环内的一次性重建逻辑，`withSessionRecovery` 包裹，R24 守卫已同步到 9 个调用点）。
- **验证状态**：本地 `Scripts/pre-push-check.py` 836 checks 0 failures；待 CI 出包、MJ 真机重签 LC2（日志应出现"正在重建 LiveContainer2 的 App ID…"），然后确认共享 App 出现。

## 2026-10-10 发布安全守卫未绑定 App ID 新建缓存失效调用点

- **现象**：LiveContainer2 的一次性 App ID 重建新增第二个 `invalidateAppIDsCache` 调用后，完整 iOS CI 的 `R112③b` 变异检查失败；产品代码仍包含新建 App ID 后的缓存失效逻辑。
- **根因**：守卫的变异锚点只匹配裸调用文本，`replace(..., 1)` 先替换到新增加的“删除 App ID 后失效缓存”调用，真正要保护的“`addAppID` 成功后失效缓存”调用仍在，导致守卫无法检验自身判据。
- **首次修复为何仍失败**：变异锚点虽已改为 `addAppID` 成功块，但 R112③b 本体仍在整份文件中搜索裸 `invalidateAppIDsCache`；新增的“删除旧 App ID 后失效缓存”调用仍会满足它，因此变异依旧被放过。
- **根治**：变异锚点保留为 `appID = createdBox.value` 与紧随其后的缓存失效完整代码块；R112③b 本体改为先截取 `addAppID` 成功到 `bundleIdentifierUnavailable` 恢复分支之间的代码区间，再只在该区间验证缓存失效调用。这样删除路径的同名调用不能再替代新建路径的安全网；不改变产品 App ID 行为。
- **涉及文件**：`Scripts/verify-release-safety.py`、`SealTests/Import/FailureContractTests.swift`。
- **验证状态**：待完整 iOS CI 重新执行发布安全守卫与 Swift 回归测试。

## 2026-10-10 失败归类基础：Apple 超时被通用 500 文案吞没

- **现象**：Apple 开发者服务请求超时可在单次签名、单项续签和全部续签中上抛，但多个边界会把非 `ImportFailure` 统一改写为 `SEAL-SIGN-500` 或 `SEAL-RENEW-500`，用户只能看到“未知错误”。
- **已确认事实**：`AppleServiceFailurePolicy.isNetworkError` 已明确把 `URLError.timedOut`、DNS 和连接失败归为网络类；`ImportFailure` 已具备 `condition`、`action`、`operation`、`origin` 和 `diagnosticID` 字段。此前缺的是一个统一的原始异常分类边界，而不是新增一套基于文案/错误码前缀的猜测。
- **本批修复**：新增 `FailureClassifier` 与 `FailureDiagnosticRecord`。分类器仅保留已确认的 `ImportFailure`，或把 Apple 限流/网络异常映射为明确语义；未确认异常保持 `unexpected + copyDiagnostics`。诊断记录使用现有隐私脱敏器并额外移除请求 URL。
- **边界**：本批只建立和测试分类契约，尚未替换签名/续签边界的旧 500 包装；下一批会逐处接入并验证传播链。
- **验证状态**：本机缺少 Swift/XcodeGen/Xcode 工具链，无法运行新增 Swift Testing；已检查测试在实现前引用的类型不存在，待 macOS CI 执行编译与测试。

## 2026-10-10 失败归类接入：签名与批量续签保留 Apple 超时

- **现象**：`AppsViewModel.signingFailure` 和 `RenewalCoordinator.normalize` 分别在单次与批量入口将原始 `URLError.timedOut` 改写为通用 500，用户操作被错误地降级为“未知错误”。
- **根因**：两个边界各自持有一份通用兜底，没有共享语义合同；设备通道虽然有专项分支，但 Apple 网络错误没有在进入 UI 前被分类。
- **修复**：单次入口与批量入口统一调用 `FailureClassifier`；单次续签显式传入 `.renew`，批量传入 `.batchRenew`。设备通道仍保留 `SEAL-SIGN-504` 与 LocalDevVPN 路由，并补齐对应的结构化语义，避免其它错误被误导到 VPN。
- **验证状态**：新增单次与批量 Apple 超时回归。因本机无 Swift/Xcode 工具链，待本批 macOS CI 编译与执行。

## 2026-10-10 profile-only 缺失 App ID 的恢复动作统一

- **现象**：profile-only 续签的两个 App ID 查询路径都识别到 `SEAL-PROFILE-337`，但仍各自手写文案和基础 `ImportFailure`，没有带上“完整重签”的结构化动作。
- **根因**：已存在 `ImportFailure.profileOnlyAppIDMissing(operation:)` 工厂，但 Apple Portal 实现没有接入它，导致 UI/账号状态逻辑只能重新从错误码推断意图。
- **修复**：新增 `ApplePortalSigningFailure.profileOnlyAppIDMissing()` 作为门户边界工厂，两条查询路径统一使用；结果固定为 `.fullResign`、`.renew`、`.provisioning`，且账号验证策略不会把它误判为需要重新验证。
- **验证状态**：新增门户失败工厂回归；待 macOS CI 编译与执行。

## 2026-10-10 错误帮助的证据边界与日志错误码保留

- **现象**：现有“查看解决办法”直接跳官网，离线时无法查看；日志轮次卡片提取到失败文案后会丢失原始 `SEAL-*` 错误码，导致无法可靠关联解决方案。过去把错误码直接解释成单一根因，也会把网络、设备或 Apple 限制误导成“账号失效”。
- **根因**：错误知识只分散在代码与日志里，没有携带置信等级和反证边界的结构化索引；日志解析器在截取 `✗` 标记后舍弃了前置错误码。
- **修复**：以 `docs/error-catalog/` 为唯一真源生成网页与 App 同字节离线索引；应用内新增错误帮助页与未知码兜底，明确标示“已确认 / 需要进一步确认 / 尚未能确认原因”；日志解析保留原始错误码并优先打开对应离线条目；完整与发布 CI 均验证目录、生成结果和一致性。
- **涉及文件**：`Scripts/error_catalog.py`、`docs/error-catalog/`、`ErrorKnowledgeStore`、`ErrorHelpView`、`LogViewerView`、三处签名错误入口及相关测试。
- **验证状态**：Python 目录校验、生成一致性与高风险条目测试已通过；Windows 无 Xcode/Swift 工具链，待完整 iOS CI 编译、Swift Testing 与真机回归。

## 2026-10-10 抽屉路由、日志导出与 Seal 自替换状态同步

- **现象**：单项签名/续签结束时会闪回旧的应用操作抽屉；日志导出有时打开“日志文件不存在”的空白页；Seal 自替换重开后仍显示“需重新签名”，手动刷新才消失；欢迎页抽屉会在阅读协议后保持过高。
- **根因**：应用操作抽屉的选择状态在续签开始和结果关闭时仍保留；日志 sheet 由独立的布尔值与 URL 驱动，存在不同渲染事务；自替换通知走渐进式 `load()`，记录先发布而证书派生状态异步更新；协议页没有阅读/欢迎两种 detent 状态。
- **修复**：续签前和操作关闭时清除旧路由；日志分享页改由已验证存在的 `LogExportDocument` 单一状态驱动；自替换通知走原子快照刷新；欢迎页固定紧凑，进入协议时切大页、返回恢复紧凑。
- **涉及文件**：`AppsRootView`、`AppsViewModel`、`LogViewerView`、`LogExportDocument`、`AgreementOnboardingView`、`AgreementOnboardingPresentationState` 与对应测试。
- **验证状态**：已完成静态差异与错误码唯一性检查；Windows 无 iOS 编译工具链，待完整 iOS CI 编译、单测与真机回归。

## 2026-10-10 协议正文切换白屏与欢迎抽屉跳变

- **现象**：点开隐私政策或用户协议时短暂白半屏、卡顿；返回时欢迎抽屉从大页瞬间缩回小页。
- **根因**：同一原生 sheet 在 `NavigationLink` push 的同时，把 detent 集合从紧凑替换为大页；UIKit 因呈现容器重配出现白屏与非连续高度变化。
- **修复**：欢迎抽屉固定唯一紧凑 detent；协议正文改为叠加在其上的独立全屏原生阅读页，关闭阅读页即回到未改变高度的欢迎抽屉。
- **涉及文件**：`AgreementOnboardingView`、`AgreementOnboardingPresentationState`、`AgreementOnboardingLayoutTests`。
- **验证状态**：待完整 iOS CI 与真机检查切换动画。

## 2026-10-10 欢迎页品牌区比例与文案收敛

- **现象**：预览稿容易把官方图标和品牌字放大，欢迎抽屉标题又重复出现 Seal，首屏层级显得拥挤。
- **根因**：品牌尺寸与文案没有作为布局契约集中管理，视图中保留旧的 112pt 图标、旧标语与重复标题。
- **修复**：将真实设备尺寸集中为 92pt 官方 Icon、46pt Seal、20pt 标语；标语统一为“让应用始终可用”，抽屉标题为“欢迎使用”，并降低蓝色光斑强度。
- **涉及文件**：`AgreementOnboardingView`、`AgreementOnboardingLayoutTests`。
- **验证状态**：Windows 无 Xcode，待完整 iOS CI 编译、单测及真机视觉验收。

## 2026-10-10 Profile-only 续签回归断言语义对齐

- **现象**：完整 iOS CI 的两个 `ProfileOnlyRenewalPolicyTests` 失败；实际判定为 `incompleteSigningIdentity`，旧断言仍期待 `missingInstalledArtifact`。
- **根因**：`Signed.ipa` 被重定义为可清理的安装缓存后，策略不再以缓存缺失作为 profile-only 的拦截依据；旧测试没有同步更新失败原因的语义。
- **修复**：保留正确的执行策略，更新两条无实时身份场景的断言及说明为“不完整签名身份”。
- **验证状态**：完整包构建、IPA 校验和安全守卫已通过；待下一轮完整 CI 验证 Swift 回归。

## 2026-10-10 协议抽屉拒绝后的恢复与布局

- **现象**：点“暂不使用”后，确认提示里的“好的”不能稳定重新显示协议抽屉，用户会留在不可操作的背景页；首屏抽屉偏高，品牌区也偏上。
- **根因**：在 alert 的按钮回调内立即把 sheet 的绑定重新设为 `true`，该回调仍和刚关闭的 sheet 处于同一个 SwiftUI presentation 事务，恢复写入可能被 dismissal 吞掉。
- **修复**：拒绝状态显式记录“等待确认”，等 alert 的绑定实际变为 `false` 后再恢复 sheet；初始抽屉由 44% 收紧为 38%，品牌区整体下移。
- **涉及文件**：`AgreementOnboardingView`、`AgreementOnboardingPresentationState`、`AgreementOnboardingLayoutTests`。
- **验证状态**：已补状态机回归断言，待完整 iOS CI 与真机验证。

## 2026-10-10 存储缓存、单项日志与首次导出可靠性

- **现象**：清理 `Signed.ipa` 后，应用记录被降级为“缺少已安装产物”，正常的描述文件续签被误导为完整重签；日志首次导出通过通知后固定等待 0.8 秒，异步镜像慢时会报“日志文件不存在”；单项签名/续签没有与“续签全部”相同的轮次摘要和真实共用耗时。
- **根因**：把可重建的安装缓存、已安装身份和续签准入混在同一组字段/状态里；导出页没有对日志 actor 的写入完成确认；轮次格式只在 `RenewalCoordinator` 的批量路径生成。
- **修复**：新增纯 `SignedIPACacheCleanupPolicy`，仅回收稳定已安装的缓存，并只清除缓存元数据；profile-only 准入不再依赖 `Signed.ipa`；日志导出改为 `SealLogStore.materializeExport()` 返回已落盘 URL；单项操作复用轮次摘要格式，成功和失败都记录真实耗时及“共用 x 秒”。
- **涉及文件**：`AppRecord`、`ProfileOnlyRenewalPolicy`、`SignedIPACacheCleanupPolicy`、`SettingsViewModel`、`SealLogStore`、`LogViewerView`、`RenewalRoundSummary`、`AppsViewModel`。
- **验证状态**：已新增回归测试；Windows 无 Xcode/Swift 工具链，待完整 iOS CI 编译、单测和真机验证。

## 2026-10-09 覆盖更新流程重设计：走待签名页

- **背景**：MJ 要求"其他 ipa 覆盖更新都是已安装列表的 ipa 先到待签名页，签名成功再回来，这样所有状态都能刷新同步了，Seal 能做到吗"。批准后实施。
- **旧设计**：导入新 IPA 时复用已安装记录的 ID，`state` 保持 `.installed`，标记 `hasPendingSelfUpdateSource=true` + `pendingUpdateSourceFingerprint`。已安装列表显示"有新版本待安装"标签。
- **新设计**：
  - `AppRecord` 新增 `replacesInstalledAppID: UUID?` 字段。
  - `ImportWorkflow.makeSelfUpdateRecord` / `makeInstalledUpdateRecord` 改为建**新的待签名记录**（新 UUID，`state: .imported`），`replacesInstalledAppID` 指向被替换的已安装记录。不再复用 ID、不再标记 pending。
  - `SigningCoordinator` 安装成功后，若 `replacesInstalledAppID` 非空，删除旧记录，本记录转正。
  - 流程：导入新 IPA → 待签名列表 → 用户签名 → 成功 → 替换已安装记录。Seal 与其它 IPA 走同一套。
- **涉及文件**：`Seal/Core/Apps/AppRecord.swift`、`Seal/Core/Import/ImportWorkflow.swift`、`Seal/Core/Signing/SigningCoordinator.swift`、`Scripts/verify-release-safety.py`（守卫同步更新）。
- **验证状态**：守卫 834 项 0 failures。未推，等 MJ 说推。真机未验证。
- **注意**：旧版已标记 `hasPendingSelfUpdateSource` 的记录仍会显示标签，直到用户重新导入新包走新流程。

## 2026-10-08 自更新失败的「同版本」角：草稿被转正 + 丢弃后又被旧快照写回

- **现象**：Seal 自更新失败（`.closeAsNotInstalled`）后，记录里的有效期 / 证书序列号
  会显示成**候选包**那份 —— 而设备上跑的仍是旧包，那份身份设备上根本不存在。
  后果不是显示难看，是**用户直到被吊销都收不到提醒**（提醒读的就是记录里的有效期）。
- **根因（两层，缺一不可）**：
  1. **判据只认版本号**：`reconcileSealRecordFromRunningBundleIfNeeded` 里判断
     「候选没在设备上」用的是 `hasPendingSelfUpdateSource && version != 运行版本`。
     **同版本**续签的自更新失败时两边版本**完全相同** ⇒ 判据恒为 false
     ⇒ `commitPendingSnapshot()` 把签名阶段的草稿转正成顶层真相。
  2. **返回值破坏了调用契约**：`.closeAsNotInstalled` 分支结尾是 `return false`，
     而 `reconcileSelfReplacement` 的契约写的是「返回**是否推进了记录**，调用方在结算后
     **必须重新读取记录**，避免用旧快照覆盖刚确认的真实身份」。这里明明推进了记录却报 false
     ⇒ 调用方**不重读**，手上那份旧快照（还带着刚被丢弃的 `pendingSignedSnapshot`）
     继续往后走，后面几轮对账把它**原样写回库**：刚丢弃的候选身份当场复活。
     真机上「同版本失败」正好同时踩中这两层，所以现象是稳定复现的。
- **修复**：
  - `reconcileSealRecordFromRunningBundleIfNeeded` 新增参数
    `candidateConfirmedNotInstalled: Bool = false` —— 由**调用方显式声明**候选的去向，
    不再让结算函数从版本号猜。判据改为
    `candidateIsOffDevice = candidateConfirmedNotInstalled || (有待安装源 && 版本不一致)`。
  - `.closeAsNotInstalled` 调用点传 `candidateConfirmedNotInstalled: true`，
    并把结尾改成 **`return true`**（「不算成功」已经由 `settlePendingBatchSealResult(to: .failed)`
    表达，与返回值是两件事）。
- **测试**：新增 `SelfAppRegistrarTests.sameVersionFailedSelfReplacementDiscardsThePendingSnapshot`
  —— 记录版本与运行包**一致**、顶层是旧 profile、草稿里是候选身份，
  跑完 `ensureRegistered()` 后断言草稿为 nil、顶层仍是设备现实、候选证书序列号没被写上顶层。
- **顺手重做开屏协议页版式**（用户反馈「大小、间隙太割裂」）：
  一张玻璃卡片 = 一组同类信息（信任摘要一张卡 / 协议入口一张卡），
  组内细线内缩对齐文字起点，组间同一档间距；间距只留四档、圆角只留两档；
  主按钮改用设计系统的 `sealPrimaryAction`（原来手写的 52pt / 字号 17 / 圆角 15 与全 App 不一致）。
  ⚠️ 保留 `欢迎使用 Seal` / `同意并继续` / `暂不使用` 三条 UI 用例锚点，一条都没动。
- **涉及文件**：`Seal/Core/Renewal/SelfAppRegistrar.swift`、
  `Seal/Features/Settings/AgreementOnboardingView.swift`、
  `SealTests/Renewal/SelfAppRegistrarTests.swift`、`docs/knowledge/PITFALLS.md`。
- **教训**：① 「两个原因**同时**成立才会复现」的 bug，只修一层会得到「修了但没好转」——
  改完必须把整条链上的每一跳都重新走一遍。
  ② 返回值的**契约写在注释里**就得当成契约遵守：`false` 在这里被当成「本轮不算成功」用，
  但它真正的含义是「记录没变，你别重读」——**同一句话被两个含义借用，必然出错**。
  ③ 内存里的旧副本 + 后面还有几轮同样的对账 = **沉默的写回**。凡是「算一次、存一份、
  后面还会再算几次」的链路，都要问一句「手上这份还是最新的吗」。

---

## 2026-10-08 同版本续签 / 自更新失败不落库（结算缺口）+「需重新签名」文案滞后一拍

- **现象（MJ 真机）**：重新续签 + 安装替换 Seal 之后，点进应用详情页，颜色已经更新，
  但「需重新签名」文案没有**立马**更新（要等下一次刷新才变）。
- **根因（同一天查出两处）**：
  1. **结算缺口** —— `SelfAppRegistrar.reconcileSealRecordFromRunningBundleIfNeeded`：
     两阶段提交重构（`6c080cc`）把「按运行包结算 profile 身份」整段挪进了
     `if existing.pendingSignedSnapshot != nil` 分支 ⇒ **没有草稿时整个对账空转**。
     于是这两类记录永远停在签名阶段的乐观值：
     ① 自更新失败（有待安装源但候选没落盘）；
     ② 用户在别处重签了 Seal 再装回来 —— **版本号不变**，只比版本号看不出来（R07 正是防这个）。
  2. **派生状态只算一次** —— `AppsViewModel.localCertificateAvailabilityByAppID`
     只在 `load()` 的后台任务里算一次，输入是记录里的 `certificateSerialNumber`；
     而续签 / 自替换结算会改那个字段 ⇒ 颜色（读记录，已变）与文案（读快照，还是旧的）**不同帧**。
- **修复**：
  - 对账改成两步：① 草稿去留按回滚判据（丢弃 / 转正）；② **标量身份**最后统一由
    「运行包 = 设备现实」覆盖。触发覆盖的条件是**能区分情形**的标记：
    **回滚**（有待安装源且版本不一致）或**运行包报出的有效期更晚**。
    ⚠️ 反向（记录更新、运行包是旧 embedded profile）**绝不回盖** ——
    profile-only 续签只注入新描述文件、不重装 App，回盖会把刚续的 profile 打回原地；
    唯一的例外是「**存在待安装的自更新源**」（那份新身份只存在于签名产物里）。
  - `AppsViewModel` 存下 `accountSecrets`，新增 `refreshCertAvailability()`，
    在**写入 `apps` 之后**与**密钥读回之后**各重算一次（两个输入各变一次算一次）。
- **顺手清理死参数**：`profileKeepMap(records:sealProfileUUID:)` 的 `sealProfileUUID`
  自 2026-10-07（Seal 永不进严格保留集合）起已无用处，连同
  `AppMaintenanceJob.sealRunningProfileUUID` 与 `AppContainer` 里读运行包的那段闭包一起删掉。
- **测试同步（CI run 37764867836 报红 4 套件 / 7 测试 / 21 断言）**：全部是「生产代码改了、
  断言没跟上」，逐条对齐语义：
  - `ProfileOnlyRenewalRecordUpdaterTests`（2）：改断言两阶段草稿 + 转正后顶层（保留 R65⑭ 要求的测试名）。
  - `AppMaintenanceJobTests`（2）：改断言 Seal **永不**进严格保留集合（旧名 `sealRunningProfileOverrides…`
    的语义已反转，随重命名对齐）。
  - `SelfAppRegistrarTests`（1）：`failedSelfUpdateRollsBackToTheRunningBundleProfile` 夹具补
    `hasPendingSelfUpdateSource = true` —— 「自更新失败」的前提就是导入过自更新源；
    没有这个标记就无法把它和 profile-only 续签区分开。
  - `SelfAppPendingHandoffTests`（1）：靠上面那处生产修复通过，断言未改。
- **同时修掉守卫唯一那条变异未命中**：`E: signed artifact and installed snapshot must be separated`
  的断言查的是**裸 token** `awaitingVerification`，而 `SignedArtifactSnapshot.swift` 第 14 行的
  **注释**里也有这个词 ⇒ 把返回表达式退成 `return .installed` 之后 token 仍在、照样通过。
  改成查**那一行表达式**本身（见 PITFALLS 第 6 条新增的第二种形态）。
- **涉及文件**：`Seal/Core/Renewal/SelfAppRegistrar.swift`、`Seal/Features/Apps/AppsViewModel.swift`、
  `Seal/Core/Maintenance/AppMaintenanceJob.swift`、`Seal/Application/AppContainer.swift`、
  4 个测试文件、`Scripts/verify-release-safety.py`、`docs/knowledge/PITFALLS.md`。
- **验证状态**：守卫断言本体 **835 项 0 failures**；593 条变异锚点**全部存在**；
  涉及改动文件的 **82 条变异 82/82 保持判别力**（含之前漏抓的 E 条）。
  待 CI 终审：`swift-regression`（841 个单测）+ `build-package`（全量 593 条变异）。
- **教训**：① 「没有草稿就什么都不做」等于把整条自愈链掐断 —— 写条件分支时要问「不满足条件时谁兜底」。
  ② 派生状态的两个输入各变一次就要各算一次，否则 UI 会**不同帧**。
  ③ 改行为时把配套入口（死参数）一起删掉，否则后人会以为它还在起作用。
  ④ 断言查 token 前先想**注释里有没有同一个词**（同一类坑第 6 条已经记过一次了）。

---

## 2026-10-08 开屏协议门控把 7 个 UI 用例全挡在门外（CI 自 2026-10-05 起第一次真跑完就红）

- **现象（CI run 37782585836 / 上一次 37764867836）**：`swift-regression` 红，
  报 `ImportFlowUITests` ×6 + `RootNavigationUITests` ×1 共 **7 个 UI 用例 / 25 处断言**失败，
  报错形如 `ImportFlowUITests.swift:10: XCTAssertTrue failed`
  以及 `No matches found for Descendants matching type TabBar`。
- **关键辨识点**：同一个 run 里**841 个单测全绿**（含上一轮修的那 7 个），
  且两次 run 的 UI 报错**文件:行号与消息逐字相同** ⇒ 与本轮改动**无关**，是既存红点。
- **根因**：`f0c7e03`（2026-10-07「实时刷新 + 定位保活退役 + 企业级协议」）新增了
  `AgreementOnboardingView` + `SealApp` 里的 `agreementAccepted` 门控 —— 它把**整个**
  `RootTabView` 挡在协议页后面。而 `SealUITests` 的用例都是 `app.launch()` 后直接去找
  根界面元素（tab 栏 /「待签名，N 个」/ 导入入口），从没点掉这层门 ⇒ 全部停在协议页。
  证据是 XCTest 在查不到元素时 dump 出来的界面树，上面只有：
  `隐私政策`、`用户协议`、`《隐私政策》`、`《用户协议》`、`同意并继续`、`暂不使用`。
  **该提交一行没改 `SealUITests/`**（`git log -- SealUITests/` 自 `c505e4a` 起为空）。
- **为什么一直没暴露**：2026-10-05 `c505e4a` 是最后一次 `swift-regression` 全绿；
  之后 100 次 run 里 **70 次 `cancelled`**（被新推送顶掉，job 根本没跑完）
  ⇒ 直到 2026-10-08 才第一次真跑完并报出来，很容易被误判成「本轮改动引入的回归」。
- **为什么早该有测试**：门控（合规）与其它 UI 是**互斥**关系 ——
  门控一旦生效，其它 UI 用例就全部失效。这类「前置门」必须在加进来时同步测试，
  否则它会**静默换掉**整个 UI 测试套件的语义。
- **修复**：
  - 生产侧只加一个**显式**启动参数 `--ui-testing-agreement-accepted`（`needsAgreementOnboarding(arguments:)`），
    `SealApp` **一行未动**。真实用户拿不到这个参数（iOS 上启动参数只有 Xcode / `simctl` 能传）
    ⇒ 门控对真实首启的行为完全不变。
  - ⚠️ 刻意**不**写成「`--ui-testing-` 前缀」这类隐式规则：AGENTS.md §3 明确
    「显式集合，禁止前缀与数字区间」—— 前缀规则会让「哪些参数能开门」不可枚举。
  - `SealUITests/ImportFlowUITests.swift`（两处启动点）与 `RootNavigationUITests.swift` 补上该参数。
  - 新增 `SealUITests/AgreementGateUITests.swift`：**真正**覆盖门控 ——
    断言「未同意时看不到主界面」→ 点「同意并继续」→ 断言**真的进得去主界面**。
    「未同意」这个前提用启动参数 `-seal.agreedAgreementVersion 0` 钉进 `NSArgumentDomain`
    （优先级高于持久域、不落盘）⇒ 不依赖模拟器里攒下来的 `UserDefaults`、不受执行顺序影响。
  - 两类用例分工：既有用例**显式越过**门控（快、确定）；门控本身由新用例负责。
    只留旁路 ⇒ 门控被删掉也没人知道。
- **涉及文件**：`Seal/Features/Settings/AgreementOnboardingView.swift`、
  `SealUITests/ImportFlowUITests.swift`、`SealUITests/RootNavigationUITests.swift`、
  `SealUITests/AgreementGateUITests.swift`（新增）、`docs/knowledge/PITFALLS.md`。
- **验证状态**：守卫断言本体 **835 项 0 failures**；593 条变异锚点**全部存在**；
  涉及改动文件的 **4 条变异 4/4 保持判别力**。
  ⚠️ 本机**无 Swift 工具链、无 iOS 模拟器** ⇒ 这几处 Swift / UI 测试改动**只能靠 CI 编译与真跑**，
  待 CI 终审。
- **教训**：① 看到「单测全绿、只有 UI 用例红」且报错两次 run 逐字相同时，
  先怀疑**前置门 / 环境**，不要怀疑业务逻辑。
  ② CI 历史里大量 `cancelled` 会造成**假绿/假静默** —— 判断「是不是我改坏的」必须看
  「上一次**真正跑完**的 run」而不是「上一次 run」。
  ③ 给界面加**前置门**（协议 / 登录 / 引导）时必须同步 UI 测试，
  否则它会静默把整套 UI 用例变成「门控用例」。

---

- **现象**：MJ 要求全量审查，查出 27 个问题（10 严重/9 中等/8 轻微）。
- **根因**：见 `~/workspace/Seal全量问题集锦.md`，每个问题都有文件行号。
- **修复**：
  - 图标/标签组：updatePreferredIcon 加 load 刷新；导入抽屉图标昵称合并保存；同 build 异包标签走指纹；列表行走解码缓存；FIFO 改 LRU。
  - 签名/续签组：自替换 IPA 复用 Data（省 30MB）；预测补齐 5 条件；renewalExecutionPaths 每轮清空；SELF-111 宽限期补洞；启动兜底只清标记不记已装；prepare 加 defer 清缓存；removeStaleProfiles 改 await。
  - 日志/设置组：导出先发通知落盘；LogRound 收尾未闭合块；SEAL-MEM-001 移到 mirror 后；协议版本只留一个源；测试 tearDown 清对 key；删 setReminderHours/communityCard 死代码；ForEach 改 offset。
  - 内存/版本组：NSCache 传 cost；countLimit 统一 10；compareVersions 调 Version.compare；beta 版按 0 处理；observer 存 token。
  - 开屏页：间距改 8pt 基准（40/16/8/24/16/12）。
- **涉及文件**：24 个（见 git status）。
- **验证状态**：守卫 831 项 0 failures，未推，等 MJ 说推。
- **教训**："全量保存+陈旧快照"是图标问题的万恶之源；NSCache 不传 cost 上限形同虚设。

---

## 2026-10-08 476ea0f 「有新版本待安装」标签常驻：只改了详情页，漏了列表行

- **现象**：MJ 反馈 Seal 自替换后，已安装列表 Seal 行的「有新版本待安装」标签一直在，点进去详情页标签也不消失。
- **根因**：标签有两个显示入口：① `ImportedAppRow.pendingUpdateKind`（列表行）；② `AppPresentation.pendingUpdateNote`（详情页/操作抽屉）。之前只给 ② 加了 build 号一致就不显示的判断，漏了 ①。列表行走自己的 `pendingUpdateKind`，直接调 `ProfileOnlyRenewalPolicy.pendingUpdateKind`，没有 build 号兜底。
- **修复**：`ImportedAppRow.pendingUpdateKind` 开头加 build 号判断：`Bundle.main` 的 `CFBundleVersion` 与 `app.buildNumber` 一致时直接返回 nil。
- **涉及文件**：`Seal/Features/Apps/ImportedAppRow.swift`。
- **验证状态**：待 CI + 真机（MJ 装新包验证标签消失）。
- **教训**：改 UI 显示逻辑必须并发查所有调用方，不能只改一处。这次是典型的「补东墙漏西墙」。

---

## 2026-10-08 83c26f4 `if let` 绑非可选 String：编译失败

- **现象**：c54db07 的 Fast run 37711643262 编译失败。CI 日志（经 MJ 授权拉取）指向 `AppPresentation.swift` 的 `if let recordedBuild = app.buildNumber`。
- **根因**：`app.buildNumber` 是非可选 `String`，`if let` 只能绑 Optional ⇒ 编译错误。手写时没核对类型（不是 CI 缓存问题——禁止猜测的又一实例）。
- **修复**：去掉 `if let`，直接 `runningBuild == app.buildNumber` 比较。
- **涉及文件**：`Seal/Features/Apps/AppPresentation.swift`。
- **验证状态**：已推，待 Fast CI。

---

## 2026-10-08 c54db07 「有新版本待安装」红标自替换后不消失：双保险

- **现象**：MJ 真机反馈（附截图 + Seal-log-30.txt）：Seal 自替重新安装后，后台进程还在跑，「有新版本待安装」标签仍然显示。
- **根因**：两处判据都太紧：① `SelfAppRegistrar` 清待安装指纹要求「build 号不同」才清，自替换后运行包与记录同 build 号 ⇒ 不清；② 显示层只看标志，没把「记录 build 号 == 运行 build 号」当作已安装。
- **修复**：① 只要 pending 指纹在就清，不再要求 build 号不同；② 显示层加一刀：Seal 记录 build 号与运行一致时直接不显示标签。
- **涉及文件**：`Seal/Core/Renewal/SelfAppRegistrar.swift`、`Seal/Features/Apps/AppPresentation.swift`；知识库 5 文件同步建好（ARCHITECTURE/CODEMAP/DECISIONS/PITFALLS/README）。
- **验证状态**：已推，待 Fast CI + MJ 真机。

---

## 2026-10-08 e913ff1 / 31cca3d ImportedAppRow：括号编译错 + 重复 static iconCache

- **现象**：补推后编译失败（e913ff1 修）；MJ 下令并发关联查内存时发现 `ImportedAppRow` 里有个无上限的 `static iconCache`，与 `AppsViewModel` 的 `decodedIconCache` 重复（PITFALLS #1「只改一处，漏了关联」的实例）。
- **根因**：① 修抽屉高度时多留了一个右花括号；② 图标缓存修了一处漏了一处。
- **修复**：① 修括号；② 删掉 `ImportedAppRow` 的重复 static 缓存，只用 ViewModel 那套。
- **涉及文件**：`Seal/Features/Apps/ImportedAppRow.swift`。
- **验证状态**：随 c54db07 已推，待 CI。

---

## 2026-10-07 bad9807 日志导出改读 Seal-log.txt + SEAL-ICON-001/002 诊断

- **现象**：MJ 问导入后日志里缺 SEAL-IPA-212（覆盖更新是否做进 App）；另图标诊断需要可落盘证据链。
- **根因**：① 导出走内存 rounds，内存里没有历史 ⇒ 导出的不是完整日志；② 图标应用链路缺诊断码，无法从日志判定"数据到了记录但 UI 没刷新"。
- **修复**：① 导出直接读 Documents 下 `Seal-log.txt`，第一次点就能导出完整日志；② 图标应用加 SEAL-ICON-001/002 两处诊断。
- **涉及文件**：`Seal/Features/Settings/LogViewerView.swift`、`Seal/Features/Apps/AppsViewModel.swift`。
- **验证状态**：build 87 已交付；Seal-log-30 证实 SEAL-ICON-001 生效（图标数据已到达记录），列表图标是否真实刷新待 MJ 真机确认。

---

## 2026-10-07 a065d3b 导入图标不显示：load() 重建字典覆盖设置

- **现象**：build 79 真机：导入抽屉改图标后，桌面（主屏幕）图标改了，Seal 应用内列表图标没改。
- **根因**：PITFALLS #4 的实例——`load()` 会重建整个 `iconData` 字典，把刚设置的自定义图标覆盖掉了；UI 自然读不到。
- **修复**：`load()` 完成后再在主线程设置；同时去掉 `updatePreferredIcon` 里的多余 `load()`，避免双重加载。
- **涉及文件**：`Seal/Features/Apps/AppsViewModel.swift`。
- **验证状态**：随 build 87 交付，待 MJ 真机确认。

---

## 2026-10-07/08 图标解码缓存上限 + 续签内存清理 + SEAL-MEM-001

- **现象**：MJ 下令并发关联查内存增长（Seal-log-30 侧写）：`decodedIconCache` 设了 `totalCostLimit` 却不限（存入不传 cost ⇒ limit 不生效，PITFALLS #3），解码后 UIImage 十几 MB 一张越积越多。
- **根因**：① 存入时没传 cost，NSCache 的 totalCostLimit 恒不生效；② 无上限 static 重复缓存（见上条）。
- **修复**：`decodedIconCache` 加 50 张 / 50MB 上限（countLimit 生效兜底）；续签完成后清理缓存；监听内存警告自动清理；续签后深度清理 `URLCache.shared`；SEAL-MEM-001 改记 App 实际占用内存（原先记的是设备总内存，误导）。
- **涉及文件**：`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Import/ImportConfirmationView.swift`（6037f68 计入）。
- **验证状态**：已推（6037f68 / 5096bf6 / deafaa9），待 MJ 真机验证内存增长。

---

## 2026-10-05 54b3f1b 「需重新签名」标签常驻：UI 直接用了永不清的标志

- **现象**：MJ 反馈已安装列表 Seal 行 Bundle ID 下方红色「需重新签名」标签一直存在，安装成功后不消失。
- **根因**：`ImportedAppRow` 直接用 `app.hasPendingSelfUpdateSource` 判断。`ProfileOnlyRenewalPolicy.hasPendingUpdateSource` 的注释（353-355 行）明确警告「不能用 `AppRecord.hasPendingSelfUpdateSource` 代替它：那个标志对 Seal 永远清不掉」——自替换路径（`SelfAppRegistrar.atomicallyApplyInstalledIdentity`）刻意不清它，语义是「导入过自更新源」而非「当前有待安装更新」。UI 偏偏用了被警告禁用的写法。
- **修复**：`ImportedAppRow` 新增 `hasPendingSelfUpdate(_:)`，调用 `ProfileOnlyRenewalPolicy.hasPendingUpdateSource(recordedVersion:runningVersion:pendingUpdateSourceFingerprint:)` 同源判据（版本比较 + 指纹），运行版本取 `Bundle.main` 的 `CFBundleShortVersionString`。仅 Seal 行参与判断。
- **涉及文件**：`Seal/Features/Apps/ImportedAppRow.swift`。
- **验证状态**：待 CI。

---

## 2026-10-05 6a56161 修过头：回滚语义被"只增不减"吃掉（CI 3 个单测红）

- **现象**：CI run 37319253679（26c3628）`swift-regression` 挂 3 个单测：`oldRunningBundleCorrectsInstalledSnapshotWithoutDiscardingUpdateSource`（`updated.expiryDate` 期望 oldExpiry 得 newExpiry）、`failedSelfUpdateRollsBackToTheRunningBundleProfile`（期望回滚到 runningExpiry 得乐观写入的新值）。另 `build-package` 的 R28 变异检查红（见下）。
- **根因**：6a56161 为修"后台任务用旧内嵌日期覆盖 profile-only 新日期"，在 `SelfAppRegistrar` 两处加了"内嵌更旧就不覆盖"。但它把**回滚语义**也吃掉了：① 自更新失败时记录里是乐观写入的"未来"日期，必须回滚到运行中旧包的真实日期（R07）；② 有待安装自更新源时（`hasPendingSelfUpdateSource`），记录反映未来包，同样要以运行包为准。两处测试都是这种场景。
- **修复**：① 主注册路径（`ensureRegistered`）：`hasPendingSelfUpdateSource == true` 时走老行为（内嵌日期覆盖）；为 false 时才用"只增不减"。② 结算路径：profile-only 根本不走结算，直接恢复原行为（无条件以运行包为准）。
- **R28 变异检查红的根因**：我给 `tapStage` 加的 `if button.isSelected { return }` 让变异后文件里仍有 `"button.isSelected"` 字符串，守卫的粗粒度 `in` 检查被绕过。修法：R28 检查改成与 R28b 同样的断言级精确模式（`"XCTAssertTrue( button.isSelected," in squash(ui_tests)`）。
- **涉及文件**：`Seal/Core/Renewal/SelfAppRegistrar.swift`、`SealUITests/ImportFlowUITests.swift`（`tapStage` 4 次重试）、`Scripts/verify-release-safety.py`（R28 检查精确化）。
- **验证状态**：待 CI。

---

## 2026-10-05 `tapStage` 只点一次被动画吞掉（CI swift-regression 红）

- **现象**：CI run 37316945665（83352a4）`swift-regression` 挂 1 个 UI 测试：`testTwoStageNavigationCanBeTappedWithoutChangingHeaderAlignment`，`ImportFlowUITests.swift:49` —— 「点了「已安装，0 个」之后它没有被选中（isEnabled=true）」。`build-package` / `signer-tests` 均绿。
- **根因**：`tapStage` 的注释写着「点 → 等 → 没到就再点」，但实现只 `tap()` 一次 + 等 10 秒。初始 mode 切换是程序化翻页（`resolveInitialModeIfNeeded`），动画未结束时 tap 会被吞掉（2026-09-17 CI 已实测过同机制）。`swipeStage` 早有 4 次重试，`tapStage` 漏了。注意与 2026-09-18 那次的区别：那次是「点了 4 次页面文字仍没出现」（点击被接受、TabView 没翻页 ⇒ 改断言为 isSelected）；这次是 isSelected 10 秒都没成立 ⇒ 点击根本没被接受 ⇒ 重试 tap 是对症的。
- **修复**：`tapStage` 改成与 `swipeStage` 对等的 4 次循环：`if button.isSelected { return }` → tap → 等 3 秒 → 未选中再点；4 次后仍未选中才断言失败（不掩盖确定性缺陷）。
- **涉及文件**：`SealUITests/ImportFlowUITests.swift`（`tapStage`）。
- **验证状态**：待 CI（`swift-regression` 的 UI 回归）。

---

## 2026-10-04 并行续签 + 350 误报根因（用户需求「快捷指令和 App 内一样快」）

- **背景**：用户问「能不能做到快捷指令和 Seal 内续签一样快」。两边走同一套代码，差距在后台冷启动（2-4 秒，系统级抹不掉），但大头是续签串行：2 个 App 要 16-20 秒。用户拍板做并行重构（此前「冒风险试试」）。
- **350 误报根因**（真机日志 00:37:10）：363 标记污染 → `renewProfilesOnly` 消费并重置通道（355）→ 但**并行的预热任务**在坏通道上失败又重新标记污染 → `installAndVerify` 看到污染=true 抛 `SEAL-PROFILE-350`。明明已重置，是误报。修法（R116）：`ensureProfileService` 加 `markTaintOnFailure` 参数，预热传 `false`；真正的注入仍标记。
- **并行设计**（R117）：
  - ① `RenewalCoordinator.process()`：非 Seal 项用 `withThrowingTaskGroup` 并行（Portal 网络 I/O 并发），Seal 串行殿后（自替换杀进程）。`processItem()` 从旧串行循环体逐行抽取，`continue` 换 `return`。
  - ② `ProfileOnlyProvisioningProfileInstaller.installAndVerify`：`isBusy` 抛 351 改为 task-chain 排队；拿锁后自愈污染（`taint.consume()` 为真则 `channel.reset()` + `start()` + 355 日志），替代 350 抛错。
  - ③ 「消费 + 重置 + 注入」从 `SigningCoordinator.renewProfilesOnly` 搬进 actor 临界区：调用方先 consume 再等串行权，另一项可能在等待期间 reset ⇒ 拆掉正在用的通道（并行竞态）。
  - ④ 路径信号 `currentRenewalExecutionPath` 单变量改按 `appID` 隔离的字典（并行下旧的是竞态）。
- **涉及文件**：`Seal/Core/Renewal/RenewalCoordinator.swift`、`Seal/Infrastructure/Renewal/ProfileOnlyProvisioningProfileInstaller.swift`、`Seal/Core/Signing/SigningCoordinator.swift`、`Scripts/verify-release-safety.py`（R93② 改查 actor、R116、R117）。
- **验证状态**：待 CI + 真机（MJ 用快捷指令连点，看总耗时与 363/355 日志）。

---

## 2026-10-03 签名/续签再提速三件套（用户需求「速度特别快」）

- **背景**：用户问「Seal 如何做到签名安装和续签都能速度特别快」。此前已做两轮（1.3.23 签名内核去浪费、1.3.41 续签免解压），本轮是第三轮，三个都是「上游没有、本仓自研」。
- **① 批量门户读缓存**：`RenewalCoordinator.process` 逐 App 串行，每项都走 `prepareProfileOnlyRenewal` ⇒ `fetchTeams`/`ensureDevice`/`fetchAppIDs` 对同一账号/Team 重拉 3 次（3 App=9 次冗余 RTT）。修法：`ApplePortalSigningService` actor 内 5 分钟 TTL 读缓存；`addAppID` 成功即失效对应 Team 条目；`bundleIdentifierUnavailable` 恢复性重拉 `bypassCache: true`。只缓存读——`fetchProvisioningProfile` 是写操作，逐目标真发。
- **② `FastSHA256` 硬件加速**：`CodeSignKit` 全仓 `import Crypto`（swift-crypto 纯 Swift SHA-256）。新增 `FastSHA256`（`#if canImport(CryptoKit)` 走 ARM SHA 硬件指令，Linux 保持 swift-crypto），页哈希与资源哈希两处调用点替换，public API 零改动。SHA-1/小数据哈希刻意不动。
- **③ 预测式后台续签**：快捷指令后台轮原来每轮全量续签。新增 `PredictiveRenewalPolicy`（纯函数）：后台轮只纳入 48h 内到期的；窗口按上次间隔自适应放宽（每周跑一次 ⇒ 约 8 天 ≈ 全量，避免漏续）；未知过期时间 fail open；手动「续签全部」照旧全量；后台 total==0 静默（不弹 `SEAL-RENEW-001`）。
- **刻意不做的两项**（已记入 upstream-alignment）：页哈希缓存（无真机验证，命中率<40% 反而更慢）、ZIP 差量打包（`unzipItem` 替换风险大，无设备验证 installd 接受度）、批量 portal 并行（Apple 1100 限流，AGENTS.md 要求先收样本）。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、`Vendor/CodeSignKit/Sources/FastHash.swift`（新增）、`Vendor/CodeSignKit/Sources/CodeDirectoryBuilder.swift`、`Vendor/CodeSignKit/Sources/CodeResourcesBuilder.swift`、`Seal/Core/Renewal/PredictiveRenewalPolicy.swift`（新增）、`Seal/Core/Renewal/RefreshPlanner.swift`、`Seal/Core/Renewal/RenewalCoordinator.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Scripts/verify-release-safety.py`（R112，8 断言+9 变异）、`docs/upstream-alignment.md`、`docs/upstream/codesignkit-perf-1.3.23.md`。
- **验证状态**：待 CI（`signer-tests` 跑 `FastSHA256Tests` 一致性，`swift-regression` 跑 `PredictiveRenewalPolicyTests`/`PortalReadCacheTests`；真机回归待 MJ 手机恢复后）。

---

## 2026-10-02 自更新源指纹算到了旧包头上（`importingSealIPAWithSameVersionRecordsSourceFingerprint` 失败）

- **现象**：CI swift-regression 挂 1 个测试：`imported.pendingUpdateSourceFingerprint` 与 `imported.ipaRelativePath` 的实际 SHA256 不一致。
- **根因**：`prepareImportCommit` 把新包先拷到 pending 目录（`Apps/.<appID>.pending-<tx>/`），`StoredAppFiles.ipaRelativePath` 指向的最终路径此时还是旧文件。指纹代码对最终路径做哈希，自更新场景（旧包存在）下算到的是**旧包**的指纹 —— 指纹本该标识新源包，错了就起不到“同版本区分新旧包”的作用。
- **修复**：改对 `draft.stagedIPA.url` 做哈希（`AppFileStore.streamingSHA256(url:)`，内容与最终落盘文件一致），不再碰最终路径。
- **涉及文件**：`Seal/Core/Import/ImportWorkflow.swift`。
- **验证状态**：待 CI。

---

## 2026-10-02 CI `Check release safety invariants` 失败（R60b / R89① / R89② 变异锚点）

- **现象**：run 36949196668 的 build-package 在守卫步骤失败，3 个 FAIL。
- **根因**：
  1. R60b 变异：我把补丁记成第二个 `# 1.0.0` 小节，变异把第一个 `# ` 降级成 `## ` 后解析出的第一节仍是 1.0.0，变异失去判别力。
  2. R89①/② 变异锚点：`hasPendingUpdateSource` 加了指纹分支后，`return Version.compare…` 改成 `if … { return true }`、调用点多了 `pendingUpdateSourceFingerprint` 参数，守卫脚本里的硬编码锚点对不上了。
- **修复**：RELEASE_NOTES 补丁条目并入唯一的 `# 1.0.0 正式版` 小节（不再有第二个 `# 1.0.0` 标题）；`Scripts/verify-release-safety.py` 里 R89①/② 的锚点与变异体同步更新（变异语义不变：①翻转比较符、②丢弃判据结果）。
- **涉及文件**：`RELEASE_NOTES.md`、`Scripts/verify-release-safety.py`。
- **验证状态**：锚点与源码逐字核对各命中 1 次；R60b 直接检查与变异模拟本地验证通过；待 CI。

---

## 2026-10-02 “组件与许可”据实审计（用户要求：真实的、能不写的不写）

- **现象**：旧列表 7 项中 `DeviceSupport` 的 URL（`SideStore/DeviceSupport`）已 404；随 SideSign 静态链接的 CodeSignKit、GSACryptoKit、libdeflate 被漏列；AnisetteKit 链接的 Unicorn 二进制、AltSign/CodeSignKit/GSACryptoKit 链接的 OpenSSL 二进制、CodeSignKit 依赖的 swift-asn1 均未列出。
- **根因**：2026-10-01 的“核对”只看了 `project.yml` 直接依赖，没查 `Vendor/*/Package.swift` 的传递依赖，也没验证 URL 可访问性。
- **修复**：逐个核对 Vendor 内 LICENSE 文件 / README 许可证声明并验证 URL。13 项：AltSign（许可证待确认——sunuannian1 fork 在锁定 revision 下确实无 LICENSE 文件，如实保留）、OpenSSL（Apache-2.0）、SideSign（GPL-3.0）、CodeSignKit（AGPL-3.0）、GSACryptoKit（AGPL-3.0）、libdeflate（MIT）、AnisetteKit（AGPL-3.0）、Unicorn Engine（GPL-2.0）、Minimuxer（AGPL-3.0）、libimobiledevice（GPL-2.0/LGPL-2.1，替换 404 的 DeviceSupport 条目）、ZIPFoundation（MIT）、swift-crypto（Apache-2.0）、swift-asn1（Apache-2.0）。不单列：CryptoExtras（属 swift-crypto）、RustBridge（属 Minimuxer 包内）、AltSign 树内 C 源码（属 AltSign 包内）；EMProxy 在 vendored Minimuxer 中不存在。
- **涉及文件**：`Seal/Features/Settings/OpenSourceLicensesView.swift`。
- **验证状态**：URL 与许可证声明均已逐项在线核实；待 CI 编译通过。

---

## 2026-10-02 导入 Seal 自身 IPA、版本号相同时无法覆盖更新

- **现象**：用户需求 —— 导入 Seal 自身的 IPA 包，即使版本号与运行中一致也要能覆盖更新。旧行为：`ProfileOnlyRenewalPolicy.hasPendingUpdateSource` 只比较营销版本，版本一致即判「无待安装更新」⇒ 走 profile-only（只换描述文件、从不安装）⇒ 新导入的包永远装不上。
- **根因**：版本比较是「有没有**新版本**」的判据，不是「有没有**新导入的包**」的判据。不能用 `AppRecord.hasPendingSelfUpdateSource` 代替 —— 那个标志对 Seal 恒为真（自替换走不到 `SigningCoordinator` 里清它的普通安装路径），用它会退化成「每次续签都完整重装」（1.3.17 的坑）。
- **修复**：新增 `AppRecord.pendingUpdateSourceFingerprint`（源 IPA 的 SHA256）。导入 Seal 自身 IPA 时在 `ImportWorkflow.commit` 里流式计算并写入（失败不阻断导入，回落为纯版本比较）；`hasPendingUpdateSource` 在版本一致时再看指纹 —— 有指纹才算待安装更新；自替换结算成功后由 `SelfAppRegistrar.atomicallyApplyInstalledIdentity` 清掉（自愈）。准入（`evaluate`）与界面（`pendingUpdateNote`）共用同一判据，不漂移。`pendingUpdateDetail` 文案改为版本无关的「新包」。第三方应用不受影响（它们的覆盖更新本就靠清空签名产物强制完整重签，无版本门）。
- **上游对照**：SideStore 的自更新是版本号驱动的更新通道，没有「导入同版本 IPA 覆盖安装」的概念 →「不跟（上游没有）」，Seal 自有机制。已记入 `docs/upstream-alignment.md` 对照台账。
- **涉及文件**：`Seal/Core/Apps/AppRecord.swift`、`Seal/Infrastructure/Persistence/CoreDataModel.swift`、`Seal/Infrastructure/Persistence/CoreDataAppStore.swift`、`Seal/Core/Import/ImportWorkflow.swift`、`Seal/Core/Renewal/ProfileOnlyRenewalPolicy.swift`、`Seal/Core/Renewal/SelfAppRegistrar.swift`、`Seal/Features/Apps/AppPresentation.swift`、`SealTests/Renewal/ProfileOnlyRenewalPolicyTests.swift`、`SealTests/Apps/AppPresentationTests.swift`、`SealTests/Import/ImportWorkflowTests.swift`、`SealTests/Renewal/SelfAppRegistrarTests.swift`。
- **验证状态**：新增 4 组回归测试（指纹判据 5 断言 / 界面同版本提示 / 导入写入指纹且等于源包 SHA256 / 结算清指纹且保留 `hasPendingSelfUpdateSource`）；本机无 Xcode，待云端 `swift-regression` 编译 + 真机验证「同版本导入→续签完整重签安装→下次续签回到 profile-only」。

---

## 2026-10-02 自续签 App Group ID 重复映射导致 Apple -1（续签幂等 bug）

- **现象**：Seal 自续签在 `preparingAppID` 阶段报 `SEAL-APPID-303 App ID 创建失败`（Apple.APIError -1）。日志显示 App ID 已复用、无需新注册、能力一致且跳过 `updateFeatures`，错误实际发生在后续 App Group 步骤；每次重试都确定性复现。
- **根因**：`BundleIDMapper.appGroupID` 不幂等。续签输入的是已签名二进制 entitlements 里的 group ID（已映射为 `group.com.mjorb.seal.seal.<teamID>`），再次映射追加出 `group.…seal.<teamID>.seal.<teamID>`；`fetchAppGroups` 查不到 → 误调 `addAppGroup` → Apple 回通用 -1，外层误包装成 SEAL-APPID-303。同文件的 `mainBundleID` 早有同类后缀保护，`appGroupID` 漏了。
- **修复**：`appGroupID` 加当前 team 后缀大小写不敏感幂等判断（已映射则原样返回），与 `mainBundleID` 对齐；新增回归测试覆盖首次映射 / 已映射再映射不变 / team 大小写 / 跨 team 不误判。
- **上游对照**：`.seal.<teamID>` 后缀是 Seal 自有映射，上游无对应做法 →「不跟」，属 Seal 自有 bug 修复。
- **涉及文件**：`Seal/Core/Signing/BundleIDMapper.swift`、`SealTests/Signing/BundleIDMapperTests.swift`。
- **验证状态**：本地等价逻辑断言通过；Windows 无 Xcode，待云端 CI 编译 + 真机自续签验证。

---

## 2026-10-01 Seal 自替换对已满足 App ID 重复写能力导致失败（本地修复，未推送）

- **现象**：安装最新 Seal 后为 Seal 自身完整重签，其他应用可以成功；日志显示目标 App ID 已存在、无需新注册且远端能力与本次请求一致，随后仍以 `SEAL-APPID-303` 失败。
- **真机证据**：`QQ文件Seal-log(1).txt` 于 18:19–18:20 反复记录“本次需 1 个 / 可复用 1 个 / 需新注册 0 个”及“完全一致 1 个”，随后 Apple 返回 `An unexpected error occurred`。因此失败不在 App ID 新建、名额或通用签名器。
- **根因**：`updateFeatures` 已能读到远端 `ALTAppID.features`，但只把相等性用于诊断，仍无条件调用 `updateAppId.action`。Seal 自身已有的 App ID 能力已经满足本轮请求，重复门户写入没有收益，且被 Apple 临时拒绝后又被外层统称为“App ID 创建失败”。
- **修复**：新增 `ApplePortalAppIDFeatureUpdatePolicy`，按 SideStore 的已满足短路判据只补缺失或关闭的 feature；满足时跳过 `updateAppId`，保留 App Group 的读取、创建和关联步骤，以及首次签名和能力变更时的原有写入路径。
- **涉及文件**：`ApplePortalSigningService.swift`、`ApplePortalSigningFailureTests.swift`、`SettingsRootView.swift`、`SigningAndRenewalGuideView.swift`、`RELEASE_NOTES.md`。
- **验证状态**：新增“远端已满足则不写 / 未满足则写”纯函数回归测试；Windows 无 Xcode，待云端完整 CI 编译与真机验证 Seal 自替换。

---

## 2026-10-01 正式版设置收束：关于入口、自动续签教程与证书页首开同步（本地修改，未推送）

- **现象**：关于 Seal 中同时放置源码、问题反馈和组件许可入口，超出应用内必要信息；快捷指令自动续签混在批量续签说明末尾；每次进入“签名证书”都会强制请求 Apple 门户，即使已有可用本机缓存。
- **根因**：关于页把外部链接与应用信息混在一起；自动续签没有独立入口；页面 `.task` 无条件调用 `load(force: true)` 与 `refreshCertificateInventory(force: true)`。此外，证书缓存被排在邮箱、图标等后台读取之后，首屏会与缓存加载竞争。
- **修复**：关于页只保留版本、Bundle ID、系统、最低支持版本、更新检查和必要的组件许可。快捷指令自动续签归入“使用指南”末尾；批量续签只说明批量操作。证书缓存前置到账号加载完成时读取，证书页首开改为本机状态与缓存优先：只有没有缓存、用户下拉刷新、切换账号没有缓存、创建或撤销证书时才同步 Apple。
- **组件与许可**：核对 `project.yml` 后保留 AltSign、SideSign、AnisetteKit、Minimuxer、DeviceSupport、ZIPFoundation 与 swift-crypto；它们均为 Seal target 直接链接或随其静态依赖分发，不能仅为缩短页面而删除。AltSign 的许可证待确认状态保持可见，不能隐藏。
- **补充**：应用详情的证书序列号和描述文件 UUID 改为完整换行显示，不再中间省略；应用操作抽屉继续只保留面向日常操作的五项摘要。
- **涉及文件**：`AboutView.swift`、`SettingsRootView.swift`、`SigningAndRenewalGuideView.swift`、`SigningCertificateSettingsView.swift`、`RELEASE_NOTES.md`、`DEBUG_LOG.md`。
- **验证状态**：已完成静态调用链核对；Windows 无 Xcode，待云端完整 CI 编译与真机验证“首次进入不发 Apple 请求、下拉刷新仍会同步”。

---

## 2026-10-01 正式版收尾：证书旧回包、存储反馈与设置内容（本地修复，未推送）

- **现象**：切换 Apple ID、撤销或更换证书后，之前发出的 Apple 门户请求可能稍后返回，短暂把旧证书重新写回页面；首次进入证书页时，本机接管状态也会先显示默认文案。存储清理完成没有反馈释放量，设置内签名流程和许可列表仍含过期或参考项目内容。
- **根因**：证书同步以账号 ID 直接写入，没有请求代次判定；撤销只在本地列表移除，不会拒绝已在途的旧回包。存储操作只记录日志，设置文案没有与当前 iOS 27 配对、profile-only 续签链路一起维护。
- **修复**：新增账号级同步代次门，撤销、换证书和新同步只接受最新回包；证书和本机管理首次读取显示同步状态。清理后在原提示位显示实际释放空间。保留原有设置布局，仅更新五段帮助、凭据安全、关于链接和精简的实际编译组件清单；正式版版本号更新为 `1.0.0`。
- **涉及文件**：`ApplePortalInventoryRefreshGate.swift`、`SettingsViewModel.swift`、`SigningCertificateSettingsView.swift`、`StorageMaintenanceView.swift`、`StorageMaintenanceSummary.swift`、设置说明页面、`project.yml`、`RELEASE_NOTES.md`、`ThirdPartyNotices.txt`。
- **验证状态**：新增代次门与存储反馈纯函数测试；首次云端守卫发现同步门的 `begin` 与既有非可变方法同名而产生名称级误报，已改为 `issueTicket`；第二轮云端编译发现 `invalidate` 的内部调用遗漏改名，已补齐，待重新触发完整 CI。Windows 无 Xcode，仍需云端完整编译和真机回归。

---

## 2026-10-01 后台定位保活重复启动与续签中断队列不可追溯（本地修复，未推送）

- **现象**：真机日志在同一秒连续出现多条 `SEAL-BACKGROUND-017`；`SEAL-RENEW-007` 只报“1 个应用结果未知”，无法判断是哪一个队列项遗留。
- **根因**：`LocationKeepAliveService.start()` 标注为幂等，但授权已满足时每次调用都会再次执行 `startUpdatingLocation()` 并写日志。`RefreshQueueStore.RecoveryOutcome` 只保存降级数量，丢失了真正被从 `running` 降为 `unknown` 的应用 ID。
- **修复**：定位服务分别记录已请求授权与已启动更新，重复调用直接返回；恢复结果保留降级队列项 ID，并在 `SEAL-RENEW-007` 写入该 ID，供下一次真机复现精确对照。
- **涉及文件**：`LocationKeepAliveService.swift`、`RefreshQueueStore.swift`、`AppsViewModel.swift`、`RefreshQueueStoreTests.swift`、`project.yml`、`RELEASE_NOTES.md`、`DEBUG_LOG.md`。
- **验证状态**：新增队列项 ID 断言；Windows 无 Xcode，未提交、未推送、未触发 CI。

---

## 2026-10-01 profile-only 日期必须来自本轮设备端文件，配对与 LocalDevVPN 状态自动同步（本地修复，待 CI）

- **现象**：用户要求“续签成功”必须代表本轮新描述文件已生效，不能因历史文件仍存在而显示成功；旧构建 `1.3.44 (88)` 日志还显示，Seal 的 profile-only 刚写入新文件后，延迟结算的自替换事务可能把包内旧 profile 的日期展示回来。iOS 27 配对完成后，LocalDevVPN 状态有时需手动点击才能让阶段页更新。
- **真机证据**：日志在 `2026-10-01 04:51:15` 记录 Seal profile 创建并到期于 `2026-10-08 04:51:15`；另一轮在 `2026-09-30 19:00:32` 写入新 profile，`19:01:03` 的自替换结算仍读到 `18:33:49` 的包内 profile。
- **根因**：设备端回读只比较 Bundle ID、UUID 和证书序列号，未比较 CreationDate / ExpirationDate，无法证明 UI 的日期属于本轮文件。LocalDevVPN 回调虽触发诊断，但 iOS 27 配对阶段依赖后续启动检查才刷新；VPN 设置页也会显示上次诊断结果。
- **修复**：新增设备端完整 profile 身份匹配：Bundle ID、UUID、创建时间、到期时间和证书必须与本轮门户返回值一致，否则 profile-only 失败且不更新记录。进入 LocalDevVPN 页立即检测真实通道；VPN 回调后直接同步配对阶段状态。
- **涉及文件**：`DeviceProfileInspector.swift`、`ProfileOnlyProvisioningProfileInstaller.swift`、`SettingsViewModel.swift`、`LocalDevVPNSettingsView.swift`、`DEBUG_LOG.md`。
- **验证状态**：已按旧版真机日志定位并完成静态差异检查；Windows 无 Xcode，待云端 CI 与真机验证。Seal 自替换的“包内旧 profile 覆盖已确认设备 profile”来源优先级仍在继续修复；未提交、未推送、未触发 CI。

---

## 2026-10-01 快捷指令结果占住列表，旧自替换会话遗留“安装中”（本地修复，待 CI）

- **现象**：导入 1.3.44 后首次续签会发生 Seal 覆盖安装；新包已实际落盘后，下一次续签界面仍可能停在“安装中”。快捷指令续签成功后，从通知进入 Seal 时应用列表有时无法点击，强制结束并重开才出现结果抽屉。
- **真机证据**：`Seal-log.txt` 记录旧进程的自替换安装在 02:46:41 收到 `Swift.CancellationError`，但新进程在 02:47:44 已由 `[SEAL-SELF-113]` 以运行包身份确认新包落盘。其后每次快捷指令均记录 `[SEAL-RENEW-009]` 成功和 `[SEAL-RENEW-023]` 结果持久化，却紧接着反复出现 `[SEAL-RENEW-021]` 与 `[SEAL-RENEW-025]`；因此实际安装/续签已成功，卡住的是旧批量会话和前台抽屉状态。
- **根因**：`batchRefreshSession` 同时承担后台任务进度、持久化恢复中间态和 SwiftUI `.sheet(item:)` 的呈现开关。快捷指令后台创建的会话被 SwiftUI 当成前台抽屉；覆盖安装杀掉旧进程时，其 `.preparingSealUpdate` 状态又可能被新界面继承。该会话既阻止应用操作 sheet，又可在错误时机被关闭，造成“列表点不动 / 结果晚出现 / 看似一直安装中”。
- **修复**：将“批量会话内容”和“是否呈现抽屉”分离。快捷指令仍严格复用 `refreshAll()` 的单飞与队列入口，只通过瞬态标记要求它不呈现过程抽屉；后台批次仅维护会话、持久化最终结果和通知，并在收尾清掉旧进程会话。前台仅在已结算载荷恢复后显式打开结果抽屉。应用操作只在结果抽屉实际呈现时让位。新增纯策略测试，固定“后台会话存在但未请求呈现时不弹 sheet”。
- **涉及文件**：`AppsViewModel.swift`、`AppsRootView.swift`、`PendingBatchResultPayload.swift`、`PendingBatchResultPayloadTests.swift`、`DEBUG_LOG.md`。
- **验证状态**：已逐行对照真机日志与会话/抽屉控制流，新增纯函数回归测试；Windows 无 Xcode，待云端完整 CI 编译与真机回归。未发布 GitHub Release。

---

## 2026-09-30 完整 CI 的 macOS runner 排队与守卫清单漂移（本地修复，待推送）

- **现象**：`ios.yml` 的两次完整 CI（run `36727963492` 的 attempt 1/2）中，三个 macOS job 都只停在 queued，约 15 分钟后被取消；job 没有 steps、runner ID 为 0。迁出签名器单测后的 run `36737305564` 已使 Linux 单测和两个 macOS job 真正启动，但 `build-package` 先被发布安全守卫拦住。
- **根因**：前两次失败发生在 GitHub 分配 `macos-26` runner 之前；此前同一分支的 run `36697417653` 已在同一 `macos-26` / Xcode 26.5 配置下通过。守卫失败则是两个独立漂移：新增 profile 服务方法令旧的协议变异锚点失配；新增 `SEAL-PROFILE-356` / `SEAL-PROFILE-355t` 尚未写入守卫的精确白名单。此前产品改版将操作抽屉收敛为五项事实摘要，也与旧守卫要求在抽屉重复长说明冲突。首次对齐后，守卫的变异自检又仍匹配旧文案和旧逗号格式；此外进度页注释中含 helper 名，原始文本检查会被注释假满足。
- **修复**：签名内核 `CodeSignKit` 单测改为 `ubuntu-latest`：其 Package 在非 Darwin 平台不拉 OpenSSL xcframework，源与测试仅使用跨平台依赖；IPA 构建与 Swift/UI 回归仍固定 `macos-26` + Xcode 26.5。守卫更新为精确校验新 profile 码，协议锚点收窄为被守护的要求本身；操作抽屉继续只显示五项事实，并强制检查「需重签」状态，完整解释留在详情页/进度页。变异自检同步改为当前文本，并在检查进度 helper 时先剥离注释，防止注释让关键保护假通过。
- **涉及文件**：`.github/workflows/ios.yml`、`Scripts/verify-release-safety.py`、`DEBUG_LOG.md`。
- **验证状态**：run `36737305564` 的 Linux `signer-tests` 与 macOS `swift-regression` 已通过；`build-package` 在守卫阶段失败、尚未产生 IPA。Windows 无 Swift；修正后待重新推送完整 CI。未创建或触发 GitHub Release。

---

## 2026-09-30 profile 服务预热超时后可能与下一次 misagent 调用并发（本地修复，未推送）

- **现象**：新增的 profile 服务预热以 8 秒有界等待执行 `dumpProfiles`。若超时，`BlockingCall` 会放弃等待但 Rust FFI 仍可能继续运行。
- **根因**：初版把“服务调用报错”和“调用超时”都视为相同的探测失败，并立即窄重建 RSD 后再探测，可能令两个 `misagent` 调用同时占用设备传输；临时目录也可能在旧调用仍写入时被提前删除。
- **修复**：探测结果明确区分成功、失败和超时。普通失败才立即窄重建一次；超时改标记进既有 `ProfileOnlyTaintGate`，本轮不再触发第二次设备调用，下一轮统一走既有“消费污染 → reset → start”流程。只在 FFI 确认结束后删除探测目录，并把 `SEAL-PROFILE-355t` 纳入描述文件超时集合，使外层重试不会重复 reset。
- **涉及文件**：`DeviceProfileInspector.swift`、`MinimuxerInstallChannel.swift`、`ProfileOnlyProvisioningProfileInstaller.swift`、`DeviceChannelTransientPolicy.swift`、`ProfileOnlyTaintGateTests.swift`。
- **验证状态**：补全超时代码集合测试；Windows 无 Xcode，尚未运行 Swift 编译、CI 或真机回归。按用户要求未提交、未推送、未触发 CI。

---

## 2026-09-30 首页导入 IPA 入口未适配系统液态玻璃（本地修改，未推送）

- **现象**：首页右上角“+”仍是无容器的大号图标，与 iOS 27 的液态玻璃工具控件不一致，导入入口缺少按下反馈。
- **根因**：首页入口没有复用项目已具备的 iOS 26+ `glassEffect` 能力，也没有为“降低透明度”和较低系统定义视觉回退。
- **修复**：将入口收敛为 44pt 圆形玻璃工具按钮，图标按系统工具栏尺度调整；iOS 26+（含 iOS 27）使用 `glassEffect`，按下缩放提供直接反馈；降低透明度和较低系统回退到同尺寸的实色圆形与边框。文件选择器、导入流程、禁用条件和辅助功能标识不变。
- **涉及文件**：`AppsRootView.swift`。
- **验证状态**：已静态核对 API 与项目既有 `GlassSurfaceModifier` 的系统版本策略一致；Windows 无 Xcode，尚未运行 Swift 编译、CI 或真机视觉回归。按用户要求未提交、未推送、未触发 CI。

---

## 2026-09-30 应用操作抽屉暴露技术标识且可切换账户（本地修改，未推送）

- **现象**：已安装应用的“应用操作”抽屉曾展示证书序列号、描述文件 UUID 等不需要用户判断的技术标识，并允许在抽屉内切换 Apple ID；这会让页面显示的账户与实际续签目标不一致，也增加阅读负担。
- **根因**：抽屉把诊断详情、账户选择和日常续签操作放在同一层，缺少面向用户的固定摘要边界。
- **修复**：抽屉仅保留真实签名账户、Apple 证书状态、描述文件状态、有效期至和完整 Bundle ID 五项；移除账户选择、序列号、描述文件 UUID、技术详情入口及附带技术说明。点击“立即续签”始终按该应用当前已解析的签名账户执行。
- **涉及文件**：`InstalledAppActionSheet.swift`、`AppsRootView.swift`。
- **验证状态**：已做静态差异与残留字段检查；Windows 无 Xcode，尚未运行 Swift 编译、CI 或真机回归。按用户要求未提交、未推送、未触发 CI。

---

## 2026-09-30 快捷指令结果抽屉错序与 profile-only 冷 misagent 通道（本地修复，未推送）

- **现象**：快捷指令成功通知进入 Seal 后，先闪出不相关的“应用操作”抽屉，才显示续签结果；单项 profile-only 续签常比应用内体感慢。
- **真机证据**：`Seal-log(22).txt` 中通知本身没有 URL action；每轮 `SEAL-BACKGROUND-008` 显示通道就绪后，首个 profile-only 仍在约 26–28 秒后抛 `MinimuxerError 1`，`SEAL-RENEW-503` 再固定退避 8 秒，成功落在触发后约 43–45 秒。
- **根因**：应用操作、批量结果分别由同一 SwiftUI 层的独立 `.sheet` 驱动，启动恢复同一轮状态变更会让旧的应用操作选择先被呈现；更关键的是，`start()` 的 RSD/UDID 成功只证明连接层可达，不证明下一步 `misagent` 描述文件服务可立即处理写入。900 秒缓存使首个 profile-only 注入可能落在冷/失效服务上，再由外层固定 8 秒退避兜底。
- **修复**：结果存在时从应用操作 sheet 的 Binding 读取侧强制返回 `nil`，结果抽屉独占呈现；profile-only 续签改为 Apple Portal 请求期间并行预热同一 `misagent` 服务（无副作用 `copy_all`），并在 20 秒健康租约内复用。预热与真实注入共享 `ProfileOnlyProvisioningProfileInstaller` 单飞，绝不并发占用设备服务；普通探测失败仅作废 Rust RSD 缓存、保留配对/provider 后立即重建一次，探测超时则交由既有污染闸门在下一轮全量重建。注入在极短窗口内仍遇明确瞬时通道错误时，同一份幂等 profile 立即窄恢复后重试一次；8/16 秒外层退避只保留为二次失败的最终兜底。
- **涉及文件**：`AppsRootView.swift`、`PendingBatchResultPayload.swift`、`InstallChannel.swift`、`MinimuxerInstallChannel.swift`、`DeviceProfileInspector.swift`、`ProfileOnlyProvisioningProfileInstaller.swift`、`ProfileServiceLeasePolicy.swift`、`SigningCoordinator.swift`、`RenewalCoordinator.swift`、`AppsViewModel.swift`、`Vendor/Minimuxer/Sources/Minimuxer.swift` 及对应测试。
- **验证状态**：已按日志与 RustBridge 实现定位、补健康租约纯策略测试；Windows 无 Xcode，本地无法编译或运行 Swift 测试。按用户要求未提交、未推送、未触发 CI；待 CI 与真机验证“快捷指令 profile-only 首项不走 8 秒退避”。

---

## 2026-09-30 后台续签结果抽屉与已安装应用操作抽屉争夺呈现层（本地修复，未推送）

- **现象**：快捷指令续签成功并发送通知后，进入 Seal 有时不立刻看到结果；点击已安装应用后才出现续签结果。关闭结果抽屉后，该应用又无法再次点开。
- **真机证据**：`Seal-log(21).txt`（构建 1.3.43）中每轮均为 `1/1 成功`，并记录 `SEAL-RENEW-024`（结果已恢复）和随后重复的 `SEAL-RENEW-021`（结果抽屉仍开/会话存在）。因此不是续签失败或 LocalDevVPN 未验证。
- **根因**：`AppsRootView` 在同一视图层上独立维护“已安装应用操作”和“批量结果”两张 `.sheet`；后台结果已恢复时，列表点击仍可写入应用操作选择，两张 sheet 竞争呈现。应用操作 sheet 关闭也没有显式清空选择，竞争后可能保留旧 item，导致同一行后续点击没有新的状态变化。
- **修复**：结果会话存在时优先恢复并独占呈现层，拒绝打开已安装应用操作；结果会话出现时清空已打开的应用操作/详情选择；应用操作 sheet 任意关闭后明确清空选择。纯策略 `BatchResultPresentationPolicy` 由回归测试固定。
- **涉及文件**：`PendingBatchResultPayload.swift`、`AppsRootView.swift`、`PendingBatchResultPayloadTests.swift`。
- **验证状态**：已按真机日志定位并写好回归测试；按用户要求，本地修改尚未提交、推送或触发 CI。

---

## 2026-09-30 iOS 27 设备页把已验证的配对错误显示为 LocalDevVPN 待验证（1.3.44，未发布）

- **现象**：我的页按持久化配对记录显示“已配对”，进入 iOS 27 的设备页却回到“准备配对 / LocalDevVPN 待验证”，迫使用户误以为每次快捷指令续签后都必须手动点“验证 LocalDevVPN”。真机日志已记录后台续签会先自动确认 `LocalDevVPN 正常`。
- **根因**：顶部摘要读取 `PairingRecord.validationStatus`，手机配对页面读取进程内 `phonePairingState`；后者初始化恒为 `.idle`，启动的轻量通道检查完成后又没有把诊断结果回写给它。两个展示面没有收敛到同一检查结果。
- **修复**：新增唯一的“通道检查结果 → 手机配对页面状态”映射；启动检查及 iOS 27 设备页打开都会复用它自动复核通道。通道准备好显示“已验证”，未取得通道结论才显示等待状态；已验证的持久化配对关系仍由 `PairingStore` 保持，瞬时通道状态不会降级它。
- **涉及文件**：`SettingsViewModel.swift`、`PairingSettingsView.swift`、`PhonePairingPresentationPolicyTests.swift`、`project.yml`、`RELEASE_NOTES.md`。
- **验证状态**：新增“自动检查成功 → 完成阶段”“无结论 → LocalDevVPN 等待阶段”两条测试；Windows 无 Xcode，待完整 CI 编译及真机“快捷指令续签完成 → 打开设备页”回归。

---

## 2026-09-30 快捷指令续签完成后，通知进入结果抽屉延迟到用户点击应用才出现（1.3.43，未发布）

- **现象**：快捷指令的 profile-only 批量续签已成功、通知也已发出；用户点击通知回到 Seal 后，结果抽屉有时立即出现，有时需点击两三个已安装应用才出现。
- **根因**：启动路径把维护作业、自替换对账、队列恢复和应用列表加载排在结果恢复前；已结算的后台结果本不依赖这些步骤，却被它们阻塞。后续列表交互触发 `load()` 才偶然恢复抽屉。
- **修复**：增加纯判据 `PendingBatchResultPayload.isReadyForImmediatePresentation`；前台首次加载及每次回到 active 时优先恢复已结算载荷。含 `awaitingSealConfirmation` 的 Seal 自替换载荷不提前展示，继续等待新进程真实身份核验。
- **涉及文件**：`PendingBatchResultPayload.swift`、`AppsViewModel.swift`、`AppsRootView.swift`、`PendingBatchResultPayloadTests.swift`、`project.yml`、`RELEASE_NOTES.md`。
- **验证状态**：新增三条纯函数测试；待完整 CI 与真机“快捷指令完成 → 点通知 → 不点应用即出现结果抽屉”回归。

---

## 2026-09-30 iOS 27 只能靠电脑导入配对文件，已装 Seal 不能自行完成首次配对（1.3.42，未发布）

- **现象**：iOS 27 已把配对入口放进“设置 > 隐私与安全性 > 开发者模式”的系统流程，但 Seal 仍要求电脑端配对助手或手动导入文件；手机已装 Seal 时无法独立完成首次配对。
- **根因**：项目只有 Remote Pairing 客户端连接实现（LocalDevVPN 后的 `MinimuxerInstallChannel`），没有作为 Pairable Host 的监听、Bonjour 广播、系统 PIN 回调和候选凭据交接。
- **修复**：引入经上游 SideInstaller 实现逐行对照的 `idevice` Remote Pairing Host（与现有客户端依赖隔离，避免升级旧 `idevice` 破坏签名/安装）；Swift 侧发布 `_remotepairing-pairable-host._tcp`，显示系统 PIN，并把生成文件交给现有 `PairingStore` 导入和 `MinimuxerInstallChannel` 验证。iOS 27+ 只展示手机配对；较低系统保留电脑文件路径。验证失败仍走原有备份恢复，不让失败候选永久覆盖可用记录。
- **涉及文件**：`Vendor/Minimuxer/RustBridge/src/phone_pairing.rs`、`Vendor/Minimuxer/RustBridge/MinimuxerBridgeIdevice.swift`、`Seal/Infrastructure/Pairing/PhonePairingHost.swift`、`Seal/Features/Settings/SettingsViewModel.swift`、`Seal/Features/Settings/PairingSettingsView.swift`、`PairingStore` 既有事务接口。
- **验证状态**：新增 Rust Host 已通过 `cargo check`；Swift 6 / 完整 iOS 构建与真机“开发者模式 → 与 Seal 配对 → LocalDevVPN 验证”尚未运行。按用户指示，不推送或发布给用户。

---

## 2026-09-30 iOS 27 手机配对首轮 CI 直接引用 Rust 桥接内部类型，Swift Regression 编译失败（1.3.42，未发布）

- **现象**：首轮 `swift-regression` 在 `PhonePairingHost.swift` 报 `cannot find type 'RustIdevice' in scope`，因此未产出 IPA。
- **根因**：`RustIdevice` 是 `Minimuxer` 包内部的 FFI 实现；应用层既有安装、签名链路均经 `Minimuxer` 公共门面访问，新增手机配对却越过门面使用了桥接类型。
- **修复**：把 Phone Pairing 的公开结果、Bonjour 广播数据和启动函数收敛到 `Minimuxer`，由门面在包内映射到 `RustIdevice`；`PhonePairingHost` 只依赖 `Minimuxer` 公共 API，保持业务层与 Rust FFI 隔离。
- **涉及文件**：`Vendor/Minimuxer/Sources/Minimuxer.swift`、`Seal/Infrastructure/Pairing/PhonePairingHost.swift`。
- **验证状态**：已基于 CI 编译错误修正，待重新推送完整 CI；未创建 Release，未向用户推送。

---

## 2026-09-29 续签慢复用完整签名两条白做功：解压 IPA + 重复能力写请求（1.3.41，用户「续签必须快」）

- **现象**（用户）：同样本地通道，SideStore 续签几秒就成功，Seal 续签要几十秒到一两分钟。
  一字一码读 SideStore `FetchProvisioningProfilesOperation.swift` 后定位差距不在底层库、在**续签**这条
  流水线本身做了什么。
- **根因（两处白做功）**：
  1. **解压 IPA**：`prepareProfileOnlyRenewal` 无条件 `signingWorkspace.prepare(.layoutOnly)`，
     而 `layoutOnly` 仍会解压 + 改 Bundle ID + 遍历扩展，大包实测 30–35 秒 —— 可续签只换描述文件、
     从不产出新 IPA，这份解压纯属浪费（首签才需要读 Mach-O 取 entitlements）。
  2. **重复能力写请求**：续签复用完整签名的 `provisioningProfiles`，对每个目标依次
     `registerAppID`（存在则复用，但仍走一遍）+`updateFeatures`+`assignAppGroups`。这些在首签时已建好，
     续签时是纯冗余；且 `updateFeatures` 的 SideStore 式「能力已满足就跳过」短路依赖 `appID.features`
     被 `fetchAppIDs` 回填 —— 本仓 `ALTAppID.features` 只被写入、从未被读取，无法证明会回填，
     照抄短路有静默丢能力风险（见 2026-09-22 台账那条「不跟随盲跳过」的顾虑）。
- **修复（对齐 SideStore 且更彻底）**：
  1. `SigningTargetRecord` 由「存权限键 `entitlementKeys`」升级为「持久化实授 `entitlements` 键值对」，
     自定义 Codable 向后兼容（旧记录缺字段落 `[:]`）。首签与 profile-only 续签两条路径都写。
  2. `reconstructProfileOnlyRenewalTargets`：记录里每个目标 entitlements 非空 ⇒ 免解压重建；
     否则回落原 `prepare(.layoutOnly)` 慢路径。
  3. 新增 `renewalProvisioningProfiles`：只「读 App ID 列表 + 下载描述文件」，
     **跳过** register/updateFeatures/assignAppGroups。SideStore 即便短路也仍会发 updateFeatures/updateAppGroups，
     Seal 续签根本不碰这三类写请求。
  4. **安全兜底靠对账而非取证**：`validateEntitlements` 对新描述文件 vs 旧描述文件实授权限逐键对账
     （`valuesManagedBySigner` 白名单外的键缺了/值变了就报 401/402 引导完整重签），
     因此「跳过能力更新」不再有「静默丢能力」风险 —— 这正补齐了 2026-09-22 台账那条「不跟随盲跳过」的顾虑。
  5. **退避重试下沉到 fetch 函数（修守卫 R24/R33）**：续签与慢路径都要「读取 App ID 列表」「申请描述文件」，
     若两处各写一份 `withSessionRecovery`，同一个 label 字符串会在文件里出现两次 —— 守卫 R24 的
     count 从 8 变 10、R33 的 mutation 自检（`replace(...,1)` 只换第一处）随之失效。故把
     「读取 App ID 列表」（读，超时重试开）下沉到 `fetchAppIDs`、把「申请描述文件」（写，超时重试关，
     内部先 delete 再重建）下沉到 `fetchProvisioningProfile`（后者拆出 `requestProvisioningProfile` 保留原逻辑），
     调用处不再包裹 ⇒ label 各唯一、count 回 8。
- **涉及文件**：`Seal/Core/Signing/SigningTargetRecord.swift`、
  `Seal/Infrastructure/Signing/ApplePortalSigningService.swift`（`prepareProfileOnlyRenewal` /
  `reconstructProfileOnlyRenewalTargets` / `renewalProvisioningProfiles` / `fetchAppIDs` /
  `fetchProvisioningProfile` 下沉）、`Scripts/verify-release-safety.py`（R24/R33 的「申请描述文件」label）、
  `SealTests/`（8 个构造点 `entitlementKeys` → `entitlements`）、`project.yml`（1.3.41）。
- **验证状态**：交 CI 编译 + 既有回归（`SignedArtifactSnapshotTests` / `ProfileOnlyRenewalPolicyTests` 等
  构造点已同步）。真机验收：免费账号续签已装应用速度显著提升、大包不再先卡「正在准备应用文件」；
  诊断页「App Group 可访问」仍「是」；若记录缺失（1.3.4x 之前旧数据）自动回落慢路径，结果不变只慢。

---

## 2026-09-29 RemotePairing 端口冷启动只恢复内存、没同步 Rust：签名/续签/安装全程 ConnectionRefused（1.3.40，用户「最基本的签名续签都做不到了」）

- **现象**（用户，1.3.39/构建 76）：自替换升级后，签名/续签/安装进来自第一笔就
  `ConnectionRefused (code 61)` / `NoDevice`；LocalDevVPN 显示已连接、设备已解锁、配对正常
  （`SEAL-INSTALL-710` / `-706b` / `minimuxer(13) ConnectionRefused` / `702d NoDevice`）。
  用户确认是正常操作、非环境问题。
- **根因**：1.3.38 加的「端口持久化」只把端口恢复到 `Minimuxer._remotePairingPort`
  （内存静态量，`restoredRemotePairingPort()` **只读 UserDefaults、回落即返回**），
  **没调 `RustIdevice.setRemotePairingPort`**。而真正建连走 Rust 侧 `PairingState.port`
  （`rsd.rs` `create_rppairing_rsd_connection` 里 `TcpStream::connect(10.7.0.1:{port})`），
  Rust 冷启动恒为默认 49152 ⇒ Swift 自认 61662、Rust 撞 49152 → 设备不在那口监听 → refused。
  更糟：端口自愈 `resolve(current, discovered)` 因 Swift 侧值「没变」返回 nil 不重探 ⇒ 死锁在错端口。
- **修复**：`restoredRemotePairingPort()` 在恢复出合法端口后**显式 `RustIdevice.setRemotePairingPort(port)`**
  同步给 Rust（与 `setRemotePairingPort` 收尾同一把杠杆），Swift/Rust 端口一致。
- **涉及文件**：`Vendor/Minimuxer/Sources/Minimuxer.swift`、`project.yml`（1.3.40）。
- **验证状态**：交 CI 编译 + 既有回归。真机验收：自替换后冷启动，签名/续签/安装首笔即通，
  不再出现 ConnectionRefused；端口自愈仅在「设备端口真的变了」时触发。

---

## 2026-09-29 后台保活只有音频一路：被打断的窗口里锁屏续签被挂起（1.3.39，用户「按最牛的方式来」）

- **现象**：锁屏/后台的自动续签只靠「静音音频无限循环」（`BackgroundKeepAliveService`）保活。
  对照 6 个依赖 LocalDevVPN 通道的同类 IPA（AirCard / Eagle / Husk / LocalDevVPN / StikDebug / 定位）
  逐包拆包，稳定者普遍声明 `audio + location` 双后台模式；Seal 当年按「跟」只做了 `audio`，但音频
  会被来电/闹钟/插拔耳机/连断蓝牙/媒体服务重置停掉，自愈之间有窗口，进程一旦被挂起、续签就半途而废。
- **根因**：只有一路保活，且它的失效模式单一。上游 SideStore 自己就有备选的
  `BackgroundLocationService`（`Info.plist` 声明 `location`），Seal 没跟这一路。
- **修复**（按上游 + 同类 App 对齐，双保险）：新增 `LocationKeepAliveService` ——
  ① `UIBackgroundModes` 加 `location` + 两项定位权限描述（缺 `AlwaysAndWhenInUse` 会让
  `requestAlwaysAuthorization()` 因缺失描述被 iOS 强制终止）；② 关键开关
  `allowsBackgroundLocationUpdates = true`、`pausesLocationUpdatesAutomatically = false`
  （后者默认 true，不显式置 false 会被系统在定位静止时静默暂停）；③ 授权分级
  （notDetermined 请求 / 已授权启动 / 被拒降级仅音频），纯判据 `LocationKeepAliveAction`
  可单测；④ 启动点与音频保活一致（`SealApp.init()` + `RefreshAllAppsIntent`）；⑤ 注入进
  `AppContainer`；⑥ 新码 `SEAL-BACKGROUND-017`/`-018` 登记。
- **涉及文件**：`Seal/Infrastructure/Background/LocationKeepAliveService.swift`（新增）、
  `Seal/Application/AppContainer.swift`、`Seal/App/SealApp.swift`、
  `Seal/Features/Intents/SealRenewalIntent.swift`、`SealTests/Background/LocationKeepAliveTests.swift`（新增）、
  `project.yml`、`Scripts/verify-release-safety.py`（守卫 R110 6 断言 + 4 变异）、
  `docs/qa/log-code-index.md`。
- **验证状态**：`py_compile` 通过；守卫 R110 + 单测交 CI。真机验收：授予「始终允许」后锁屏快捷指令
  续签 `SEAL-BACKGROUND-017` 出现、多一层活保障；权限被拒时降级 `SEAL-BACKGROUND-018`、仅音频保活。

---

## 2026-09-29 RemotePairing 端口未持久化：续签/安装冷启动先撞默认端口再 Bonjour 重查（1.3.38）

- **现象**（用户，1.3.37）：每次进 Seal 续签/安装，通道先撞一下默认端口才连上，进来那一下卡顿
  （「续签慢」）。
- **根因**：`Minimuxer.remotePairingPort` 冷启动恒为 `MuxerConstants.rsdPort`（49152，仅内存
  `private static var`）；`setRemotePairingPort` 只写内存 + 通知 Rust（作废旧端口 RSD 缓存），
  **从不落 UserDefaults**；Bonjour 发现端口（`adoptDiscoveredRemotePairingPort`）只在失败后触发、
  采纳后也不持久化。设备 `_remotepairing._tcp` 不挂固定端口时，每次冷启动都要「撞 49152 →
  就绪失败 710 → Bonjour 重查（浏览 1.8s + 解析 1.2s）→ 换端口」这一整轮。
- **修复**（对齐上游 SideStore `lastDiscoveredRemotePairingPort`）：`Minimuxer.swift` 把端口持久化到
  UserDefaults —— ① 冷启动由 `restoredRemotePairingPort()` 恢复上次端口（非法值回落默认）；
  ② `setRemotePairingPort` 采纳新端口后写回 + `synchronize`（后台进程被回收也不丢）；
  ③ `resetRemotePairingPort` 换设备 / 重新导入配对时 `removeObject` 清掉，避免残留上一台设备的死端口。
  换设备时序天然正确：恢复在任何 `start` 之前，`Muxer.start` 内 `pairingIdentityChanged` 会把错误端口
  reset 回默认；同一设备端口未变时冷启动第一下即通。
- **涉及文件**：`Vendor/Minimuxer/Sources/Minimuxer.swift`（恢复/写回/清除）、
  `Scripts/verify-release-safety.py`（守卫 R109 1 断言 + 2 变异）。
- **验证状态**：`py_compile` 通过；守卫 R109 交 CI。真机验收：同一设备、端口未变的连续两次冷启动，
  第二次省掉 Bonjour 重查、进来的卡顿消失；换设备后不残留旧端口。

---

## 2026-09-29 快捷指令续签成功但进 Seal 结果抽屉有延迟：非自替换结果不落盘（1.3.37）

- **现象**（用户真机，1.3.36）：锁屏/后台用快捷指令续签，系统通知已报「已续签成功」，之后进 Seal
  打开「续签成功」抽屉却要等一会儿才能看到成功反馈。
- **根因**：`runBatchRefresh` 只在 `result.awaitingConfirmation > 0`（Seal **覆盖安装自己**）时调用
  `persistPendingBatchResultForSealUpdate` 落盘；普通应用、以及 Seal 走 profile-only（只换描述文件、没换
  进程，`awaitingConfirmation == 0`）时，结果只留在内存里的 `batchRefreshSession`。快捷指令那轮在后台跑完、
  进程被系统回收后，下次进 Seal 走 `restorePendingBatchResultIfNeeded` 读不到任何载荷 ⇒ 抽屉恢复不出
  那笔真实的「成功」。
- **修复**：把持久化方法重构为 `persistPendingBatchResult(forceSealAwaiting:)`；`awaitingConfirmation == 0`
  分支**同样落盘**（`forceSealAwaiting: false`，按每个项的**真实终态** completed/failed/waiting 写，
  不再把 Seal 一律记成 awaiting）。恢复侧 `restoredResult` / `settledQueueStates` 本就按条目终态派生，无需改动。
  绝不伪造：载荷里的终态都来自 RenewalCoordinator 已逐项确认的结果。
- **涉及文件**：`Seal/Features/Apps/AppsViewModel.swift`（方法重构 + 分支补持久化）、
  `Scripts/verify-release-safety.py`（守卫 R108 1 断言 + 1 变异）。
- **验证状态**：`py_compile` 通过；守卫 R108 交 CI（变异自查钉住「非自替换也必须落盘」）。
  真机验收：锁屏快捷指令续签成功后直接进 Seal，抽屉**立即**显示该轮真实成功/失败分桶。

---

## 2026-09-29 守卫变异锚点歧义：对称函数复用同款 guard 行致变异自查漏检（1.3.36）

- **现象**：CI `build-package` 第一步 `verify-release-safety.py` 报
  `FAIL: Guard failed mutation check: Update: an ambiguous set of IPA assets`。
- **根因**：新增 `sha256DownloadURL` 时复用了 `ipaDownloadURL` 里**完全相同**的
  `guard candidates.count == 1 else { return nil }`。变异 runner 用 `str.replace(old, new, 1)` 只换
  **第一处**（ipa），原判据 `"..." in update_checker` 又被**第二处**（sha256）满足 ⇒ 变异被放跑、
  自查判失败。
- **修复**：把「ambiguous set」判据从「是否存在」改成 `count == 2`（两个直链挑选函数各一处）；
  变异改第一处后 count 降为 1 ⇒ 判据失败 ⇒ 变异被抓回。
- **涉及文件**：`Scripts/verify-release-safety.py`（1 断言）。
- **验证状态**：本地 `rg -c` 确认恰好 2 处 + `py_compile` 通过；交 CI 变异自查。
- **常犯坑位**：给已配变异锚点的纯函数写**同款对称函数**时，若复用了锚点同款代码行，
  `.replace(old,new,1)` 只会改第一处、`in` 判据会被第二处满足 ⇒ 变异自查静默漏检。
  要么用 `count == N`（钉住总处数），要么把锚点文本写得更长使其唯一。

---

## 2026-09-29 发版前收尾：内建更新补 SHA256 完整性校验 + 证书复用快速路径抽纯函数补单测（1.3.36）

- **背景**（回答「距离正式版还差什么」）：三条缺口 —— 供应链安全、测试覆盖缺口、回归验证。
  前两枪在本版合入，回归验证前一轮（1.3.33–1.3.35）已真机走通（多任务可用）。

  ① **供应链安全：内建更新此前只校验版本串 + 域名白名单**。版本串挡住「换成旧包」，挡不住
  「同版本内容被替换」—— 同一合法域名下资产被调包就装进盗版/篡改包。这是**安全**缺口：退化后
  编译照过、其余检查照绿，只能靠守卫钉住。
  - **修复**：下载 IPA 后从 Release 资产挑唯一 `.sha256` 直链 → 下载校验和 → `AppFileStore.streamingSHA256`
    流式算本地哈希 → `UpdateChecker.hashMatches` 大小写无关比对；**缺校验和 / 对不上一律 `phase = .failed`**
    fail closed（不落盘、不覆盖、不 `onInstall`）。
  - **涉及文件**：`UpdateChecker.swift`（`sha256DownloadURL`/`expectedSHA256`/`hashMatches` 三纯函数 +
    `UpdateNotice.sha256DownloadURL`）、`AppFileStore.swift`（`streamingSHA256` 提为 static）、
    `UpdateNoticeView.swift`（`onInstall` 前插校验）、`UpdateCheckerAssetTests.swift`（7 单测）。
  - **守卫**：R107（3 断言 + 2 变异）。
  - **验证状态**：纯函数单测覆盖；不涉真机安装路径，交 CI。

  ② **测试覆盖缺口：`signingIdentity` 两个快速路径分支的 7 天复用判据无法单测**（AGENTS.md §3 早已记
  「既无守卫也无单测」）。两分支都要求本地证书剩余有效期覆盖免费 profile 的 **7 天**寿命，否则把
  「次日到期证书」签进新包 ⇒ 次日 iOS 判「尚未验证」闪退。此前判据散在 actor private + 网络里，删掉
  校验也编译照过。
  - **修复**：抽纯函数 `SigningCertificateMaterialPolicy.fastPathReuseDecision(remoteSerials:targetSerialNumber:reuseStatus:)`
    返回三态；先 `guard reuseStatus == .reusable`（7 天门）再归一化比对 serial。`signingIdentity` 改调纯函数，
    行为不变、日志保留（列表拉取失败仍记原因 + 耗时，便于分限流/超时/网络）。
  - **涉及文件**：`SigningCertificateMaterialPolicy.swift`（新增枚举 + 纯函数）、
    `ApplePortalSigningService.swift`（快路径改 switch 判定）、`SigningCertificateMaterialPolicyTests.swift`（4 单测）。
  - **守卫**：R102 由「钉两处 `Self.certificateReusable(local)` 调用」改为「钉纯函数调用点 + 纯函数本体」
    （2 断言 + 2 变异）。
  - **验证状态**：纯函数满覆盖单测；不涉真机安装路径，交 CI。

---

## 2026-09-29 免费账号签 LiveContainer：3001（参数无效）→ 降级后再撞 1200（未启用 App Group）（1.3.34）

- **现象**（真机，1.3.33 构建 68）：放开三处免费闸门后，免费账号重签 LiveContainer 仍失败。
  Apple 先返 **3001**（`provided parameters are invalid`）；Seal 走空能力降级重发成功后，紧接着
  `assignAppGroups` 又撞 **1200**（`Application Group feature should be enabled before associating`）。
  ⇒ App Group 依旧没签进去，多任务仍不可用。
- **根因**（逐文件读上游 + AltSign 源码，非网上搜索）：
  ① **3001**：`updateFeatures` 把 `updated.entitlements = filteredEntitlements`（app-groups 数组、
  increased-memory-limit 等值）写进 App ID，AltSign 的 `update`（`ALTAppleAPI+Operations.swift`）把这些
  **entitlements 值**连同 feature 开关一起塞进 `updateAppId.action`。上游 SideStore 的 `updateFeatures`
  （`FetchProvisioningProfilesOperation.swift:233`）只发 **feature 开关**
  （`targetFeatures: [ALTFeature: String]`，"true"/"false"），**从不发 entitlements 值**；免费账号两种
  一起发被 Apple 3001 拒。
  ② **1200**：3001 降级分支把 App ID 的 feature 清空（App Group 开关并未真正启用），但调用点仍
  **无条件**执行 `assignAppGroups`（assign 端点）⇒ Apple 判「先启用 App Group 再关联」而 1200 拒。
- **修复**：
  ① `updateFeatures` 改为只发 feature 开关（`"true"/"false"`），不再写 `updated.entitlements`
  （`copy()` 后本就是空字典，AltSign `update` 于是只提交开关）；补 `featureEnabled` 纯函数对齐
  SideStore 的 isEnabled 判据（数组非空 / 布尔取值 / 默认开）。
  ② `assignAppGroups` 调用点包一层 `if updated.downgradedToEmptyEntitlements == false` —— 降级后
  跳过，避免 1200；正常路径（feature 已启用）零影响。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、
  `Scripts/verify-release-safety.py`（R24 变异锚点同步缩进 + 降级跳过注释）、
  `docs/upstream-alignment.md`、`DEBUG_LOG.md`、`RELEASE_NOTES.md`、`project.yml`。
- **验证状态**：⏳ CI 编译 + 真机回归待做。
  真机验收：免费账号重签 LiveContainer，不再 3001/1200，诊断页 `App Group 可访问` 变「是」、多任务可用。

---

## 2026-09-29 签后校验会误报 401/402：filteredAppIDEntitlements 留下非 feature 能力 + App Group 原始 ID 未映射（1.3.35）

- **现象**（代码路径推演，非真机）：1.3.34 修完 3001/1200 后，签含 App Group 的应用仍会在
  「描述文件逐 bundle 校验」关报 **SEAL-ENTITLEMENT-401 / 402**。前一轮真机（1.3.33 构建 68）止步于
  3001/1200，还没走到这一步 ⇒ 这两枪是「修完 3001/1200 之后才会浮出的下一环」，不能等真机再撞。
- **根因**（逐文件读上游 `SideSign/CodeSignerAPI.swift:95-123` + `AltSign/ALTCapabilities.swift`）：
  上游签名器以**描述文件授权集**为起点生成 Mach-O entitlements、与 app 原始 entitlements 取交集 ⇒
  **portal 拿不到的能力本就写不进包**。而 `filteredAppIDEntitlements` 却：
  ① 把 `increased-memory-limit` 等 `ALTFeature(entitlement:) != nil` 判定不过的能力也塞进
  「期望授权集」⇒ 描述文件不带它们 ⇒ `validateEntitlements` 拿「期望」对「描述文件」必报 **401**；
  ② App Group 的 group ID 保留**原始**值，而 `assignAppGroups` 用 `bundleIDMapper.appGroupID` 映射成
  `group.<x>.seal.<teamID>` 才提交、描述文件返回的也是映射后 ID ⇒「原始」对「映射后」⇒ 必报 **402**。
- **修复**（`filteredAppIDEntitlements` 单点生效，`updateFeatures` / `requestedEntitlements` 同源自洽）：
  ① 加 `guard ALTFeature(entitlement: entitlement) != nil else { continue }` —— 只保留能经门户
  feature 开关提交的能力（appGroups / interAppAudio）；
  ② 对 `.appGroups` 值经 `signingWorkspace.bundleIDMapper.appGroupID(original:teamID:)` 映射，
  与 `assignAppGroups` 提交、描述文件返回的 ID 逐字一致。
  ⚠️ 只改「账本」、不碰签名器：最终 Mach-O 的 entitlements 仍由上游 SideSign 按描述文件裁剪 ⇒
  不会多授/少授任何能力，只是消除误报。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、
  `Scripts/verify-release-safety.py`（新增 R65⑲ 主守卫 + 两条变异锚点）、
  `docs/upstream-alignment.md`、`DEBUG_LOG.md`、`RELEASE_NOTES.md`、`project.yml`。
- **验证状态**：⏳ CI 编译 + 真机回归待做。
  真机验收：免费账号重签 LiveContainer，全流程不再 3001 / 1200 / 401 / 402，
  诊断页 `App Group 可访问` 变「是」、`App Group 名` 为映射后 `group.*.seal.<teamID>`、多任务可用。

---

## 2026-09-29 免费账号签名被剥掉 App Group ⇒ LiveContainer 多任务不可用（1.3.33）

- **现象**（真机诊断页 + 样本取证）：Seal 免费账号签出的 LiveContainer（3.8.10，Bundle `com.kdt.livecontainer.seal.CT8QZ7352B`）
  在「免 JIT 模式诊断」页显示 `App Group 名 = Unknown`、`App Group 可访问 = 否`；证书五项全正常（团队 CT8QZ7352B 匹配、有效期至 2027）⇒ 多任务与内置 SideStore 均不可用。
- **根因**（三证合一）：源 IPA（3.8.8 单独版）主 App + 3 个扩展都声明了
  `com.apple.security.application-groups = [group.com.SideStore.SideStore, group.com.rileytestut.AltStore]`
  ＋ `increased-memory-limit` ＋ healthkit；Seal 签出的产物这三样**全无**、profile 只剩 4 键。
  `ApplePortalSigningService.swift` 三处免费闸门剥掉 App Groups：
  ① `filteredAppIDEntitlements` 里 `if team.type == .free, entitlement == .appGroups { continue }` 直接丢弃；
  ② `updateFeatures` 里 `team.type != .free` 才 toggle `features[.appGroups] = true`；
  ③ `assignAppGroups` 调用点 `team.type != .free` 才执行。
  （`increased-memory-limit` 是白名单放行后被 Apple 3001 拒 → 降级清空，本日志 2026-09-24 已记，非本次；healthkit 不在免费白名单，本就不该免费拿。）
- **修复**：放开三处闸门 —— 免费账号与付费账号同样保留/分配 App Group（对齐 SideStore 上游
  `Feature.freeFeatures` 含 `.appGroups`、`updateAppGroups` 无条件执行）。对无 App Group 的普通应用零影响
  （`assignAppGroups` 内 `guard originalGroups.isEmpty == false else { return }` 直接空转）。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、
  `docs/upstream-alignment.md`、`DEBUG_LOG.md`。
- **验证状态**：⏳ CI 编译 + 真机回归待做。
  真机验收：免费账号重签 LiveContainer，诊断页 `App Group 可访问` 变「是」、`App Group 名` 不再是 Unknown；多任务可用。
  ⚠️ 唯一未验证事实：免费账号 `addAppGroup`/`assign` 是否被 Apple 接受 —— 若被拒，`assignAppGroups`
  会 throw（与上游一致硬失败），届时再决定回退或仿 3001 降级兜底。

---

## 2026-09-28 快捷指令续签「全失败」那一轮什么都没发 —— 通知判据 `succeeded > 0` 把失败吞了（1.3.32）

- **现象**（用户真机，1.3.31）：快捷指令在后台续签，日志记「续签完成：共 3，成功 0，失败 3」
  （逐项 `NSURLErrorDomain -1001`，Apple 服务器超时），紧接着一句
  「本轮没有成功续签的项，按规则不发」⇒ **用户什么通知都没收到**，以为续签成功了。
- **根因**：1.3.31 的通知判据是 `BackgroundRenewalNotificationResult.shouldNotify == (succeeded > 0)`。
  这条判据本身是「只报喜」的思路，与「快捷指令续签的全部价值 = 不打开 App 也能知道结果」直接冲突 ——
  失败才是最需要打扰用户的那一半，却被判据整轮吞掉 ✗。
- **修复**：
  ① `shouldNotify` 改为 `total > 0`（**有项要续签就发**）—— 全失败 / 全未执行 / 全待核验都会发；
     标题分四档（完成 / 部分失败 / 失败 / 未完成），正文把四桶一个不少地列出；
  ② `awaitingConfirmation` 原来**根本没被带进通知**（`AppsViewModel` 组装参数时漏了这个字段）
     ⇒ 正文「已续签 1/3」看不出另外 2 个是「待核验」，会被误读成失败 ⇒ 补进参数与正文；
  ③ 新增 `BackgroundRenewalSkippedNotice`，覆盖**本轮根本没跑起来**、且**不会自动补上**的三档：
     让位给非续签类操作（导入配对文件 / 管理证书，只占 `activeLease`）、取操作锁等满 30 秒、
     整轮抛错的两个 `catch`（原来只写 `batchRefreshSession.status`，后台没人看得见）；
  ④ 让位分流判据新增 `hasActiveRenewalWork`（那项操作会不会把应用续完）：让位给**签名 / 续签**
     **刻意不发**（那一轮自己会给出结论），只发让位给非续签类的那一档。
- **涉及文件**：`Seal/Infrastructure/Notifications/BackgroundRenewalNotifier.swift`、
  `Seal/Features/Apps/AppsViewModel.swift`、
  `SealTests/Notifications/BackgroundRenewalNotificationResultTests.swift`、
  `docs/qa/log-code-index.md`（`SEAL-BACKGROUND-016`）、
  `Scripts/verify-release-safety.py`（R106④ 判据改写 ＋ 新增 R106⑥ ＋ 变异 8 条）、
  `RELEASE_NOTES.md`、`project.yml`（1.3.32）。
- **验证状态**：⏳ 守卫交 CI 跑（本机不再跑）；CI `swift-regression` 编译与真机回归待做。
  真机验收：快捷指令续签**全失败也收到「Seal 续签失败」通知**；被非续签操作挡住 / 等锁超时 /
  整轮抛错各收到一条对应通知；Seal 内手动续签始终不发通知。

---

## 2026-09-28 锁屏下用快捷指令续签：日志说成功、抽屉全红 —— 钥匙串 `WhenUnlocked` 锁屏读不到（1.3.31）

- **现象**：锁屏状态下用快捷指令续签，日志记**成功**，打开 Seal 抽屉里**全是失败**。
  用户当场纠正：「抽屉失败是因为真实就是失败了，**日志误判了**」。日志里只剩一句
  `Seal.KeychainError 1`（没有别的上下文）。
- **根因（逐行读真源码，不靠搜索）**：
  ① 不打开 App 的续签由快捷指令在**锁屏**时冷启动进程触发
     （`SealRenewalIntent` / `RefreshAllAppsIntent`，`openAppWhenRun = false`），
     而这条链路**每次都现读钥匙串**、进程里没有任何内存缓存：
     `SigningCoordinator.signAndInstall` 一进来就 `keychain.load(accountID:)` 取
     `AccountSecret`（authToken / 口令 / 各证书 P12）—— **profile-only 续签也走这条**，
     它只更新描述文件，照样要这份密钥；每次 Apple 请求还要
     `AnisetteClient` 的 `loadIdentifier()` / `load()`。
  ② 两处 store 的条目都写的是 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
     ⇒ **锁屏时不可读** ⇒ 抛 `KeychainError`。
  ③ `RenewalCoordinator.isRetryable` **不认**这个错误（不是通道瞬时错误、不是 `SEAL-NET-`、
     不是网络错误）⇒ **不重试** ⇒ `SEAL-RENEW-500` 直接判失败进抽屉。
  ④ 为什么日志会「说成功」：`KeychainError` 是 struct 且**未实现 `CustomNSError`** ⇒
     桥成 `NSError` 后 `domain` 恒为 `Seal.KeychainError`、**code 恒为 1**、
     文案是系统默认 ⇒ 真机日志只剩一句 `Seal.KeychainError 1`，把「设备锁定」与
     「条目不存在」混成同一句话，看起来像「钥匙串里没有」。
- **修复**：
  ① **写入权限**改为 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`（锁屏可读；
     仍保留 `ThisDeviceOnly` ⇒ 口令与私钥**不随 iCloud 同步**，AGENTS.md §4）。
     上游 SideStore/AltStore 用 `.afterFirstUnlock` **＋ `synchronizable(true)`** ——
     那是为了让它的 App 与 App Extension 共享账号；Seal **只跟可访问性这一半、不跟同步那一半**。
  ② **一次性迁移** `KeychainAccessibilityMigrator`：改写入常量只影响**新写入**的条目，
     而 profile-only 续签**根本不写钥匙串**（只读）⇒ 已加过账号的老设备会一直是旧值。
     迁移只按 `class + service` 查询、`SecItemUpdate` 只改可访问性（口令与私钥明文不出内存）。
     **同步**跑（`SealApp.init()`，必须早于任何钥匙串读取），并在 `RootTabView` 的
     `scenePhase == .active` **补做** —— 锁屏冷启动那次会被系统拒绝
     （`errSecInteractionNotAllowed`），而保活让进程活很久、`init()` 不会再跑，只挂 init 有真实缺口。
  ③ 迁移完成判定 `shouldMarkCompleted = didChangeAnything && !isBlocked && !hasFailure`：
     **刻意不把 `.nothingToDo` 当完成** —— 设备锁着时 `SecItemUpdate` 也可能返回
     `errSecItemNotFound`（条目锁屏不可见）而不是 `errSecInteractionNotAllowed` ⇒
     会被误判成「本来就没有条目」⇒ 一旦落标记就再也不重试，**修复静默失效** ✗。
  ④ `KeychainError` 实现 `CustomNSError`：`errorCode = Int(status)`、`describe` 把
     `errSecInteractionNotAllowed` 翻成「设备已锁定，当前无法读取该钥匙串条目」。
- **顺带（用户同轮要求）**：**只有快捷指令续签成功才发系统通知，Seal 内手动续签不发**。
  `AppsViewModel` 用请求级标记 `backgroundTriggerRequested`（`refreshAllFromBackgroundTrigger()`
  置位，**放在让位 `guard` 之后** —— 被让位时本轮没跑，不该发通知），在
  `runBatchRefresh` **入口处**（任何 `guard` / `throw` 之前）**消费并清位**；
  ⚠️ 收尾处清位是错的：本轮有三条**不产生结果**的出口（`renewalCoordinator` 缺失、
  抢不到操作锁、`refreshAll` 直接抛错），标记会跨轮存活 ⇒ 「快捷指令失败一次、之后手动续签」
  误发通知（写守卫时发现并改掉，R106④ 钉住这个顺序）。
  `BackgroundRenewalNotifier` 只在 `succeeded > 0` 时投递一条。
  全失败 / 全未执行**刻意不发**（那属于「用户需要处理」，界面与日志已有引导，弹通知既不解决问题
  又会与「续签成功」的语义混在一起）。用户没给通知权限时**只留日志、不在后台索要权限**
  （`requestAuthorization()` 在后台根本弹不出授权框）。
  ⚠️ **这一条判据（`succeeded > 0`）已在 1.3.32 被真机推翻** —— 全失败那一轮彻底沉默，
  见本文件顶部同名条目。
- **涉及文件**：`Seal/Infrastructure/Security/KeychainAccessibility.swift`（新）、
  `Seal/Infrastructure/Notifications/BackgroundRenewalNotifier.swift`（新）、
  `Seal/Infrastructure/Security/KeychainVault.swift`、`Seal/Infrastructure/Accounts/AnisetteProvisioningStore.swift`、
  `Seal/Application/AppContainer.swift`、`Seal/App/SealApp.swift`、`Seal/App/RootTabView.swift`、
  `Seal/Features/Apps/AppsViewModel.swift`、
  `SealTests/Security/KeychainAccessibilityTests.swift`（新）、
  `SealTests/Notifications/BackgroundRenewalNotificationResultTests.swift`（新）、
  `docs/qa/log-code-index.md`、`Scripts/verify-release-safety.py`（守卫 **R106**）、
  `docs/upstream-alignment.md`（钥匙串可访问性对照台账）、`RELEASE_NOTES.md`、`project.yml`（1.3.31）。
- **验证状态**：✅ 守卫本机复跑 **PASS（788 断言 / 556 变异，含新增 R106 的 5 断言 ＋ 7 变异）**；
  ⏳ CI `swift-regression` 编译与真机回归待做
  （Windows 本机不编译 Swift，单测/编译通过 ≠ 可用）。真机验收：**锁屏下用快捷指令续签成功**
  且收到系统通知；解锁后打开 Seal 抽屉状态与日志一致。

---

## 2026-09-28 「Wi-Fi 与 LocalDevVPN 都连了」仍签名 / 续签失败：RSD 端口变了却被误报成 708，端口自愈永不触发（1.3.29 续）

- **现象**：用户**做对了操作**（Wi-Fi ＋ LocalDevVPN 都连上），签名 / 续签 / 配对校验仍失败，
  报 `SEAL-INSTALL-708`「设备未响应」；重试多少轮都只撞同一个死端口。用户明确要求：
  **「都连了就必须一定能签名续签，不受任何影响」**。
- **根因（逐行读真源码，不靠搜索）**：
  ① iOS 不保证 `_remotepairing._tcp` 挂在固定端口。设备换端口后，
     `Minimuxer.readyVerdict()` 在 RemotePairing 模式下（`Muxer.isrppairing` 为真）走
     `testDeviceConnection(ifaddr: "10.7.0.1")`
     （`Vendor/Minimuxer/Sources/Minimuxer.swift:132-133`），它探测的是**当前 `remotePairingPort`**
     （同文件 `:284-286`）⇒ 端口不对**必然**返回 `.tunnelUnreachable`。
  ② 但 `readyDeviceIdentifier()` 用的是**裸 `isReady()`** ⇒ 原因被丢光 ⇒ `lastDiscoveryDetail` 恒空
     ⇒ 最终失败落到 `discoveryFailure(tunnelReachable: true, detail: nil)`
     ⇒ 归成 **708**（`deviceNotRespondingFailure`）。
  ③ 端口自愈只认 **710**（`RemotePairingPortPolicy.reprobeFailureCodes`）⇒ **永不触发** ✗。
  ④ 配对校验路径（`SettingsViewModel.runInstallChannelCheck`）**直接调 `diagnose()`、不走
     `start()`** ⇒ 连 `startOnce` 的外层那次重试都没有 ⇒ 配对页上「都连上了还报错」永远修不好 ✗。
- **修复**（`MinimuxerInstallChannel.swift`）：
  ① 新增 `lastReadinessIssueRaw` 记录就绪原因；`readyDeviceIdentifier()` 用 `readinessVerdict()`
     替换裸 `isReady()`（判定**完全等价**：`readyVerdict().isReady == ready()`，只多出原因）。
  ② `diagnose()` 诊断循环内接一次端口重查：`readinessFailure` → `RemotePairingPortPolicy
     .shouldReprobe(failureCode:)` → `reprobeRemotePairingPortIfNeeded`，**让配对校验路径也能自愈**；
     判据复用唯一那份表，不在通道里再抄一张（本仓反复踩的「两张表同源」坑）。
  ③ 拿不到设备标识的最终失败据**就绪原因**归码（710 而非 708）；隧道本身不可达时保持 `discoveryFailure`
     的 701 / 708 判断。
- **为什么这样就能「都连了就一定成功」**：端口一换 → 就绪报 `.tunnelUnreachable` → 归 710 →
  当场经 Bonjour 重查端口 → `Minimuxer.setRemotePairingPort` 写新端口，Rust 侧
  `set_remote_pairing_port`（`Vendor/Minimuxer/RustBridge/src/idevice_support/rsd.rs:152-168`）
  按 `generation` **作废按旧端口建的 RSD 连接缓存** ⇒ 下一轮 `readyDeviceIdentifier()` 即连上新端口。
  即：**判对原因（过程）→ 触发自愈 → 真的连上（结果）**；改错误码只是让自愈能被触发的手段。
- **涉及文件**：`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`、
  `SealTests/Installation/InstallChannelDiagnosticClassificationTests.swift`（新增
  `portLevelReadinessReasonMapsToReprobeCode` / `nonPortReadinessReasonsDoNotTriggerReprobe`）、
  `Scripts/verify-release-safety.py`（守卫 **R104**，4 断言 ＋ 4 变异）。
- **验证状态**：✅ 守卫本机复跑 **PASS（782 断言 / 549 变异，含新增 R104 的 4 断言 ＋ 4 变异）**；
  ⏳ 待 CI `swift-regression` 编译 ＋ 真机回归（Windows 本机不编译 Swift，单测/编译通过 ≠ 可用）。

---

## 2026-09-28 把「通知提前量 `leadHours` 真正生效」当修复改进去 —— 它其实改了**被测试钉住的规格**，CI `swift-regression` 红（**已回退**）

- **现象**：`a64d2b9` 推送后 CI `swift-regression` ✗：`ExpiryNotificationPlannerTests
  .schedulesSealBeforeExpiration` 报 `Expectation failed: (plans.count → 0) == 1`，**紧接着**
  进程 `Swift/ContiguousArrayBuffer.swift:692: Fatal error: Index out of range`、`exit code 65`
  —— 测试在前一条断言失败后仍去取 `plans[0]`，下标越界把整个测试进程打崩。
  `build-package` ✓、`signer-tests` ✓ —— **又一次只有 `swift-regression` 能暴露**（同 09-28 那条
  `Int` 传参的教训）。
- **根因**：`a64d2b9` 把 planner 的 `-24 * 3_600` 改成 `-leadHours * 3_600`（并让 scheduler 传
  `leadHours`）。但**「提醒恒定排在到期前 24 小时」是规格**，有两处钉住：
  ① 设置页标签写死「提前 24 小时提醒」（`SettingsRootView`，无 UI 可改该值）；
  ② `schedulesSealBeforeExpiration` 明确断言「即使传 `leadHours = 144`，`fireDate` 仍是到期前 24 小时」。
  于是 `leadHours = 144` ⇒ `fireDate` 落在过去 ⇒ 被 `guard requestedFireDate > now` 滤掉 ⇒ `count == 0`。
- **为什么当初会改错**：看到 `planner.plans(for:now:)` 没传 `leadHours`、`NotificationPreferences
  .leadHours` 又确实读写 UserDefaults，就断定「参数是死的 ⇒ 修它」。但**「偏好能存取」与「排期用不用它」
  是两条独立不变量**：前者由 `NotificationPreferencesTests` 覆盖，后者是**被测试钉住的规格**。
  在没有任何 UI 能改该值的前提下改排期 = **未被要求的行为变更**（AGENTS.md「最小改动 / 不要改没坏的东西」）。
- **修复**：**回退** —— planner 还原为 `-24 * 3_600`、scheduler 还原为 `plans(for:now:)`；
  并在两处各留一条**规格说明**注释（写明钉住它的两个位置 ＋「曾改成 `-leadHours * 3_600` 导致
  CI 红」），防止下次再被「顺手修」。`RELEASE_NOTES.md` §4 由「七处」改回「六处」并删掉该条。
- **涉及文件**：`Seal/Core/Notifications/ExpiryNotificationPlanner.swift`、
  `Seal/Infrastructure/Notifications/ExpiryNotificationScheduler.swift`、`RELEASE_NOTES.md`。
- **验证状态**：⏳ 待 CI `swift-regression` 复验（Windows 本机不编译 Swift）。

---

## 2026-09-28 复核 AGENTS.md §2「两条未走流式的历史路径」——两条其实都已修好（**文档漂移**）

- **现象**：无用户上报。这是**逐行复核** AGENTS.md §2 时发现的**文档漂移**：旧记录写着
  「注意还有两条**未走流式**的历史路径……改到它们时顺手改掉」，而代码里**两条都已经改了**。
- **事实核对**（逐行读代码，不凭记录）：
  ① `AppFileStore.extractNestedIPAIfNeeded`（`AppFileStore.swift:241`）走的是
     `archive.extract(nestedIPAEntry, to: nestedIPATempURL)` —— **流式落盘**；旧写法是
     `Data` ＋ `reserveCapacity(uncompressedSize)`，而 `uncompressedSize` 是**包内自填值**
     ⇒ 500MB+ 嵌套包选完即被 jetsam 杀掉（表现为「点了没反应」）。
  ② `IPAParserService.isEncryptedBinary`（`IPAParserService.swift:439`）用
     `archive.extract(entry) { chunk in if binaryData.count < 4096 { binaryData.append(chunk) } }`
     —— 只流式读**主二进制前 4KB** 判 Mach-O 头，不再 `extract` 整个主二进制。
- **为什么要改记录**：留着旧记录会让下一次会话去「顺手修」**已经修好的代码**（白工 ＋ 误改
  既有正确实现的真实风险）。AGENTS.md 明文「冲突时以代码为准，并回来更新本文件」。
- **修复**：AGENTS.md §2 改为「✅ 已于 2026-09-28 逐行复核，确认都已改成流式」，并写明两个
  判据的位置与旧错法，避免再被旧记录误导。
- **涉及文件**：`AGENTS.md`（§2 大包内存纪律）。
- **验证状态**：✅ 逐行读代码确认两条均已流式；守卫侧另有 `nestedData` **不得**出现于
  `IPAParserService` 的断言（`verify-release-safety.py`），本次未新增守卫（属文档同步，不改行为）。

---

## 2026-09-28 CI `swift-regression` 编译失败：新测试把 `Int` 传给了 `TimeInterval`（守卫 PASS 也拦不住）

- **现象**：`a64d2b9`（1.3.29）推送后 CI **`build-package` ✓、`signer-tests` ✓，只有
  `swift-regression` ✗**，报
  `AppPresentationTests.swift:53:48: cannot convert value of type 'Int' to expected argument type 'TimeInterval'`，
  外加一条**级联**假错 `:57:39: cannot infer contextual base in reference to member 'renewal'`
  （同一函数内前一条语句类型失败 ⇒ 后续 `#expect(presentation.kind == .renewal)` 被带崩）。
- **根因**：新测试写 `now.addingTimeInterval(Int(3.9 * 86_400))`。`TimeInterval` 是 `Double`，
  **整数字面量**（`-60` / `86_400`）能隐式转换，但 `Int(...)` 产生的是**真正的 `Int` 值**，
  不会隐式转 `Double` ⇒ 编译失败。修法：去掉 `Int(...)`，直接写 `3.9 * 86_400`（已是 Double）。
- **为什么守卫没拦住**：`verify-release-safety.py` 是**纯静态文本断言**，不编译 Swift；
  而 `build-package` job **不编译测试 target** ⇒ 只有 `swift-regression` 能暴露。
  **教训**：守卫 PASS ≠ 能编译。改测试文件后，`swift-regression` 是**唯一**关卡，
  不要拿「守卫全绿」当「可以发布」。
- **涉及文件**：`SealTests/Apps/AppPresentationTests.swift`。
- **验证状态**：⏳ 待 CI `swift-regression` 复验。

---

## 2026-09-28 证书导出把 **Apple ID 账号口令**当证书密码回传外部应用（补守卫 R103）

- **现象**：无用户上报 —— 这是**自查**出来的安全缺陷（写 R102 守卫时顺手复核
  `CertificateExportHandler`）。
- **根因**：`performExport` 取 `secret.password`（`AccountSecret.password` = **Apple ID
  账号口令**）当证书密码，拼进 `callback_template` 的 `$(PASSWORD)` 交给外部应用
  （LiveContainer 等）。两重危害：
  ① 把账号口令泄露给第三方应用；
  ② Seal 的 P12 由 AltSign/OpenSSL 生成、**本身没有密码**（全仓解析处一律
     `ALTCertificate(p12Data:password:nil)`）⇒ 传过去的密码是错的，目标应用解不开包。
  上游 SideStore 传的是**证书自己的**密码（`CertificateManager.getPassword(for:)` =
  序列号），Seal 没有这一层封装 ⇒ 正确做法是**空串**。
- **修复**：`let password = ""`；同时补 **URL query 转义**（`urlQueryEncoded`，从
  `urlQueryAllowed` 再剔掉 `;/?:@&=+$, `）—— base64 里的 `+` 在 query 里会被解成**空格**、
  `/` `=` 也会被目标解析器误读 ⇒ 不转义传过去的是**损坏的证书**（表现为「导入失败」
  而非报错）。
- **涉及文件**：`Seal/Infrastructure/Accounts/CertificateExportHandler.swift`（含顶部流程注释
  与 `performExport` 内注释同步改写，避免注释与实现打架）。
- **验证状态**：守卫 **R103①**（本文件不得出现取账号口令的属性路径、必须有 `let password = ""`）
  与 **R103②**（base64 必须过 `urlQueryEncoded`）＋ 两条变异自检 —— 本地 **PASS
  （778 checks / 545 mutations）**。⚠️ 本项**无单测** ——
  `performExport` 是 `@MainActor` 且含 `UIApplication`/Keychain，判据抽纯函数的成本高于收益，
  故只钉源码断言。

---

## 2026-09-28 快速路径两支的 7 天复用校验补源码守卫（R102）：此前只靠「记得别删」

- **现象**：无真机现象 —— 这是一条**防退化**记录。AGENTS.md §3 一直写着
  「快速路径列表命中 / 网络失败回退两支既无守卫也无单测」，但一直没补。
- **根因**（为什么必须补）：这两支的 `Self.certificateReusable(local)` 是**唯一**把
  「次日到期的证书」挡在新包之外的东西。把它删掉：**编译照过**、其余 700+ 条静态检查**照绿**，
  只有真机上表现为「iOS 判尚未验证 ⇒ 一打开就闪退」。也就是说，它一旦被误删，
  除了真机回归没有任何环节会拦住 —— 正是「必须钉成源码断言」的形态。
- **修复**：`Scripts/verify-release-safety.py` 新增 **R102①**：取 `ApplePortalSigningService.swift`
  的快速路径片段（`// 快速路径：…` → `// 慢速路径：…`），断言
  - `fast_path.count("Self.certificateReusable(local)") == 2`，**且**
  - 两支各自的形态都在：`}), Self.certificateReusable(local) {`（Apple 列表命中）
    与 `if Self.certificateReusable(local) {`（列表拉取失败回退本地）。
  - **为什么不只写 `count == 2`**：那会假绿 —— 删掉一支的校验、同时在别处再补一次同样的
    调用，计数照样是 2。判据必须落在**每一支的形态**上。
  - 同时补**两条变异自检**（抹掉任一支的校验 ⇒ R102① 必须报红），防止守卫本身空转。
- **涉及文件**：`Scripts/verify-release-safety.py`、`AGENTS.md`（§3 签名把「既无守卫也无单测」
  改成「单测仍缺、源码守卫已补」）。
- **验证状态**：守卫本地两轮一致 **PASS（778 checks / 545 mutations）**，含 R102① 的两条变异。
  ⚠️ **单测仍缺** ——
  要真正可单测，得先把 `signingIdentity` 里这段「拉列表 + 两支回退」抽成纯函数，
  本次只补了守卫，未动该结构（见 AGENTS.md §3）。

---

## 2026-09-28 公开仓库泄露开发者账号：日志 / 文档 / 测试夹具里的真实 Apple ID 与 Team ID

- **现象**（AGENTS.md §4 早先记为「已知违反」，一直没清）：`DEBUG_LOG.md`、`docs/qa/`、
  若干**源码注释**与**测试夹具**里直接抄着真机日志里的**真实** Apple ID 邮箱与 **11 个真实
  Team ID**。公开仓库里这等于把开发者账号（以及若干第三方 App 的 Team）一起公开。
- **根因**：排障时为了「可对账」把真机日志原文抄进文档与夹具，没有任何脱敏环节；
  而 `LogPrivacyRedactor` 只管**运行时**日志，管不到**仓库里的文本**。
- **修复**：全仓（跳过 `upstream/` 与 `Vendor/`）按**固定映射**改写为**等长合成占位符**
  `TEAM000001`…`TEAM000011`（10 位大写字母数字，与仓内既有的 `TEAM123456` / `ABCDE12345`
  同形）；邮箱改写为 `sun***n1@gmail.com`（`AppleAccountClient.maskEmail` 的形态）。
  - **等长**是刻意的：Team 后缀会被 `hasSuffix(".seal.\(teamID)")`、`count == 10` 这类
    判据碰到，缩短成 8 位（`343***F9` 那种掩码）会改变测试夹具的行为。
  - **固定映射**是刻意的：`docs/qa/2026-09-16-profile-pileup-and-ui-row-layout.md` 的结论是
    「18 个 base × 13 个不同 Team 后缀」，映射若不固定，这条结论就散了。
  - 写回时**读、写都用 `newline=""`**，绝不让 Python 翻译行尾（本仓有 CRLF 文件，
    行尾被改写会让 `sha256sum -c` 类校验静默失败 —— 已踩过一次）。
- **涉及文件**：`DEBUG_LOG.md`、`docs/qa/2026-09-16-profile-pileup-and-ui-row-layout.md`、
  `docs/qa/2026-09-26-cert-rotation-gate-deadlock.md`、`AGENTS.md`（§4 改写为「已清干净」
  并给出占位符约定）、`Scripts/verify-release-safety.py`（注释）、
  `Seal/Core/Accounts/RenewalAccountResolver.swift`、`Seal/Core/Maintenance/ProfileReclaimPolicy.swift`、
  `Seal/Infrastructure/Signing/ApplePortalSigningService.swift` 及 12 个 `SealTests/**` 文件，
  共 18 个文件 / 109 处。**改后全仓已搜不到任何真值**（残留的 `sunuannian1` 只以仓库地址形态出现）。
- **验证状态**：静态守卫 773 checks / 540 mutations **PASS**；改动全是**字面量**替换
  （源码里 4 处命中全在注释、其余全在测试夹具与文档），两侧同步改写 ⇒ 断言仍自洽。
  ⏳ 待 CI `swift-regression` 复验测试夹具。

---

## 2026-09-28 快捷指令 / 手动续签整轮全失败：批量重试不恢复通道（复用死会话）+ 四处同批修复

- **现象**：快捷指令后台触发与手动续签**整轮全失败**；日志里同一项重试多次仍撞
  `[Minimuxer.MinimuxerError 1]`（`NoConnection`）。用户对照 SideStore 问「为什么它那么稳」。
- **根因**（批量路径）：
  1. `RenewalCoordinator.process` 的重试循环只 `Task.sleep` 后 `continue`，
     **不恢复设备通道** ⇒ `MinimuxerInstallChannel.start()` 的 900 秒成功缓存把已被
     隧道抖动顶掉的**同一个**死会话原样还回来 ⇒ 三次重试全撞同一个死会话。
  2. 单签路径（2026-09-27 刚补 `reset()`）与批量**各写一份**恢复动作 ⇒ 必然漂移
     （本仓反复踩过的「两张表同源」坑）。
- **修复**：
  1. 新增 `SigningCoordinator.prepareInstallChannelForRetry(after:)` 作为**唯一**恢复动作
     （判据仍是纯函数 `DeviceChannelTransientPolicy.requiresChannelResetBeforeRetry`：
     通道类 ⇒ `reset()`；描述文件超时类 ⇒ 只清熔断）。
     单签 `AppsViewModel.signWithChannelRetry` 与批量 `RenewalCoordinator.process`
     **都调它**；批量只在**通道类**失败时动通道，并留痕 `SEAL-RENEW-503`。
  2. 同批另修四处：R98 `MinimuxerInstallChannel.installationFailure` 改用 `errorDetail`
     取词（与 `isTerminalInstallError` 同源；否则 `ImportFailure` 只经 `NSError` 桥接拿到
     `title`，`No space left` / `ApplicationVerificationFailed` 等设备原文全丢）；
     R99 `DeviceProfileCleaner` 的 dump 目录枚举失败 fail closed（不得 `(try? …) ?? []`
     退化成空清单、与「设备上确实没有」同形）；R100 `SealLogStore.exportText()`
     （= 镜像到 Documents 的 `Seal-log.txt`）也过脱敏；R101 已安装列表 / 签名历史的
     剩余天数改**四舍五入**（免费 profile 恰好 7 天，刚签完读到的 6.99 天向下取整显示「6天」），
     且天数颜色与显示数字**同源**（`days <= 3`，避免「显示 4 天却橙色」）。
- **涉及文件**：`Seal/Core/Signing/SigningCoordinator.swift`、
  `Seal/Core/Renewal/RenewalCoordinator.swift`、`Seal/Features/Apps/AppsViewModel.swift`、
  `Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`、
  `Seal/Infrastructure/Installation/DeviceProfileCleaner.swift`、
  `Seal/Infrastructure/Diagnostics/SealLogStore.swift`、
  `Seal/Features/Apps/AppPresentation.swift`、`Seal/Core/SigningHistory/SigningHistoryRecord.swift`、
  `docs/qa/log-code-index.md`、`SealTests/Apps/AppPresentationTests.swift`、
  `Scripts/verify-release-safety.py`（守卫 R97–R101，含变异自检）。
- **验证状态**：静态守卫 R97–R101（含变异自检）；新增单测 `freshlySignedProfileShowsSevenDays`
  / `justUnderFourDaysShowsFourNeutralDays`（由 CI `swift-regression` 跑）；**真机待回归**：
  通道抖动时应看到 `SEAL-RENEW-503`（批量）/ `SEAL-SIGN-503`（单签）后自愈；
  已安装列表刚签完应显示「7天」。

---

## 2026-09-27 自替换后自动续签 Seal 硬失败 `SEAL-SIGN-500`：单应用路径没接通道重试、通道失败没归类

- **现象**（用户导出的 1.3.27 真机日志，`Seal-log(6)(3).txt`）：
  `20:16:13` Seal 自替换 `exit(0)` → `20:16:24` 新进程起保活 → `20:16:27` 自动续签 Seal
  → `20:16:33` `SEAL-PROFILE-363`（设备端描述文件枚举不可用）→ `20:16:57`
  `[SEAL-SIGN-500] 签名流程遇到未预期错误。[Minimuxer.MinimuxerError 1]`（`NoConnection`）。
  即：**刚重启的通道还在抖**，续签在通道没站稳时硬失败，用户看到一句无动作可做的笼统话。
- **根因**（两条，互相放大）：
  1. **单应用路径没有通道重试**。批量 / 后台续签走 `RenewalCoordinator` +
     `DeviceChannelTransientPolicy`（同源词表 + 8 秒退避），通道抖动能自愈；
     而单应用走 `AppsViewModel.startSigning → runSigning`，**直接把 `signAndInstall` 的
     异常抛给用户** ⇒ 同一个抖动，批量能自愈、单签整轮白做。
  2. **通道失败没归类**。底层是裸 `MinimuxerError`，落到 `unexpectedSigningFailure`
     一律包成 `SEAL-SIGN-500`「未预期错误」——**既没有下一步动作，也看不出这是通道问题**。
- **修复**：
  1. `DeviceChannelTransientPolicy` 新增单签预算与**纯函数**判据：
     `singleAppMaxAttempts`（= 3，与批量 `maxAttempts` 一致）、
     `shouldRetry(afterAttempt:maxAttempts:error:)`、
     `retryDelayNanoseconds(forAttempt:)`（8 秒 × 尝试序号）、
     `requiresChannelResetBeforeRetry(_:)`、`diagnostic(_:)`。
  2. `AppsViewModel.runSigning` 的 `signAndInstall` 抽进 `signWithChannelRetry(...)`：
     同一份词表判可重试、**重试前先拆死会话**（通道类 `installChannel?.reset()`；
     描述文件超时类只清熔断，交给 `renewProfilesOnly` 的污染闸门自己 reset + start）、
     8 秒退避、留痕 `SEAL-SIGN-503`。
  3. 失败归类 `AppsViewModel.signingFailure(for:)`（`nonisolated`，可单测）：通道类给
     **带码可引导**的 `SEAL-SIGN-504`（recovery 引导去检查 LocalDevVPN），其余才是 `SEAL-SIGN-500`；
     `SEAL-SIGN-504` 登记进 `InstallFailureSettingsRoute.localDevVPNCodes` + 码表。
- **涉及文件**：`Seal/Core/Renewal/DeviceChannelTransientPolicy.swift`、
  `Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Settings/InstallFailureSettingsRoute.swift`、
  `docs/qa/log-code-index.md`、`SealTests/Renewal/DeviceChannelTransientPolicyTests.swift`、
  `Scripts/verify-release-safety.py`（守卫 R96，含变异自检）、`project.yml`（1.3.28）。
- **验证状态**：静态守卫 R96（含 9 条变异自检）+ 单测（`DeviceChannelTransientPolicyTests` 新增 6 例）
  本机跑绿；**真机待回归**：自替换后自动续签 Seal 若再撞通道抖动，日志应出现 `SEAL-SIGN-503`
  并在 8 秒后重试；兜不住时应是 `SEAL-SIGN-504` 且「恢复」按钮跳 LocalDevVPN 页。

## 2026-09-27 通道失败只剩一句笼统话 + 隧道掉线后重试撞死会话：就绪判据丢原因、掉线不被识别

- **现象**：① 续签 / 安装失败时提示永远是同一句「设备连接失败（超时、网络不可达或无设备）」——
  「**LocalDevVPN 没开**」与「**设备没响应**」是两种完全不同的下一步动作，用户却拿不到区分；
  ② 安装 / 上传中途隧道掉线后重试三次都失败，而且**三次撞的是同一条已死的会话**。
- **根因**（**Seal 侧**）：
  1. 就绪判据只有 `Minimuxer.ready() -> Bool` —— 一个**布尔值**，失败时「为什么失败」在返回那一刻就丢了。
     上游 `SideStore/minimuxer` 的 `isReady(withNetworkCheck:withDDIMountCheck:)` 返回的是**带原因的结果**
     （配对没加载 / 没启动 / 没有 VPN / 不可达 / 没有设备 / muxer 没监听）。
  2. 通道复用一条**缓存会话**（900 秒窗口）；掉线后 `Minimuxer.reset()` 拆的是 **Rust 侧**会话，
     而 `start()` 复用的是**通道自己的 Swift 侧缓存**（`cachedDeviceIdentifier` / `lastSuccessfulStart`）
     ⇒ 缓存没清，下一次 `start()` 在窗口内**直接还回那个已作废的 UDID**，重试自然一直撞死会话。
- **修复**：
  1. 把上游那条**带原因**的判据补进来（`MinimuxerReadyVerdict` / `MinimuxerReadyIssue`），
     **判定与顺序一字不改**（`readyVerdict().isReady` 与 `ready()` 完全等价，原因全部来自原本就要算的布尔量
     ⇒ 没有新增探测、也没有新增等待）。Seal 侧新增纯函数 `ChannelReadinessPolicy` 把原因翻成可判读类别，
     安装入口改走**带原因的门禁**（`requireReady()`）：`noVPNInterface ⇒ SEAL-INSTALL-701`、
     `tunnelUnreachable ⇒ 710`、`noDevice ⇒ 708`、`heartbeatStale ⇒` 单独文案。
     分类**只允许一份**（`ChannelReadinessPolicy`），通道里不再另抄一张表。
  2. 新增纯函数 `DeviceChannelVPNDropPolicy`（移植上游 `isVPNDrop` 思路），识别 `broken pipe` /
     `connection reset` / `early eof` 这类**传输层对端消失**的错误（刻意**不含**
     `ApplicationVerificationFailed` / `No space left` 这类设备语义错误，否则失去区分度）；
     通道内每次 `Minimuxer.reset()` 之后**必须连 Swift 侧会话缓存一起作废**；观测到掉线时立刻作废缓存
     并留痕 `SEAL-VPN-003`（警告级）。
- **涉及文件**：`Vendor/Minimuxer/Sources/Minimuxer.swift`（`readyVerdict()` / `MinimuxerReadyIssue`）、
  `Seal/Core/Renewal/ChannelReadinessPolicy.swift`、`Seal/Core/Renewal/DeviceChannelVPNDropPolicy.swift`、
  `Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`、`SealTests/Renewal/ChannelReadinessPolicyTests.swift`、
  `SealTests/Renewal/DeviceChannelVPNDropPolicyTests.swift`、`docs/qa/log-code-index.md`、
  `Scripts/verify-release-safety.py`（新增 R94①–⑥ 断言 + 8 变异）、`RELEASE_NOTES.md`、`project.yml`（`1.3.27`）。
- **验证状态**：⚠️ **待真机回归**（Windows 本机不能编译）。回归点：
  ① 关掉 LocalDevVPN 再续签 ⇒ 提示应是「LocalDevVPN 未就绪」而不是「设备未响应」；
  ② 开着 VPN、手机锁屏离线再续签 ⇒ 应是「设备未响应」；③ 安装中途掉线后重试 ⇒ 日志里应出现 `SEAL-VPN-003`，
  且下一次操作**重建**连接（而非复用旧会话）。
- **教训**：**「判定等价」不等于「信息等价」** —— 把 `Bool` 换成「带原因的 Result」时，
  只要原因全部来自原本就要算的量，就**既不多一次探测、也不改变任何行为**，却能立刻让失败可行动。
  另一条：`reset()` 这类「拆会话」的操作必须**连上层缓存一起作废**，否则上层会在窗口内把死会话再还回来。
- **CI 实测补记（2026-09-27，提交 `5b5a561`）**：`swift-regression` 报
  `MinimuxerInstallChannel.swift:580:38: error: cannot find type 'MinimuxerReadyVerdict' in scope` ✗ ——
  `MinimuxerReadyVerdict` / `MinimuxerReadyIssue` 都**嵌套**在 vendor 的 `public struct Minimuxer` 里，
  Seal 侧必须写**限定名** `Minimuxer.MinimuxerReadyVerdict`，裸名编译不过。
  **为什么静态守卫没拦住**：守卫只做文本比对、不做类型解析，看不到「嵌套」这层语义
  ⇒ 已补守卫 **R94①c**（断言 `-> Minimuxer.MinimuxerReadyVerdict?` 存在）＋ 变异自检（把限定名改回裸名必须报红）。
  **教训**：**跨模块引用 vendor 的嵌套类型时，限定名是硬约束**；这类错本机（Windows 不能编译）只能靠 CI 兜，
  所以凡是「新增跨模块类型引用」都要顺手想一句「它是嵌套的吗」，并让守卫把限定名钉住。

## 2026-09-27 隧道通、就是连不上：RemotePairing 端口被硬编码成 49152

- **现象**：LocalDevVPN 通、隧道也通，但续签 / 安装**始终**连不上设备；重试多少轮都一样。
- **根因**（**Seal 侧**）：Seal 把 RemotePairing 服务端口**硬编码**成 `49152`（`MuxerConstants.rsdPort`），
  Rust 侧 `SocketAddrV4::new(Ipv4Addr::new(10, 7, 0, 1), 49152)` 写死；而 iOS **不保证**
  `_remotepairing._tcp` 挂在这个端口上 ⇒ 设备侧守护进程换端口之后，就变成「隧道通、这个端口不通」，
  每一轮重试都撞同一个死端口（自愈不了）。
- **修复**（对齐上游 SideStore `MinimuxerWrapper` 的「失败后经 Bonjour 重查端口、变了就换」）：
  1. 新增纯函数 `RemotePairingPortPolicy`，只在**端口不对同义**的那一类失败上触发重查
     （就绪失败码 `SEAL-INSTALL-710`，或 `connection refused` / `no route to host` / `connection timed out`
     这类**端口层**原文）。**显式集合**，不用数字区间 —— 否则 `709`「安全握手未完成」也会被算进来
     （`AGENTS.md` 第 3 节：错误码 → 动作必须用显式码集合）。
  2. 新增 `RemotePairingPortDiscovery`：`NWBrowser` 并发浏览 `_remotepairing._tcp` 系列取服务端点，
     `NWConnection` 解析端口；复用现成 `ContinuationBox`（**不新造锁盒**）。`project.yml` 已声明
     `NSBonjourServices` —— 缺它 `NWBrowser` **不报错、只是永远没有结果**（静默失效，日志上看不出来）。
  3. 通道在**两处**接线（诊断失败后 `startOnce` / 安装失败重试循环），且换端口**赶在 `reset()` 之前**
     —— 反过来（先 reset 再换端口）会让重建后的那一轮仍撞旧端口，等于白跑一轮。
  4. **发现到不同端口才采纳**（`Minimuxer.setRemotePairingPort` 同步给 Rust 侧并作废按旧端口建的 RSD 缓存；
     端口没变则什么都不做，不无谓拆掉一条已经好的连接），留痕 `SEAL-VPN-004`（警告级）。
  Rust 侧：`PairingState` 加 `port` 字段（默认 `DEFAULT_REMOTE_PAIRING_PORT = 49152` 作回退）＋
  `set_remote_pairing_port(port)`（**换端口即作废 RSD 连接缓存**）＋ 新 FFI
  `rust_bridge_idevice_set_remote_pairing_port`；连接创建改用 `state.port`。
- **涉及文件**：`Seal/Core/Renewal/RemotePairingPortPolicy.swift`、
  `Seal/Infrastructure/Installation/RemotePairingPortDiscovery.swift`、
  `Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`、`project.yml`（`NSBonjourServices`）、
  `Vendor/Minimuxer/Sources/Minimuxer.swift`、`Vendor/Minimuxer/RustBridge/MinimuxerBridgeIdevice.swift`、
  `Vendor/Minimuxer/RustBridge/src/bridge_idevice.rs`、
  `Vendor/Minimuxer/RustBridge/src/idevice_support/rsd.rs`、
  `SealTests/Renewal/RemotePairingPortPolicyTests.swift`、`docs/qa/log-code-index.md`、
  `Scripts/verify-release-safety.py`（新增 R95①–⑥ 断言 + 10 变异）、`docs/upstream-alignment.md`、`RELEASE_NOTES.md`。
- **验证状态**：⚠️ **待真机回归**。回归点：设备换了 RemotePairing 端口后续签 ⇒ 日志里应出现
  `SEAL-VPN-004`，且本轮**换端口后**能连上（而不是一直撞旧端口）。
  ⚠️ **本机不能编译**（`NWEndpoint` / `NWBrowser` 的 Sendable 与 `ContinuationBox` 约束以云 CI 为准）。
- **教训**：**「网络层通」不等于「服务端口通」** —— 探测通过（隧道可达）只证明到网关的路由没问题，
  不代表目标守护进程还挂在**记忆里的那个端口**上；凡是「硬编码对端端口/地址」的地方，
  都要问一句「这个值由谁保证不变」。另一条：Bonjour 浏览**漏声明 `NSBonjourServices` 是静默失败**，
  必须靠守卫把「声明」与「代码里的服务类型列表」钉成同源。

---

## 2026-09-27 `Lara`（`Eagle.app`）签名安装后一打开就闪退：瘦身把 arm64e / arm64 搞成混装

- **现象**：`Lara` 能签名、能安装，一点图标就闪退；崩溃报告 `bug_type 309`，
  `termination.namespace = DYLD` / `indicator = Library missing`。
- **证据（崩溃报告原文）**：
  `Library not loaded: @rpath/libgrabkernel2.dylib`；
  `Referenced from: <97DDAF4A…> /Volumes/VOLUME/*/Eagle.app/Eagle`；
  `…/Eagle.app/Frameworks/libgrabkernel2.dylib (mach-o file, but is an incompatible architecture (have 'arm64', need 'arm64e'))`；
  `usedImages[0]` 里 `Eagle` 的 `arch = arm64e`。
- **根因**（**Seal 侧 bug，不是 IPA 的问题**）：`SigningWorkspace.stripArm64eArchitecture(in:)`
  是**逐文件**做的 —— 每个文件各自「能瘦成 arm64 就瘦」。而 dyld 要求**同一 bundle 内主二进制
  与它加载的每个 dylib 架构一致**：`Lara` 的主程序是 **thin arm64e**（越狱工具，没有普通 arm64 slice）
  ⇒ 按「thin 原样保留」的规则留着 arm64e；`Frameworks/libgrabkernel2.dylib` 是 **fat(arm64 + arm64e)**
  ⇒ 被瘦成 arm64 ⇒ arm64e 的主二进制去加载 arm64 的 dylib ⇒ dyld 在 `main` 之前就 `abort_with_payload`。
- **修复**：`stripArm64eArchitecture` 改为**两遍 + 全树一致**：第一遍只分类
  （新增 `machOStripScan(of:)` + `Arm64eStripScan`，**只读文件头、一个字节都不改**），
  只要遇到**任何一个**瘦不到普通 arm64 的 Mach-O（thin arm64e，或 fat 里只有 arm64e）
  就**直接 `return`、整棵不动**；确认全树都能瘦，第二遍才逐个切 arm64 slice。
  ⇒ 判据与执行共用同一份 cpusubtype 解析（避免「判定」「执行」两套规则漂移）。
- **涉及文件**：`Seal/Infrastructure/Signing/SigningWorkspace.swift`（重写 `stripArm64eArchitecture`
  + 新增 `machOStripScan(of:)` / `Arm64eStripScan`）、`Scripts/verify-release-safety.py`
  （新增 R91⑨c 断言 + 变异自检）、`RELEASE_NOTES.md`、`project.yml`（`1.3.26`）。
- **验证状态**：⚠️ **待真机回归**（Windows 本机不能编译，一切以云 CI + 真机为准）。回归点：
  ① `Lara` 重新签名安装后能正常打开；② 普通 App 产物体积与 1.3.25 一致（瘦身没被整体关掉）。
- **教训**：**「逐文件」的优化遇到「跨文件一致性」约束时，必须先全树判定、再动手** ——
  改到一半才发现不能改，架构就已经混装了；而且这类错**只在真机 dyld 上暴露**，
  本机既不能编译也不能跑，必须靠真机崩溃报告定位。

## 2026-09-27 profile-only 续签「一次超时毒掉后续全部」：污染标记是永久闸门、没有解除路径

- **背景**（用户原话）：「续签有问题」—— 1.3.25 真机上某一项「只换描述文件」的续签失败后，
  之后**每一项**都失败。
- **现象**（真机日志顺序）：以 `SEAL-PROFILE-363`（设备端描述文件枚举不可用）开场 →
  `Minimuxer.installProvisioningProfile` 超过 30 秒未返回（`SEAL-PROFILE-352`）→ 置「污染」标记 →
  之后**每一项** profile-only 续签都在入口被 `SEAL-PROFILE-350` 挡下 ⇒ 成片失败。
- **根因**（**Seal 侧 bug**）：`ProfileOnlyProvisioningProfileInstaller` 的 `isTainted` 是
  **永久**闸门 —— 它表达的是「上一次同步 FFI 没有取消机制、可能仍在后台跑，直接再注入就是并发注入」，
  但**没有任何解除路径**。而 1.3.25 起后台保活让进程**跨轮存活**（保活正是为此而设）
  ⇒ 一次通道抖动 = 本进程后续**全部** profile-only 续签被挡，直到用户重启 Seal。
  1.3.25 修的是「死会话复用」（`SEAL-PROFILE-363` 的成因），**没修这个永久闸门** ⇒ 用户仍报「续签有问题」。
- **修复**：
  1. 污染标记抽成**纯状态机** `ProfileOnlyTaintGate`（`private(set) var isTainted` +
     `markTainted()` + `consume()`）—— 抽成值类型是因为 `SealTests` target 看不到 Minimuxer，
     判定留在 actor 私有 `Bool` 里就**永远测不到**。
  2. `consume()` 是**「读取 + 清除」一个原子操作**：写成 `if isTainted { reset(); isTainted = false }`
     会让两个并发调用都看到 `true`、各自重置一次通道。
  3. `SigningCoordinator.renewProfilesOnly` 在注入**之前** `consumeTaintIfAny()`，
     为真时 `await installChannel.reset()` **再 `await installChannel.start()`**，然后才注入，
     并留痕 `SEAL-PROFILE-355`（警告级）。
     ⚠️ 重置必须走 `installChannel.reset()`（连 Swift 侧 `cachedDeviceIdentifier` 等一起清），
     **不能**裸 `Minimuxer.reset()`（只拆 Rust 会话，下一次 `start()` 仍还回已作废的 UDID）。
     🔴 **`reset()` 之后必须重新 `start()`**（2026-09-27 读 Minimuxer 源码才发现）：
     `Minimuxer.reset()` 不只是拆 Rust 会话 —— 它先读 `Muxer.isrppairing` 再 `Muxer.reset()`
     （`teardownLocked()` 把 `_isrppairing` 归零、清配对缓存），并 `Provision.resetProvider()`
     清掉描述文件 provider；而 `Provision.getProvider()` 是**按 `Muxer.isrppairing` 现场选传输**的
     ⇒ 归零后会选 `LockDownProvision`（`Device.getFirstDevice()` 走 usbmuxd），
     而本环境是 RemotePairing（LocalDevVPN）⇒ 注入会在 15 秒轮询后抛 `NoDevice`
     ⇒ **自愈反而造出一次「重置后第一次操作必失败」**（只靠外层重试兜回来，白多一轮 + 15 秒）。
     重新 `start()` 会走到 `Minimuxer.start(pairingFile:logPath:)`（`_isrppairing` 复位、
     `RustIdevice.setRpPairingFile` 重设）⇒ 传输恢复。**reset 之后必 start** 也是设置页
     导入配对文件 / 恢复连接的既有模式。守卫 R93② 现在同时钉住 `reset()` 与随后的 `start()`。
  4. `DeviceChannelTransientPolicy` 新增 `profileOperationTimeoutCodes`
     （`SEAL-PROFILE-352` / `-353`），与「安装提交前」那批 `transientChannelFailureCodes`
     **刻意分开**：那批重试前**不需要**动传输，这两个**必须**先重置（正是 R05「超时 ≠ 失败」的落点）。
     `isTransientChannelFailure(_ failure:)` 同时认两表 ⇒ 同一项被纳入续签重试、自己就能自愈。
- **涉及文件**：`Seal/Infrastructure/Renewal/ProfileOnlyProvisioningProfileInstaller.swift`
  （新增 `ProfileOnlyTaintGate` + `consumeTaintIfAny()`）、`Seal/Core/Signing/SigningCoordinator.swift`
  （`renewProfilesOnly` 消费污染 + 重置通道 + `SEAL-PROFILE-355`）、
  `Seal/Core/Renewal/DeviceChannelTransientPolicy.swift`（`profileOperationTimeoutCodes`）、
  `SealTests/Renewal/ProfileOnlyTaintGateTests.swift`（新增）、`Scripts/verify-release-safety.py`
  （新增 R93①–⑤ 断言）、`docs/qa/log-code-index.md`、`RELEASE_NOTES.md`、`project.yml`（`1.3.26`）。
- **验证状态**：⚠️ **待真机回归**（Windows 本机不能编译；一切以云 CI + 真机为准）。回归点：
  ① 正常续签全部成功；② 若中途出现一次 `-352` / `-353`，日志应紧跟 `SEAL-PROFILE-355`
     而**不是**之后每项都 `SEAL-PROFILE-350`。
- **教训**：**「标记一个『可能有后台任务在跑』的状态时，必须同时设计它的解除路径」** ——
  永久闸门遇到「进程跨轮存活」（保活 / 批量）就是「一次抖动毒掉后续全部」；
  而这类错在单进程一次性的旧模型里根本不会暴露。另外：**消费语义要「读取即清除」一个原子操作**，
  否则并发调用会各自重置一次通道。

## 2026-09-27 快捷指令后台续签「续不上」：死会话复用、保活不自愈、手动/后台互撞、通道码没进重试词表

- **背景**（用户原话）：「快捷指令那边的自动续签不会续签不成功，锁屏、看电视、听歌各种情况下
  都需要能够续签成功，不会被占用通道，手动续签不会被快捷指令续签互相影响」。
- **现象 / 根因（四件独立的事，一次改完）**：
  1. **死会话被一轮一轮复用**。每轮后台批量续签都以 `SEAL-PROFILE-363`（「设备端描述文件
     枚举不可用（通道未就绪或解析失败）」）开场、随后整项以 `Minimuxer.MinimuxerError 1`
     （`NoConnection`）失败，而**同一进程**里几分钟前的前台续签成功。
     ⇒ 根因：`MinimuxerInstallChannel.start()` 的 900 秒缓存只查 `isReady()`（**裸 TCP**：
     `rsdPort` / `lockdowndPort` 通着就放行），而 `connect_to_rsd_services` 缓存的 **RSD 会话
     早已死掉**；保活让进程跨轮存活，于是这个死会话被一轮一轮发出去，**重试也拿到同一个死会话**
     （重试自愈不了）。
  2. **保活不能自愈**。保活的失败模式全是「进程还在、标志位还是 true、但音频早停了」：
     - 拔耳机 / 断蓝牙 ⇒ 系统 `setActive(false)` 并停掉播放；
     - 媒体守护进程重启（`mediaServicesWereResetNotification`）⇒ 所有音频对象作废，
       `AVAudioPlayer` 变无效对象；
     而旧实现**只监听中断**这一种，且 `isRunning` 是**自维护的布尔位** ⇒ 音频停了它仍是 `true`，
     `start()` 的幂等闸门把后续**每一次**自愈请求全部挡掉 ⇒ 保活一旦死掉就再也起不来。
  3. **手动与后台互撞时静默丢弃**。后台触发不看是否已有操作在跑就重复点火（多造一次 installd
     命令，历史事故 R05）；而手动入口的 `guard` 一律直接 `return` —— 用户点了「续签全部」/「签名」
     却**什么都不发生**、日志里也一行没有。真机上这最容易被误读成「快捷指令把通道占住了」。
  4. **通道码没进重试词表（词表不同源）**。安装链路把底层错误**归类成带码的 `ImportFailure`**
     （`SEAL-INSTALL-70x` / `SEAL-VPN-001`）才抛给续签侧，而 `RenewalCoordinator.isRetryable`
     只认 `SEAL-NET-` 前缀 ⇒ 这些通道码被当成**终态错误**、整轮白做 —— 与构建 53 那个
     「通道抖动被当成终态」是同一个错法，只是换了一层包装。
- **修复**：
  1. `start()` 复用缓存前加 **RSD 级**活性闸门 `cachedSessionIsAlive(age:)`（与 `probeCachedSessionIfStale`
     共用 `fetchUDIDDetailed()` 原语与 5 秒有界预算，区别是**这个决定行为**）；缓存不可信
     （过期 / 隧道不可达 / RSD 会话死）时**清掉** `cachedDeviceIdentifier` / `lastSuccessfulStart`，
     让下一次 `start()`（含重试）真正重建。`reset()` 同时清 Swift 侧缓存与 60 秒熔断
     （它拆的是 Rust 会话，Swift 缓存不清的话第一笔操作继续用死连接）。
  2. `isRunning` 改成**真实播放状态**（`player?.isPlaying == true`，对齐上游 SideStore
     `BackgroundAudioService.swift:15-17`）；另设 `isEnabled` 表达「意图」供通知回调判据用。
     恢复动作抽成**唯一实现** `reactivate(reason:)`（`start()` 与三种自愈共用）；新增
     `routeChangeNotification` / `mediaServicesWereResetNotification` 监听（`object: nil` ——
     媒体服务重置会换新会话实例，用旧实例当过滤器就再也收不到通知），并把路由变更判据抽成
     可单测的纯函数 `BackgroundKeepAlivePolicy.shouldReactivate(afterRouteChange:)`
     （`categoryChange` 自激、`noSuitableRouteForCategory` 注定失败 ⇒ 不恢复）。
  3. 后台触发在点火前 `guard hasActiveSigningWork == false`，命中则**让位并留痕**
     （`SEAL-BACKGROUND-014`）；手动入口（`startBatchRefresh` / `startSigning` / `restartSigning`）
     与取锁失败（`runBatchRefresh`）不再静默 `return`，改为 `alertFailure = operationInProgressFailure`
     （`SEAL-OP-002`，明确说出**被谁挡住**）。
  4. `DeviceChannelTransientPolicy` 新增**显式** `transientChannelFailureCodes`（`ImportFailure` 码），
     `Error` 重载**优先按 `ImportFailure` 的码判**；`RenewalCoordinator.isRetryable` 把通道判定
     提到 `SEAL-NET-` 分支**之前**（退避也跟着走 8 秒基数）。
     **只收「安装提交之前」的通道码**：`701 / 705 / 706b / 706t / 708 / 709 / 710 / SEAL-VPN-001`；
     **刻意不收** `702` / `702d`（安装阶段，底下那次安装可能还在跑 ⇒ 重试会造并发 installd）、
     `702t`（超时 ≠ 失败）、`702l` / `702s`（确定性拒绝）、`703` / `704` / `707` / `SEAL-PAIR-*`
     （配对 / 信任是记录问题，同 `PairingError=2`）、`711`–`735`（签名包问题，重试无用）。
- **涉及文件**：`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`、
  `Seal/Infrastructure/Background/BackgroundKeepAliveService.swift`、
  `Seal/Features/Apps/AppsViewModel.swift`、`Seal/Core/Renewal/DeviceChannelTransientPolicy.swift`、
  `Seal/Core/Renewal/RenewalCoordinator.swift`、
  `SealTests/Background/BackgroundKeepAliveTests.swift`、
  `SealTests/Renewal/DeviceChannelTransientPolicyTests.swift`、
  `docs/qa/log-code-index.md`、`Scripts/verify-release-safety.py`。
- **验证状态**：⚠️ **待真机回归**（Windows 本机不能编译；一切以云 CI + 真机为准）。
  静态守卫已加：R90⑭（`isRunning` 用真实播放状态 + `isEnabled` 表达意图）、R90⑮（监听路由变更 /
  媒体服务重置并自愈）、R90⑯（自愈日志码登记进码表）、R92⑩/⑩b/⑩c/⑩d（通道 `ImportFailure` 码表、
  `Error` 重载优先按码判、通道判定排在 `SEAL-NET-` 之前、单测齐全）、R92⑪（让位码 `-014` 与冲突码
  `SEAL-OP-002` 留痕并登记进码表），各配变异自检。
  ⚠️ 本机跑守卫用托管解释器绝对路径并放后台（见 AGENTS.md §7）。

---

## 2026-09-26 导入新版 Seal 后点「续签」不会真正装上：profile-only 准入只比 Bundle ID、不比版本

- **背景**（用户原话）：「我是将 1.3.20 直接导入 1.3.19 的 seal 里，它没有在待签名页而是在已安装
  显示了 1.3.20 版，点续签是直接续签了，但是关于里还是 1.3.19 —— 是不是续签的还是 1.3.19、
  显示的是 1.3.20，延伸到推送版本更新的时候要怎么操作设计」。
- **现象（用户看到的三件事，逐条对上代码）**：
  1. **落在「已安装」页、显示 1.3.20**：覆盖更新（`ImportWorkflow.makeSelfUpdateRecord` /
     `makeInstalledUpdateRecord`）**刻意**把记录写成**新导入包**的版本号（`version: parsed.version`）
     并置 `hasPendingSelfUpdateSource = true`，同时**保留** `mappedBundleIdentifier` / 账号 /
     证书 / 描述文件（`state: .installed`），只清掉 `signedIPARelativePath` / `signedIPASHA256` /
     `signedArtifactStatus` ⇒ 它**按设计**进已安装列表，而列表上那个版本号描述的是
     「**已导入的源包**」，不是「设备上正在跑的包」。
  2. **点「续签」直接续签了**：走的是 profile-only（`renewProfilesOnly`）—— **只换描述文件、
     从不安装** ⇒ 设备上跑的还是 1.3.19。
  3. **「关于」里仍是 1.3.19**：`Bundle.main` 的 `CFBundleShortVersionString` = **正在运行的版本**，
     这一条是**真话**。⇒ **用户的两个疑问答案都是「是」**：续签的确实是 1.3.19，
     显示的 1.3.20 是「待安装的源包版本」。
- **根因**：`ProfileOnlyRenewalPolicy.evaluate(app:liveIdentity:)` 的**实时身份通道**
  （Seal 自己专用；第三方应用走记录通道，缺 `signedArtifactStatus` 本就会回落完整重签）
  原先**只比对 Bundle ID 相等** ⇒ 直接 `.eligible` ⇒ 放行快路径。
  于是「已导入 1.3.20、实际跑着 1.3.19」被判定合格，新版本**永远装不上**，
  而界面与记录一直显示 1.3.20 —— 一条**自洽的假象**，用户只能从「关于」页看出不对。
- **⚠️ 不能用 `hasPendingSelfUpdateSource` 当判据（本轮差点踩，已避开）**：那个标志对 Seal
  **永远清不掉** —— 自替换安装成功后进程被系统换掉，清标志那行
  （`SigningCoordinator.swift` 里 `updated.hasPendingSelfUpdateSource = false`）走的是**普通安装**
  路径（`isSelfReplacement: false`），而 Seal 自己的自替换安装走
  `SelfReplacementCoordinator.submitPrepared` → `installChannel.install(..., isSelfReplacement: true)`，
  且 `SelfAppRegistrar` 的待安装分支**刻意一直保留**它（源文件还在、记录版本 ≥ 运行版本就保留，
  否则「更新源」与列表版本号都会丢）⇒ 拿它当判据 = 把快路径**永久关停**，
  那正是 1.3.17「续签全都要重装」的坑。
- **修复**（判据改用**版本比较** —— 它是**自愈**的：装完新版本后记录版本与运行版本自然相等，
  不需要清任何标志）：
  1. `ProfileOnlyRenewalPolicy` 新增**唯一判据纯函数**（准入与界面**共用同一份**，防两处漂移）
     `hasPendingUpdateSource(recordedVersion:runningVersion:)`：两边都要过 `nonBlank`，
     任一读不出来 ⇒ 返回 `false`（**不得声称**有待安装更新，与 R85 的 `.undetermined` 同一条纪律）。
  2. `LiveProfileOnlyIdentity` 新增 `runningVersion`（来源：`SelfAppMetadata.current()?.version`
     = `Bundle.main` 的营销版本）；`liveIdentity(installedIdentity:runningVersion:app:)` 里过
     `nonBlank` 守卫。**只有 `app.isSeal` 时才读** —— `SelfAppMetadata.current()` 读的是
     `Bundle.main`，对第三方应用用它会拿到 Seal 自己的版本（假阳性）。
  3. 实时身份通道改为：版本不一致 ⇒ `.requiresFullResign(.pendingSelfUpdateSource)`
     ⇒ 回落**完整重签 + 安装**，一次就把新版本装上。
  4. 这条拒绝原先**静默**（guard 里只判 `case .eligible`，被拒理由被丢掉）⇒ 现在先算
     `decision`、再进 guard，并在 guard 失败后**精确归因**留痕 `SEAL-PROFILE-365`（**警告级**）：
     「记录里的版本 X 与正在运行的版本不一致，本次改为完整重签并安装，装完新版本才真正生效」。
     ⚠️ 归因必须只认这一个 case（与 `SEAL-PROFILE-364` 同一条纪律）。
  5. 界面（详情页 + 操作抽屉）在「证书序列号」附近多一行
     `AppSigningPresentationHelpers.pendingUpdateNote(for:runningVersion:)`：
     「已导入的新版本还没装上：本次续签会完整重签并安装，装完新版本才真正生效；
     之后续签回到只更新描述文件。」判据与准入**同源**（同一个纯函数）、只对 Seal 生效。
- **涉及文件**：`Seal/Core/Renewal/ProfileOnlyRenewalPolicy.swift`、
  `Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Features/Apps/AppPresentation.swift`、
  `Seal/Features/Apps/AppDetailView.swift`、`Seal/Features/Apps/InstalledAppActionSheet.swift`、
  `Seal/Features/Apps/SigningProgressView.swift`（helper 改名，进度卡片**不**接新文案）、
  `SealTests/Renewal/ProfileOnlyRenewalPolicyTests.swift`（+4 条）、
  `SealTests/Apps/AppPresentationTests.swift`（+1 条）、
  `docs/qa/log-code-index.md`（登记 `SEAL-PROFILE-365`）。
- **守卫**：**R89**（① 判据必须是版本比较 + 双侧 `nonBlank`；② 实时通道必须回落
  `.pendingSelfUpdateSource`；③ `runningVersion` 必须随实时身份取出并过 `nonBlank`；
  ④ 调用点必须传**运行**版本且仍只在 `app.isSeal`；⑤ 拒绝必须留痕 `SEAL-PROFILE-365` 且归因精确；
  ⑥ `describe` 有可读说明；⑦ 新码已登记索引；⑧ 界面两处接上 + 与准入同源 + 只对 Seal；
  ⑨ 三个方向的单测；⑩ 文案 helper 有单测）＋ 10 条变异项。
  ⚠️ 同时修了 **R85⑦ / R89⑤ 两处「判据被注释满足」**（见「常犯坑位」）。
- **验证状态**：静态守卫通过（两遍，`698 checks / 447 mutations`）。**待** CI 编译 + 真机回归
  （真机判据见 `RELEASE_NOTES.md` 1.3.21）。

---

## 2026-09-26 构建 49 真机日志复盘：保活文案自相矛盾、自身记录同步失败说不出原因、已安装页对账缺阳性对照

- **背景**：用户发来构建 49（1.3.19）真机日志（12:05 导出，248 条）要求复查。上一轮四项
  需求在真机上**都按设计工作**（① `SEAL-PROFILE-364` 警告 + 回落完整重签 + 之后回到
  profile-only；② 无「装完又重签一次」；③「已等待 m:ss」只在设备安装阶段出现；
  ④ 新文案在位）。复查中另发现**三处**问题（前两处是文案/日志，第三处是真实缺口）。
- **现象与根因（三条各自独立）**：
  1. **保活日志自相矛盾**：`SigningCoordinator` 的「Seal 自续签事务：后台保活已启动，
     **覆盖证书、描述文件、签名和安装**」写在**续签路径判定之前**（`shouldUseProfileOnlyRenewal`
     在下方才定，profile-only 分支还会在 `renewProfilesOnly` 直接 `return`），条件只有
     `app.isSeal && installAfterSigning` ⇒ 走 profile-only 时**照样打印**。真机 `11:57:02`
     两行紧邻：「保活已启动，覆盖证书、描述文件、签名和安装」＋「续签路径已确认：仅更新
     描述文件；不会重新签名、打包或安装 IPA。」⇒ 自相矛盾。这是用户需求④「没有做的事不写」的残留。
  2. **`SEAL-SELF-REG-001` 说不出下一步**：文案只有「Seal 自身记录同步失败」一句，
     **不带底层原因**。真机 `11:49:55` / `11:49:57` 连报两次（每次紧邻
     「中断于 skipped-no-managed-bundle-ids」⇒ 记录库当时是空的，属「刚装完 Seal、
     还没加 Apple ID、还没导入配对」的启动窗口）。同族 `SEAL-SELF-115` 一直带 `\(error)`。
     判据：**拿着这条日志能不能直接说出下一步**。
  3. **已安装页对账缺阳性对照（真实缺口）**：`AppsViewModel.reconcileInstalledAppsWithDevice`
     用设备查询结果**决定删不删本地记录**，下游 `delete` 会连带 `fileStore.removeApp`
     **删掉本地文件** —— 但这条路径**没有**「先问一个确定装着的 App」这道网。
     姊妹路径**都有**：`DeviceInstalledAppScanner.confirmedInstalledBundleIdentifiers`
     （注释原文「阳性对照 ＋ 逐条设备核验，**先问完再动手**」）、`DeviceProfileCleaner`
     （「阳性对照：Seal 自己**一定**装着」）、`AppRecordRecovery`、`MinimuxerInstallChannel`。
     根因：`Vendor/Minimuxer/Sources/Minimuxer.swift` 的 `isAppInstalled` 实现是
     `inst.lookup(appId:) != nil`，Rust 侧把 RPC 失败与「没查到」返回成**同一个空指针**
     ⇒ 通道半坏时对**每一个** Bundle ID **静默答「没装」**（不抛错、只答否）；
     而 `InstalledAppDeviceVerifier` 只能抓**抛错**的失败（404 / 超时 / 冷却）
     ⇒ 「通道说假话」与「App 真的没装」在代码里完全同形。
     真机先例就写在 `DeviceProfileCleaner` 注释里（「com.mjorb.seal.<TEAM_ID> 被答成未安装」）——
     同一个 API、同一台设备。
- **修复**：
  1. 文案改为「Seal 自续签事务：后台保活已启动，**避免续签过程中被锁屏或切后台挂起**」
     （只陈述保活的目的，不宣称覆盖了哪几步）；同步修 `SigningProgressView` 里**引用旧文案**
     的注释（不改就会留下一条 grep 不到真源的注释）。
  2. `SEAL-SELF-REG-001` 补 `\(error)`。
  3. 在 `reconcileInstalledAppsWithDevice` 的 `do` 块**最前面**插入**阳性对照**：
     拿 `Bundle.main.bundleIdentifier`（= 正在运行的 Seal）**真发一次设备查询**；
     拿不到 Bundle ID 或对照未通过 ⇒ 写 `SEAL-INSTALL-739`（**警告级**）＋ `return false`
     （整轮一条记录都不删）。⚠️ 码必须**新**：`SEAL-INSTALL-709` 已被
     `MinimuxerInstallChannel` 的「与设备的安全握手未完成」占用 —— 复用会让用户查码表
     时得到错误解释。
     ⚠️ 与既有的「先问完、再动手」是**互补**的两条网：那条防「问一半通道坏了」，
     这条防「通道从头到尾都在说假话」（那种情况下每条查询都成功返回 `false`）。
- **涉及文件**：`Seal/Core/Signing/SigningCoordinator.swift`、
  `Seal/Core/Maintenance/AppMaintenanceJob.swift`、`Seal/Features/Apps/AppsViewModel.swift`、
  `Seal/Features/Apps/SigningProgressView.swift`（注释）、
  `docs/qa/log-code-index.md`（登记 `SEAL-INSTALL-739`，并补上一直漏登记的 707 / 708）。
- **守卫**：**R88**（① 必须拿**运行中的 Seal 自己**做对照；② 必须**真发一次**设备查询；
  ③ 顺序「对照 ⇒ 收集缺失 ⇒ 删除」；④ 对照未通过必须**整轮中止**；
  ⑤ 两条中止路径都留痕、且码是**新**的；⑥ 拿不到对照 Bundle ID 也 fail closed）
  ＋ 6 条变异项。守卫 **688 checks / 435 mutations 两遍全绿**。
- **验证状态**：静态守卫通过（两遍）。**待** CI 编译 + 真机回归
  （真机判据见 `RELEASE_NOTES.md` 1.3.20）。

---

## 2026-09-26 界面说人话：首次安装的证书缺私钥要能看懂、子流程不再抢走抽屉、阶段文案对齐真实动作

- **背景**（用户原话，四项一次提）：
  「1、第一次签名 Seal 到手机，手机打开 Seal，Seal 第一次没办法自己重新申请证书签名重装一次
  直接被拦截了，可以在第一次安装手机设备证书没有或者与远端不同时 证书序列号那可以写一句
  需要重新签名一次获取本机证书 文案具体你来设计，匹配之后后续再走不重装的更新续签模式。
  2、签名新 ipa 容易出现到安装步骤后又重签一次。3、去掉那个阶段上的等待多少时间的文案，
  设备安装阶段的保留。4、将签名链路和续签和安装实际的真实操作对应的文案写精准，
  没有做的事不写，位置也不要乱」。
- **现象与根因（四条各自独立）**：
  1. **首次安装签不了**：重装 Seal 会清空钥匙串 ⇒「本机没有该证书的私钥」，而 profile-only
     准入没有这条判据 ⇒ 宣布「仅更新描述文件」，执行侧才抛 `SEAL-PROFILE-334`。
     用户看到的是拦截，看不出真正原因。
  2. **「装完后又重签一次」**：`SigningCoordinator` 在父会话里跑**证书轮换事务**时，
     会在**同一条会话**里重新签名安装**另一个** App（通常是 Seal），并把子流程阶段
     **原样透传**给父会话 `progress`；`AppsViewModel.updateSigningStage` **无条件**写
     `signingSession?.status` ⇒ 抽屉在父会话装完、正在 `verifying` 时被覆盖回签名阶段。
     ⚠️ **重签本身是必要的**（旧证书已被撤销，不重签那些 App 会立刻打不开）——
     错的是**显示层**（见「常犯坑位」第一条）。
  3. **多余的等待文案**：进度卡片整条自带计时，而它只对**设备安装阶段**有意义
     （installd 安装期间不回报任何进度，计时是唯一能证明进程还活着的信号）。
  4. **阶段文案与真实动作不符**：「正在申请证书」（实际绝大多数是**复用**）、
     「正在注册 Bundle ID」（实际先读已有列表，只对缺失的发注册请求）、
     「已注册 N / N 个 Bundle ID」（那个数是**已就绪**的个数，不是本次新注册数）。
- **修复**：
  1. `ProfileOnlyRenewalPolicy.localCertificateMaterialBlock(...)`（纯函数，三态
     `.ready` / `.needsFullResign` / `.undetermined`）＋ 准入**提前**判定（`return false`
     回落完整重签）＋ 留痕 `SEAL-PROFILE-364`（**警告级，不是失败**）；
     `AppSigningPresentationHelpers.localCertificateRebuildNote`（紧凑版）/
     `localCertificateRebuildDetail`（完整版）在**证书序列号那一行**说明，三处落点
     （详情页 / 操作抽屉 / 进度卡片）。⚠️ 判据必须用 `app.certificateSerialNumber`
     （= 执行侧真正用的那个值），**不是**带实时兜底的 `effectiveCertificateSerialNumber`
     ——「准入查 A、执行用 B」是 `SEAL-PROFILE-361` 那个洞的同一种错法。
  2. 新增纯判据 `SigningStageAttribution`（`target(for:sessionAppID:)` /
     `isFirstInstallEntry(entering:previous:)`）＋ `AppsViewModel.rotationSubflowStage` 簿记；
     `updateSigningStage` 按主体分叉 —— `.session` 写显示状态，`.otherApp` 只留痕
     ＋ 评估 Seal 自替换的「回主屏」。
  3. `SigningProgressView` / `BatchRefreshView` 的进度卡片不再显示自己的计时；
     `InstallWaitNote`（设备安装阶段）保留「设备正在安装，此阶段没有进度回报 · 已等待 m:ss」。
  4. `SigningStage.stageTitle`：「正在申请证书」→「**正在准备证书**」、
     「正在注册 Bundle ID」→「**正在核对 App ID**」；`unitsText` →「已**准备** N / N 个 App ID」。
- **涉及文件**：`Seal/Core/Signing/SigningStage.swift`、`SigningStageUpdate.swift`、
  `SigningCoordinator.swift`、`Seal/Core/Renewal/ProfileOnlyRenewalPolicy.swift`、
  `Seal/Features/Apps/AppsViewModel.swift`、`AppPresentation.swift`、`AppDetailView.swift`、
  `InstalledAppActionSheet.swift`、`SigningProgressView.swift`、
  `Seal/DesignSystem/InstallWaitNote.swift`、`Seal/Core/Signing/SigningProgressBudget.swift`、
  `docs/qa/log-code-index.md`（登记 `SEAL-PROFILE-364`）。
  新增单测：`SealTests/Signing/SigningStageAttributionTests.swift`（6）、
  `SealTests/Signing/SigningStageCopyTests.swift`（4）。
- **守卫**：**R85**（本机证书材料状态：三态 / 同源判据 / 只算已安装 / 文案真源 /
  两个 helper 只在 `.needsFullResign` 说话 / 三处落点 / `SEAL-PROFILE-364` 闸门 /
  私钥判据排最后 / 索引登记 / 三方向单测 / 文案 helper 单测）、
  **R86**（阶段归属纯判据 / 只有会话主体写状态 / 子流程保留回主屏 / 闸门落子流程簿记 /
  两处清空 / 四方向单测）、
  **R87**（证书阶段不说「申请」/ App ID 阶段不说「注册」/ 计数行「已准备」/
  新写法必须在位 / 三方向单测）。⚠️ R10 的断言由 `count == 2` 改为 `== 3`
  （`updateSigningStage` 按主体分叉后多了一条调用，子流程那条**必须留着**）。
- **验证状态**：⚠️ **待真机**。判据见 `RELEASE_NOTES.md` 1.3.19 的【验证】段
  （① 重装 Seal 后首次签名应成功且出现 `SEAL-PROFILE-364`，再续签应回到「仅更新描述文件」；
  ② 装完后抽屉**不应**跳回签名阶段；③ 进度卡片不应再显示「已等待 m:ss」，
  设备安装阶段应保留；④ 界面上不应再出现「正在申请证书」「正在注册 Bundle ID」）。

---

## 2026-09-26 恢复证书自动轮换：1.3.17 的「绝不撤销运行中 Seal 的证书」把免费账号锁死了

- **背景**（用户原话）：「你这不自动给我撤销证书，我下载 seal 啥也干不了，全被拦截了」。
  输入日志：构建 1.3.17 / 47（2026-09-26 09:03–09:05）。
- **现象**（日志时间线）：
  - 09:04:32「准备签名：LiveContainer」→ 09:04:39「证书轮换：候选只剩 Seal 正在使用的证书
    ⇒ 不自动撤销」→ 09:04:41 `[SEAL-CERT-204b]`（3022 名额满）；
  - 09:05:06「准备签名：微信」→ 09:05:19 同一条「不自动撤销」→ 09:05:22 `[SEAL-CERT-204b]`；
  - 09:05:36「开始续签：Seal」→ 09:05:39 `[SEAL-PROFILE-334]` 当前证书不可续签。
  ⇒ **三条路径（签第三方 App、签另一个、续签 Seal 自己）全部失败**，用户「啥也干不了」。
- **根因**：1.3.17 为了修「撤销运行中 Seal 的证书 → 自替换失败 → 变砖」（构建 38 / 46），
  在 `ApplePortalSigningService` 撞 204b 后的轮换分支前加了一道闸门
  （`SigningCertificateRotationGate.candidatesExcludingRunningSealCertificate`）：
  **签非 Seal 时剔除所有「运行中 Seal 正在用」的候选**；剔除后为空就 `throw` 回原始 204b。
  ⚠️ 免费团队只有 **1 个**活动槽位，而 Seal 自己的证书在覆盖安装后**必然**丢失本机私钥
  ⇒ 它**就是**唯一候选 ⇒ 被剔除 ⇒ 永远建不出新证书 ⇒ **永久死锁**。
- **为什么「剔除」本来就是多余的**：`rotationRank` 早已把 Seal 的证书排在**最后**
  （`isRunningSealCertificate ⇒ 3`，普通证书 0/1/2）⇒ 只有「别无选择」时才会撤到它 ——
  这正是原设计：「最后撤 Seal 的证书 → 本事务末尾自替换恢复」。
  另外两条路径（`SEAL-CERT-204e` 一键全撤、`CertificateCleanupPolicy` 自动清理）
  也都跳过 Seal 的证书 ⇒ **没有任何出口**，只剩死锁。
- **修复**：删除 `SigningCertificateRotationGate`，调用点恢复 `candidates: candidates`。
  安全性改由**三条**保证（缺一条都不行）：① `rotationRank` 把 Seal 的证书排最后；
  ② 撤销前必须发 warning 说清后果；③ 撤销后由 `resignAppsAffectedByCertificateRotation`
  （`includeSeal: true`）在本事务末尾以新证书重签并重装 Seal 恢复。
  ⇒ 变砖的真凶是**自替换安装失败**，不是撤销本身；而「不撤」的代价是链路整体不可用 ✗。
- **同时改掉规格侧**：`CertificateTakeoverPolicy`（无生产调用点，但是被守卫与单测断言的
  验收规格）原写「真实签名者 A 永远不能成为撤销候选」，且单测
  `fullSlotsWithOnlySignerBlocks` 断言「只剩 A 一张时必须 blocked」——
  那等于把死锁钉成契约。现改为「**A 排最后但仍进候选**」，
  规格与运行时（`rotationCandidates`）重新同义。
- **上游对照**：SideStore 的 `CertificateProvisioningFlow` 是**先创建** → 撞 3022 才
  `replaceCertificate`（撤销 → 再创建）；它**从不把自己排除在候选之外** —— 本次与上游一致。
- **涉及文件**：`Seal/Core/Signing/SigningCertificateRotationGate.swift`（删除）、
  `Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、
  `Seal/Core/Signing/CertificateTakeoverPolicy.swift`、
  `SealTests/Signing/SigningCertificateRotationGateTests.swift`（删除）、
  `SealTests/Signing/SigningCertificateMaterialPolicyTests.swift`、
  `SealTests/Signing/CertificateTakeoverPolicyTests.swift`、`Scripts/verify-release-safety.py`。
- **验证状态**：新增单测
  `capacityRecoveryStillOffersTheRunningSealCertificateWhenItIsTheOnlyOne`（候选不得为空）
  与 `fullSlotsWithOnlySignerStillOffersIt`（只剩 A 时仍提供候选）；
  守卫 R84⑥ 改为**反向契约**（不得出现闸门、必须 `candidates: candidates,`、
  Seal 的证书必须排最后）＋ 3 个变异锚点；Takeover 断言与变异同步。
  本机无 Swift 工具链 ⇒ 待 CI 编译与 Swift 回归；真机待验（构建 48）。

---

## 2026-09-26 续签「全都要重装」：准入只看记录、核验一票否决、轮换撤了运行中 Seal 的证书

- **背景**（用户原话）：「签名续签链路你弄坏了；另外续签需要全部不重装；严格把控所有给你链路，
  不要串；好好深入研究，并发的问题都给解决；把上游代码研究透，能直接照抄就直接搬过来」。
  输入日志：构建 1.3.16 / 46（2026-09-26 01:24–01:29，仅五分钟）。
- **现象**（日志时间线）：
  - 01:24:30「开始续签：Seal」→ 紧接着「续签路径已确认：**需要完整重签并安装**」，
    而且**没有** `SEAL-PROFILE-363`；
  - 01:24:32「证书检查：远端 1 张，本机有私钥 **0** 张，可复用 0 张；Seal 在用但无私钥 1 张」；
  - 01:24:37「证书轮换：撤销 …442EB5AF，原因=无本机私钥，**运行中Seal=是**」
    → 重签 Seal → 01:24:50「3 秒内进程仍存活（转场未生效），强制 exit(0)」
    → 01:25:30 `SEAL-SELF-109` 中止；
  - 01:26:41 / 01:27:12 两条 `SEAL-PROFILE-363`（Guoguo）→ 回落完整重签 → 01:28:08 才成功；
  - 01:25:01 / 01:26:40 / 01:29:11 三次 `SEAL-INSTALL-707`（设备探测超时）。
  ⇒ **Seal 与 Guoguo 的续签全部重装了一遍**，Seal 自身还被换了进程。
- **根因 A（准入只看记录）**：`ProfileOnlyRenewalPolicy.evaluate(app:)` 要求 9 类记录字段齐全，
  其中 `signedDeviceIdentifier` / `signingTargets` / `signedIPARelativePath`（⇒ `hasSignedArtifact`）
  由 `SelfAppRegistrar` 维护 —— 它**从不写**这三项。⇒ 2026-09-25 那次「不按身份排除 Seal」
  （R82）在真机上**一次都没生效过**：每次都在准入处 `return false`，所以连 363 都不会出现。
  ⚠️ 这正是「上游放行、下游又拦」的第三种形态：**准入放行了、判据本身却恒假**。
- **根因 B（核验一票否决）**：`SEAL-PROFILE-363` 把「设备端核验未确认」当成回落条件。
  而核验输入是**本地 DB 记录**（可能与设备现实错位），走同步 FFI 枚举、30 秒上限 ⇒ 又慢又误拦。
  上游 `refresh` 管线**根本不枚举设备描述文件**（`dumpProfiles` 在 SideStore 全仓只有设置页一处
  业务调用），准入只核验「已安装产物的签名证书是否仍在门户活动列表」
  （`VerifyCertificateOperation(willResign: false)`）。
- **根因 C（轮换撤了运行中 Seal 的证书）**：`ApplePortalSigningService.rotateCertificatesAndCreateIdentity`
  会把「运行中 Seal 正在用」的证书当普通「无本机私钥」候选**自动撤销**。撤销后 Seal 只能靠
  自替换安装恢复，那一步失败 Seal 当场打不开（构建 38 变砖同因）。上游 `CertificateProvisioningFlow`
  里撤销**必须经用户确认**；本仓没有等价的「撤 Seal 自己的证书」确认入口
  （`revokeKeylessCertificatesAfterConfirmation` 会跳过 Seal 的证书）⇒ 死路。
- **根因 D（并发抢设备会话）**：`AppsViewModel.reconcileInstalledAppsWithDevice` 的设备核验
  走同步 FFI，与签名 / 安装 / 续签**共用同一条 RSD 会话**；续签进行中必然超时，
  还把失败弹窗推给用户。⚠️ **根因是并发，不是预算太短** —— 调大 `timeoutSeconds` 只会让
  每次失败等更久，并让「尽力读取」的核验借走安装链路的验证预算（守卫 G 正是防这个）。
- **修复**：
  1. 新增 `LiveProfileOnlyIdentity` + `ProfileOnlyRenewalPolicy.liveIdentity(installedIdentity:app:)`
     ＋ `evaluate(app:liveIdentity:)`：以**运行产物**（`SelfAppMetadata.current()` 读运行包 CMS 身份）
     作为第二条准入通道，对齐上游「准入看已安装产物」。
     ⚠️ 只在 `app.isSeal` 时读 —— `SelfAppMetadata.current()` 读 `Bundle.main`，
     对第三方 App 用会读成 **Seal 自己**的身份（假阳性）。
  2. `SigningCoordinator.shouldUseProfileOnlyRenewal` 改双通道；设备绑定判据拆成
     `ProfileOnlyRenewalPolicy.isBoundToCurrentDevice`（记录通道**不放松**）。
  3. `SEAL-PROFILE-363` 降级为**纯诊断日志**；核验上限 30 秒 → 5 秒；安全网交给
     注入后的逐份读回（`ProfileOnlyProvisioningProfileInstaller.installAndVerify` → `SEAL-PROFILE-354`）。
  4. 新增 `SigningCertificateRotationGate.candidatesExcludingRunningSealCertificate`：
     非 Seal 自身签名时**剔除**运行中 Seal 的证书；剔除后为空则抛回原 `SEAL-CERT-204b`。
  5. `AppsViewModel` 设备核验与前台操作**互斥**（有前台操作时整体跳过，记 `SEAL-INSTALL-708`）。
  6. 修正 `ProfileOnlyRenewalPolicy` 里「上游 refresh 三步」的**过时注释**（已证为五步）。
- **涉及文件**：`Seal/Core/Renewal/ProfileOnlyRenewalPolicy.swift`、
  `Seal/Core/Signing/SigningCoordinator.swift`、
  `Seal/Core/Signing/SigningCertificateRotationGate.swift`（新）、
  `Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、
  `Seal/Features/Apps/AppsViewModel.swift`、
  `Seal/Core/Apps/InstalledAppRefreshProbePolicy.swift`（仅补说明，值不变）、
  `SealTests/Renewal/ProfileOnlyRenewalPolicyTests.swift`、
  `SealTests/Signing/SigningCertificateRotationGateTests.swift`（新）、
  `docs/qa/log-code-index.md`（363 语义）、`Scripts/verify-release-safety.py`（R84）。
- **⚠️ 本轮写守卫时踩到的坑（值得记）**：R84④ 的第一版判据是
  `"useProfileOnlyRenewal = false" not in <block>`，而那个 block 的**注释里**恰好引用了
  旧写法 ⇒ 断言**恒假**。守卫自己没报「写错了」，只在
  `check-mutation-power.py` 的 **BASELINE FAIL** 里露出来。
  ⇒ 两条纪律：① 判「源码里不得出现某写法」时先 `strip_comments`（它保留字符串字面量）；
  ② **新写的 `check()` 一定要先跑定点判别力脚本看基线**，别直接跑整轮。
  同轮第二个同族坑：R84⑥ 的判据把被 Swift 折行拆开的两行写成一条连续字符串 ⇒ 同样恒假。
- **验证状态**：静态守卫 + 单测（待 CI）；**真机回归未做**（本机无 Xcode/Swift）。

---

## 2026-09-25 安装失败的归因按前缀一刀切：把「所有问题」都算到 VPN 头上

- **背景**（用户要求）：「除了之前的内置 VPN 的路子，其他做到最优最好的状态，
  **只要开了外部 LocalDevVPN，就一定不要以为 VPN 来影响所有体验**」。
- **现象**：任何 `SEAL-INSTALL-*` 失败，弹窗上唯一的「恢复」按钮都会把用户送进
  「LocalDevVPN」设置页 —— 包括与本地隧道毫无关系的那些：
  `702s`（设备存储空间不足）、`702l`（免费账号 3 应用上限）、`702f`（DRM 元数据残留）、
  `702t`（安装超时 —— 超时 ≠ 失败）、`711…730` / `735`（签名包内容类，需重新签名）、
  `737` / `738`（需重启 Seal）、`716`（本机签名包记录不完整）。
  用户点完被送到一个**解决不了他问题**的页面，只能自己再退回来。
- **根因（第一处）**：`AppsViewModel.settingsRoute(for:)` 里一条
  `if failure.code.hasPrefix("SEAL-INSTALL-") { return .localDevVPN }`
  ⇒ 安装族**全部**几十个码被路由到 VPN 页。
  这是「按**码的形态**归因」，而不是「按**提示文案在让用户做什么**归因」。
- **根因（第二处，同族）**：`SEAL-INSTALL-703`（设备配对不可用）与 `707`（无法刷新已安装应用）
  也带 `SEAL-INSTALL-` 前缀 ⇒ 落进 `InstallFailureActionPolicy.action(for:)` 的**前缀兜底**
  ⇒ 界面给出「重新安装」按钮。而它们的 recovery 文案是「重新连接手机并完成配对后重试」
  —— **重装修不好一份失效的配对文件**；`SigningProgressView.isPairingFailure` 又只认
  `SEAL-PAIR-` 前缀 ⇒ 认不出它们，按钮永远换不成「重新配对设备」。
- **根因（第三处，过时文案）**：`SEAL-INSTALL-701` 的 reason 仍在说
  「**付费账号的 Seal 会自动拉起内置隧道**」—— 而内置 `SealTunnel` 早已移除
  （`SealTunnel/` 目录已空），`LocalDevVPNOnDemandActivator` 与 `MinimuxerInstallChannel`
  的注释都明说「不再自动拉起内置隧道」。留着这句会让用户按一条**不存在**的路径排查。
  同族的 5 处文案按「免费账号 / 付费账号」区分隧道依赖 —— 实际上**与账号类型无关**。
- **修复**：
  1. 新增 `Seal/Features/Settings/InstallFailureSettingsRoute.swift`：判据变成
     **显式码集合**（8 条：701 / 705 / 706 / 706a / 706b / 706t / 708 / 710），
     其余一律 `nil`（不跳转）；配对族引用 `InstallFailureActionPolicy.pairingCodes`（单一真源）。
  2. `InstallFailureActionPolicy` 新增 `pairingCodes = {703, 707}`，
     并在 `action(for:)` 里把配对判定排在**前缀兜底之前**（顺序就是安全本身）。
  3. `SigningProgressView.isPairingFailure` 把这两条一并认成配对失败。
  4. 6 处用户可见文案改成「Seal 不内置隧道（内置隧道已移除），一律依赖外部 LocalDevVPN」
     /「Seal 依赖外部 LocalDevVPN 软件提供本地隧道」。
- **涉及文件**：`Seal/Features/Settings/InstallFailureSettingsRoute.swift`（新）、
  `Seal/Features/Apps/AppsViewModel.swift`、`Seal/Core/Installation/InstallChannelDiagnostic.swift`、
  `Seal/Features/Apps/SigningProgressView.swift`、
  `Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`、
  `SealTests/Settings/InstallFailureSettingsRouteTests.swift`（新）、
  `SealTests/Installation/InstallChannelDiagnosticClassificationTests.swift`、
  `Scripts/verify-release-safety.py`。
- **守卫与测试**：新增 **R83**（12 条断言 + 11 个变异锚点；守卫 **638/383 → 650/394**）。
  其中 R83③b 是**同源闸门**：凡 recovery 恰为「检查是否打开 LocalDevVPN」的失败，
  其 code 必须在集合里（并断言这样的失败 ≥ 5 条，防正则漂移后变成空集 ⇒ 永远绿）。
  单测两个文件：路由三方向（通道码 ⇒ VPN / 无关安装码 ⇒ 不跳转 / 703·707 ⇒ 配对）
  ＋ 三个动作集合两两互斥。
- **验证状态**：⚠️ 待真机（CI 编译与单测通过 ≠ 可用；见 `docs/qa/2026-09-25-install-failure-vpn-attribution.md`）。

---

## 2026-09-25 Seal 自身续签改成「只更新描述文件、不重新安装」（运行时更新，不再自替换）

- **背景**（用户要求）：「把 Seal 自身续签也做成更新描述文件不重新安装，能够运行时更新」。
  构建 44 的真机日志把这条路的**代价**量化了：批量续签跑到 Seal 那一项（第 3/3）时，
  Seal 必须**自替换**（重新签名 + 覆盖安装自己）⇒ 进程被系统换掉
  ⇒ 队列项还停在 `running` 就随进程消失 ⇒ 新进程启动后降级成未知，报
  `SEAL-RENEW-007`「上次续签被中断，1 个应用的结果未知，需要重新核验」
  （`20:51:19` 与 `20:59:55` 各一次）；同一轮 `SEAL-SELF-109`（Seal 自更新安装遇到未预期错误）
  **连报两次**（`20:52:45` / `20:53:00`），并引出多轮自替换结算 + 5 次 `SEAL-INSTALL-707`。
  用户只能反复手动重试「续签全部」。
- **根因**：`ProfileOnlyRenewalPolicy.evaluate` 第一句就是
  `guard app.isSeal == false else { return .requiresFullResign(.sealSelfReplacement) }`
  ⇒ **Seal 永远不走 profile-only 路径**，永远走完整重签 + 自替换安装。
  即：Seal 是唯一**用不上**这条快路径的应用，而它恰好是每次批量续签都要跑的那一个。
- 🔑 **上游 SideStore 的稳定做法（对照，本轮调研）**：它的续签管线 `PipelineStepDefinition.refresh`
  只有三步 —— `fetchProvisioningProfiles`（45）/ `cacheResignedMetadata`（1）/ `refreshApp`（39），
  **不含重签、不含安装**；`RefreshAppOperation` 对每个目标只做
  `installProvisioningProfiles(_:)`（misagent 注入描述文件），**对 SideStore 自己同样如此**。
  自替换（`handleSelfReinstallation`）只出现在 install / update / resign 管线里。
  本仓对应实现是 `ProfileOnlyProvisioningProfileInstaller.installAndVerify`
  → `Minimuxer.installProvisioningProfile(profile:)`（同样是 misagent、同样 30 秒有界、同样读回核验）。
  ⇒ 「只换描述文件」对 Seal 在技术上**完全可行**，缺的只是那条按身份的一刀切。
- **修复**：
  - 删掉 `evaluate` 开头的身份豁免，以及只为它存在的枚举 case `FullResignReason.sealSelfReplacement`
    （全仓唯一消费点是 `ApplePortalSigningService` 里**不带关联值**的 `== .requiresFullResign`，
    删掉无副作用）。
  - **安全边界一条都没放松**：记录不完整（缺已装产物 `hasSignedArtifact` / 缺签名身份 /
    缺目标记录）时照旧回落完整重签 —— 删掉的是「按身份一刀切」，不是判据本身。
  - `shouldUseProfileOnlyRenewal` 与 `renewProfilesOnly` 本来就没有 `isSeal` 分支
    ⇒ 准入放行后自然走通，**无需改动**（守卫 R82③ 钉住「这两处今后也不得加」）。
- 🔴 **只改准入是不够的 —— 批量结算侧还假定「Seal 续签 = 自替换」**（同一轮里发现的第二半）。
  `RenewalCoordinator` 的结算分支原来只判 `updated.isSeal`，然后**无条件**
  「不计成功、留在 `running`、等新进程核验」。准入放行之后，Seal 那一项其实**已经成功、
  进程也没重启**，却仍被记成「等待新进程核验」⇒ 启动时根本没有自替换事务可结算
  ⇒ 又变回 `SEAL-RENEW-007`。**这正是本项目反复出现的「上游放行、下游又拦」：
  改了一半、看起来改完了。**
  - 修法：把「要不要等新进程核验」的判据从**应用身份**换成**实际路径** ——
    `SigningCoordinator` 本来就在设备端身份核验之后通过 `onRenewalExecutionPath` 回调
    `.profileOnly` / `.fullResign`（这是权威信号，不需要再实现一遍判据）。
    协调器（actor）新增 `currentRenewalExecutionPath` 留住它，**按项重置**，
    结算改成 `if updated.isSeal, currentRenewalExecutionPath != .profileOnly`。
  - ⚠️ 判据取 `!= .profileOnly`（**没明确确认是快路径就按保守处理**）：信号缺失时保持旧行为，
    只会多一次「等待新进程核验」，不会把可能已被换掉的进程谎报成已完成。
  - ⚠️ 顺带确认：证书轮换子流程调 `signAndInstall` 时**没有**传 `onRenewalExecutionPath`
    （走默认 `{ _ in }`）⇒ 不会污染本项的路径记录。
- **附带效果（重要）**：Seal 走 profile-only 后**不推 `.pushing` / `.installing` 阶段**，
  所以 `SelfInstallAutoBackground.returnToHomeAfterSealUpload`（回主屏）与批量项的
  `awaitingSealConfirmation` / `persistPendingBatchResultForSealUpdate`（载荷持久化）
  **自然都不触发** —— 它们本来就是为「自替换必须让出前台、结果只能留给新进程核验」准备的，
  这条路现在根本不需要（`awaitingConfirmation` 归 0 ⇒ 批量按正常 `completed` 收尾）。
  ⚠️ **但记录不完整时 Seal 仍会回落完整重签 + 自替换**（例：每次 Seal 版本升级后
  `SelfAppRegistrar` 原子重建记录会把 `signedIPARelativePath` 置 nil ⇒ `hasSignedArtifact` 为假）
  ⇒ 那条路径**必须保留**；本轮只是让「记录完整」这个常见情形不再付出「换掉进程」的代价。
- **涉及文件**：`Seal/Core/Renewal/ProfileOnlyRenewalPolicy.swift`（删豁免 + 论证注释）、
  `Seal/Core/Renewal/RenewalCoordinator.swift`（结算按实际路径 + 按项重置）、
  `SealTests/Renewal/ProfileOnlyRenewalPolicyTests.swift`（两条新单测，一正一反）、
  `Scripts/verify-release-safety.py`（**R82**：7 断言 + 8 变异；守卫 631/375 → **638/383**）。
- **验证状态**：⚠️ 待真机（构建号见交付单）。判据：批量续签跑到 Seal 那一项时日志出现
  「续签路径已确认：仅更新描述文件」＋「profile-only 续签已由设备端逐份读回确认」，
  且**不再出现** `开始自替换安装` / `SEAL-SELF-109` / `SEAL-RENEW-007`，
  **进程不重启**（日志时间戳连续、不出现启动横幅）。

## 2026-09-25 扫回的记录导入覆盖更新后仍续签不了（`accountID` 压根没有）

- **现象**（用户原话）：「当我导入已有应用时提示覆盖更新，点完就到了已安装页，但是点续签时却续签不了」
  （构建 1.3.13 / 43 真机日志）。日志序列：18:13:31 `SEAL-RECOVER-001` 扫回 2 个应用 →
  18:14:01 添加 Apple ID → 18:28:58 / 18:29:12 `SEAL-IPA-212` 导入覆盖更新 →
  点「立即续签」⇒ 18:29:20 / 18:29:25 / 18:30:23 **三次全部**报
  `SEAL-AUTH-110`「缺少签名账号记录」。
- **根因**：`SigningCertificateSelectionPolicy.validateAccountAndTeam` 里有一句
  `guard let boundAccountID = app.accountID else { throw … SEAL-AUTH-110 }`。
  而扫回的记录 `accountID` 必然是 `nil` —— `AppRecordRecovery.recoverRecordsFromDeviceProfiles`
  按 Team 匹配账号（`accounts.first { $0.teamID == draft.teamIdentifier }?.id`），
  扫回**发生在「配对成功之后、用户添加 Apple ID 之前」**（日志：18:13:31 扫回、18:14:01 才添加）
  ⇒ 那一刻账号库是空的 ⇒ 写 `nil`；导入覆盖更新又**如实继承**这个 `nil`
  （`ImportWorkflow.makeInstalledUpdateRecord` 传的就是 `existing.accountID`）⇒ 这条记录**永远**续签不了。
- 🔴 **又一次「上游放行、下游又拦，等于没修」**：日志里 `SEAL-AUTH-110` 的**上一条**正是
  `开始续签：Guoguo，Apple ID：sun***@gmail.com，Team：…` —— 说明
  `RenewalAccountResolver` 已按同 Team **成功解析出账号**，是 policy 又拦下的。
  这是「**悬空引用**」陷阱家族的**第四种表现**（前三：证书轮换 `candidate.accountID == accountID`、
  续签 `??` 兜底被悬空 UUID 短路、R70 的悬空 UUID 裸比较）。
- **修复**：改**判据本身**，不是改文案 —— `accountID` 缺失是**合法状态**。
  决定签名身份的是 `signingTeamID` 而不是 `accountID`；同 Team 的账号签出的是同一个签名身份，
  installd 覆盖的仍是设备上同一个 App。`AccountBinding` 新增第三态
  `.recoveredFromMissingBinding`（与 `.recoveredFromDanglingBinding` 同族不同成因：
  那条是「UUID 指向已不存在的账号」，这条是「压根没记过」），放行后**仍过同 Team 判据** ——
  既无绑定又无 Team 时落到 `SEAL-AUTH-113`，**仍然拒绝**（不是后门）。
  `SigningCoordinator` 按态分记 `SEAL-AUTH-111b`（悬空的 `-111a` 保留，两者下一步动作不同）。
  续签成功后 `applySigningResult` 会把 `accountID` 写回 ⇒ 记录**自愈**。
- 🔴 **只改这一处就够**（已全仓核对）：`continueSigningRequest` 里也有
  `guard let accountID = app.accountID … SEAL-AUTH-104c`，但 `requestSigning` 对
  `belongsInInstalledList` 的应用**直接走 `startBatchRefresh`** ⇒ 那个分支不可达（与日志一致：
  用户看到的是 110 而不是 104c）。`ProfileOnlyRenewalPolicy` 的 `app.accountID != nil`
  与 `SigningCoordinator` 两处缓存命中判据（770 / 1623）都只是**优雅降级**（退回完整重签），
  不是闸门；`SettingsViewModel` / `AppDetailView` 那两处只用于展示。
- **涉及文件**：`Seal/Core/Signing/SigningCertificateSelectionPolicy.swift`、
  `Seal/Core/Signing/SigningCoordinator.swift`、
  `SealTests/Signing/SigningCertificateSelectionPolicyTests.swift`（+3 条）、
  `Scripts/verify-release-safety.py`（**R81**：5 断言 + 4 变异；并把 R70① 的变异锚点缩进
  8 → 12 空格 —— 本轮把那段包进了 `if let`）。
- **验证状态**：⚠️ 编译 / 单测 / 真机回归待 CI 与真机确认（Windows 本机无法编译）。

## 2026-09-25 重装 Seal 后找不回已安装应用（设备端扫回）＋ 有效期秒级 ＋ 取消被记成超时

- **现象**（用户原话）：「当我只卸载了 seal，其他 seal 签名的 ipa 没有卸载，但这样我重新安装 seal，
  之前通过 seal 安装的就进入不了 seal 已安装列表，能不能做到查到之前 seal 安装的并添加进已安装列表里；
  另外所有时间的有效期限精确到秒」。另一批反馈来自构建 40 真机日志：
  ① 同一条超时日志里心跳写「已等待 46 秒」、结论行写「已等待 803 秒」；
  ② 14:10:49 同一秒出现 `SEAL-INSTALL-702t` 与 `SEAL-SIGN-012`（用户点了取消）。
- **根因（需求 A）**：记录（`Seal.sqlite`）随 Seal 一起被卸载 ⇒ 设备上的应用还在，本地一条记录都没有。
  唯一残留的证据是**设备端的描述文件**：Bundle ID 形如 `<原始>.seal.<team>`。
  本仓的 `ProfileReclaimPolicy` 早已用这条形态规则做**回收**（删多余 profile），
  但从来没有做它的**反向**（把 profile 折回记录）。
- **修复（需求 A）**：新增「设备端扫回」，落在维护作业第 1 步（`AppRecordRecovery.restoreMissingRecords()` 末尾）：
  ① `DeviceInstalledAppScanner.profileSummaries()` 走 `Provision.dumpProfiles` +
     `ProvisioningProfileReader`（与 `DeviceProfileInspector` 同一条通道，按 UUID 去重，
     `parsed == 0` 视为**读不到**而非空集），整段跑在 `BlockingCall.bounded(15 秒)` 里；
  ② `InstalledRecordRecoveryPolicy`（纯函数，可单测）做**本地筛选**：形态同源（`.seal.` 前后都要有内容）、
     Team 必须可信（已添加账号的 Team ∪ 已有记录的 `signingTeamID`）、已被记录覆盖的不重建、
     用户删过的（墓碑）不重建、Seal 自己不参与、扩展不单独建记录、反推不出原始 Bundle ID 就不建；
  ③ 候选非空才发设备查询：**阳性对照**（拿 `Bundle.main.bundleIdentifier` 问）+ 逐条
     `InstalledAppDeviceVerifier.isInstalled`，**任一条抛错整轮中止、一条都不建**
     （与 `reconcileInstalledAppsWithDevice` 的「先问完再动手」同一条纪律）；
  ④ `makeRecord` 身份诚实：`state = .installed`、`mappedBundleIdentifier` 填设备真实 ID、
     `signedIPARelativePath` / `signedIPASHA256` / `signedArtifactStatus` 全空
     （⇒ `hasSignedArtifact == false`，天然进不了 profile-only 续签与「安装已签名产物」路径）、
     `ipaRelativePath` 给**必然不存在**的占位路径、`version`/`size` 不编造、
     `importWarnings` 写明「无本地原始 IPA」。
- 🔴 **两处「好心办坏事」的坑，都在实现时被拦下**：
  ① 给扫回记录填**证书序列号**（描述文件里恰好只授权一张时）会让两处破坏性链路立刻选中它 ——
     证书轮换的「自动重签受影响应用」（它没有本地 IPA ⇒ 必然失败）与撤销证书的确认弹窗
     （会承诺「这 N 个应用会被自动重新签名安装」，而其中一个永远不会成功）。
     描述文件里的 `DeveloperCertificates` 是**授权列表**、不是**实际签名者**（本仓明文区分），
     所以序列号**留空**。
  ② 扫回**必须**排在维护作业第 4 步（设备端旧描述文件清理）**之前** —— 新补回的记录是那份 profile
     唯一的本地引用，反过来的顺序会让清理把它当旧账删掉，而设备上的 App 正靠它运行（当场打不开）。
     守卫 R80 用**下标顺序**钉住（只查「存在扫回调用」会被顺序骗过去）。
- **修复（需求 B）**：`SealSettingsDateFormatter.dateFormat` → `"yyyy-MM-dd HH:mm:ss"`
  （11 个调用点一处生效）；`AppSigningSheet` 里同格式的死代码副本一并改（两处不一致会让同一天显示两种时间）。
  日志 / ISO8601 / 文件名格式**不动**。
- **修复（取消 ≠ 超时）**：`BlockingCall.bounded` 的 `catch { return nil }` 会把
  `CancellationError` 一并折叠成 nil ⇒ 用户主动取消落进超时分支、被记成 `SEAL-INSTALL-702t`。
  三条出口都改：带进度路径与已暂存包路径先判 `Task.isCancelled` 抛 `CancellationError`；
  重试循环 `catch` 开头 `if error is CancellationError || Task.isCancelled { throw CancellationError() }`
  （**不重试、不 `Minimuxer.reset()`** —— reset 会拆掉可能仍在跑的那条连接，R05）。
  `runSigning` 的 `catch is CancellationError`（不弹窗、不记失败）才是取消该走的出口。
  顺带把超时日志改成报**实际**等待（`Date().timeIntervalSince(startedAt)`），
  不再报预算上限 —— 真机那条「46 秒 vs 803 秒」的自相矛盾就是这么来的。
- **用户可预期性**：新增 `DismissedInstalledRecordTombstones`（落
  `applicationSupport/Seal/DismissedInstalledRecords.json`，**不用** `UserDefaults` ——
  它会被 Seal 自签覆盖安装清掉，墓碑一丢被删的记录就自己回来了）；
  `SigningCoordinator` 在重签入口对「扫回记录缺本地 IPA」明确拒绝（`SEAL-RECOVER-002`，
  且**排在账号解析与免费账号 3-app 预检之前**，否则用户先被一条无关错误挡住）；
  扫回结果并入 `MaintenanceReport.recovered`，`AppMaintenanceJob` 只在**真有候选或失败**时留痕
  （`SEAL-RECOVER-001`，没有候选不写 —— 每次启动一条「扫了 0 个」会把真实信号挤出环形缓冲）。
- **涉及文件**：新增 `Seal/Core/Recovery/InstalledRecordRecoveryPolicy.swift`、
  `Seal/Infrastructure/Installation/DeviceInstalledAppScanner.swift`、
  `SealTests/Recovery/InstalledRecordRecoveryPolicyTests.swift`；改
  `Seal/Core/Recovery/AppRecordRecovery.swift`、`Seal/Core/Maintenance/AppMaintenanceJob.swift`、
  `Seal/Application/AppContainer.swift`、`Seal/Features/Apps/AppsViewModel.swift`、
  `Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`、
  `Seal/Features/Settings/SettingsFormatters.swift`、`Seal/Features/Apps/AppSigningSheet.swift`、
  `Seal/Core/Configuration/AppConfiguration.swift`、`Scripts/verify-release-safety.py`（R80）。
- 🔴 **设备扫描必须注入（默认 nil），不能写死**：`AppRecordRecovery.restoreMissingRecords()`
  被 `AppRecordRecoveryTests` 的三个用例**直接调用** ⇒ 扫回写死在它里面，那三个用例就会在
  CI 的模拟器上真的去调 `Provision.dumpProfiles`（**无设备可连**的同步 FFI：最坏白等 15 秒、
  还可能直接崩掉测试进程）。改成 `protocol InstalledAppScanning` ＋
  `deviceScanner: (any InstalledAppScanning)? = nil`（与 `StaleProfileSweeping` 同一做法），
  生产路径由 `AppContainer` 接 `DeviceInstalledAppScanner.live`；未接线留
  `skipped-not-wired`（必须与「设备端确实没有可补的」分得开）。
  守卫 R80 的 `Scan/inject` / `Scan/notwired` / `Scan/wire` 三条钉住它。
- **代价（有意接受）**：维护作业第 1 步多一次 profile dump（候选为空时**不发**设备查询）。
  第 4 步本来就有一次 dump，所以最坏情况（隧道死）从约 15 秒变成约 30 秒，
  常见情况只多一次亚秒级 dump。换来的是用户「重装 Seal 后应用全回来了」。
- **验证状态**：⚠️ 编译 / 单测 / 真机回归待 CI 与真机确认（Windows 本机无法编译）。
- 🔴 **「变异锚点存在」≠「变异有判别力」**（同一条守卫上一轮踩了两次，属于常犯坑位）：
  ① `Cancel/waited` 的变异锚点是 24 空格缩进那处（唯一，命中超时结论行），变异**确实生效了**；
  但断言写成「**整文件**里存在 `let waited = Int(Date().timeIntervalSince(startedAt))`」，
  而 `beginInstallHeartbeat` 里有一句**一模一样**的（16 空格）⇒ 改掉超时那处后断言照样成立，
  变异白写。
  ② `Cancel/order` 的断言是「区间里存在 `Minimuxer.reset()`」，而那段区间里有一句**注释**
  也写着 `Minimuxer.reset()` ⇒ 把真代码挪走/挪后都不影响它；同时原变异只把
  `if detail.contains("MissingPackagePath") == false` 改成 `if false`（**根本没改变顺序**），
  与「顺序」这条判据根本不是同一件事。
  **两条规律**：(a) 断言必须**限定到唯一路径** —— 用 `section_or_empty` 切出那条分支再断言，
  不要用整文件 `in`（同名字符串在别处出现是常态）；(b) 判「顺序」的断言必须
  `strip_comments` 后再比下标，否则**注释会替真代码满足断言**。
  另注：变异块换掉后**注释会留在原地**（本轮换 `Cancel/order` 时留下两条 `㉕`），
  改变异要连注释一起改。
  **自查法**：先只跑这几条变异做定点复验（每条 = 一遍 `violations()`，几十秒），
  确认「改掉判据真的报红」之后再跑整轮 —— 整轮在 OneDrive 上要 20 分钟以上。
- 🔴 **CI 构建 42 单测红了 3 条 —— 全是测试数据错，不是实现错**（`swift-regression`）：
  `InstalledRecordRecoveryPolicyTests` 的 `skipsBundleIdentifierAlreadyCoveredByARecord` /
  `respectsDismissedTombstones` / `doesNotRecoverExtensionsAsStandaloneApps`。
  ① 前两条：`Context` 的字段文档写着「已归一化 / 已大写」，但**没有任何东西强制它** ——
  测试助手手搓 `Context` 时传了 `com.example.demo.seal.ABCDE12345`（Team 段**大写**），
  而 `drafts()` 是按小写查表的 ⇒ `known` / `dismissed` 两条闸门**一条都没筛掉**。
  ⇒ 修法**不是**改测试数据，而是把归一化搬进 `Context.init`：这个前置条件容易违反、
  违反后**静默失效**（多建记录、把用户删掉的捞回来），只写在文档里不够。
  顺带加一条 `contextNormalizesWhateverItIsGiven` 钉住「`init` 与 `context(...)` 两条
  构造路径不会分叉」，测试助手改为**故意传原始值**。
  ② 第三条：**扩展的映射形态写错了**。真实规则在 `BundleIDMapper.extensionBundleID` ——
  扩展挂在**主 App 映射后**的 ID 下面（主 `…seal.ABCDE12345`、扩展
  `…seal.ABCDE12345.share`），**不是**各自加 `.seal.<team>` 后缀。
  写成 `com.example.demo.share.seal.ABCDE12345` 会让 `isExtensionBundleID` 的前缀判据落空
  ⇒ 扩展被当独立 App 建记录（真机上就是一条点开就报错的僵尸）。
  ⚠️ **`DeviceProfileCleaner` 那边的 `isExtensionBundleID` 判的也是「映射后 ID 的前缀」，
  在回收场景是成立的**（它拿到的两边都是映射后 ID）—— 别因为这条测试就去改它。
  ③ 教训：**新增单测时，测试里构造的「设备端数据」必须按真实映射规则造**
  （`BundleIDMapper.extensionBundleID` / `BundleIDPolicy.recommendedBundleIdentifier`），
  不能凭直觉拼字符串 —— 拼错了测试照样编译、只在 CI 上红。

---

## 2026-09-25 导入新版只落「待签名」页、装不上（含 Seal 自己）：`commit` 里 `existing` 被硬编码成 nil

- **现象**（用户原话）：「我想要的是**覆盖安装**，目前有新版我都装不了，包括 seal 也是；
  **新导入的话就在待签页**，覆盖更新安装就到已签名」。另一处相关反馈：导入新版后签名时报
  「Bundle ID 冲突」。
- **根因**：`ImportWorkflow.commit` 里 `let existing: AppRecord? = nil` 是**硬编码**，
  原注释写着「同一个 IPA 允许导入多个副本，不查找待签名记录进行替换 / 每次导入都创建独立条目」。
  只有 `existingSeal != nil`（导入的是 Seal 自己**且记录身份匹配**）才走替换分支 ⇒
  **第三方导入新版恒新建一条待签名记录**（= 用户看到的「待签页」）。连锁三跳：
  ① 新记录经 `preferenceSource` 继承同一条已安装记录的 `mappedBundleIdentifier`
     ⇒ 签名时 `enforceBundleIdentifierUniqueness` 报 `SEAL-BUNDLE-004`「Bundle ID 冲突」；
  ② 新记录 `belongsInInstalledList == false` ⇒ `SigningCoordinator.isInstalledRenewal` 为假
     ⇒ 走不到续签那条**免免费账号 3-app 预检**的路径；
  ③ 合起来就是用户看到的「有新版也装不了」。
  Seal 自己另有一个缺口：`existingSealRecord` 只认
  `preferredExistingSealRecordForImportedIPA`（original / mapped / preferred 三匹配），
  记录身份与导入包**都对不上**时返回 nil ⇒ 新建 `isSeal == false` 的普通记录 ⇒ 同样被 004 拦下
  —— 这就是「连 Seal 自己也装不了」。
- **修复**：
  ① 新增纯函数 `ImportReplacementPolicy`：候选 = **同原始 Bundle ID 且已安装**的第三方记录
     （只认 `originalBundleIdentifier`，与 `userIdentityKeys` 正交；**待签名记录绝不参与**，
     否则会毁掉「多副本」路径）；有多条时取最近安装 / 导入的那条。
  ② 新增 `ImportCommitTarget`（`.newRecord` 默认 / `.replaceInstalled(appID:)`）显式表达意图；
     提交时用 `confirmedReplacement(appID:)` **按 id 复核**，复核不过**回落新建**
     （绝不把别的记录覆盖掉）。重试沿用**同一个**目标（否则重试会悄悄变回新建）。
  ③ 新增 `makeInstalledUpdateRecord`：复用 `existing.id` 与全部签名身份字段
     （mapped Bundle ID / 账号 / Team / 证书 / 描述文件 / `signingTargets`），
     **清空** `signedIPARelativePath` / `signedIPASHA256` / `signedArtifactStatus`
     （否则「复用已签名包直接安装」那条路径会把**旧版本**装回设备），置
     `hasPendingSelfUpdateSource = true`（装好后由 `SigningCoordinator` 自动清零）。
  ④ 🔴 **文件目录键必须等于记录 id**：`AppFileStore` 用 appID 同时决定 `Apps/<appID>/`
     目录名与写进记录里的相对路径（`Original.ipa` / `Signed.ipa`）⇒ 原
     `commitAppID = existingSeal?.id ?? draft.appID` 在覆盖更新时与记录 id 不一致，
     签名阶段会去一个**不存在的目录**取包。已改为
     `existingSeal?.id ?? existing?.id ?? draft.appID`。
     ⚠️ 这个隐患在改动前**不可达**（`existing` 恒 nil），是「替换待签名记录」那条旧路径的遗留。
  ⑤ UI：确认页检测到可覆盖记录时显示「更新方式 / 覆盖更新「名」（v旧 → v新）」，
     主按钮变「覆盖更新」，并额外提供「**新建副本（不覆盖）**」出口 ——
     破坏性操作必须由用户显式确认，不能静默替换。
  ⑥ 留痕：覆盖成功记 `SEAL-IPA-212`，复核不过回落新建记 `SEAL-IPA-213`
     （否则「点了覆盖更新却回到待签页」在日志里完全看不见，第②类日志必须能说出下一步做什么）。
  ⑦ Seal 自更新兜底：新增构造参数 `runningSealBundleIdentifier`
     （`AppContainer` 传 `Bundle.main.bundleIdentifier`），导入包 Bundle ID 与**运行中**的 Seal
     相同 ⇒ 无论记录写成什么样都按自更新处理。
- **涉及文件**：`Seal/Core/Import/ImportReplacementPolicy.swift`（新增）、
  `Seal/Core/Import/ImportWorkflow.swift`、`Seal/Application/AppContainer.swift`、
  `Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Import/ImportConfirmationView.swift`、
  `Seal/Features/Apps/AppsRootView.swift`、
  `SealTests/Import/ImportReplacementPolicyTests.swift`（新增）、
  `SealTests/Import/ImportWorkflowTests.swift`、
  `Scripts/verify-release-safety.py`（R79）。
- **验证状态**：守卫 R79（21 条断言 / 17 个变异锚点）两遍全绿；新增单测覆盖
  「覆盖更新复用记录并清空签名产物」「目标非已安装 / 已删除时回落新建」「重试沿用覆盖目标」
  「导入运行中的 Seal 走自更新」「判据的六条边界」；**真机回归待用户执行**
  （清单见交付说明）。
- **常犯坑位（新增）**：**「改动前不可达的隐患」不会因为新功能而消失，它只是被新功能激活了。**
  `commitAppID` 少写一个 `existing?.id` 之所以没人发现，是因为 `existing` 恒为 nil ⇒
  那行永远等价于 `draft.appID`。一旦让 `existing` 有值，它就立刻变成「覆盖后签名找不到源包」。
  ⇒ 给一条**死路径**注入新语义时，必须把那条路径上**每一个**依赖「目标就是 draft」的假设
  都重新读一遍（这里还有 `recordID` / `preferenceSource.excluding` / 文件目录键三处，
  前两处原实现已经写对，只有文件目录键没有）。

---

## 2026-09-25 删账号重加后「单点续签必失败、续签全部却成功」：设备核验三态被折成 Bool（构建 39 真机）

- **现象**（用户复验）：① 删 Apple ID 重新添加后，点**一个**应用续签会走完**三个**应用的签名流程
  （「续签的一个，签名的 3 个」）；② 之后除 Seal 自己外，**其他应用单点续签全部失败**（连试三次），
  而点「续签全部」却能全部成功。
- **日志**（`Seal-log(20)(1).txt`，`构建 1.3.10 (39)`）：
  `10:51:51 证书检查：远端 1 张，本机有私钥 0 张` → `10:51:57 撤销 …BCC6734D（运行中Seal=是）`
  → `10:52:17 证书轮换事务：自动续签 2 个受旧证书影响的已安装应用，Seal 始终最后安装`（现象①，
  连 Seal 共 3 个；前一轮 `10:43` 同链路是 `自动续签 1 个`）；
  `10:56:18 / 10:56:44 / 10:57:48 开始续签：LiveContainer|Guoguo` → `续签路径已确认：仅更新描述文件`
  → `10:56:34 / 10:57:00 / 10:58:04 [SEAL-PROFILE-362]`（三次，间隔各 16 / 15 / 16 秒）；
  而**同一时段** `10:57:11` 起的批量续签（`SEAL-RENEW-020` 第 1/3、2/3、Seal 自续签）**全部成功**
  （`10:57:14 / 10:57:24 / 10:57:45`）（现象②）。
- 🔑 **独立佐证（用户原话「除了能单独续签 seal 以外，其他应用单独续签却续签不了」）**：
  `ProfileOnlyRenewalPolicy.evaluate` 第一句就是 `guard app.isSeal == false else {
  return .requiresFullResign(.sealSelfReplacement) }` ⇒ **Seal 永远不走 profile-only 路径**
  ⇒ 永远不执行那段 `containsProfile` 核验 ⇒ **永远不可能报 362**。
  > ⚠️ **该身份豁免已于 1.3.15 撤销**（2026-09-25）：Seal 现在与普通应用走同一条准入判据，
  > 记录完整时也走 profile-only。详见本文件顶部「Seal 自身续签改成只更新描述文件」那条。
  也就是说：**唯一能单点续签成功的应用，恰好就是唯一不使用这条路径的应用** —— 与根因完全互锁，
  这不是巧合。日志里 Seal 也确实走的是 `开始自替换安装`（完整重签），没有一条 362 属于它。
- **根因（三个，必须分开看）**：
  ① **删账号会连本机证书私钥一起删掉** —— 私钥存在该账号的 Keychain 条目里
     （`AccountSecret.certificateP12BySerial`），`deleteAccount` 调 `keychain.delete(accountID:)`；
     重加同一 Apple ID 拿到的是**新 UUID** ⇒ 读不回旧私钥 ⇒ 下次续签只能撤销旧证书、另建新的，
     而**撤销会让所有用旧证书签名的已安装应用失效** ⇒ 必须自动重签它们（含 Seal）。
     **行为本身正确且必要**（不重签那些应用会打不开），但用户事先毫不知情。
  ② **`SEAL-PROFILE-362` 把设备核验的三态折成了二态**。`DeviceProfileInspector.containsProfile`
     返回 `Bool?`（`nil` = 无法核验 / `false` = 身份不符 / `true` = 确认），调用点却写
     `... == true` 后**直接抛错** ⇒ 通道抖动一次就落进同一条死路，应用**永久**续签不了。
     单点与批量**调的是同一个 `signAndInstall`、同一份记录、同一张证书**，差别只在通道时序
     ⇒ 批量恰好核验成功、单点恰好失败 —— 现象②「交替出现且规律稳定」由此而来。
     ⚠️ 该核验还**没有超时保护**（`Provision.dumpProfiles` 是同步 FFI，本仓同步 FFI 无取消机制）
     ⇒ 从「续签路径已确认」到抛错整段**无上限**（实测 16 秒；日志粒度不足以再细分
     等通道 / `isReady()` / dump 各占多少）。
  ③ **⚠️ 加重因素（本轮**未**改，属独立议题）：设备通道争用**。三次单点失败都紧跟在
     `SEAL-INSTALL-707`（已安装页设备探测超时）之后十几秒内；同一窗口还有
     `SEAL-PROFILE-322 … dump 尝试 2 次`（维护侧 dump **重试过**）与
     `SEAL-STORAGE-006 维护作业…被打断`。已安装页探测走 `Minimuxer.isAppInstalled`、
     维护/签名侧走 `Provision.dumpProfiles` —— **两条都是不可取消的同步 FFI、跑在同一个
     设备会话上，彼此之间没有任何串行化**：`InstalledAppRefreshProbeGate` 只互斥「探测 vs 探测」
     （且它在 FFI 真正返回**之前**就 `finish()` 释放了），`OperationCoordinator` 只管前台操作，
     维护作业的 `MaintenanceGate` 只在**粗粒度检查点**才察觉前台已开始。
     探测 2 秒超时后那条 FFI **仍在跑**，于是接下来十几秒内任何 `dumpProfiles` 都可能
     拿不到可解析结果 ⇒ `containsProfile` 返回 `nil` ⇒ 撞上根因②。
     **修根因②已经让续签不再失败**（回落完整重签）；③ 只让它**变慢**，要真正消除得给
     全部设备 FFI 加统一串行化，风险远大于收益，留作独立议题（已在交付清单标注）。
     📌 **上游同族证据（2026-08-26）**：SideStore `#1443`「Refresh All intermittently causes
     misagent BrokenPipe / channel closed when profile installs overlap」——现象是**并发**的描述文件
     （misagent）操作互相打断（`BrokenPipe: channel closed`），**同一应用几秒后单独重试就成功**，
     证书/配对/VPN 全没变；报告者定位到「`PipelineRunner.perform()` 用 `withThrowingTaskGroup`
     并发跑各应用、这一层**没有任何 misagent 串行化**」，并把期望行为写成
     「safely support concurrent profile management **or serialize access to misagent**」。
     与本案**同类**（只是输的那一次不同：他们批量内互相打断，我们单点撞上探测/维护的孤儿 FFI）。
     ⇒ 结论：**misagent 侧缺并发保护是上游已知缺陷**，不是 Seal 独有。
- **这是「问设备 → 按答案做决定」家族的第四处**（前三处：`DeviceProfileCleaner`、
  `InstalledAppDeviceVerifier`、`DeviceProfileInspector.referencedCertificateSerials`）。
  **教训：设备查询结果绝不能折成 `Bool`；「无法核验」必须有独立出口。**
- **修复**：
  - 新增顶层 `ProfileOnlyIdentity`（四态）＋ `ProfileOnlyIdentityVerifier`（纯函数、可注入设备查询 ⇒ 可单测）。
  - **核验先于路径通知**，且**没明确通过就回落完整重签**（留痕 `SEAL-PROFILE-363`），
    不再抛 `SEAL-PROFILE-362`（该码移入「已从源码移除」）。安全约束不破：profile-only 只是
    **加速路径**，「不以本地旧记录直接覆盖设备」由**完整重签**天然满足（重新申请描述文件并注入，不读旧记录）。
  - 核验查询加 **30 秒有界超时**（`HardTimeout.run(cancelsWorkOnTimeout: false)`）：
    超时 ⇒ `nil`（无法核验）⇒ 回落，与 `ProfileOnlyProvisioningProfileInstaller` 同量级。
  - 新增 `isInstalledRenewal`，让**两条**续签路径都跳过免费账号 3-app 预检（续签是覆盖安装、
    不新增设备槽位）—— 否则回落路径会撞 `SEAL-APPID-DEVICELIMIT`，把修复变成另一种失败。
  - 「删除 Apple ID」确认弹窗补告知：**会一并清除本机签名凭据；重新添加后需更换证书，
    并自动重签关联应用**（现象①的源头告知）。
- **验证状态**：守卫新增 7 条断言 ＋ 3 条变异锚点；单测 `ProfileOnlyIdentityVerifierTests`
  钉住四条出口（重点：`nil` 必须落到 `.unavailable`，**不得**等于 `.mismatched`）。真机复验见交付清单。
- ⚠️ **踩到的守卫坑（R22）**：把 `SEAL-PROFILE-362` 移入 `log-code-index.md` 的「已从源码移除」表时，
  我在那一行的**说明里**写了新码（反引号包裹）⇒ R22 的 `table_codes()` 会把「已移除」表里
  **所有反引号码**当成移除清单，于是判定 363「又回到源码里了」。
  **规则：移除表的表格行里不要出现任何仍在源码的码**（要提就写不带反引号的纯文本或「见主表」）；
  已在文档该节加了醒目提示。

## 2026-09-25 删除 Apple ID 后第三方应用仍无法续签：悬空引用的**第三处**（构建 37 真机）

- **现象**（用户复验报告 ＋ 截图）：删 `sun***n1@gmail.com` → 重新添加后，3 个应用抽屉都显示了 id，
  但**只有 Seal 自己能续签**；Guoguo / LiveContainer 点「立即续签」报「Apple ID 不匹配」，
  按钮是「重新验证 Apple ID」（而账号明明已验证过）。
- **日志**（`Seal-log(18)(1).txt`，`构建 1.3.8 (37)`）：
  `00:24:40 Apple ID 已移除…关联应用数：3` → `00:25:15 Apple ID 已添加` →
  `00:25:24 开始续签：LiveContainer` → `00:25:24 错误 [SEAL-AUTH-111] Apple ID 不匹配`；
  `00:25:52 证书轮换事务：受影响应用 LiveContainer / Guoguo 自动恢复失败 [Apple ID 不匹配]`；
  `00:25:35 开始续签：Seal` → 成功。
- **根因**：`SigningCertificateSelectionPolicy.validateAccountAndTeam` 用
  `boundAccountID == account.id` **精确比较 UUID**。删账号→重加会**新建**账号记录（新 UUID）
  ⇒ 记录里的旧 UUID 悬空 ⇒ 必然不等 ⇒ 抛 `SEAL-AUTH-111`，**连下面那句同 Team 比较都走不到**。
  而 `if app.isSeal` 分支**只比 Team、不比 UUID** ⇒ 只有 Seal 能过 —— 现象与代码结构一一对应。
- **这是同一个陷阱家族的第三处**（前两处见下方「常犯坑位」）：`RenewalAccountResolver`（R68）
  负责「**选哪个账号**」（它已用同 Team 回退选对了），这里负责「**校验选得对不对**」。
  ⇒ **上游放行、下游又拦，等于没修**。**教训：修一处判据后，必须顺着链路把下游所有
  复核同一件事的地方都找出来** —— 判据集中在一个纯函数还不够，**消费它的每一道闸门都要跟着改**。
- **修复**：`validateAccountAndTeam` 新增 `knownAccountIDs: Set<UUID>?`，按
  「绑定账号是否仍在账号库」分流：仍在 ⇒ 仍拒绝（保护不丢）；已悬空 ⇒ 交给同 Team 判据
  （换 Team 仍拒绝 `SEAL-AUTH-112`）。**缺省 `nil` ⇒ 保持旧行为（宁可拒绝）**，
  这样漏改的调用点不会因此变危险。新增 `AccountBinding` 返回值 ＋ `SEAL-AUTH-111a` 留痕。
- **四处调用点全部传入现存账号集合**：`SigningCoordinator`（`validateAccountAndTeam` ＋
  `resolvedSerialNumber`）、`AppsViewModel`、`AppSigningSheet`。
- **刻意不改**：`SigningCoordinator.installCachedSignedIPAIfPossible` 里的
  `app.accountID == account.id` —— 那里不等就该**回落到重新签名**（缓存的包是旧账号签的），
  正是正确行为。**改之前先判断「不等」在这里意味着什么**，别一刀切。
- **版本号**：`MARKETING_VERSION` 1.3.8 → **1.3.9**。理由：1.3.8 的 IPA 已交付到用户手上
  （用户正在用它复验），同一版本号出现两份行为不同的产物会让复验与 tag 都说不清。
- **守卫**：新增 **R70**（5 条断言 / 5 个变异），钉住「不得用裸 UUID 比较」＋ 缺省值必须保守
  ＋ 回退必须留痕 ＋ 四处调用点都要传 ＋ 悬空不得绕过 Team 判据。
- **单测**：`SigningCertificateSelectionPolicyTests` ＋5（悬空同 Team 放行 / 悬空换 Team 拒绝 /
  绑定账号仍在时仍拒绝 / 缺省保持旧行为 / 一致时报 `.consistent`）。
- **验证状态**：守卫本地两遍全绿（**555 ＋ 315** → 加 R71 后 **558 ＋ 319**）；CI 与真机复验待跑。

### 同轮顺带修掉的三处审查项（P1 / P2 / P4）

- **P1 删除无效的连接重置**：`InstalledAppDeviceVerifier.isInstalled` 里那句
  「查询前重置连接，避免使用已断开的 RSD 缓存连接导致误判」是**被证伪的理由** ——
  `Install.resetProvider()` 只清 Swift 侧对象、**清不掉 Rust 的 RSD 会话缓存**
  （同结论见 `MinimuxerInstallChannel.probeCachedSessionIfStale` 的注释）。而
  `MinimuxerInstallChannel.verifyInstalled` 已于 2026-09-24 按同一理由删掉。
  ⇒ 顺藤摸瓜发现 `MinimuxerInstallChannel.installPushedIpa` 里**还有两处**同样的调用
  （安装前 ＋ 重试前，理由文字也一样）⇒ **一并删除**。该函数自己的注释指出
  「会话在两段之间被重建会让 installd 报 MissingPackagePath」—— 重置**可能正是那个
  重建的来源**。全仓实际调用已清零（只剩注释里的说明）。守卫 **R71①**。
- **P2 先问完再动手**：`reconcileInstalledAppsWithDevice` 原本**边问边删** ——
  循环中途通道变坏（第 1 条已判「设备上没有」并删掉、第 2 条才抛错）就会**删一半**。
  改成先收集 `missingOnDevice`、全部问完再删；中止文案补「本轮未删除任何记录」。守卫 **R71③**。
- **P4 默认值必须在「不打扰用户」那侧**：`refreshInstalledApps(userInitiated: Bool = true)`
  的默认值是陷阱（三个调用点全都显式传 `false`）⇒ 改成 `false`，想弹阻断式提示必须显式传。守卫 **R71②**。
- **刻意未做**（已评估、不阻塞交付）：`SEAL-INSTALL-707` 的耗时诊断（`code 2` 已说明是超时，
  耗时无额外信息）；`SEAL-RENEW-023` 日志去重（信噪比问题，价值不成比例）；
  `SettingsViewModel` 证书健康统计的悬空少算（纯显示）；
  以及 `reconcile` 的**阳性对照**改造（改动大、必须真机验证 ⇒ 留作下一轮）。

---

## 2026-09-24 最低支持抬到 iOS 17.4：禁止 iOS 16.0–17.3.1（用户指令）

- **指令**（用户原文）：「16.0-17.3.1禁止使用」。落地范围经确认 = **抬门槛到 17.4，Lockdown 通道代码保留**。
- **为什么分界线是 17.4**：17.4 是 Apple 引入 `CoreDeviceProxy` 的那一版 ⇒ 这是**唯一**一条
  不依赖本机配对（Lockdown）、不需要 LocalDevVPN 的安装链路。低于 17.4 要么根本装不上（16.x 及以下），
  要么只能走必须开 VPN 的 Lockdown —— 链路依据见 `docs/qa/2026-09-20-pairing-os-support-matrix.md`。
- **改动**（部署目标共 **9 处**，漏一处 CI 就红 —— 这是本轮最容易踩的坑）：
  ① `project.yml` **5 处**：`options.deploymentTarget.iOS` + 4 个 target（Seal / DeviceSupport / SealTests / SealUITests）；
  ② `Config/Base.xcconfig` **1 处** `IPHONEOS_DEPLOYMENT_TARGET`（项目级默认，会被 target 级覆盖，
  但两处必须一致 —— 这处最容易漏，因为它不在 `project.yml` 里）；
  ③ 三份 workflow 各 **1 处**硬编码断言：`ios.yml` / `ios-fast.yml` / `ios-release.yml`
  （`test "$TARGET" = "17.4"`；`ios.yml` 用的是 `$SEAL_TARGET`）；顺带把 step 名从
  「Verify Seal minimum deployment target remains iOS 17」改成「… iOS 17.4」。
- **界面口径同步**（旧文案属于「显示与行为相反」）：`AboutView` 的「最低支持」17.0 → 17.4；
  `PairingSettingsView` 原文案承诺「iOS 17.0–17.3.1 会改用『本机配对』」⇒ 新门槛下这些机器
  **连装都装不上**，改为「Seal 最低支持 iOS 17.4，iOS 17.3.1 及以下无法安装」。
- **刻意保留**：Lockdown 通道代码**不删**（用户明确要求）—— 配对助手仍按 `< 17.4 ⇒ Lockdown`
  分流，老版本 Seal（≤ 1.3.7）的用户还能用。守卫 **R69⑤** 钉住它，防以后「顺手清理死代码」。
- **版本号**：`MARKETING_VERSION` 1.3.7 → **1.3.8**。理由：1.3.7 的 IPA 已经交付到用户手上
  （桌面 `Codex-Seal-IPA/`），同一版本号出现两份门槛不同的产物会让真机复验与发版 tag 都说不清。
- **守卫**：新增 **R69**（5 条断言 / 8 个变异），钉住 9 处一致 + 界面口径 + Lockdown 保留。
- **不影响的两件事**（先证伪，别白查）：① `#available(iOS 16.4, *)`（`GlassSurface.swift`）
  在部署目标还是 17.0 时就已经恒真，本轮**不引入新警告**，且全仓无 warnings-as-errors；
  `#available(iOS 26.0 / 26.4, *)` 仍有效。② 预编译 `RustBridge.xcframework` 的 minOS 是 16.0 ≤ 17.4
  ⇒ **抬门槛不构成冲突**（只有**降**门槛才需要查它）。
- **验证状态**：守卫 PASS（本地两遍）；CI 待跑。**真机**：17.4 及以上可装，17.3.1 及以下应装不上。
- 🔴 **对真机复验的影响**：1.3.7 的续签修复若要在 **iOS 17.0–17.3.1** 设备上验，必须用
  **已交付的 1.3.7 IPA**（门槛仍是 17.0）—— 1.3.8 在那台机器上装不上。

---

## 2026-09-24 删除 Apple ID 后其他应用无法续签：记录里的 `accountID` 是悬空引用（构建 34 真机）

- **现象**（用户报告，构建 1.3.6(34) 真机）：Seal + guoguo + livecontainer 三个应用都用
  `sunuannian` 这个 Apple ID 签过；在「我的」里删除该 Apple ID、再重新添加同一个 Apple ID 之后，
  **只有 Seal 自己能续签**，其他应用都显示异常，且**一点续签就提示去添加 Apple ID**。
- **根因**：应用记录里的 `accountID` 是**悬空引用** —— 指向一个**已经不存在**的账号 UUID。
  链路三处（缺一不可）：
  ① `SettingsViewModel.deleteAccount` **刻意保留**应用的账号绑定（日志原文「关联应用保留原账号绑定，
     用于防止误用其他账号续签」）⇒ 删除后 `accountID` **不是 `nil`**，而是一个悬空 UUID；
  ② 重新添加同一 Apple ID 时，`persistAuthenticatedAccount` 的 `duplicateAccount` 查不到旧记录
     （`deleteAccount` 已经 `accountRepository.delete(id:)` 把它**真的删掉**了）⇒ **新建一条记录、
     新的 UUID** —— 构建 34 日志 `20:34:08 Apple ID 已添加（Team: …）` 实证；而应用记录的
     `accountID` 仍指着**被删掉的旧 UUID** ⇒ **永远悬空**
     （⚠️ 同一份日志 `20:35:22 Apple ID 已重新绑定到现有账号记录` 是用户**又添加了一次**、
     绑到 `20:34:08` 刚建的那条记录上 —— 仍是**另一个** UUID，改变不了悬空；我起初把它读成
     「重新绑定回被删掉的原记录」，那是**误读**，靠 `duplicateAccount == nil` 那行分支文案才纠正过来）；
  ③ 三处续签入口都直接信任这个 UUID，且**都不会失败得有声有色**：
     - `AppsViewModel.beginRenewalDirectly`：`else if let recordedAccountID = app.accountID { accountID = recordedAccountID }`；
     - `AppsViewModel.beginSigning`：`(isRenewal ? app.accountID : nil) ?? accountID` —— 悬空 UUID
       **不是 `nil`** ⇒ `??` 兜底**永远不会执行**，用户在抽屉里手动选的账号也被忽略
       （与 R67 那句 `candidate.accountID == accountID` 是**同一个陷阱的两种表现**）；
     - `RefreshPlanner.makeQueue`：`app.accountID ?? fallbackAccountID`，且「按 Team 匹配」
       **只给 `isSeal` 开了口子** ✗。
  为什么只有 Seal 没事：`SelfAppRegistrar` 每次启动都「**版本一致也回补 Team/账号**」
  （首次未记录时从运行包的描述文件补全）⇒ 只有它的绑定被重新指回可用账号。
- **观测性缺口**：`SEAL-AUTH-104b` 这条失败出口**只设 `alertFailure`、一行日志都不写** ⇒
  构建 34 的 233 行日志里该码**零命中**，而「点了续签却什么都没发生」正是最需要日志的场景。
  界面侧同样反向：`InstalledAppActionSheet` 按「记录 UUID 反查得到账号吗」决定文案，
  而续签走的是另一套判据 ⇒ 显示「未记录·自动选择」、行为却是拒绝，**显示与行为正好相反**。
- **修复**：
  ① 新增纯函数 `Seal/Core/Accounts/RenewalAccountResolver.swift`（`Resolution` 四态：
     `resolved` / `recordedAccountNeedsVerification` / `recordedAccountMissing` /
     `noSelectableAccount`），作为续签账号解析的**唯一判据**：记录账号**必须真的存在**；
     不存在时按**同 Team**（`signingTeamID`，大小写与首尾空白不敏感）找可选账号 ——
     同 Team 才能保证 Bundle ID 前缀 / Keychain 访问组 / App Group 不变；有 Team 信息却匹配不上时
     **拒绝**，绝不静默换 Team；只有旧数据完全没有 Team 信息时才退回「传入账号 / 第一个可选账号」。
     **顺带统一**：旧的「按 Team 匹配」只给 `isSeal` 开小灶，而风险与判据对所有应用完全相同 ⇒ 现在对所有应用生效。
  ② 三处入口（`beginRenewalDirectly` / `beginSigning` / `RefreshPlanner.makeQueue`）全部改走该解析器；
     `beginSigning` 对**全新签名**仍严格要求用户选定的账号（不替换、不猜测）。
  ③ 每条失败出口都留痕（新私有方法 `logAccountResolutionFailure`），并按原因分码：
     `SEAL-AUTH-104f`（记录账号需重新验证）/ `SEAL-AUTH-104g`（记录账号已删除且无同 Team 账号）
     —— 两者**下一步动作不同**（重新验证 vs 添加同 Team 账号），折成一个码就说不清。
  ④ 界面与判据**同源**：`InstalledAppActionSheet` 调同一个 `resolve`，失效状态改用告警色
     `Color.sealWarning` 显示「记录账号已失效」/「记录账号需重新验证」。
  ⑤ 新增 15 条单测 `SealTests/Accounts/RenewalAccountResolverTests.swift`；守卫新增 **R68**
     （10 条断言 + 13 个变异锚点）。
- **涉及文件**：`Seal/Core/Accounts/RenewalAccountResolver.swift`（新）、
  `SealTests/Accounts/RenewalAccountResolverTests.swift`（新）、
  `Seal/Features/Apps/AppsViewModel.swift`、`Seal/Core/Renewal/RefreshPlanner.swift`、
  `Seal/Features/Apps/InstalledAppActionSheet.swift`、`Scripts/verify-release-safety.py`（R68）、
  `RELEASE_NOTES.md`、`project.yml`。
- **验证状态**：守卫本地两遍全绿（含 R68 的变异全部被抓）。
  🔴 **CI 抓到一条本地抓不到的顺序 bug（构建 35 第一次 run，`swift-regression` 单点失败）**：
  解析器里「一个可用账号都没有」的 guard 原本排在「记录账号是否存在」**之前** ⇒
  「记录账号还在、只是需要重新验证」被短路成 `.noSelectableAccount`，
  丢掉「是哪个 Apple ID 要重新验证」这条更有用的信息。
  单测 `reportsNeedsVerificationInsteadOfSilentlySwitching` 期望
  `.recordedAccountNeedsVerification`、实际得到 `.noSelectableAccount` ⇒ **只有它一条红**
  （639 tests / 96 suites，1 issue）。
  ⇒ 修法是把判定顺序调过来（**改判据、不是改测试期望** —— 测试期望才是设计意图）；
  ⇒ 并把**顺序**本身钉进守卫（新增 R68③b：`find(记录账号判定) < find(空表 guard)`）
  —— **静态断言查不出「两段代码谁在前」，只有单测能查**，所以两者都要有。
  ⚠️ 顺带纠正：单测是 **15 条**不是 17 条（我第一版记错，已改）。
  ⚠️ **真机复验配方**：删账号 → 重新添加同一个 Apple ID → **单独对某个业务应用**续签
  （**不要**批量、**不要**对 Seal 自己）；判据 = 续签成功且日志里**不再出现**「续签被拒」。

---

## 2026-09-24 撤销之后必须有人负责：恢复判据失效 + 失败出口无提示（构建 33 两轮真机）

- **现象**：为验收「证书轮换子流程」修复连跑两轮真机，日志里
  `证书轮换事务：自动续签 N 个受旧证书影响的已安装应用` **连续两轮 0 命中**
  （`DownloadsSeal-log(12)(1).txt` / `(13)(1).txt`，构建 1.3.5(33)）。同一批日志还暴露两个观测性缺口。
- **根因**（两条，均代码 + 日志双证；改回旧写法**不编译失败、也不跑挂单测**）：
  ① **恢复判据失效**：`affected` 过滤器里有一条 `candidate.accountID == accountID`。它让
     「本机无私钥」（要**删过**账号 —— `deleteAccount` 会 `keychain.delete`）与
     「accountID 相等」（要**没删过**）**互斥** ⇒ 恢复**永远不触发** ✗。
     而 `deleteAccount` 刻意保留应用的旧绑定（原文「关联应用保留原账号绑定，用于防止误用
     其他账号续签」），重新添加同一 Apple ID 时 `duplicateAccount == nil` ⇒ 建**新 UUID**
     ⇒ 恒不相等 ⇒「删账号重加」这个最自然的复现配方**必然无效**（为此白跑一轮真机）。
     判据其实只需要**证书序列号**（全局唯一）。
  ② **撤销之后没人负责**：两处恢复调用点都在**成功路径**上（`app.isSeal` ⇒ 装之前
     `includeSeal: false`；非 Seal ⇒ 装之后 `includeSeal: true`），而
     `CertificateRotationTransactionState` 是 `signAndInstall` 内的**局部量** ⇒ 一旦后面失败，
     撤销的后果**永久丢失**：用户只看到「安装失败」，不知道别的 App 已经被撤销的证书废掉、
     已经打不开了（第一轮：`17:04:28` 撤销 → `17:04:32` 外层失败，日志里对此一字未提）。
- **另两条（观测性缺口）**：③ 批量续签**逐项失败**只推 UI 事件、不落日志（逐项成功早有
  `SEAL-RENEW-020`）⇒ 真机 `18:04:45 批量续签结果抽屉已关闭（total: 3, succeeded: 1, failed: 2）`
  之后查不出失败的是谁、为什么。④ `dump` 失败不报尝试次数：`summary.dumpAttempts = dump.attempts`
  写在**成功路径**上、失败分支提前 `return` ⇒ 恒为 1 ⇒ 日志分不出「一次都没重试」与
  「重试 3 次仍失败」（`17:55:14 → 17:55:58` ≈ 3×15 秒，日志却只写「中断于 dump，首个错误：NoDevice」）。
- **修复**：
  ① 抽出纯函数 `SigningCoordinator.appsAffectedByCertificateRotation(...)`，**去掉 `accountID` 过滤**。
  ② 恢复子流程回传**真正恢复成功的 appID**；新增 `pendingRotationRecovery`（三条出口共用，
     避免「修一条漏两条」）与 `failureWithRotationConsequence`（把后果追加进 `reason`、
     **保留原 code/recovery**、写 `SEAL-CERT-240`）；三条出口（`ImportFailure` / 非
     `ImportFailure` / 取消）全覆盖。⚠️ 刻意**不自动补跑恢复**：失败多半意味着通道不可用，
     此刻重签只会再失败一次、把真因埋掉。
  ③ `RenewalCoordinator.emitFailure` 补日志 `SEAL-RENEW-030`（App 名 + code + title + reason）。
  ④ 新增 `DumpProfilesFailure(attempts:underlying:)`，重试耗尽时抛出；失败分支取回真实次数写进摘要。
  ⑤ `verifyInstalled` 三处修正：改用会**抛错**的 `Minimuxer.isAppInstalled`（折叠 `nil` 的
     `lookupApp` 会把「查询失败」读成「没装」）；8 轮都没查到时做**阳性对照**（拿 Seal 自己问），
     对照不通过 ⇒ 新码 `SEAL-INSTALL-707b`（无法验证，去修通道）而不是 `707a`（确实没装上，
     去重装）；删掉无效杠杆 `Install.resetProvider()`（清不掉 Rust 的 RSD 会话缓存，真正的杠杆
     是 `Minimuxer.reset()`，而那会拆掉可能仍在服务的连接）。`707b` 落进
     `InstallFailureActionPolicy.acknowledgeCodes`（「重新安装」兜底对通道故障是白重装一次）。
- **涉及文件**：`Seal/Core/Signing/SigningCoordinator.swift`、
  `Seal/Core/Renewal/RenewalCoordinator.swift`、
  `Seal/Infrastructure/Installation/DeviceProfileCleaner.swift`、
  `Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`、
  `Seal/Core/Installation/InstallChannelDiagnostic.swift`、
  `SealTests/Signing/CertificateRotationAffectedAppsTests.swift`（新增）、
  `SealTests/Installation/InstallChannelDiagnosticClassificationTests.swift`、
  `SealTests/Installation/DeviceProfileCleanerTests.swift`、`Scripts/verify-release-safety.py`。
- **验证状态**：守卫新增 **R67**（9 条断言 + 9 个变异锚点），并同步调整 R25 / R66 的锚点
  （R25 的 `lookupApp` 断言随实现换成 `isAppInstalled`；R66 的 `rotation_body` 结束锚点改为
  紧跟其后的 `pendingRotationRecovery`，避免把新函数吞进来让约束力**悄悄变弱而检查全绿**）。
  ⏳ **待真机复验**：按修正后的配方（重装 Seal ⇒ 所有记录共用同一新 UUID ＋ **单独**对普通 App
  完整签名触发轮换）应看到 `证书轮换事务：自动续签 N 个受旧证书影响的已安装应用`（N ≥ 1）。

---

## 2026-09-24 抽屉卡在「正在验证安装」：子流程的阶段必须透传、主体必须跟着信号走（构建 31）

- **现象**（`DownloadsSeal-log(11)(1).txt`，构建 1.3.5(31)）：签名安装成功后**桌面已经有图标**，
  但抽屉 UI 一直停在「正在验证安装」。用户报告的时刻 `14:57:2x` 正好落在日志里 `.verifying`
  阶段的 **56 秒**区间（`14:56:27 → 14:57:23`）内。
- **根因**（三段，每段都有代码 + 日志实证；共同特征是**改回旧写法既不编译失败、也不跑挂单测**）：
  ① `SigningCoordinator` 在用户那个 App 装完之后，**仍在同一条父会话里**跑证书轮换事务
     （本轮轮换了证书），该事务会重新签名安装**含 Seal 自己**在内的受影响应用
     ⇒ 同一条父会话里先后推进**两个不同 App** 的阶段。
  ② 该事务调 `signAndInstall(..., progress: { _ in })` —— **空回调** ⇒ 子流程每一次阶段变化
     都被丢掉 ⇒ 抽屉停在**父会话的最后一个阶段**（`.verifying` = 「正在验证安装」）。
  ③ 回主屏判据用的是**会话主体**（`signingSession?.app.isSeal`），而父会话主体是用户那个 App
     （实测 LiveContainer）⇒ 判据**恒假** ⇒ Seal 的自替换拿不到「该回主屏了」，
     installd 一直等旧进程让位（日志：`自替换安装仍在等待：已等待 32 秒`），
     直到 `waitForSelfReplacement` 的 **894 秒**上限才抛错。
- **阳性对照**（同一次日志）：批量续签那条链路**是正常的** ——
  `开始自替换安装` → `上传完成，1.2 秒后判断前台状态并回主屏` → `触发回主屏转场`，
  因为它本来就在状态层按 `.restart` 闸门触发。
- **修复**：
  ① 新增 `SigningStageUpdate` / `SigningStageSubject`（`Seal/Core/Signing/SigningStageUpdate.swift`）：
     阶段信号**携带主体**（`appID` / `appName` / `isSeal`），`isSeal` 取自**被推进的那个 App**。
  ② `SigningCoordinator` 的 `progress` 参数类型由 `(SigningStage)` 改为 `(SigningStageUpdate)`；
     证书轮换子流程把父会话的 `progress` **原样透传**（不再用空回调），并补发
     `broadcastsInstallStage: true`（子流程只透传阶段、接不到安装通道的 Double 哨兵）。
  ③ `AppsViewModel.updateSigningStage(_:subject:)` 按**信号主体**判回主屏
     （`(subject?.isSeal ?? signingSession?.app.isSeal) == true`）；阶段日志带主体名
     （`阶段进入：…（<App 名>）`）。
  ④ 两处进度回调（签名 / 重新安装已签名包）都把主体交给状态层。
- **涉及文件**：`Seal/Core/Signing/SigningStageUpdate.swift`（新增）、
  `Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Features/Apps/AppsViewModel.swift`、
  `Seal/Core/Renewal/RenewalCoordinator.swift`、`Scripts/verify-release-safety.py`。
- **验证状态**：守卫新增 **R66**（12 条断言 + 7 个变异锚点）；`r66-precheck` 基线 526 检查 /
  0 失败、7 条变异全部被抓住。⏳ **待真机复验**：轮换证书场景下，日志应出现
  「阶段进入：正在验证安装（Seal）」，随后紧跟 `上传完成，1.2 秒后判断前台状态并回主屏` →
  `触发回主屏转场`；抽屉不应再停在「正在验证安装」。
- ⚠️ **不要顺手改 `RenewalCoordinator` 的事件主体**：批量链路刻意仍用本项 `latestApp` 当主体 ——
  若改用信号主体，会在队列中段交前台、把未跑项丢掉（该文件里有注释）。
- ⚠️ **新增守卫变异时 `expected` 必须与 `check()` 消息前缀逐字符相同**（含 `**` 加粗标记、
  全角括号）。本轮实际踩到：6 条 R66 的 `expected` 漏了消息里的 `**`／在中间插了括号说明
  ⇒ 变异**其实被抓住了**、却会报 `Guard failed mutation check`（同 2026-09-24 那条同主题条目）。
  已把 `~/.workbuddy-ai/tmp/guard-anchor-precheck.py` 的检查④ 从「启发式提醒」改成
  **对静态判不了的条目直接跑真实变异模拟**（280 条里 30 条，约 35 秒）—— 因为公共前缀
  这类启发式**两个方向都会错**：`ios.yml: publish job`（动态）与
  `ios.yml: publish must wait for …`（另一条规则的字面量）公共前缀 17 字符会误报，
  而 `R66: 「重新安装已签名包」…`（真笔误）只有 5 字符会漏报。

---

## 2026-09-24 LiveContainer 401 的修复：能力降级的清空范围必须跟着「描述文件」走（构建 30）

- **现象**（`DownloadsSeal-log(9)(1).txt`，构建 1.3.5(30)，14:02–14:11）：
  ① ✅ **上一轮的修复真机生效**：抖音（9 bundle = 主 1 + 扩展 8）批量续签走快路径 ——
  `14:10:12 profile-only 续签已由设备端逐份读回确认（注入 1 份描述文件、覆盖 9 个目标）`，
  **9 个目标全部指向同一 UUID `ea70ee1a`**；`[SEAL-RENEW-020] 批量续签：第 1/2 项成功`；
  `需要完整重签` **零命中**（构建 29 是 1 次）⇒ 658 MB 整包重传没了。
  ② 🔴 **LiveContainer 仍 401**（`14:09:01` / `14:09:17` 两次）：
  `[SEAL-ENTITLEMENT-401] 描述文件未授权 …LiveProcess 请求的权限：com.apple.developer.kernel.increased-memory-limit`。
- **根因**（五环，每一环都有代码或日志实证）：
  ① `sharedProfileBlocker` 比的是**声明集**（主 App ⊇ 扩展），而 LiveContainer 主 App
  **自己也声明了** `increased-memory-limit` ⇒ 判「装得下」⇒ 走共享模式（`App ID 阶段开始：共享主描述文件`）。
  ② 共享模式 `portalMappings` 只留主 App ⇒ **只有主 App 走 `updateFeatures`**。
  ③ `filteredAppIDEntitlements` 对免费账号**放行** `increased-memory-limit`
  （`ALTFreeDeveloperCanUseEntitlement` 白名单含它）⇒ 提交给 Apple ⇒ **3001**
  （`updateAppId.action` 判参数无效）⇒ 按空能力重发 ⇒ **那份描述文件什么都不授予**。
  ④ 降级只清 `requestedEntitlements[主App]`，而**全部 4 个 bundle 共用这一份描述文件**
  ⇒ 扩展的请求集还留着 ⇒ 签后逐 bundle 校验必红。
  ⑤ 🔴 **`SEAL-ENTITLEMENT-401` 是 Seal 自己的误报**：上游 `SideSign` 的
  `CodeSignerAPI.prepare` 以 `matchedProfile.entitlements` 为起点、只保留 App 也声明过的键
  ⇒ 描述文件没有的能力**根本不会写进 Mach-O** ⇒ **签出的包本来就自洽、能装能跑**，
  是 Seal 拿「本次请求集」对账把它拦下了。
  - **抖音为什么没事**：它的扩展不依赖被拒的能力 ⇒ 降级后仍自洽 ⇒ 能签。
    ⇒ 「同一个 3001 对不同 App 后果完全不同」正是「必须报出被拒的是哪几条能力」的理由。
- **修复**：
  ① `AppExtensionProfileStrategy` 新增纯函数
  `affectedBundles(whenDowngrading:strategy:mappedMainBundleID:mappedBundleIdentifiers:)` ——
  共享模式返回**全部** bundle（它们嵌入同一份描述文件），独立模式只返回自己；
  **不变量：结果恒含被降级的那个 bundle**（防调用方漏传 ⇒ 静默退化回原始 bug）；去重 + 稳定排序。
  ② `ApplePortalSigningService` 的降级分支改为**按该函数算出的范围**逐个清空 `requestedEntitlements`
  （原来是只清 `mappedBundleID` 那一行）。
  ③ `updateFeatures` 的降级补**能力名诊断**（原来只说「这组能力」、无法归因）：
  现在报出「本次提交的能力：…」，**只报能力名、不报值**。
- **涉及文件**：`Seal/Core/Signing/AppExtensionProfileStrategy.swift`、
  `Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、
  `SealTests/Signing/AppExtensionProfileStrategyTests.swift`、`Scripts/verify-release-safety.py`、
  `RELEASE_NOTES.md`、`DEBUG_LOG.md`。
- **验证状态**：新增 5 条单测（共享清全部 / 独立只清自己 / **恒含被降级者** / 去重稳定 /
  共享模式下非主 App 只清自己）；守卫 R65 扩到 **⑱（⑱/⑱b/⑱c 三条断言 + 2 个变异锚点）**。
  ⏳ **待真机复验**：LiveContainer 应能签上 —— 日志应出现
  「能力被 Apple 拒（3001）⇒ 本轮该描述文件不授予任何能力；已一并清空 4 个共享它的目标的请求集」，
  且**不再出现** `SEAL-ENTITLEMENT-401`。
- ⚠️ **已知取舍（不是 bug，别当缺陷修）**：`com.apple.developer.kernel.increased-memory-limit`
  免费账号**拿不到**（Apple 3001）⇒ LiveContainer 内部运行大 App 的内存上限较低。
  这与「共享 vs 独立」**无关** —— 独立模式下 `LiveProcess` 自己的 App ID 同样会被 3001 拒
  （旁证：2026-09-22 `Seal-log(36).txt` 里 LiveContainer 走的正是**独立模式 4 份描述文件**、
  签并装成功，但它照样拿不到那条能力）。
- 🔎 **未验证的探索方向**（**别当结论**）：`ALTAppID.capabilities` 字段与
  `ALTCapabilityIncreasedMemoryLimit = "INCREASED_MEMORY_LIMIT"` 常量在本仓
  **只声明、从未被读写**（`ALTAppID.copy()` 也不复制 `capabilities`），而
  `ALTAppleAPI+Operations.update` 只发 `appID.features` ⇒ `increased-memory-limit`
  **只能**走 `parameters["entitlements"]`。若 Apple 其实要求它走 capability 参数，
  补上就有机会让 Apple 接受 —— **需要真机验证，本轮不做**。

---

## 2026-09-24 续签被逼成完整重签 + 共享描述文件降级未传播（构建 29）

- **现象**（`Seal-log(8)(1).txt`，构建 1.3.5(29)，11:26–11:44）：
  ① **续签退化成完整重签**：`11:40:04 续签路径已确认：需要完整重签并安装。` ⇒ 抖音 `658.2 MB` 整包重传 + 安装，`11:44:24` 才成功（约 4 分钟）；批量续签 `total: 2, succeeded: 1, failed: 1`；
  ② **LiveContainer 仍签不上**：`11:28:27 [SEAL-ENTITLEMENT-401] 描述文件未授权 …LiveProcess 请求的权限：com.apple.developer.kernel.increased-memory-limit`，且 `11:28:24 App ID 阶段开始：共享主描述文件` —— **上一轮加的自动回退没有触发**（日志里没有那条回退诊断）。
- **根因**：
  ① 上一轮为修 `SEAL-PROFILE-337` 加的 `ProfileOnlyRenewalPolicy` 判据（「共享 + 含扩展 ⇒ 完整重签」）**把快路径整个丢掉了**；而且它用的 `app.effectiveExtensionProfileStrategy` 是 `defaultFor(isSeal:)`、**不看记录**（`AppRecord` 注释明写「字段仍会记录实际产物」，取用时却被忽略）⇒ 连历史上按**独立**描述文件签过、扩展 App ID 明明存在的应用也被误判成完整重签。真正的问题是**续签侧不支持共享策略**（`prepareProfileOnlyRenewal` 写死 `.independentProfiles`）。
  ② 共享模式下**只有主 App 走 `updateFeatures`**；Apple 拒能力（3001）时 `downgradedToEmptyEntitlements` 只清了 `requestedEntitlements[主 App]`，而**全部 9 个 bundle 共用这一份主描述文件** ⇒ 扩展的请求集还留着 ⇒ 签后逐 bundle 校验必报 401。上一轮的回退判据跑在 Phase 1 **之前**，看不到这个降级 ⇒ 永远不触发。
- **修复**：
  ① `prepareProfileOnlyRenewal` 的策略改为**取自记录**：`app.extensionProfileStrategy ?? .independentProfiles`（1.3.5 之前的记录没有该字段 ⇒ 那时只有独立模式）；共享模式只取回主 App 一份描述文件，份数判据按策略分叉（共享 = 恰好 1 份）；`ProfileOnlyPortalResult` 新增 `binding(forBundle:)` / `resolvedBindings(forBundleIdentifiers:)`，把「一份描述文件 → 多个目标」解析清楚；`ProfileOnlyRenewalRecordUpdater` 改为按**实际目标**建记录（用 `SigningTargetRecord(binding:signedBundleIdentifier:)`），否则多条记录会**塌成主 App 一条**（R65⑩ 失配）。
  ② 撤销 `ProfileOnlyRenewalPolicy` 里那条一刀切判据（准入不再看策略）。
  ③ 给能力降级补**诊断**（原来完全没有日志）：写明「Apple 拒绝了哪个 App ID 的这组能力、已按空能力重发」，共享模式下追加「扩展嵌入的就是这一份」。
- **涉及文件**：`Seal/Core/Renewal/ProfileOnlyRenewalPolicy.swift`、`Seal/Core/Renewal/ProfileOnlyRenewalRecordUpdater.swift`、`Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、`SealTests/Renewal/ProfileOnlyRenewalPolicyTests.swift`、`SealTests/Renewal/ProfileOnlyRenewalRecordUpdaterTests.swift`、`Scripts/verify-release-safety.py`、`RELEASE_NOTES.md`。
- **验证状态**：守卫 R65 ⑨/⑬/⑭ 重写 + 新增 ⑰；新增单测 `sharedMainProfileIsRecordedForEveryTargetWithoutCollapsingThem`（钉「记录不塌」）与 `eligibilityDoesNotDependOnTheExtensionProfileStrategy`。本地守卫 **511 checks / 271 mutations PASS**；✅ **CI run `35957863923`（run #30）三 job 全绿**（`signer-tests` / `build-package`（含「Check release safety invariants」守卫步）/ `swift-regression`），提交 `d389007`。⏳ **待真机复验**：抖音续签应显示「仅更新描述文件；不会重新签名、打包或安装 IPA」，并给出「注入 1 份描述文件、覆盖 9 个目标」（不再重传 658 MB 整包）。
- ⚠️ **LiveContainer 仍未解决**：降级传播这一轮只**加了日志**、没改行为 ⇒ 它的 401 仍在。可行修法见下一条。

---

## 2026-09-24 守卫变异检查：`expected` 与断言消息前缀不一致 ⇒ 伪装成「判据失效」

- **现象**：守卫报 2 条 `FAIL: Guard failed mutation check: R65⑰: …`，而**源码断言 511 条全过**
  （这个反差就是诊断线索 —— 断言本身没问题）。
- **根因**：守卫判据是 `any(item.startswith(expected) for item in mutated_failures)` ——
  「变异被抓住了」靠**消息文本前缀匹配**，不是编号 ✗。断言消息写
  `「**一份描述文件 → 多个目标**」`，而两条变异（⑰/⑰b）的 `expected` 漏了 `**` ⇒
  变异**其实被抓住了**，只是前缀对不上 ⇒ 报成「判据失效」✗（会把人骗去改断言逻辑）。
- **修复**：两条 `expected` 改成与断言消息**逐字符一致**（含 `**`）。
- **防复发**：`~/.workbuddy-ai/tmp/guard-anchor-precheck.py` 新增检查 ④ —— 抽 `check()` 第 2 参的
  **字面量消息**（398 条），逐条变异断言「某条消息以 `expected` 开头」，查不到即硬失败
  （5 秒，替代整轮 6 分钟）。判据见技能 §5f。
- **涉及文件**：`Scripts/verify-release-safety.py`。

---

## 2026-09-24 共享主描述文件的能力降级没有传播（LiveContainer 401 的根因）

- **现象**：LiveContainer（主 App + 3 扩展）在共享模式下签名，`LiveProcess` 报
  `[SEAL-ENTITLEMENT-401] 描述文件未授权 …increased-memory-limit`（构建 27 连续 5 次、构建 29 仍复现）。
- **根因**：`ApplePortalSigningService` 的 Phase 1 里，`updateFeatures` 若被 Apple 拒（3001）
  会返回 `downgradedToEmptyEntitlements`，调用方只清 `requestedEntitlements[mappedBundleID]`。
  共享模式下 `portalMappings` **只有主 App** ⇒ 只清了主 App 的请求集；而主描述文件被
  **全部 bundle 共用**（`validateEmbeddedProfiles` 拿它逐个 bundle 对账）⇒ 扩展请求集里的
  独有能力没人清 ⇒ 必报 401。
- **为什么上一轮的回退判据没救它**：`sharedProfileBlocker` 比较的是**应用声明的能力**
  （主 App ⊇ 扩展），而实际决定描述文件内容的是**Apple 批了什么**。主 App 自己也声明了
  `increased-memory-limit` ⇒ 判据认为「装得下」⇒ 不回退；Apple 拒了之后才缺，判据看不到。
  ⇒ **「请求集」不等于「授予集」**，判据必须落在**授予集**上。
- **候选修法**（当时未做）：在共享模式下 Phase 1 之后核对「主 App 实际获批的集合」能否
  覆盖每个 bundle 的请求集；不能覆盖就**回退独立描述文件重跑一次 Phase 1**。
- **本轮已做**：给降级补诊断（原来一条日志都没有）。

> 🔴 **本条的两个判断都已被上一条（构建 30 的 401 修复）修订**：
> ① **「把扩展的请求集也清空」不是静默降级** —— 上游 `SideSign` 的 `CodeSignerAPI.prepare`
>    以**描述文件授予集**为起点生成 Mach-O 的 entitlements，描述文件没有的能力
>    **根本不会写进包** ⇒ 清空只是让 Seal 的**账本**与**实际产物**一致；
>    不清才是错的（拿一个比产物更宽的集合去对账 ⇒ 必然假红，把本来能装的包拦下）。
> ② **「回退独立重跑 Phase 1」救不了它** —— 独立模式下 `LiveProcess` 自己的 App ID
>    也会被同一个 3001 拒、那份描述文件同样不授予 ⇒ 401 只是换个位置出现。
>    （9-22 的 `Seal-log(36).txt` 旁证：LiveContainer 走独立模式 4 份描述文件能签能装，
>    但同样拿不到那条能力 ⇒ 「独立模式能过」成立、「能拿到能力」不成立。）

---

## 2026-09-24 共享主描述文件的两个真机回归（构建 27）

> ⚠️ **本条的两条修法都已被上一条（构建 29）修订**：① 「共享 + 含扩展 ⇒ 完整重签」把快路径丢掉了，
> 已撤销，改为**续签侧支持共享策略**；② 「扩展请求了主 App 没有的能力就回退独立」的判据
> 跑在 Phase 1 之前、看不到 Apple 的能力降级 ⇒ 对 LiveContainer 从未触发，根因见上一条。

- **现象**（`Seal-log(7)(1).txt`，构建 1.3.5(27)，06:38–09:34）：
  ① 抖音（9 bundle = 主 1 + 扩展 8）批量续签失败：`[SEAL-PROFILE-337] App ID 身份已变化：Apple 门户中找不到 …DYShareExtension App ID`（同一批「成功 2、失败 1」）；
  ② LiveContainer（3 扩展）**连续 5 次**签不上：`[SEAL-ENTITLEMENT-401] 描述文件未授权 …LiveProcess 请求的权限：com.apple.developer.kernel.increased-memory-limit`；
  ③ 共享策略本身在**签名 + 安装**链路上是通的：`App ID 阶段开始：共享主描述文件，本次需 1 个 App ID`、9 条「描述文件核验」全部 `描述文件 Bundle=主 App 的 ID`、`签名并安装成功`。
- **根因**：
  ① 两条链路策略互不相容 —— `13d8b63` 的**签名**路径用共享主描述文件（门户只注册主 App 的 App ID）；`aba8b3a` 的**续签**路径 `prepareProfileOnlyRenewal` 硬编码 `.independentProfiles` + `requiresExistingAppIDs: true`（要求全部 9 个 App ID 都已存在）⇒ 共享模式从不注册扩展 App ID ⇒ 含扩展的 App **永远进不了 profile-only**。而 `ProfileOnlyRenewalPolicy.evaluate` **完全不看策略**，判成 `.eligible` 后必然失败且**不回退**。
  ② 共享模式隐含假设「主 App 的能力 ⊇ 每个保留扩展的能力」，该假设对扩展**独有**的能力不成立：`requestedEntitlements` 对全部 bundle 都建（2096–2109），但 Phase 1 只对 `portalMappings`（共享模式下只有主 App）提交 `updateFeatures` ⇒ 主 App ID 的能力集不含 `increased-memory-limit` ⇒ 主 profile 不授予 ⇒ 逐 bundle 校验必红。独立模式下扩展有自己的 App ID、能力提交到它自己那份上；即使 Apple 拒（3001）也有 `downgradedToEmptyEntitlements` 兜底 —— 共享模式下这条兜底**永远走不到**。
- **修复**：
  ① `ProfileOnlyRenewalPolicy` 新增 `.sharedMainProfileHasNoExtensionAppIDs`，`evaluate` 末尾（放在记录类判据**之后**，让更具体的提示优先）对「共享策略 + 含扩展」直接判完整重签。
  ② `AppExtensionProfileStrategy` 新增纯函数 `sharedProfileBlocker(mainBundleID:entitlementsByBundleID:)` 与 `resolvedForSigning(requested:mainBundleID:entitlementsByBundleID:)`：只把 `.sharedMainProfile` **降级**成 `.independentProfiles`（永不反向），并按 Bundle ID 字典序**稳定排序**（否则日志会抖）。`ApplePortalSigningService.provisioningProfiles` 在算完能力集后解析策略，`portalMappings` / 日志文案 / 返回的 `ProfilePreparation.extensionProfileStrategy` 三处**统一用解析后的值**（否则回退是空转），并加一条诊断写明是哪个扩展的哪个能力触发了回退。
- **涉及文件**：`Seal/Core/Renewal/ProfileOnlyRenewalPolicy.swift`、`Seal/Core/Signing/AppExtensionProfileStrategy.swift`、`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、`SealTests/Renewal/ProfileOnlyRenewalPolicyTests.swift`、`SealTests/Signing/AppExtensionProfileStrategyTests.swift`、`RELEASE_NOTES.md`、`Scripts/verify-release-safety.py`。
- **验证状态**：新增/改写的纯函数单测（含「永不反向」「稳定排序」两条不变量）；守卫 R65 扩到 ⑯（**19 断言 / 19 锚点**），本地守卫 **510 checks / 268 mutations PASS**。✅ **GitHub Actions `iOS` run 29（`a33fc42`）三 job 全绿**（`build-package` / `signer-tests` / `swift-regression`）⇒ 编译与 `SealTests` 回归通过。⚠️ 仍待**真机**复验：抖音续签应走完整重签、LiveContainer 应能签上（日志出现「共享主描述文件不适用于本次 IPA」）。

---

## 2026-09-24 共享主描述文件策略零守卫覆盖

- **现象**：1.3.5 引入 `AppExtensionProfileStrategy`（普通 IPA 共享主描述文件以省 Apple 门户配额）后，`Scripts/verify-release-safety.py` 里**没有任何规则**在守它 —— 全仓 grep `extensionProfileStrategy` 在守卫里**零命中**；1.3.5 那批提交只把既有 R26/R31 的文案跟着改名同步了，没有为新功能加规则。
- **根因**：这一版的三种错法都**不报错、不崩**，只在真机上表现为「又慢又费配额」或「签名整体不可用」：① 默认方向写反 ⇒ 优化被静默关掉；② 消费点没接上 ⇒ 策略退化成一个纯声明，门户映射照旧全量；③ 校验点写死成扩展自己的 Bundle ID ⇒ 共享描述文件必然校验失败。单测只覆盖纯策略的返回值，编译更是完全挡不住 ⇒ 只能靠静态守卫。
- **修复**：新增守卫 **R65**（12 条断言 + 13 个变异锚点）钉住 ① 默认方向 ② 共享模式只留主 App 一条映射 ③ 扩展按主 profile 校验 ④ 独立模式原样透传 ⑤ `AppRecord` 委托而非另写一份 ⑥ 门户映射经策略 ⑦ 嵌入校验经策略 ⑧ 重签阶段按策略分流 ⑨ profile-only 续签**有意**保持独立 ⑩ `SigningTargetRecord` 记录键 = 实际被重签的 Bundle ID ⑪ 策略落回记录与待签 App ⑫ 单测防删空。同时在 `ApplePortalSigningService.prepareProfileOnlyRenewal` 的独立策略处补上注释，说明它为何**不能**被「顺手改成一致」。
- **涉及文件**：`Scripts/verify-release-safety.py`、`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`。
- **验证状态**：本地守卫 **494/249 → 506/262 PASS**（Windows 可跑，4–5 分钟一轮）；共享描述文件本身的**多扩展 IPA 真机签名/安装/续签回归仍待做**。

---

## 2026-09-24 共享描述文件测试未按模型参数顺序构造

- **现象**：应用 Release 包编译、校验和上传均已成功，但 Swift 回归在新增 `AppExtensionProfileStrategyTests` 编译阶段失败。
- **根因**：`ProvisioningProfileBinding` 的成员初始化器参数顺序是 `teamIdentifier`、`creationDate`；测试把二者写反，Xcode 正确拒绝编译。
- **修复**：按模型声明顺序构造测试 binding；测试仍验证共享 profile 记录扩展的实际签名 Bundle ID。
- **涉及文件**：`SealTests/Signing/AppExtensionProfileStrategyTests.swift`。
- **验证状态**：Release IPA 已构建通过；待修复后的完整 Swift/UI 回归。

---

## 2026-09-24 共享描述文件改动遗漏 profile-only 记录调用

- **现象**：共享主描述文件改动首次 CI 编译失败，`ProfileOnlyRenewalRecordUpdater` 无法解析 `SigningTargetRecord.init(binding:)`。
- **根因**：为共享模式增加“实际签名 Bundle ID”参数时，把既有初始化器改成带默认参数的单一重载；Swift 对函数引用 `SigningTargetRecord.init(binding:)` 不再将其识别为可推断的映射闭包。
- **修复**：恢复显式 `init(binding:)` 兼容入口，内部传入 profile 自身 Bundle ID；共享模式仍显式传扩展实际 Bundle ID。profile-only 继续保持每个 Bundle 独立 profile 和独立签名记录。
- **涉及文件**：`Seal/Core/Signing/SigningTargetRecord.swift`、`Seal/Core/Renewal/ProfileOnlyRenewalRecordUpdater.swift`。
- **验证状态**：前两次 CI 已定位并证实为唯一编译错误；待修复后的完整 GitHub Actions 编译与回归。

---

## 2026-09-24 多扩展 IPA 续签重复消耗 Apple 门户配额

- **现象**：普通 IPA 含多个扩展时，续签会按主应用及每个扩展分别请求 Apple App ID 和描述文件；免费账号不仅等待长，也更容易碰到 App ID 配额。
- **根因**：Seal 的门户映射把每个待签 Bundle ID 都当作独立描述文件目标，未对齐 SideStore 的“保留扩展时共享主描述文件”路径。
- **修复**：普通应用固定使用共享主描述文件策略：门户只注册/请求主应用一次；所有保留扩展仍各自本地重签，但嵌入主描述文件，并按实际扩展权限、设备、证书和有效期逐项校验。Seal 自身继续走独立内部策略，不受该优化影响。
- **涉及文件**：`Seal/Core/Signing/AppExtensionProfileStrategy.swift`、`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、`Seal/Core/Signing/SigningTargetRecord.swift`、`SealTests/Signing/AppExtensionProfileStrategyTests.swift`、`docs/upstream-alignment.md`。
- **验证状态**：已新增纯策略与签名目标记录测试；Windows 本机无 Xcode，待 GitHub Actions 完整编译、Swift 回归及多扩展 IPA 真机签名/安装/续签回归。

---

## 2026-09-23 配对助手泄漏英文底层错误并压住 UDID

- **现象**：配对被系统拒绝时，界面在主按钮下方直接显示 `Pairing rejected: Failed to authenticate...`，并与 UDID 行重叠；刷新按钮与最小化按钮的可点击区域也有 4px 重叠。
- **根因**：旧覆盖层将 `pairing_file_message` 不经分类直接绘制在按钮下方；刷新定位为右侧 `-112px`，而其后两个 32px 控件按 4px 间隔应从 `-120px` 起。
- **修复**：底层文本仅用于识别拒绝/失败，不再直接渲染；拒绝映射为中文提示卡“配对请求未获允许”与“再次发起配对”，其他交接失败也使用中文提示卡。刷新、最小化、退出统一为 32px 并以 4px 间距排列。
- **涉及文件**：`Tools/SealPairingAssistant/seal_ui_tail.rs.txt`、`patch_upstream.py`、`.github/workflows/pairing-assistant.yml`。
- **验证状态**：待固定上游覆盖脚本与 GitHub Actions Windows Release 构建。

---

## 2026-09-23 配对助手完成态重复陈述并提供无必要的主操作

- **现象**：完成态同时展示顶部“已完成 / 配对完成 / 现在可关闭此窗口”、底部“配对已完成，可以回到 Seal 继续操作”以及“重新生成配对文件”主按钮，结论、下一步和恢复动作混在同一层级。
- **根因**：完成态沿用了失败后的主按钮分支，且成功引导同时来自标题和旧的底部 guidance 区。
- **修复**：完成态仅保留顶部结论与关闭窗口指引，设备徽标显示“完成”；隐藏底部成功提示和主按钮。重新生成只在交接失败时显示。
- **涉及文件**：`Tools/SealPairingAssistant/seal_ui_tail.rs.txt`、审核 HTML。
- **验证状态**：待 GitHub Actions Windows Release 构建与完成态截图审核。

---

## 2026-09-23 配对助手审核稿与实际 Windows 界面不一致

- **现象**：审核稿已收敛为紧凑的 `820×700` 窗口、统一的顶部图标按钮和无重复文案，但实际 Windows 配对助手仍是旧的 `920×700` 布局：保留最大化按钮、刷新/最小化/退出规格不一，且“准备配对/已就绪/生成并交给 Seal”重复陈述同一状态。
- **根因**：审核 HTML 与 `seal_ui_tail.rs.txt` 是两套独立渲染实现；此前只更新审核稿，没有将定稿规格回写进 egui 覆盖层与其 CI 标记。
- **修复**：覆盖层窗口改为 `820×700`，移除最大化；顶部三个操作均为 `32×32`、默认无框且悬停显色；状态驱动标题与副文案，阶段统一为“连接/检查/生成/交接”，就绪态只保留“开始配对”；UDID/复制同基线且复制默认无框；移除主界面来源页脚。
- **涉及文件**：`Tools/SealPairingAssistant/seal_ui_tail.rs.txt`、`Tools/SealPairingAssistant/patch_upstream.py`、`.github/workflows/pairing-assistant.yml`、`Tools/SealPairingAssistant/README.md`。
- **验证状态**：已在官方固定提交 `e3abb34` 上运行覆盖脚本；本机 Windows `cargo build --release --locked` 通过。上游构建脚本下载 DDI 首次超时后，以仅供编译的临时非空占位文件重跑，未进入仓库或产物；待 GitHub Actions Windows Release 编译与人工审核截图。

---

## 2026-09-23 配对文件导入在 LocalDevVPN 未连接时长期显示验证中

- **现象**：Windows 配对助手已将可解析的配对文件写入 Seal，但 LocalDevVPN 未连接时，设置页立即切为“验证中”；用户无法区分“文件已导入”与“设备尚不可达”。
- **根因**：自动写入、手动导入和启动轻量检查都在导入成功后无条件调用完整 `runInstallChannelCheck`。该调用先写入 `.validating`，之后才探测 LocalDevVPN 与真实设备。
- **修复**：新增 `PairingValidationStartPolicy`。被动导入/启动检查先以短 TCP 探测判断 LocalDevVPN 隧道；不可达时保持 `.unverified`（“已导入，待验证”），可达才启动完整验证。用户主动点击 LocalDevVPN 检测仍不跳过完整验证。
- **涉及文件**：`Seal/Infrastructure/Pairing/PairingValidationStartPolicy.swift`、`Seal/Features/Settings/SettingsViewModel.swift`、`SealTests/Pairing/PairingStoreTests.swift`、`project.yml`、`RELEASE_NOTES.md`。
- **验证状态**：新增纯规则回归用例；Windows 本机无 Xcode，待 GitHub Actions 完整编译/Swift 回归，以及“未连 VPN 导入 → 待验证；连接 VPN 后验证成功”真机回归。

---

## 2026-09-23 Seal 结算结果更新触发双抽屉

- **现象**：批量自续签首次打开时先出现并立即关闭“等待核验”抽屉，随后才出现“Seal 已更新”。
- **根因**：结算后重读载荷重新构造 `BatchRefreshSession()`，生成新 UUID；SwiftUI 将其识别为新的 sheet 项。
- **修复**：已存在结果抽屉时重用其 UUID，只替换结果内容和条目状态。
- **验证状态**：待完整 CI 与真机回归。

---

## 2026-09-23 Seal 批量自续签结算后抽屉未即时更新

- **现象**：日志已记录 `SEAL-RENEW-028` 成功，但同一次首次打开的抽屉仍显示“等待 Seal 核验”；用户关闭前未等到常规加载。
- **根因**：结算后的载荷已落盘，但界面依赖低频 `load()` 才重读，窗口内沿用先恢复的旧载荷。
- **修复**：仅在恢复结果仍等待 Seal 时，最多 4 秒每 500ms 检查载荷指纹；结算写回后立即替换抽屉结果，关闭抽屉时取消检查。
- **验证状态**：待完整 CI 与真机批量续签回归。

---

## 2026-09-23 证书归属导出与证书页状态同步

- **现象**：LiveContainer 导出入口取“当前活跃 Apple ID”，可能与该应用实际签名账号不一致；撤销或创建本机证书后，证书页短暂显示旧证书/旧接管状态。
- **根因**：导出处理器没有接收应用所属账号；证书事务落盘后依赖后续异步 `load()` 才更新页面快照。
- **修复**：导出入口仅对该账号已签署的 LiveContainer 显示，并显式传入该账号；撤销和本机证书创建的持久化成功后立即提交展示账号快照。
- **验证状态**：待完整 CI 与真机验证。

---

## 2026-09-23 Seal 自替换首次启动仍展示旧等待状态

- **现象**：真机完成 Seal 覆盖安装后，第一次打开新包时结果抽屉仍可能显示“等待新版本核验”；关闭并重新打开才显示已更新。
- **根因**：`RootTabView` 的启动检查与 `AppsRootView` 的恢复链路同时调用 `AppsViewModel.load()`。前者可在 `SelfAppRegistrar` 用真实运行包完成结算之前读取旧的 `awaitingSealConfirmation` 载荷并展示，形成首屏竞态。
- **修复**：根标签页不再对应用页发起并行加载；应用页独占且严格串行执行“自替换身份对账 → 队列恢复 → 读取/展示批量结果”。设置页轻量检查保留，不影响账号与环境刷新。
- **涉及文件**：`Seal/App/RootTabView.swift`、`RELEASE_NOTES.md`。
- **验证状态**：根因由真实首开行为与启动调用图确认；待 GitHub Actions 完整编译与真机一次自替换首开回归。

---

## 2026-09-23 已安装页预期冷却状态重复写入告警

- **现象**：构建 1.2.8 (16) 真机日志中，首次设备应用查询超时后，用户连续下拉或页面任务取消会继续记录多条 `SEAL-INSTALL-707`，但列表已按设计保留且没有弹窗。
- **根因**：设备核验的冷却和并发门正确防止了不可取消 FFI 叠加，但 `AppsViewModel` 将首次超时、冷却中、查询已在进行与 `CancellationError` 一律视为同等级日志告警。
- **修复**：将日志判定抽为 `InstalledAppRefreshFailure.shouldLogDiagnostic`。首次超时及其他可行动设备错误继续记录；冷却中、查询已在进行和页面取消属于保护机制的预期状态，静默结束并保留列表。
- **涉及文件**：`Seal/Core/Apps/InstalledAppRefreshFailure.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`SealTests/InstalledApps/InstalledAppRefreshFailureTests.swift`、`project.yml`、`RELEASE_NOTES.md`。
- **验证状态**：已补纯函数回归用例；待 GitHub Actions 完整编译与真机连续下拉回归。

---

## 2026-09-23 自替换结算与结果恢复并发竞态

- **现象**：构建 1.2.7 (15) 真机日志中，`SEAL-RENEW-028` 已记录 Seal 自替换由新进程身份核验结算成功，但随后关闭结果抽屉仍记录“成功 2、等待 Seal 核验 1”。
- **根因**：`AppsViewModel` 与启动维护作业并发。前者先恢复安装前持久化的 `awaitingSealConfirmation` 载荷，后者才由真实运行包身份把同一载荷写成 `completed`；恢复标志只防重复恢复，未识别载荷后来已经改变，旧抽屉状态因此留存。
- **修复**：为持久化载荷建立稳定指纹。已恢复会话在没有活动批量任务时，仅当读到的新载荷指纹变化才重新派生结果与条目状态；自替换结算仍只由 `SelfAppRegistrar` 的真实身份对账触发，未放宽成功判据。
- **附带诊断修复**：同一真机日志还显示已安装页刷新在 LocalDevVPN 基础通道正常后，应用查询仍因 `SealInstalledAppDeviceVerifier 2` 超时。保留当前 fail-closed 行为（不删记录、不弹窗），但将日志从只有 domain/code 改为脱敏后的底层原因，便于区分超时和服务错误。
- **附带等待优化**：已安装页是尽力读取，原先错误复用查询类的 15 秒默认上限；本次改用专属 2 秒预算，并在超时后冷却 20 秒，避免用户连续下拉叠加无法取消的 FFI 查询。签名/安装后的验证仍使用原预算，不能为界面速度降低安装结论可靠性。
- **附带取消收尾**：已安装页设备查询任务若因离开页面被取消，原本可能把互斥门闩留在“查询中”；现取消与超时统一进入冷却，底层 FFI 自行返回前不再叠加新查询。
- **Apple ID 总览刷新审计**：总览每账号原本串行请求 App ID 与证书两次，分别重复 anisette、团队查询与网络会话；服务已有 `.all` 范围可一次取全，页面却未使用。现总览每账号改为一次完整同步；单项 App ID 详情、签名证书页、未签名列表、存储统计及签名通道检测按其数据源各自保留，不把网络/设备长预算误压缩为页面预算。
- **配对文件导出**：原先只能导入，无法由用户备份当前有效凭据。新增显式导出按钮与风险确认；`PairingStore` 仅导出已规范化且重新通过结构校验的 XML plist，不带验证元数据、Apple ID 凭据或任何额外备份副本。导出内容含配对私钥，因此不记录到 Seal 日志。
- **涉及文件**：`Seal/Core/Renewal/PendingBatchResultPayload.swift`、`Seal/Core/Apps/InstalledAppRefreshFailure.swift`、`Seal/Core/Apps/InstalledAppRefreshProbePolicy.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Apps/InstalledAppDeviceVerifier.swift`、`Seal/Features/Settings/SettingsViewModel.swift`、`Seal/Features/Settings/CertificatesRootView.swift`、相应续签、已安装页与 Apple ID 同步单测、`Scripts/verify-release-safety.py`。
- **验证状态**：已补“结算后载荷指纹变化”单测与静态守卫；Windows 本机无 Xcode，待完整 CI 与真机批量自续签验证。

---

## 2026-09-23 自替换已结算但结果抽屉仍显示等待核验

- **现象**：构建 1.2.6 的真机日志中，Seal 在新进程完成身份核验并记录 `SEAL-RENEW-028` 成功后，关闭批量结果抽屉仍显示“成功 2、等待新进程核验 1”。同时通知自动重排只写 `SEAL-NOTIFY-002a`，没有底层错误信息；已安装页设备核验逐项删除记录时会连续触发全量加载，却继续使用删除前快照，且下拉刷新时设备暂不可达会反复弹窗。
- **根因**：结果抽屉可能在新进程结算前从载荷恢复；恢复后被 `hasRestoredPendingBatchResult` 阻止再次读取已结算载荷，计数沿用旧进程的 `awaitingConfirmation`。通知后台重排吞掉了 `NSError` 的 domain、code 与描述，提醒时间设置失败也没有写日志。已安装页复用公共 `delete()`，而它每成功一项就立刻 `load()`，让循环快照与异步发布交错。
- **修复**：`PendingBatchResultPayload.restoredResult` 统一按持久化条目派生最终分桶；启动队列恢复明确覆盖“仅由旧载荷恢复”的抽屉。新增统一、脱敏的 `NotificationSchedulingFailure`，供后台重排和设置页复用，并为提醒时间更新失败补日志。设备核验删除改为静默批处理，整轮结束后只重载一次已安装列表；下拉刷新明确使用静默设备核验，失败时保留列表并仅记录 `SEAL-INSTALL-707` 诊断；手动删除仍即时刷新。
- **涉及文件**：`Seal/Core/Renewal/PendingBatchResultPayload.swift`、`Seal/Core/Apps/InstalledAppRefreshPolicy.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Core/Notifications/NotificationSchedulingFailure.swift`、`Seal/Features/Settings/SettingsViewModel.swift`、相应续签、通知和已安装页策略单测。
- **验证状态**：已补纯函数测试和发布安全守卫；Windows 本机无 Xcode，待完整 GitHub Actions 编译/Swift 回归与真机复验。

---

## 2026-09-23 批量续签 Seal 自替换被旧进程提前结算

- **现象**：批量续签到 Seal 时，旧进程在覆盖安装阶段把 Seal 预先写成 `completed`；候选包尚未由新进程验证，结果抽屉、队列与真实运行包可能互相矛盾。
- **根因**：`AppsViewModel.persistPendingBatchResultForSealUpdate` 为回避中断后 `running` 幽灵项，直接伪造 Seal 成功；启动顺序又先恢复续签队列、后执行 `SelfAppRegistrar`，真实身份核验来不及参与结算。
- **修复**：新增 `awaitingSealConfirmation` 持久化状态与 `PendingBatchResultStore`；`RenewalCoordinator` 将 Seal 保持为待新进程核验，`SelfAppRegistrar` 仅在真实候选身份匹配后结算成功、候选未落盘结算失败；启动先运行自注册再恢复队列，并允许已验证结论覆盖先前的 `unknown`。
- **涉及文件**：`Seal/Core/Renewal/`、`Seal/Infrastructure/Renewal/RefreshQueueStore.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Apps/AppsRootView.swift`、`Seal/Application/AppContainer.swift`、续签单测。
- **验证状态**：新增载荷结算与未知状态回写单测；Windows 本机无 Swift/Xcode 工具链，待完整 GitHub Actions 编译、Swift 回归和真机自替换回归。

---

## 常犯坑位

- 🔴 **`in` 判据会被「注释」满足 ⇒ 变异失去判别力（本轮一次踩到两条）**（2026-09-26）。
  判据写成 `"SEAL-PROFILE-364" in gate`，而那段代码**上面就有一行注释**解释
  「与 `SEAL-PROFILE-364` 同一条纪律」⇒ 把真码里的 `code: "SEAL-PROFILE-364"` 改成 `363`
  之后断言**照样成立**，变异白写（R85⑦ 的变异 ⑥ 当场报 `Guard failed mutation check`）。
  同一轮新增的 R89⑤ 也是同一形态（新注释里写了 `SEAL-PROFILE-365`）。
  ⚠️ 已知的旧笔记只写了「判**顺序**的断言要 `strip_comments`」（见下方那条），
  很容易被读成「只有顺序判据才需要」✗ —— **普通 `in` 判据同样需要**。
  ⇒ **判据串必须落在代码上**：`strip_comments(区间)` 之后再 `in`，并把串写成**带上下文的形式**
  （`code: "SEAL-PROFILE-364"` 而不是裸的 `SEAL-PROFILE-364`），这样注释怎么写都不会替真码满足它 ✓。
  ⇒ 自查法：改完一段代码后 **grep 一遍自己刚写的注释里有没有出现被其它断言引用的字符串**
  （日志码、函数名、枚举 case 都是高发词），有就回去把那条断言改成 `strip_comments` ✓。

- 🔴 **共享查询 API 的「答否」可能不是「没有」，而是「通道坏了」——没有阳性对照的删除路径会把记录和文件一起删掉**（2026-09-26）。
  `Minimuxer.isAppInstalled`（Lockdown 路径）的实现是 `inst.lookup(appId:) != nil`，
  而 Rust 侧把 **RPC 失败**与**「没查到」**返回成**同一个空指针** ⇒ 通道半坏时它对
  **每一个** Bundle ID 都**静默答「没装」**（不抛错、只答否）；而
  `InstalledAppDeviceVerifier` 只能抓**抛错**的失败（404 / 超时 / 冷却）
  ⇒ 「通道说假话」与「App 真的没装」在代码里**完全同形** ✗。
  ⚠️ 危险的是**下游动作**：`reconcileInstalledAppsWithDevice` 拿这个「否」去 `delete`，
  而 `delete` 会连带 `fileStore.removeApp` **删掉本地文件** —— 一次通道抖动就白删一批记录。
  ⇒ **判据：任何「按设备查询结果做删除」的路径，都必须先拿一个「一定装着」的 App
  （Seal 自己：`Bundle.main.bundleIdentifier`）**问一次**做阳性对照**；
  对照没通过 ⇒ **整轮一条都不删**（fail closed），并留痕。姊妹路径早就这么做
  （`DeviceInstalledAppScanner` / `DeviceProfileCleaner` / `AppRecordRecovery` /
  `MinimuxerInstallChannel`），**漏的是这一条** ✓。守卫 **R88**。
  ⇒ 附带一条：**新码不要顺手复用旧码** —— 本次差点把 `SEAL-INSTALL-709` 用在
  「已安装页核验中止」上，而 709 已经是「与设备的安全握手未完成」
  （同一个码说两件事 ⇒ 用户查码表得到**错误解释**）✗。守卫 R88⑤ 现在同时钉住「码是新的」。

- 🔴 **写在「分支判定之前」的日志，会把两条互斥路径都描述成同一条**（2026-09-26）。
  `SigningCoordinator` 在 `shouldUseProfileOnlyRenewal` **之上**就打「Seal 自续签事务：
  后台保活已启动，覆盖证书、描述文件、签名和安装」，而 profile-only 分支
  （`renewProfilesOnly`）**根本不重签、不打包、不安装**。真机 `11:57:02` 两行紧邻：
  「…覆盖证书、描述文件、签名和安装」＋「续签路径已确认：**仅更新描述文件**；
  不会重新签名、打包或安装 IPA。」⇒ 同一秒里自相矛盾 ✗。
  ⚠️ 条件只有 `app.isSeal && installAfterSigning`，与「走哪条路」**无关** ——
  所以它不是「偶发」，是**必然**在每次 profile-only 续签时发生。
  ⇒ **判据：日志文案只在它描述的那件事已经确定发生时写**；做不到就只陈述**目的**
  （「避免续签过程中被锁屏或切后台挂起」）而不是**步骤清单** ✓。
  ⇒ 顺手一条：改文案后要 grep 一遍**引用了旧文案的注释**（`SigningProgressView` 里就有一处），
  否则会留下一条 grep 不到真源的注释（下一次复盘会被它误导）。

- 🔴 **「子流程的阶段」不是「本会话的显示状态」——让它写父会话，用户就看到一段没发生在本 App 上的流程**（2026-09-26）。
  用户原话：「签名新 ipa 容易出现到安装步骤后又重签一次」。真机日志（构建 48）逐行印证：
  父会话是 Guoguo 的续签，`10:07:44` 已经进入 `verifying`（安装已返回），紧接着
  `10:07:44 waitingForChannel（Seal）` → `10:07:46 preparingBundle（Seal）` →
  `10:07:47 preparingCertificate（Seal）` → `10:07:47 签名并安装成功`。
  ⚠️ **真相不是「多签了一次」**：装完之后确实又签了一次，但签的是**另一个 App（Seal）**，
  而且那是**必要**的 —— 本轮发生了证书轮换（`revokedSerials` 非空），用旧证书签过的
  已安装 App 不重签就会因证书被撤销而**立刻打不开**（`resignAppsAffectedByCertificateRotation`）。
  ⇒ 出问题的是**显示层**：`updateSigningStage` 收到子流程阶段后**无条件**写
  `signingSession?.status` ⇒ 抽屉在父会话装完、正在验证时被覆盖回签名阶段。
  ⚠️ 这个形态最难的地方是**症状与根因不同层**：用户报的是「又重签一次」（听起来像签名次数的问题），
  实际是「另一个 App 的阶段被当成当前 App 的阶段显示」✗。
  ⇒ **判据：阶段信号必须自带主体**（`SigningStageUpdate.subject` = 谁在走这个阶段），
  状态层**按主体分叉** —— 只有属于**会话主体**的阶段才写父会话的显示状态；
  子流程只在自己内部记账（`rotationSubflowStage`）✓。
  ⇒ **同一个陷阱的另一半**：给「属于会话主体」加判据时，**不能顺手把子流程里
  Seal 自替换的「回主屏」也关掉** —— 那条判据是「**Seal** 被覆盖安装」，与父会话是谁无关
  （构建 31 真机：拿会话主体去判 ⇒ 子流程里恒假 ⇒ installd 一直等旧进程让位到 894 秒上限）✓。
  守卫 **R86**（6 断言 + 6 变异）。

- 🔴 **阶段文案宣称一件「绝大多数时候没发生」的事 ⇒ 用户会去做没用的事**（2026-09-26）。
  `.preparingCertificate` 原文案「**正在申请证书**」，而这一阶段实际做的是
  「读远端证书列表 → 查本机有没有对应私钥 → 决定**复用**还是撤销重建」——
  真机日志里紧随其后的是「证书决策：**复用** Apple 生效列表中的本机证书 …976EFE08」，
  即**绝大多数时候根本没有申请**；`.preparingAppID` 的「正在注册 Bundle ID」同理
  （先读已有列表，只对缺失的发注册请求，真机常见「需新注册 0 个」）。
  ⚠️ 同类错法历史上把用户推进过死循环：`.preparingBundle` 曾被算进「正在验证 Apple ID」，
  用户盯着「正在验证 Apple ID 16%」等了两分钟，跑去**重新验证 Apple ID** 然后被限流 ✗。
  ⇒ **判据：写阶段文案时，去日志里找「紧随这一阶段的那一行」** ——
  那一行说的才是这一步真正做的事；文案与它不一致就是错 ✗。
  ⇒ 顺带一条计数口径：`unitsText` 的数字来自「**已就绪**的个数」（复用的 + 新建的都算），
  所以是「已**准备**」而不是「已注册」（`ApplePortalSigningService` 的注释原文：
  「用**已就绪的个数**而不是循环下标」）✓。守卫 **R87**（5 断言 + 5 变异）。

- 🔴 **「为了安全而关掉一条链路」= 把可用性彻底交出去，而它看起来像「更保守」**（2026-09-26）。
  构建 46 的真机症状（「撤销运行中 Seal 的证书 → 自替换失败 → Seal 变砖」）被我判断成
  「撤销本身是根因」，于是在证书轮换的调用点加了「剔除运行中 Seal 的证书」的闸门。
  ⇒ 结果是**免费账号彻底死锁**：免费团队只有 **1 个**活动槽位，而 Seal 自己的证书在
  覆盖安装后**必然**丢失本机私钥 ⇒ 它往往是**唯一**候选 ⇒ 被剔除 ⇒ 抛回
  `SEAL-CERT-204b`（3022 名额满）⇒ **签任何 App、续签任何 App 全部失败**
  （构建 47 真机：LiveContainer / 微信 / Seal 自身三条路径被同一道闸门拦死，
  用户原话「我下载 seal 啥也干不了，全被拦截了」）。
  ⚠️ 这个闸门**有注释论证、有独立文件、有 4 条单测、还有守卫 R84⑥ 钉着它** ——
  整套「看起来像设计如此」的包装，让「链路整体不可用」看起来像一个安全决定 ✗。
  ⇒ **判据：动「要不要允许某个破坏性动作」之前，先问「不允许的时候，还有没有出路？」**
  —— 若答案是「没有」（免费账号只有一个槽位），那就**不是**在收紧，而是在**关停** ✓。
  ⇒ 正确形态是**排好顺序 + 说清后果 + 准备恢复**，不是「不做」：
  ① `SigningCertificateMaterialPolicy.rotationRank` 把 Seal 的证书**排到最后**
  （只有别无选择才轮到它）；② 撤销前必须发 warning（讲明「Seal 将在本事务末尾重装」）；
  ③ 撤销后由 `resignAppsAffectedByCertificateRotation(includeSeal: true)` 在末尾恢复。
  ⇒ 真凶是**自替换安装失败**（构建 38 / 46 的 `SEAL-SELF-109`），不是撤销本身 ——
  **认错一个环节会把整条链路一起赔进去**，这就是「根因没找准就动手」的代价 ✗。
  ⇒ 同族（同一个 bug 的另一半）：`CertificateTakeoverPolicy` 的**规格**也写着
  「真实签名者 A 永远不能成为撤销候选」，且有单测 `fullSlotsWithOnlySignerBlocks`
  断言「只剩 A 一张时必须 blocked」—— 那正是把死锁**钉成了契约**。
  ⇒ **规格与运行时必须一起改**，否则下一个人照着规格去「修」运行时，死锁就会回来 ✓。

- 🔴 **按「码的形态」归因 ⇒ 把所有问题都算到同一个嫌疑人头上**（2026-09-25）。
  `AppsViewModel.settingsRoute` 里一条 `hasPrefix("SEAL-INSTALL-") { return .localDevVPN }`
  就把安装族**几十个**错误码全路由到 VPN 设置页 —— 设备存储不足、免费账号 3 应用上限、
  DRM 残留、安装超时、签名包损坏、需重启 Seal 全在里面。
  用户点弹窗上唯一的「恢复」按钮被送到一个**解决不了他问题**的页面。
  ⚠️ 这个形态**不报错、不崩、界面看起来也「有引导」**，所以长期没人发现。
  ⇒ **判据：写「错误码 → 某个去处」的映射时，问一句「我判的是这条错误码的
  哪个属性？」** —— 判**前缀 / 数字区间 / 模块名**都是判形态；只有
  「**这条提示的文案本身在让用户做什么**」才是判语义 ✓。
  ⇒ 落地形态：**显式码集合 ＋ 一个同源闸门**（凡 recovery 文案写着「去检查 LocalDevVPN」
  的失败，其 code 必须在集合里）—— 否则「文案让用户去查 VPN，却没有按钮能送他过去」。
  ⇒ 同族：AGENTS.md §3 早就写着「错误码 → 按钮动作必须用显式码集合，禁止
  `hasPrefix("SEAL-INSTALL-71"/"72"/"73")` 这类数字区间」—— 本次的缺陷正是同一条规矩的
  **另一半**（数字区间换成了**完整前缀**，看起来更「安全」，其实一样是判形态）✗。
  同族第三处：**过时文案**（「付费账号会自动拉起内置隧道」，而内置隧道已移除）——
  文案与代码注释**互相矛盾**时，用户会按一条不存在的路径排查。
  ⇒ **删掉一个机制时，要全仓 grep 它的名字（含用户可见文案）**，别只删实现。

- 🔴 **「按身份一刀切」会把一条链路**永久**关掉，而且看起来像「设计如此」**（2026-09-25）。
  `ProfileOnlyRenewalPolicy.evaluate` 第一句 `guard app.isSeal == false else { … }` 让 Seal
  **永远**用不上「只换描述文件」的快路径 ⇒ 每次续签都必须**自替换**（重新签名 + 覆盖安装自己）
  ⇒ 进程被系统换掉 ⇒ 批量续签队列项留在 `running` 就消失、变成未知（`SEAL-RENEW-007`）。
  ⚠️ 这个豁免**不报错、不崩，还专门有一条单测钉着它**
  （`sealAlwaysRequiresTheExistingFullResignRoute`）⇒ 它把「Seal 必须走完整重签」
  变成了一个**恒真的默认结论**，读代码的人看不出那是一条限制。
  ⇒ **判据：写「某某对象不适用」的豁免时，先问「这条路径对它真的不可行，还是只是没试过？」**
  —— 前者要写明理由与代价，后者就是缺口 ✓。
  ⇒ **别为豁免写「断言豁免存在」的单测**：那等于把限制固化成不变量 ——
  本次删豁免时，正是那条单测第一个报红（它成了唯一「记得」这个限制的地方）。
  同族：把判据从「**记录是否完整**」改成「**这是谁的应用**」＝ 用身份替代事实。

- 🔴 **「本规则的锚点全对」≠「我改的那一行的锚点全对」**（2026-09-24，白跑一轮 11 分钟）。
  为 R65 把 `"App ID 阶段开始：\(extensionProfileStrategy == …)"` 改成
  `\(resolvedExtensionProfileStrategy == …)`（正当改动 ✓）—— R65 自己的 **19 条锚点全对**、
  R65 专用预检**全绿**；而**同一行**还被 **R31**（「Phase 1 的入口必须先留痕」）的锚点钉着
  ⇒ 守卫跑到 **11 分钟后**才报 `Mutation anchor missing: ApplePortalSigningService.swift` ✗✗。
  ⇒ **判据：锚点是「按行」钉的，不是「按规则」钉的** —— 改一行前要问的是
  「**这一行**被几条规则钉着」，而不是「我这条规则的锚点要不要改」✓。
  ⇒ 落地：**别再手写「本规则的锚点清单」做预检** —— 它**结构上**看不见别的规则 ✗。
  改成**全量锚点扫描**（`~/.workbuddy-ai/tmp/guard-anchor-precheck.py`，**5 秒**）：
  用 `ast` 把守卫自己的 `mutations` 抽出来，逐条验证 `old in 目标文件`
  —— 与守卫的判据 `if old not in original` **完全等价**，但不用跑 268 次变异模拟。
  ⚠️ 抽 `mutations` 的三个坑（都踩了）：① 守卫里是 `mutations = […]` **再加**
  `mutations += […]` **两段**（只抓 `ast.Assign` 只得 **53/268** 条 ✗）；
  ② **不能用 `ast.literal_eval`**（锚点里有 `+` 拼的跨行字符串，如 R37 那段 Mach-O 头部
  ⇒ 遇 `BinOp` 报 `ValueError`）⇒ 自写小求值器（含 `Call(chr, …)`，守卫用 `chr(34)` 塞双引号）；
  ③ **不能用 `exec` 加载守卫**（头部 `Path(__file__).with_name(...)` ⇒ `NameError`）
  ⇒ 用 `runpy.run_path`。

- 🔴 **`Dictionary(uniqueKeysWithValues:)` 用在「键可能重复」的地方 = 崩溃开关**（2026-09-24）。
  为「共享主描述文件装不装得下扩展能力」新增能力集时用了它，而**同一个函数里**早有一份
  等价的、用**赋值式累加**写的循环（`requestedEntitlements`）⇒ 两处形状不一致：
  键重复时前者 **trap（崩溃）**、后者静默取后者 ✗。
  ⇒ **判据：「由某个映射/集合生成的序列」当键时，默认它**可能重复**（本仓扩展 ID 有
  「哈希缩短」路径，理论上存在碰撞面）⇒ 用赋值式累加，别用 `uniqueKeysWithValues` ✓。
  **同族自查：`grep -rn "uniqueKeysWithValues" Seal/`**（本仓另有 5 处）——
  每处都要问一句「键来源会不会重复、重复了是崩溃还是可接受」；
  ⚠️ 但**别顺手全改**（最小改动纪律）：形状与所在函数已有的写法对齐即可。

- 🔴 **「守卫文件在 diff 里出现过」≠「新功能被守卫覆盖了」**（2026-09-24）。
  实例：1.3.5 引入 `AppExtensionProfileStrategy`（普通 IPA 共享主描述文件以省门户配额）时，
  作者**确实**动过守卫 —— R26/R31 的文案跟着 `mappings` → `portalMappings` 改名同步了 ✓
  ⇒ 于是「守卫文件被改过」看着像已维护，但**新符号在守卫里零命中**：
  `grep -n "extensionProfileStrategy" Scripts/verify-release-safety.py` = **0** ✗。
  ⇒ **判据：别问「守卫动过没有」，要问「这个新符号/新判据在守卫里有没有断言」** ✓ ——
  直接 `grep -n "<新类型名>" Scripts/verify-release-safety.py`，**零命中就是零覆盖**，
  与「文件被改过」无关。
  ⚠️ **该补的往往是「消费链路」而不是「本体」**：本体有单测，消费点没有。
  本次 12 条断言里有 7 条钉的是「策略有没有被真的用上」（门户映射 / 嵌入校验 / 重签分流 /
  记录键 / 落回记录），这些错了**不报错、不崩**，只在真机上表现为「又慢又费配额」
  或「签名整体不可用」⇒ 编译与单测**都挡不住**。
  同族：本文件「只声明依赖不等于接上了」那条。

- 🔴 **交付产物的校验清单：「内容对」≠「能用」**（2026-09-21，同一族第三次）。
  `sha256sum -c` 的**验收动作只能是拿目标工具真的跑一次全 OK** ✓；
  「哈希值看着对」不算验收 ✗ —— 已发生的两个实例**哈希本身都是对的**：
  - ① `-Encoding ASCII` ⇒ 中文文件名被替换成 `Seal????.exe`（2026-09-20 修）；
  - ② `Set-Content` 在 Windows 上**固定写 CRLF** ⇒ 文件名后多一个 `\r`（2026-09-21 修）。
  两次都出在**生成侧**（`pairing-assistant.yml` 用 PowerShell 写清单），也都**只有真去 `-c` 才暴露**。
  ⇒ 写这类生成步骤时，**编码与行尾都要显式指定**，别依赖默认值：
  `[System.IO.File]::WriteAllText($p, $text, [System.Text.UTF8Encoding]::new($false))`，
  文本里的换行写反引号 n ⇒ 一次同时避开 CRLF 与 BOM ✓
  （⚠️ **PS 5.1 的 `UTF8` 带 BOM**，与 CRLF 一样会让 `-c` 失败）。

- 🔴 **有外层重试的地方，内层预算必须短**（2026-09-20 真机，构建 184）。
  「就绪探测」跑在外层重试循环里，却各自用了**一次性路径**的长预算 ⇒ 真机界面卡
  **12 分钟以上**没结论 ✗，而且**设备不可达时每轮都走满**（最坏路径恰好是最常见的那条 ✗）。
  - 具体：`MinimuxerInstallChannel.diagnose()` 的设备探测是 `for attempt in 0..<36` ＋ 500ms
    睡眠（**注释写明意图 = 给 RSD 握手约 18 秒** ✓），但每轮里的 `Minimuxer.ready()` 都要走
    `Device.getFirstDevice()`，而它默认轮询 `deviceFetchTimeoutMs` = **15 秒**才抛 `NoDevice`。
  - ⚠️ **「等待」和「代价」是两件事，别混成一个数**：
    - **等待** = 「外层有界等待」与「内层预算」中的**较小者**。`isReady()` 外面套着
      `offThread(5 秒)` ⇒ 修复前每轮只等 5 秒（＋0.5 s 睡眠 = 5.5 s）⇒ 名义 **≈ 3.4 分钟**。
      **那 15 秒从来没有延长过等待** ✗ —— 这条我前三版全写反了。
    - **代价** = 每轮**丢掉一个还在跑 15 秒的后台阻塞调用**（`offThread` 超时后它继续跑），
      它一直占着 Swift 协作线程池的线程，把后续 `Task.sleep` 与计时器的恢复一并推迟
      ⇒ **实测 12 分钟以上**（≈ 每轮 20 秒）就是它。**修复把它缩到 1 秒才是关键那一刀** ✓。
  - ⚠️ **「可能很贵的调用」≠「一定会被调用」** —— 算「最坏耗时」前必须**逐行读控制流** ✓
    （`readyDeviceIdentifier()` 第一行 `guard await isReady() else { return nil }` ⇒
    `ready()` 为假时 `fetchUDIDDetailed()` 根本不会被调用）。
  - 修复后（构建 **186**，探测改用 1 秒）⇒ **约 20–60 秒**：隧道没通 ~20 秒（每轮 0.5 秒）、
    隧道通了只差设备 ~56 秒（每轮 1.5 秒）✓。**循环外的固定开销（~2 秒）也要算进去** ✓。
  - **判据**：给一个循环加超时前，先问两句 —— ①「**内层一次调用最坏多久**」（决定要不要缩预算）；
    ②「**超时之后那个调用还会跑多久**」（决定它会不会把线程池占住、反过来拖长墙钟）✓。
  - 附带一条**顺序**规则：`ready()` 原实现**无条件**先跑最贵的 `getFirstDevice()`，
    再拿它和便宜判据一起进逻辑与 guard ⇒ **最坏路径最慢** ✗。
    **逻辑与的判据要按「便宜 → 贵」排序**，便宜的那侧已经为假就直接返回 ✓
    （守卫 **R61** 按**下标顺序**钉住，因为「只查短预算」会被上游顺序骗过去 ✓）。
- 🔴 **给带非 ASCII 文件名的产物生成校验清单，绝不能写成 ASCII 编码**（2026-09-20，配对助手产物）。
  `.github/workflows/pairing-assistant.yml` 用 `Set-Content … -Encoding ASCII` 写
  `SHA256SUMS.txt` ⇒ PowerShell 把 `Seal配对助手.exe` 里的中文**逐个替换成 `?`**，
  清单里变成 `Seal????.exe` ✗ —— 用户 `sha256sum -c SHA256SUMS.txt` 直接报「没有那个文件」✗。
  ⚠️ **哈希本身是对的**，所以这个错**看不出来**：只有真去 `-c` 校验才暴露
  （我是在交付前手工核哈希时才发现的）。
  ⇒ 改成 `-Encoding UTF8` ✓；⚠️ 但这**只在 shell 是 `pwsh`（PS 7）时成立** ——
  PS 5.1 的 `-Encoding UTF8` **会带 BOM**，BOM 同样会让 `-c` 失败 ⇒
  那种环境要写 `[System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))`。
  **判据：产物校验清单必须能被 `sha256sum -c` 直接跑通** ✓（**哈希对 ≠ 清单可用** ✗）。
  ⚠️ 同一个文件里 `[Text.Encoding]::ASCII.GetString(...)` 查 PE 头是**正当用法** ✓，
  别顺手把它一起「修」了。
- 🔴 **校验清单的行尾必须是 LF —— CRLF 会让 `sha256sum -c` 把 `\r` 当成文件名的一部分**
  （2026-09-20，与上一条**同一天、同一类缺陷的第二个实例**）。Windows 上用编辑器 / Write 工具
  直接落盘会写出 CRLF ⇒ `-c` 报
  `sha256sum: 'Seal配对助手.exe'$'\r': No such file or directory` ✗ ——
  ⚠️ **哈希同样是对的**，还是那个陷阱：**「文件内容对」≠「文件可用」** ✗。
  ⇒ 落盘后 `sed -i 's/\r$//' <清单>`（或用 `printf` 写）；**交付前 `sha256sum -c` 必须真的跑一遍** ✓。
  ⇒ 判据合并成一句：**产物校验清单的验收 = 拿目标工具真的跑一次 `-c` 全 OK**，
  而不是「哈希值看起来对」✗（编码坑与行尾坑都是这么漏过去的）。
- **iOS 有一条硬性 CPU 预算：任意 180 秒窗口内，App 的 CPU 时间不得超过 90 秒（50%）**（2026-09-19）。
  超了**不是抛错、不是崩溃**，而是被系统**直接终止** ✗ —— 日志**来不及 flush**，
  所以现象是「**日志戛然而止**」，看起来像闪退，但崩溃日志里根本没有异常栈。
  **判据**：崩溃日志文件名是 `Seal.cpu_resource-*.ips`、`bug_type 202`，正文写着
  `Event: cpu usage` / `exceeding limit of 50% cpu over 180 seconds` ✓。
  ⇒ **签名一个「大包 + 多扩展」的 App（抖音：780 MB + 8 扩展）会正好把预算撑爆** ✗。
  ⇒ **任何本地耗时优化都要按「CPU 秒数」而不是「墙钟秒数」来评估**：
  实测（构建 147）解压 7–11 秒 + 归一化 30–35 秒 + 瘦身 2–5 秒 ≈ 50 秒 CPU，
  再加上重签（对全部 Mach-O 做 SHA-1/SHA-256 页哈希）就突破 90 秒 ✗。
  ⚠️ 同一次崩溃里 `Footprint: 152.94 MB -> 1109.84 MB (+956.91 MB)` ——
  内存**不是**这次的死因，但已到需要警惕的量级 ✓。
- **「长任务没有日志」要先分清是「没埋点」还是「埋了但没落」**（2026-09-19）。
  `signing` 阶段一行日志都没有，两个原因叠在一起：
  ① Seal **从来没打开**签名器自带的 `SigningDiagnostics`（`AppSigningOptions.diagnostics`
  默认 `.disabled`）⇒ **根本没有那几行**；
  ② 进程被 CPU 预算杀掉 ⇒ **即使有也来不及落盘**。
  ⇒ 处置完全不同：① 接线（`d07b42f`）；② 减少 CPU 或分批。
- 🔴 **发布时别走错档：`ios-release.yml` 是「快速档」，签名器/RustBridge/安装链路的大改动必须走完整档**（2026-09-20）。
  `ios-release.yml` 的**文件头自己写着**：跳过模拟器 UI 回归与 **`signer-tests` 测试门**，
  用于「**只改了 Swift 业务逻辑、没动 Rust 桥/签名器**」的小版本快速出包 ✗；
  **大改动仍须走完整 iOS workflow** ✓。
  ⇒ **1.2.0 换了签名器** ✗ ⇒ 应走 **`ios.yml`** 的 `publish-release`
  （`needs: [build-package, signer-tests, swift-regression]` ✓ —— 两个门都在 ✓），
  **不是** `ios-release.yml` ✗。
  **判据：发布前先读那个 workflow 的头部注释** ✓ —— 本仓把「这档能用来干什么」写在文件头 ✓
  （和「刻意不 reset」那条同源：**理由都写在注释里** ✓）。
- 🔴 **换一个「值」时，先数清有几条路径在用它 —— 短链是不透明的，看不出它指向谁**（2026-09-20）。
  「加入 QQ 群」有**两条路径** ✗：`mqqapi://…&uin=<群号>&card_type=group`（**主路径**，QQ 装了直接开群卡 ✓）
  ＋ 短链 `qm.qq.com/q/XXXX`（只在 **QQ 没装**时兜底 ✓）。
  用户给的新短链 `https://qm.qq.com/q/8HfHpTmOzu` 解析出来是**另一个群**（群号 `1051135067`、
  群名「Seal 官方群」✓），而代码里 `qqGroupNumber` 还写着旧群 `1093450608` ✗
  ⇒ **只换短链 ⇒ 主路径照样跳进旧群** ✗✗。
  **⚠️ 短链是不透明的** ✗ —— 从 `qm.qq.com/q/XXXX` **看不出**它指向哪个群 ✓，
  必须**抓落地页**才拿得到（`群号: <digits>` / `"groupcode":"<digits>"` / 头像 URL `qlogo.cn/gh/<digits>/` ✓）。
  **判据：换链接/换 ID 之前，先 grep 出「这个值的所有使用者」** ✓（本仓第 6 次同族 ✗）；
  ⚠️ **且「两处指向同一个群」无法静态校验** ✗（要联网解析短链 ✗）⇒
  只能靠**代码注释**（已写 ✓）＋ 守卫 **R59**（钉「两条路径都还在」✓）＋ 本条台账 ✓。
- 🔴 **给 struct 写 `var description` **不会**让字符串插值用它 —— 必须显式遵循 `CustomStringConvertible`**（2026-09-20 真机踩到）✗。
  我给诊断加了个 `TimedProbe`，里面有 `var description: String`，以为 `"\(timedProbe)"` 会用它 ✗ ——
  **实际走的是合成的 memberwise 描述** ⇒ 真机日志里打出来的是
  `TimedProbe(probe: Seal.…InstallProbe.unavailable, seconds: 2.40802764…812e-05)` ✗
  （而且长到被日志行**截断** ✗）⇒ **诊断反而把日志变难读了** ✗✗。
  ⇒ 修法：`struct TimedProbe: CustomStringConvertible` ✓（`description` 才会被插值采用 ✓）。
  **判据：任何「自定义描述」的类型，第一件事就是确认它遵循了 `CustomStringConvertible`** ✓；
  ⚠️ **这类退化是静默的** ✗ —— 编译过、跑得动、断言全绿，**只有真机日志里才看得出来** ✗
  ⇒ 必须**加守卫**（本仓已加 **R58b** ✓）。
  **⚠️ 更一般的教训：加诊断 ≠ 诊断可用** ✓ —— 诊断上线后**第一次拿到真实日志时，
  要把它当「输出」验收**（能读吗？被截断了吗？会不会反而更难查？）✗，
  别默认「我加了就一定有信息」✓。
- 🔴 **别把「刻意不覆盖」当成「漏掉」—— 判「同一规则只覆盖一条路径」之前，先读另一条路径的注释**（2026-09-20）。
  我查到 `removeProfiles` 里两条路径待遇不同：`dumpProfiles` 有**有界重试**
  （`Provision.resetProvider()` ＋ 等 4 秒 × 3 次 ✓），而**阳性对照是单发** ✗ ——
  加上真机证据（两次中止同行都带 `dump 尝试 2/3 次` ⇒ 列描述文件那条路径重试了 2–3 次才成功），
  我判断这是「同一已知条件只给一条路径加防护」（本仓已有 4 次前科 ✗），
  **并打算照抄 `dumpProfiles` 给阳性对照加 reset ＋ 重试** ✗。
  **结果在动手前读到 `probeInstalled` 上面那段注释** ✓：

  > **刻意不调 `Install.resetProvider()`**（虽然 `InstalledAppDeviceVerifier` 会调）：
  > 本函数跑在「刚装完一个 App」与「自替换结算」两个时间点上，此刻可能有
  > installation_proxy 连接正在服务，重置会把它拆掉（**R05**）。缓存连接失效的代价
  > **已经由阳性对照兜住** —— 那种情况下对照会抛错或答错，**直接中止整轮，方向是安全的**。

  ⇒ **阳性对照「单发」是刻意的** ✓，而且**不 reset 正是为了不触发 R05** ✗ ——
  两个调用点的**语境不同**：`InstalledAppDeviceVerifier` 跑在**安装完成之后**（可安全重置 ✓），
  而 `DeviceProfileCleaner` 跑在**安装前后**（重置会拆掉正在服务的连接 ✗）。
  **判据：判「这条路径漏了防护」之前，先 `grep -n '刻意\|不要\|禁止' <那个函数上方 30 行>`** ✓ ——
  本仓大量「看起来该统一、其实刻意不统一」的决定**都写在注释里** ✓；
  读不到理由 ≠ 没有理由 ✗（而按错的结论去改，会**破坏一条已经想清楚的安全边界** ✗✗）。
  ⚠️ **同一轮里我连续两次「结论没落在代码上」**（先误判阳性对照挑错 ID、再误判重试漏覆盖 ✗）——
  **两次都靠动手前读代码拦住** ✓ ⇒ **结论必须引用代码原文，而不是日志里那个字符串** ✓。
- 🔴 **新加一个 CI 门禁时，要预期它「第一次跑就红」—— 而且红的原因很可能在上游**（2026-09-20）。  换签名器后把 `rork-sign-tests` 改成 `signer-tests`（测 `CodeSignKit` ＋ `SideSign`），
  **首次运行**就红 ✗ —— 但红的不是我们的改动：
  `Vendor/SideSign/Tests/SideSignTests.swift` **上游自己就没写 `import Foundation`** ✗
  （`cannot find 'FileManager' in scope` ✓），另有一处 `entries.map(\.filename)`
  的 key path 推断失败 ✓。**那套测试上游大概从来没跑过** ✓。
  ⇒ **判据：新门第一次红时，先分清「我的改动坏了」还是「这个门第一次照出了既有问题」** ✓
  （看错误行落在**我们没碰过的文件**里 ⇒ 是后者 ✓）。
  ⇒ 处置看**价值**：`SideSign` 剩下的用例只测 `Device` 模型与 `Archive` 往返，
  而 **Seal 完全不用 `SideSign.Archive`** ✓ ⇒ 零价值 ⇒ **收窄门禁**（删掉那一步 ✓），
  **不要为了让它变绿去给上游打补丁** ✗（用户死命令「不要打补丁」✓）。
  ⚠️ 同一个门里 `CodeSignKit` 那步是**全绿**的 ✓ —— **门禁要分步，别把两个包塞一个 step** ✗，
  否则一个包的缺陷会掩盖另一个包的结论 ✓。
- 🔴 **删一个 vendor 目录里的一层时，要顺着依赖把「编译不过的残留」一次删干净**（2026-09-19）。
  删掉 `Vendor/SideSign` 的 anisette / 门户两层之后，**同一个仓库里还剩两处残留** ✗：
  `CLI/`（`import AnisetteKit` ＋ `DeveloperPortal` / `CertificateRequest` ✗）与
  `Tests/SideSignTests` 里 2 个用例（引用同一批已删类型 ✗）。
  ⇒ **它们不参与 App 构建**（`project.yml` 只引 `product: SideSign` ✓）⇒ **CI 照样全绿** ✓，
  所以**不会自己暴露** ✗ —— 只有有人在该目录下跑 `swift build` / `swift test` 才会炸 ✗。
  **判据：删完一层之后，`grep -rn '<被删类型>' <那个 vendor 目录>` 必须为空** ✓
  （`Sources/` ＋ `CLI/` ＋ `Tests/` ＋ `Package.swift` 四处都要查 ✓）。
- 🔴 **换掉一个「会打补丁的依赖」时，先把它带来的独有能力逐项列出来**（2026-09-19）。
  换签名器丢掉的不只是代码，还有**三项能力** ✗：① 签名缓存（`SigningCacheOptions`）
  ② 逐 bundle 诊断（`AppSigningOptions.diagnostics`）③ FairPlay `cryptid` 清零补丁。
  ⇒ 前两项让**性能与可观测性变差**（大包 CPU 预算更紧 ✗、日志里看不出死在哪个 bundle ✗），
  第三项是**「装完启动崩」** ✗✗。
  **判据：换完先写一张「丢了什么」的表**（本仓落在 `docs/upstream-alignment.md` 第九节 ✓），
  并逐项标成**待真机验证** ✓ —— 否则这些能力是**静默消失**的 ✗
  （不崩、不报错、守卫全绿，只有真机上才知道 ✗）。
  **判据：先在崩溃日志里找 `Event:` 那一行**，别一上来就怀疑代码崩了。

- **用别人的函数当判据之前，先读它的实现**（2026-09-19）。`InstallStageTimeline.tick(entering:currentStage:)`
  看起来像「阶段是否切换」✗，实际只对 **`.installing`** 返回 `.restart`（其余一律 `.clear`）——
  它是「**安装计时起点**」的簿记。拿它当阶段日志的闸门 ⇒ **只有 `installing` 会落日志** ✗
  （真机实测整份日志只有 1 条 `SEAL-STAGE-001`，正是 `installing`，完全印证）。
  ⇒ **名字像什么不重要**；把某个函数当判据前，先读它的实现，或先问「它的返回值域覆盖我需要的所有情况吗」。
  同族：`Minimuxer.lookupApp` 的 `String?` 把「没装」与「查询失败」折叠成同一个 `nil` ✗。
- **anisette 是「一次性快照」，不是「会话」**（2026-09-19）。`ALTAppleAPISession` 这个名字
  让人以为它该复用一整轮 ✗，但里面的 `X-Apple-I-MD` 是**有效期只有几十秒的一次性验证码** ✗。
  任何**长时间本地工作**（解压 / 全树遍历 / 打包，抖音要 105–120 秒）之后再用它，
  Apple 一律判会话异常返回 **1100**（Seal 侧渲染成 `SEAL-AUTH-102c`）。
  ⇒ **判据：本地工作超过约 30 秒，之后就必须重新 `anisetteProvider.fetch()` 并重建 session。**
  ⚠️ 这条极难从日志看出，因为**失败点在时间上离真正的病根（取 anisette 的那一刻）很远** ——
  唯一可靠的线索是「gap **之前**的请求全部成功、gap **之后**的第一个请求立刻 1100」。
- **加日志埋点时，「埋了」不等于「会落」**（2026-09-19）。给 `updateSigningStage` 加了阶段日志，
  自认为埋好了，真机一验 —— 整份日志只有 2 条 ✗。两个原因叠在一起：
  ① 它排在 `guard signingSession != nil` **之后**，而**批量续签走 `BatchRefreshSession`、
  `signingSession` 可能为空** ⇒ 整段 return；
  ② 闸门用错 API（见上）。
  ⇒ **埋点写完，下一次拿到真机日志的第一件事是验收埋点**，并且要问
  「**用户最常走的那条路径**有没有数据」✓。

- **证书序列号跨来源比对必须归一化**（strip leading zeros），否则会用不同表示误判「证书被轮换/不在授权列表」。
- **「进度条停在某个 % 不动」有两种成因，先分清是哪一种**：① **阶段推进没到**（回调没发 / 被闸门跳过）—— 这时要顺着阶段切换链路查，别盯着百分比；② **进度值里没有时间项**（阶段推进正常，但数值只是阶段枚举的纯函数，所以只能冻结 + 跳变）—— 见下一条。两者现象都是「卡住」，处置完全不同：① 修阶段推进，② 改数值模型。
- **「进度条跳着走 / 像卡住」的根因通常是「进度只是阶段枚举的纯函数」，不是动效参数**。Seal 的进度环与底部 5 格轨道原先都是 `SigningStage` → 写死常数（10 个阶段 10 个数，**没有任何时间项**），所以两次阶段推送之间界面只能冻结、阶段一变就跳一格；而同一套语义还写在**三处 switch** 里（`segmentFraction` / `overallProgress` / `timelinePosition`），改一处漏两处不报错。⇒ **判据：先问「这个百分比里有没有时间项」**。修法是「一张预算表（地板 / 天花板 / 时间常数）+ 阶段内指数收敛」，并把「已确认」与「估算」画成**两种笔触**（深色弧不随时间变化、浅色弧永远不自己走到终点），再给当前格加一条**不推进百分比**的扫光 —— 「后端在干活但界面不动」只能靠这个信号消解，假百分比消解不了。⚠️ 三条硬约束：① **上界必须严格小于下一阶段的起点**（`ceiling_i == floor_{i+1}`），否则阶段切换时数字会跳或往回退；② **加逐帧驱动（`TimelineView`）时必须撤掉原有的 `.animation(_:value:)` 与 `repeatForever`** —— 每个 tick 触发一次补间，观感是黏滞 + 抖动，比不做动画更糟；③ **不要给「不可知且可能很长」的阶段插值到 100%**，慢设备上会出现「100% 了却还没装完」，比不给进度更伤信任。
- **`rg` 查询带再加工时，行号输出用 `-n`，别拿 `-r` 当行号**。
- **证书轮换 / 证书自动清理两条撤销路径都要各自守住「无法确认 Seal 真实签名证书就禁止撤销」**，缺一条就会误删 Seal 自己的命根子证书。
- **iLoader 等第三方签名工具产出非标准签名结构/描述文件**，Seal 的 `AppBundleSigningIdentityReader` 可能读不出真实 CMS 签名者，会连锁触发 SEAL-CERT-232 / SEAL-SELF-105，只能电脑覆盖安装兜底。**允许放宽的只有「CodeDirectory 全量哈希校验」（第三方改结构导致哈希对不上属正常），身份识别仍必须落在「一致 signer serial」+ `signerNotAuthorizedByProfile`（serial 须在描述文件授权证书内）双校验上；任何「连 signer serial 都读不出仍继续签名」的弱化都是明令禁止的**——那会直接导致误删 Seal 自己命根子证书。
- **改动核心语义（签名/证书/续签）时，老的同名单测往往断言的就是正要被替代的行为**。改实现后云构建的 `swift-regression` 就会在这些测试上红（exit 65），而 `build-package` / `rork-sign-tests` 仍绿。动手前先 grep 相关 `SealTests/**/*Tests.swift` 核对断言，并与实现改动同步更新到新设计，避免「改实现 → 推一次 → 只有这里红 → 再修测试推一次」的双倍等待。
- **`verify-release-safety.py` 的守卫会按字符串断言 UI 结构**。改动证书页/证书展示相关代码时，先跑一遍守卫（Windows 上也能跑），它会直接点名「哪条断言 + 哪个变异锚点」失效；改动是有意为之就同步更新守卫（连同变异锚点），**不要为了过守卫把实现写回去**。
- **同一实体的两处 UI 展示必须同源**。同一张证书的「关联了哪些 App」曾出现行标签用 `associatedApps`（含扩展 target）、下方清单用 `affectedApps`（只看顶层 serial + `state == .installed`）两套判定，结果自相矛盾（标签说在用、清单说暂无），Seal 自身因 `belongsInInstalledList` 恒为真且 `state` 不一定是 `.installed` 尤其容易被漏掉。**展示口径要复用同一个函数**；撤销影响评估仍走更严的 `affectedApps`，两者不可合并。
- **私有 selector + `guard responds(to:) else { return }` = 静默 no-op**。Seal 自续签的「回主屏」原来只有一条 `perform("suspend")`，不响应时什么都不做，最后由 installd 杀进程 —— 用户观感就是「闪退」。凡是靠私有 API 实现的可感知行为，都必须有兜底路径（此处是 `UIControl().sendAction(_:to:for:)` + `exit(0)`），不能静默返回。
- **「卡很久」的排查方向是「该并行的被串行等了」，不是「超时太长」**。签名/续签曾卡在「正在连接设备」很久：`SigningCoordinator` 里已经做了隧道与签名并行，但 `AppsViewModel.runSigning` 在更早的位置 `await refreshSigningChannel()` 把整段诊断又同步等了一遍，并行化对首个调用完全失效。**改并行化时要顺着调用链往上游找还有没有第二次同步等待**；并发启动同一通道还要在通道层做单飞合并，否则重复诊断、耗时翻倍。
- **批量入口解阻塞的前置条件是「下游有熔断」**。`startBatchRefresh` 的前置 `await refreshSigningChannel()` 看着像冗余，其实是保护：`MinimuxerInstallChannel.startOnce` 失败时**不写缓存**，去掉等待后通道不可用会让 N 个 App 各跑一遍 75s 诊断（N×75s）。**要解阻塞必须先在通道层加失败熔断**（失败后 60 秒窗口内直接抛同一错误），并且熔断只能挡「同一轮批量内部」的连续调用 —— 用户发起的会话（`runSigning` / `startBatchRefresh` / `refreshSigningChannel`）都要显式 `clearFailureCooldown()`，否则用户修好 VPN 再点也被秒拒，看起来像 Seal 坏了。
- **只在 extension 里给方法默认实现 = `any Protocol` 静态派发到空实现**。`clearFailureCooldown()` 若只写在 extension，`any InstallChannel` 会调用默认空实现，具体实现的覆写永远不执行，表现是「用户手动重试一直被拒」而守卫全绿。**凡是需要动态派发的行为都必须声明为 protocol requirement**（本仓 `install(onProgress:)` 已踩过一次，现已加守卫断言锁住）。
- **Apple 免费账号的 `1100 session expired` 多数是「限流被掐断」，不是真过期**。抖音（主 App + 8 扩展 = 9 个 bundle ID）在 App ID 阶段连发 9 次 `addAppID` + 9 次 `updateFeatures`、再连发 9 次描述文件申请，二十余次密集请求会触发 Apple 掐断会话。**判据：报错前 1–3 秒若有「证书决策」成功，说明 session 服务端仍有效**（同一账号几分钟前刚成功签过别的 App 也是同一证据）。此时引导用户「重新验证 Apple ID」是死循环 —— 重新登录后密集请求再次触发限流。对策是请求节流 + 对 1100 退避重试，且 **App ID 阶段的 1100 文案必须与 account 阶段分开**（前者给「稍后重试」，后者才给「去重新验证」）。
- **错误分类禁用子串匹配**。`diagnostic.contains("1100")` 会把形如 `com.example.app1100` 的 Bundle ID 报错误判成「会话过期」，把「Bundle ID 不可用」错报成「登录过期」。只认错误码 + 官方英文文案。
- **错误映射入口有多条，判据与文案必须共用一份实现、共用同一个优先级顺序**。Apple 返回 `3018 / requires signing in with two-factor authentication` 时（**密码没问题，只是要输验证码**），界面给的是「重试；如持续失败请核对 Apple ID 与密码」—— 把用户引向一个正确的密码。`AppleAccountClient` 有**三个**映射入口（`make` / `validate` / `failure(from:)`），当时都没有这个分支。**「只在其中一条链路上加」是这类修复最容易犯的错**：不崩、不编译失败，只在真机上重新给出错误引导。判据先认**错误码**（稳定），描述只做兜底（会随语言与措辞变）。顺序也要统一：**最具体的诊断排最前**（双重认证 → 限流 → 网络 → 泛化），两处顺序不一致时同一个错误会给出不同提示。守卫按「每个函数体内两个调用的相对位置」断言，不是「文件里有没有这两个字符串」。
- **「同一条规则只落在两条链路中的一条」——而且守卫也只钉住那一条，于是它一直绿着**。心跳（活性日志）本来只有**自替换**那条安装路径有，普通安装没有；守卫的心跳断言也写的是 `自替换安装仍在等待：`，所以普通链路静默时它照样通过。真机后果：普通安装卡了 **9 分多钟**，日志里从「开始安装」到用户导出**一行都没有**，「还在装」与「死了」分不开。⇒ **加一条链路级的规则时，先数清有几条链路，再检查守卫是不是也只覆盖了一条**。
  **同族已发生 6 次**（每次都是「我以为覆盖完了」的时候）：
  ① `InstallStageTimeline`（单签有闸门、批量没有）；
  ② 错误映射的 `detail` 构造（两份拷贝）；
  ③ 安装心跳（只有自替换那条有）；
  ④ `withSessionRecovery` 的证书创建（当时数出来「3 个 portal 变更」，实际不止）；
  ⑤ `updateFeatures`（Phase 1 每个 bundle ID 发**两次**写请求，只护住了第一次）；
  ⑥ 证书轮换路径的 `addCertificate`（与签名链路各一份，**漏掉的后果最严重** ——
  轮换是**先 revoke 再创建**，创建失败会让账号变成 **0 张证书** ⇒ 用它签过的 App 全部打不开）。
  **数链路的正确姿势是「枚举这一类操作」，不是「数我看到的调用点」** ——
  `grep ALTAppleAPI.shared.` 这类枚举才是起点。
- **「受保护集合」若来自本地记录，那它对「本地记录里根本没有的对象」等于零保护**。旧 Team 后缀 profile 回收的第一道保护是「Seal 记录里出现过的 Bundle ID」，但**重新安装 Seal 之后记录里只剩 Seal 自己**，此时设备上其它 App 的主 App 还能靠设备端核验救下，**扩展完全救不回来**（`isAppInstalled` 对扩展恒为 `false`）。⇒ 判据不能只有「记录里有没有」，还要有「**结构上能不能推断出它属于某个已装对象**」（这里是「父 App 的 Bundle ID + `.` 前缀」）。**新增这类判据时先问：这个集合为空/不全时，谁的错法方向是删数据？** 是的话就必须有第二道与记录无关的防线。
- **「先问完、再动手」比「边问边做」多一层保护，而且常常是必需的**。设备端核验原先边问边删，改成「先问完所有候选、再决定」之后：①扩展判定能用上完整的「本轮哪些候选确实装着」；②中途通道不可信时**一份都不删**（连已经问过的那几条也不删），而不是「删了一半才发现通道坏了」。代价只是本轮不回收，下次维护再来。
- **用户提示里绝不能说「已自动重试」——除非真的重试了**。安装超时文案写着「超过 10 分钟仍未完成，**系统已自动重试**」，而超时路径其实是**原样抛出、不重试**的（R05：底下那次安装很可能还在跑）。用户读到会**继续等一个并不存在的重试**，而正确的下一步是「等一会儿回列表看 App 是不是其实已经装上了」（底层调用确实不会被取消）。同一条里「10 分钟」也是错的：等待上限按包大小算（小包 804 秒、大包 2400 秒）。**判据：文案里凡是「已经帮你做了什么」的说法，都要在代码里找到那件事真的做了。** 这与 3018 那次同族 —— 文案把用户引向错误预期，不崩、不编译失败，只在真机上让人做出错误判断。
- **`section()` 的标记可能被变异删掉 ⇒ 整轮守卫带 Python 栈崩掉**。变异检查会对**每个**变异重跑一遍 `violations()`；只要某个变异恰好删掉了某条 `section()` 的标记（本仓真实一例：`if Self.isTimeoutInstallError(error) {` → `if false {`），`section()` 就会 `raise`，一条失败都报不出来。⇒ 这类**只用于断言**的调用改用 `section_or_empty()`（返回空串 ⇒ 断言失败，既不静默通过也不崩）；变异循环本身也加了兜底，把这种崩溃报成一条可读的失败。**加新的 `section()` 断言后，一定要跑一次完整守卫（含变异）**，只跑断言看不出这个。
- **「脱敏过度」和「脱敏不足」一样是缺陷，而且更难发现**。手机号脱敏模式的字符类里有数字与连字符，于是把 `2026-09-17T06:38:18Z` 里的 `2026-09` 当成号码脱掉 ⇒ **日志里所有 ISO 时间戳的年月都没了**（`2026-09-17` → `20****09-17`）。危害不是「难看」而是「**读不出信息**」：证书的 `notBefore` / `notAfter` 相差一年，脱敏后只差 1 秒，看上去像「到期早于生效」，排查时差点被当成 bug 报上去。⇒ **脱敏规则改完，拿一条真实日志行跑一遍，确认「该留的还在、该去的没了」**——只断言「秘密不出现」发现不了这类问题（`LogPrivacyRedactorTests` 原本只有那一侧）。放宽「日期形状」这类豁免时尤其要小心：**豁免条件越宽，脱敏的口子越大**，所以两个方向都要有单测。
- **两条恢复机制**都对**、但互不知情 ⇒ 同一件事给出三份互相矛盾的结论**。批量续签包含 Seal 自己时，进程必然在队列项还是 `running` 的时候被杀；队列恢复盲目把 `running` 降级为 `unknown`（「1 个应用的结果未知，需要重新核验」），而**结果其实已经写进持久化载荷**了（`succeeded: 2`）—— 于是假警报 + 队列幽灵条目 + 界面同时显示「成功 2/2」。⇒ **降级前先问「有没有更权威的数据源已经给出结论」**；有的话按结论**结算**，只有真没结论的才降级。**顺序也是修复的一部分**：必须先恢复载荷、再结算队列，否则那个 `running` 项在载荷被读之前就被标成未知了。⚠️ 这是「两条链路各说各话」的又一例（此前：`InstallStageTimeline`、错误映射的 `detail` 构造、安装心跳），区别是这次**两条都对**。
- **把判据从「只能内部用」的地方挪出来时，先确认访问级别够不够**。把 `settledQueueStates` 挪到新文件后，它依赖的 `BatchRefreshSession.Item.State` 状态↔字符串映射当时是 **`private extension`（file 级）** ⇒ 新文件**和它的单测**都编译不过（`initializer is inaccessible due to 'fileprivate' protection level`），云构建直接红。**修法不是抄一份**（那就成了「同一条规则两份实现」，迟早漂移成「写进去是 completed、读出来当未知」），而是**把映射搬到类型自己的文件并放开为 `internal`**，让写入侧、读取侧、单测共用一份。⚠️ 顺带：守卫断言别写成 `"extension X {" in ...` —— 它是 `"private extension X {"` 的**子串**，抓不到「被收回成 file 级」；两个条件都要落在**新文件**上。
- **异常日志也要幂等**。只写「异常」不够，还要保证同一条异常**不会每次轮询重复写** —— 重复会把真警报埋掉。实际踩到：`SEAL-RENEW-021` 的判据是「载荷还在 + 会话开着」，而载荷要等抽屉关闭才清 ⇒ 这中间每次 `load()` 都报同一条警告。⇒ 判据里要能区分「**已经处理过**」与「**真的被跳过**」（加显式标志）。
- **加变异锚点时要检查 `old` 在文件里是否唯一**。同一文件里 `let lowered = normalized(bundleID)` + 紧随的 guard 出现了**两次**（`isReclaimableOrphan` 与 `isExtensionBundleID`），只写这两行的锚点会**打到别处**（变异照旧「被抓住」，但抓它的是别的断言 —— 这条锚点其实没在守它想守的东西）。⇒ 锚点带上**函数签名**那一行才唯一。判据：锚点的 `old` 在文件里 `count == 1`。
- **「两份同名」本身就是危害**。设备上长期留着一份陈旧的「Seal」profile，不只是「多一份垃圾」：用户手动清理时会**删错正在用的那一份**（对应 App 立刻无法启动）。⇒ 判断某个「清不掉的东西」要不要修时，除了「占多少空间」，还要问「**它会不会让人做错事**」。
- **不可逆操作失败时，文案必须说清「已经造成了什么」**。证书轮换是「先撤销、再创建」，而创建失败（非 3022）会直接抛出 —— **证书已经没了**，用那张证书签的 App 全部无法启动。旧文案只说「已释放 N 张」+「稍后重试」，于是：①用户不知道 App 为什么突然打不开；②真实原因常是会话失效，「稍后重试」**永远不成功**，把人引向重试死循环。⇒ 文案三问：**发生了什么、已经造成了什么、下一步该做什么**。只答第一问是不够的。
- **统计字段的文案要跟字段语义对齐**。`usedBundleIDCount` 是「已注册存活数量」，却被渲染成「N 个可用 App ID」——日志里 `10 个可用 App ID` 的真实含义是**已用满 10 个**。这直接导致用户「id 有足够的名额」的误判，把排查方向带偏。同一字段在别处（`已签名 n / 10`）写法是对的，**两处口径不一致时以字段定义为准，并统一**。
- **查「某字段有没有被写入」必须同时搜 `字段:` 与 `字段 = ` 两种形式**。只搜 `provisioningProfileUUID:`（构造器标签）会得出「扩展 UUID 从未落库」的错误结论，而真实写入是 `app.extensions[index].provisioningProfileUUID = binding.profileUUID`。**结论依赖 grep 完备性时，先确认搜索模式覆盖了赋值 / 解构 / 下标三条路径**，否则会基于假前提写错修复方案。
- **设备端 profile 的清理范围要按「本次安装实际装上的那一组」算，不能按主 Bundle ID**。一次安装会为**每个扩展**各装一份 profile（抖音 8 扩展 = 9 份）。只按主 Bundle ID 匹配 ⇒ 扩展的旧 profile 从头到尾没人清理（真机：LiveContainer 的 ShareExtension 一天堆 6 份）。反过来也不能把 `Frameworks/*.framework/embedded.mobileprovision` 算进保留集合 —— 它不会被 installd 装成设备 profile，算进去等于给那个 Bundle ID 发免死金牌。
- **扩展包的容器后缀是 `.appex`，不是 `.app`**。写「找出所有会被安装的 bundle」这类谓词时，只匹配 `.app` 会**静默漏掉全部扩展**——守卫全绿、测试也可能绿（如果测试恰好只断言主 App），但扩展清理根本没生效。本仓统一约定是 `pathExtension == "appex"`（见 `SigningWorkspace`、`AppBundleSigningIdentityReader`、`ApplePortalSigningService`），新代码照此对齐。**这类「绿着坏掉」的缺陷要靠「断言目标物确实被包含」的测试抓**：`SignedArtifactProfileReaderTests` 里 `collectsMainAndExtensionProfiles` 断言 `count == 2` 才把它暴露出来，而只断言「framework 被排除」的那条当时是**假通过**。
- **删错一份设备 profile = 对应 App 立刻无法启动**（iOS 启动时会校验 profile 是否还在设备上）。所以「拿不到可信的『该保留哪一份』」时**必须整组跳过**，绝不能猜「保留最新那份」——宁可留着旧 profile 占地方。同理，以记录为删除依据时要注意**乐观值与已安装值的边界**：`SigningCoordinator.applySigningResult` 在**签名阶段**就写扩展的 UUID（顶层 `provisioningProfileUUID` 反而等安装校验通过才推进，见 R08），所以「签名成功但安装失败」时扩展记录指向一份设备上不存在的 profile，拿它当保留集合会删掉真正在用的那一份。
- **守卫用 `"片段" in 源码` 断言时，同一模式出现多次就会失去约束力**。删除步骤从 1 处变成 2 处后，`check("guard gate.shouldAbort(token) == false else" in job)` 在删掉其中一处的变异下仍然通过（被另一处掩盖）—— 守卫变成「永远全绿」，比直接失败更危险。**同一模式出现多次时改为按出现次数断言**（`job.count(...) >= 2`）。这次是变异测试自己把问题暴露出来的。
- **字段存在不等于语义可信**。`AppExtensionRecord.provisioningProfileUUID` 有值，但它的写入时机（签名阶段）比顶层字段（安装校验后）早，两者**可信度不同**。任何「以记录为删除/撤销/覆盖依据」的逻辑，都要先问「这个字段是在哪个时点写的、那时设备上真的换了吗」。
- **`build-package` 不编译测试 target，所以测试代码的编译错误会绕过它、只在 `swift-regression` 红**。本机无 Swift 工具链时，给 `SealTests/**` 加新调用（尤其是构造器）等于「盲写」，一轮 CI 白等 13 分钟。2026-09-16 实际踩到：`error: argument 'ipaRelativePath' must precede argument 'signedArtifactStatus'`（Swift 的 memberwise init **强制实参顺序与声明一致**，漏写中间的默认参数可以，但顺序不能颠倒）。**对策**：守卫 R09 用 Python 解析 `AppRecord` 声明的参数序列，逐个校验所有调用点的标签顺序；**同类坑当天咬了第二次**（给 `signAndInstall` 加 `onInstallProgress` 时写到了 `broadcastsInstallStage` 之后），现已把 R09 通用化为「声明文件 + 声明锚点 + 调用点正则 + 调用点数下限」的列表，覆盖 `AppRecord` / `signAndInstall` / `installSignedIPA` / `installCachedSignedIPAIfPossible`。加新调用前**逐字段对照声明顺序**，别凭记忆。
  **2026-09-17 同类的第三次**：`Set(keepMaps.first?.keys ?? [])` ⇒
  `cannot convert value of type '[Any]' to expected argument type 'Dictionary<String, String>.Keys'`。
  **`Dictionary.Keys` / `Values` 不是 `ExpressibleByArrayLiteral`**，`?? []` 里的 `[]` 会退化成 `[Any]`。
  通用判据：**`??` 右侧用字面量兜底时，左侧必须是可以从该字面量构造出来的类型**
  （`Array` / `Set` / `Dictionary` 可以，`Keys` / `Values` / 其它 `Collection` 不行）。
  已做成守卫的静态检查（含变异锚点）。
- **「进度条停在 X% 不动」要先问「这个阶段到底有没有进度回调」**。iOS 安装阶段（installd 经 installation_proxy 安装）**完全不回报进度**：上传结束（1.01 哨兵）之后到安装完成之间，UI 拿不到任何数值。所以「停在 93%」「卡在传输中」往往不是进度 bug，而是**阶段推进缺失 + 缺少等待说明**。两个界面表现不同只是因为订阅的东西不同：单签订阅 Double 哨兵（能切到 `.installing` ⇒ 93%，然后静止），**批量只订阅 `SigningStage`、根本收不到哨兵**，于是整段停在「传输中」。判据：`SigningProgressView.overallProgress(.installing) == 0.93`、`BatchRefreshView.runningStageTitle(.pushing) == "传输中"`。
- **`guard app.applicationState == .active else { return }` 出现在「自动切后台」流程里是危险的**。`.inactive` 是**瞬时**失焦（控制中心、通知横幅、来电、App 切换器预览、系统弹窗），进程仍在前台。Seal 自续签依赖「旧进程让出前台」才能被 iOS 完成替换，把 `.inactive` 当「用户已离开」直接 return，会连 `exit(0)` 兜底一起跳过 ⇒ 界面永久停在 93%。**只有 `.background` 才算用户真的切走了**；`.inactive` 要等它恢复，恢复不了就走兜底退出。
- **`applicationState == .background` 时「什么都不做」同样会永久卡住 —— 这是 2026-09-16「续签卡在 93%」的真正根因**。上面那条把 `.inactive` 修好了，但 `.background` 被写成 `case .standDown: return false`，语义是「用户已切走、进程让出前台、iOS 会自己完成替换 ⇒ 不强杀」。**这个前提对「覆盖安装运行中的自己」不成立**：iOS 需要旧进程**终止**，而后台进程不会自己终止 —— 自续签还主动开了后台保活（日志「Seal 自续签事务：后台保活已启动」），等于把这个前提主动破坏掉。结果是进程既不转场也不退出、永久占着前台，installd 一直等它让位，`stageAndInstall` 永远不返回。**正确做法：有界等待（等用户回到前台走转场）+ 超时强杀**（后台强杀用户无感，而不终止进程 iOS 就完不成替换）。**判据：凡是「某个状态下就什么都不做」的分支，问一句「那谁来推进这件事」** —— 如果答案是「系统会自己搞定」，先验证这个假设对**覆盖安装自己**是否成立。
- **用「什么没发生」反推代码路径（否证法）**。真机日志里自替换起点之后进程**既不转场也不退出**、照常写后台日志。把每个候选路径的**必然后果**列出来对照：`.triggerTransition` 必然调 `suspend`（生效 ⇒ 进程冻结 ⇒ 日志停止）、`.waitForForeground` 超时必然 `exit(0)`（⇒ 进程终止）。两者都没发生 ⇒ 动作在到达它们之前就被丢掉了 ⇒ 只剩 `.standDown` 的立即返回。**当「证据不足」时，先找那些「只要走到就必然留下痕迹」的路径，用痕迹的有无把候选集砍到只剩一个** —— 这比继续猜快得多，也不需要额外的埋点。
- **`let x = x(...)` 会编译失败：局部变量名与函数名相同时，右侧解析到的是尚未初始化的局部变量**（`error: use of local variable 'x' before its declaration`）。写 `let step = step(for: state)` 这种「顺手同名」的写法必踩。改名（`currentStep`）即可。**这类错误只在 `swift-regression` 暴露**（本机无 Swift 工具链时是盲写），所以「变量名与它调用的函数同名」要在写完时立刻自查。
- **运行中的模态抽屉必须有退出通道**。`showsFooter: !isRunning` 配合 `.interactiveDismissDisabled(isRunning)` = 运行中既没有按钮也不能下滑关闭。真卡住时用户被锁死在一个静止弹窗里，感受就是「怎么都没反应」——这跟进度显示是**两个独立**的体验缺口，修了进度也别把退出通道忘了。运行中至少留一个「取消」（**软取消**：立即关界面，已下发的安装由 installd 跑完，结果以列表刷新为准）。
- **守卫里「扫到 0 个调用点」= 检查必然通过**。新写的实参顺序校验第一版正则用了 `(?<![A-Za-z0-9_.])signAndInstall\(`，而真实调用点全是 `coordinator.signAndInstall(`（前一个字符是 `.`），被反向断言全部排除 ⇒ 零调用点 ⇒ 零错误 ⇒ 绿。**凡是「遍历 + 断言」的守卫都必须一并断言「扫到了多少个」，并设下限**，否则改一个正则就能让它静默失效。
- **变异检查的期望文案必须与真实断言文案对得上**。`any(item.startswith(expected))` 是按前缀匹配的：文案写错会报成 `Guard failed mutation check`，看起来像「变异没被抓到」，实际是断言已被触发但消息不匹配。看到这条失败先核对真实消息，再改锚点。
- **守卫脚本自己也会慢到被超时杀掉**。`violations()` 在变异检查里要跑 70+ 遍，每遍都 `rglob` 目录 + `strip_comments` 全部 Swift 源码（约 2MB 的纯 Python 字符循环）⇒ 近 3 分钟，超过默认命令超时被 SIGTERM（表现为「无任何输出、exit 1」，很容易误判成脚本崩了）。**每遍内的 `load` 与 `strip_comments` 结果都要缓存**（缓存必须限定在单遍作用域内 —— 跨遍缓存会读到陈旧文本，让变异检查静默失效；另外重绑 `load = load_cached` 前要先把原始 loader 存到另一个名字，否则闭包递归到自己）。`rglob` 结果在进程内只算一次。优化后 48 秒。
  ⚠️ **后续再加检查时这条还会复发**（2026-09-21：新检查对 80 个含 `#expect(` 的测试文件去注释 ⇒ 守卫从 4.6 分钟涨到 **9 分 26 秒**，实测）。**判据：往 `violations()` 里加任何「遍历全部测试文件 + 去注释」的检查之前，先数一遍它会命中多少个文件** —— `violations()` 的调用次数 = 变异条数（200+），单遍多 1 秒就是总时长多 4 分钟。修法是加 **raw 文本前置过滤**：先用廉价正则判「原文里有没有可能命中」，命中才去注释（该过滤必须是**可靠上界**：真违规的文本形态一定会在原文里出现）。
- 🔴 **工作区被别的会话共用时，「只提交自己的文件」也不够 —— 守卫文件是共享的，里面会混进对方的断言**（2026-09-21 实测弄红一轮 CI，`build-package` 的第一步就挂）。
  我在本地跑完守卫（461 断言 / 243 变异，**PASS**）之后、提交之前，另一个会话往 `Scripts/verify-release-safety.py` 里加了 **1 条检查 + 1 个变异锚点**（`overallProgress` 反向断言），**并把一条既有锚点的文本从旧签名改成新签名**（`stageElapsed(_ now: Date)` → `stageElapsed(at now: Date, startedAt:)`）。
  ⇒ 我只提交自己那 3 个文件，**守卫里却带着指向对方新代码的锚点**，而对方的 `SigningProgressView.swift` 没提交 ⇒ CI 报
  `FAIL: Mutation anchor missing: Seal/Features/Apps/SigningProgressView.swift` ✗。
  **判据：本地守卫 PASS ≠ 提交树的守卫 PASS。** 提交前必须问两句 ——
  ①「**这个共享文件在提交里是什么版本**」；②「**它引用的每个路径 / 锚点文本，在提交树里都存在吗**」。
  - **便宜的取证手法**：`git cat-file -e <新提交>:<路径>` 逐个核对守卫 `load()` 的**全部**路径（本次 93 条，0 缺失）；
    再把提交里的守卫与上一个远端尖端逐行 diff，**`-` 行必须为零**（`git diff <上一个尖端> <新提交> -- Scripts/verify-release-safety.py`）。
    ⚠️ 光看 `+` 行不够 —— 本次致命的那一处是**既有锚点的文本被对方改写**，它表现为一行 `-` 一行 `+`。
  - **根治**：用 `git worktree add --detach <远端尖端>` 建隔离副本，在副本里**重做**自己的守卫改动、在副本里跑守卫、再从副本推送 ✓（副本有自己的 index，完全绕开对方的工作区）。
  - ⚠️ 顺带一条：`git worktree list` 里可能已有**上一轮会话遗留的副本**（本次停在旧提交且索引有残留）⇒ **不要复用/清理它**，另开新路径 ✓。
- **两条链路各抄一份同一条规则 = 迟早漂移，而且漂移不会编译失败**。安装阶段的计时起点规则（进入 `.installing` 记一次、重复推送不重置、离开清空）原先在 `AppsViewModel.updateSigningStage` 与 `BatchRefreshSession.advanceStage` 各有一份拷贝。漂移后单签与批量的「已等待 m:ss」必有一个变成假象（永远 0:00，或带上上一项的等待时间），**没有任何编译 / 测试信号**。对策是抽成纯函数（`InstallStageTimeline`）两边共用，并让守卫断言「两处都调它」。
- **源码文本断言守「形状」，单测守「行为」，两者不能互相替代**。`.inactive → .waitForForeground` 这条分支是「Seal 自续签永久停在 93%」的根因，修完当时**只有守卫里的字符串断言** —— 重构可以把它改成任何返回值，只要那行文字还在，守卫就绿。**凡是「错了不崩、只在真机上卡死」的分支，必须先把判断抽成可测的纯函数（如 `SelfInstallAutoBackground.step(for:)`）再写单测**；守卫那边同时断言「单测文件里的关键断言确实存在」，防止测试被删空后仍然全绿。
- **副作用触发点不要挂在界面上 —— 界面会消失，副作用不该跟着消失**。Seal 自续签的「回主页」原先挂在 `SigningProgressView.onChange`。同一个版本里我给运行中的抽屉加了「取消」按钮（软取消：立即关界面，**已下发的安装由 installd 跑完**），于是用户在安装阶段点取消 ⇒ 界面消失 ⇒ 挂在界面上的触发点收不到后续阶段推进 ⇒ 替换静默失败。**判据：这个副作用是「状态到达某一点就该发生」，还是「用户看着界面时才该发生」**；前者必须放在状态层（ViewModel / Coordinator），界面只负责渲染。同类隐患还有：挂在界面上的埋点、上报、清理任务。**加了「关闭/取消」通道之后，要复查一遍有哪些副作用是挂在被关闭的那个界面上的。**
- **重复推送的阶段推进要设「首次进入」闸门**。`updateSigningStage(.installing)` 会被调用不止一次（安装通道的 >1.0 哨兵 + 签名侧补发），挂在它上面的副作用（起计时、触发「回主页」）必须用 `InstallStageTimeline.Tick == .restart` 之类的闸门只跑一次，否则会排出多个任务。
- **同步阻塞 FFI 的等待必须带超时，否则「卡住」= 永久**。`Minimuxer.stageAndInstall` 没有取消机制，自替换分支原先写的是裸的 `try await installation.value` —— 一旦底下不返回，界面就永久停在 93%，进程还活着（其它后台任务照常打日志），**从外面完全看不出区别**。普通 App 分支有 `offThread(seconds:)` 兜底，所以这个缺陷只出现在 Seal 自续签上。**判据：凡是 `await` 一个「无法取消的同步调用」，都要问「它不返回会怎样」**；答案若是「永久」，就必须加看门狗。
- **「停止等待」和「取消工作」是两件事，别用同一个开关**。`offThread` 走 `HardTimeout.run` 的默认 `cancelsWorkOnTimeout: true`，超时会把承载 FFI 的任务 `cancel()`。同步 FFI 本身响应不了取消，但 **Rust 侧若把取消信号当「调用方放弃」来清理，就会撤销已经下发的 installation_proxy 命令** —— 那是把「可能还在装」变成「确定装不上」。自替换只能**停止等待**（显式 `cancelsWorkOnTimeout: false`），绝不能取消。
- **会「静默卡死」的链路必须自带日志**。安装（尤其自替换）在 2026-09-16 之前一行日志都没有：真机日志里 Seal 自替换在「签名产物核验通过」之后 93 秒空白、没有任何结论，而**同一天的普通 App 安装从开始到「签名并安装成功」只有 7 秒**。没有「安装调用已返回」这类对照日志，「卡住」和「在装」在日志上无法区分。安装阶段 installd 不回报任何进度，所以还要有**心跳**（每 15 秒一条）。日志必须 `flush()`：自替换的终点是当前进程被替换掉，留在缓冲里的最后几行会随进程消失。
- **同一个 Bundle ID 上不能有两个并发 installd 命令（R05）**。真机日志 Seal-log(8) 里 91 秒内提交了两笔自替换安装，而第一笔从未返回 —— 用户「怎么都没反应」之后重试，就在同一 Bundle ID 上叠了第二个安装命令。同步 FFI 取消不掉，所以只能**在入口用闸门拒绝第二笔**；而且**超时不解锁**（底下那次很可能还在跑），并且这类拒绝要按终态处理 —— 重试路径里的 `Minimuxer.reset()` / `Install.resetProvider()` 会把可能仍在跑的安装连接拆掉，比不重试更糟。
- **把重复实现合并成一份时，记得同步更新按「出现次数」断言的守卫**。安装通道的无进度重载改为转发到带进度的实现后，`count("if Self.isTimeoutInstallError(error) {") == 2` 这条断言立刻失效（变成 1）。这是**预期内的失败**，改断言而不是把实现写回去。同理，给某个常量/片段加断言前先确认它在文件里出现几次 —— `logStore: logStore` 在 `AppContainer` 里同时出现在安装通道与签名协调器两处，全局匹配会让「只改安装通道那一处」的变异检不出来（本轮实际踩到，改用 `section()` 限定构造段）。
- **`#if !targetEnvironment(simulator)` 的边界要按「模拟器切片编不编译」来划，别按「读起来像不像真机代码」**。同一类错误在 2026-09-16 一天内咬了两次（`diagnostic`、`isTimeoutInstallError`）：符号定义在 `#if !targetEnvironment(simulator)` **之内**，却被 `#if` **之外**的代码引用 ⇒ **`build-package` 全绿（只编设备切片）、只有 `swift-regression` 红**，一轮白等 13–16 分钟。**判据：写完一段与平台无关的辅助逻辑（错误归类、诊断文本、超时判定）时，先问「谁会调它」** —— 调用方在 `#if` 外，定义就必须在 `#if` 外。现在守卫有一条通用检查（`Simulator: device-only members ...`）：把「模拟器不编译」的行整段抹掉，再看有没有**只**在被抹掉部分里定义的顶层类型成员出现在抹后文本中。注意判定条件必须同时覆盖 `#if !targetEnvironment(simulator)` 的**整个分支**与 `#if targetEnvironment(simulator)` 的 **`#else` 分支** —— 只认前者会把 `bindTunnelConfiguration`（定义在 `!simulator` 里、调用点在同文件的 `#else` 里）误报成缺符号。
- **`#expect(...)` 里不能出现 `mutating` 方法调用**。swift-testing 的 `#expect` 是**宏**：它把表达式重写成闭包、把子表达式绑成 `$0`/`$1`…，于是 `mutating` 成员作用在捕获值上编译不过 —— `error: cannot use mutating member on immutable value: '$0' is immutable`。修法是先把结果取到局部变量再断言：`let ok = gate.acquire(); #expect(ok)`。**这个错误同样只在 `swift-regression` 出现**（`build-package` 不编译测试 target），2026-09-16 紧随上一条之后踩到（`#expect(gate.acquire())`，95 条报错全是同一个宏展开）。守卫已加通用检查（`#expect must not call a mutating method ...`），mutating 方法名从 `Seal/` 里现取、不写死。
- **`#expect(_:_:)` 的第二参数是 `Comment?`：字符串字面量（含 `"\(变量)"` 插值）可以，`String` 变量不行**。想给循环里的断言带上「是哪个键/哪一项失败」，很容易顺手写成 `#expect(cond, key)` —— 直接报 `error: cannot convert value of type 'String' to expected argument type 'Comment?'`（`Comment` 只遵循 `ExpressibleByStringLiteral` / `ExpressibleByStringInterpolation`，没有从 `String` 的隐式转换）。修法是插值：`#expect(cond, "缺少 \(key) 时不应判定为完整")` ✓。**与上一条同族：这个错误也只在 `swift-regression` 出现**（`build-package` 不编译测试 target，照绿），2026-09-21 踩到，一轮白等 4.5 分钟。⚠️ 同理 `sourceLocation:` 是**带标签**参数，不能当第二参数位置参数传（本仓正确写法：`#expect(failure.code == code, sourceLocation: sourceLocation)`）。已做成守卫通用检查（`#expect must not pass a bare identifier as its comment`，判据「实参以 `, 裸标识符` 结尾」，含变异锚点；上闸前在全仓 1185 处 `#expect` 上验证过零误报）。
- **守卫的耗时波动本身就是故障源**。变异检查每一遍都会把所有源文件重新读一遍（200+ 文件 × 90 多遍 ≈ 2 万次磁盘读），而本仓在 OneDrive 同步目录里，单次读延迟不稳定 —— 同一份代码整轮耗时实测在 **61–117 秒**之间波动，已经贴到命令默认 120 秒超时（超时会被 SIGTERM，且**没有任何输出**，极易误判成脚本崩了）。对策：在 `main()` 里按路径缓存**基准内容**（每遍只有**一个**文件被替换成变异版本，所以不会读到陈旧文本），耗时降到 53 秒。⚠️ **不要**顺手把 `strip_comments` 的结果也跨遍缓存 —— 那会让被替换的那个文件读到基准版的去注释结果，变异检查静默失效（守卫全绿但什么都没检查）。
- **日志必须写在「挂起 / 退出」之前，并且立刻 `flush()`**。Seal 自替换的「回主屏」终点是 `suspend`（进程被冻结）或 `exit(0)`（进程结束）—— 这两条路之后写的任何日志都出不来。所以「即将触发转场」这条**必须在 `triggerHomeTransition` 之前落盘**，每条日志都要 `flush()` 而不是只 `append`（`SealLogStore` 的 `append` 只写内存缓冲）。顺序反了、或只 append 不 flush，等价于这条链路仍然静默：下次真机排查又只剩「一片空白」。**判据：给一条「会静默卡死」的链路加日志时，先问「这段代码的终点是什么，日志有没有机会落盘」。**
- **守卫断言要断「语义」，不要断「拼出来的文案」**。`check("case .standDown: return false" in squashed)` 这种拼接式断言，只要在分支里插一条日志就失效 —— 而报出来的失败信息看着像「语义坏了」，实际只是文案挪了位置，很容易把人带偏。改成 `section(squashed, "case .standDown:", "case .triggerTransition:")` 切出分支，再断言里面的**语义**（如 `"guard outcome == .wait else" in branch and "return }" in branch`）。要断顺序时用 `branch.index(a) < branch.index(b)`，同样不依赖日志措辞。
- **「某字符串在分支里」不等于「那条控制流存在」—— 日志文案会伪装成代码**。给 `.standDown` 写断言时一度用了 `"exit(0)" in stand_down`，而这段的**日志文案**里正好含「强制 exit(0) 让 iOS 完成替换」几个字：有人删掉真正的 `return`（于是永远走不到 `exit(0)` 兜底）时，断言照样通过 —— 绿着坏掉。**断控制流要看结构**（`return }`、`guard ... else`），**不要看那几个字符在不在**；文案是给人看的，不是给守卫看的。
- **「最佳努力」的链路如果把失败只写进内存 / 事务审计，等于没写**。`DeviceProfileCleaner` 的摘要本来只 `return` 给调用方，调用方再决定写哪；而自替换结算那条路径只把摘要塞进**事务审计文件**（`SelfReplacementTransactionStore`），排障时导出的日志里一个字都没有。同理 `AppsViewModel.runMaintenanceIfIdle` 的 `.skipped` 只有一句 `break`、`.failed` 只弹窗。结果：真机上 Seal 自己堆了 16 份旧 profile，日志里**查不出这条清理跑没跑、是不是被判成身份已变化**。**判据：写「失败不影响主流程」的代码时，问一句「用户把日志发给我，我能看出它失败了吗」** —— 答案若是「不能」，就必须补日志（事务审计、内存缓冲都不算数，排障入口只有导出的日志）。
- **「一次就放弃」的重试类逻辑，要先算清「底层等多久才失败」**。`Provision.dumpProfiles` 内部轮询 `MuxerConstants.deviceFetchTimeoutMs`（**15000 ms**）后抛 `NoDevice` —— 真机日志里那条 `扫描 0，匹配 0，删除 0，中断于 dump，首个错误：NoDevice` 的 15 秒间隔与它完全吻合，说明**一次都没重试**。而两个触发点的时机都不保证设备已连上（安装后 RSD 可能正在重建、启动时 LocalDevVPN 隧道可能还没起来）。**重试必须配「先重置连接再等一等」**：provider 缓存着一条已经断开的 RSD 连接时，不重置的话三次重试全走同一条死路，循环还在、次数还在，等于没重试（守卫要断言重试体里真的有 `resetProvider()`，不能只断言「有个 for 循环」）。
- **摘要文案是排障通道，字段少一个就退回「一片空白」**。`ProfileCleanupSummary.logMessage` 是清理唯一的对外输出。历史上它没有「试了几次」这个字段，于是 `扫描 0，匹配 0，删除 0，中断于 dump` 这行看不出「是设备没连上，还是清理逻辑坏了」。**给这类摘要加字段时，同时想清楚「哪几种失败要用它区分」**；并且要给 `logMessage` 写单测 —— 源码断言只能证明字段被赋值，证明不了它**真的出现在日志里**（比如被脱敏吃掉、`logStore` 没注入）。
- **「某个日志码零命中」之前，先确认那个字符串在你分析的那个构建里存在**。2026-09-17 一天内踩了两次同一个坑：拿 `SEAL-PROFILE-320`（维护第 4 步的无条件日志）零命中，去论证「维护期清理从来没跑过」—— 但 `git show 0c16174:Seal/Core/Maintenance/AppMaintenanceJob.swift | grep -c profileSweeper` = **0**，那个构建里**根本没有第 4 步**。零命中在这里只是平凡真。**判据：`git show <sha>:<file> | grep <字符串>` 先确认它存在**，再谈「有没有出现」；否则「零命中 ⇒ 没执行」这条推理链的第一步就是空的。（同一天还犯过一次同类的：把 `扫描 325，匹配 1` 当成泄漏信号，其实是旧构建单条 keep-map 的正常表现。**根因都是没先定版** —— 见下一条。）
- **同一模式出现多次时，「在不在」式断言会互相掩盖；反过来，给常量加断言前要先数它出现几次**。给 `.skipped` / `.failed` 补日志时，三个非 `.completed` 分支各有自己的日志码，断言必须**按分支切出来**再查（`section()` 逐个切），不能在整个 `switch` 上查一次 `logStore?.append(` —— 那样删掉其中一个分支的日志仍会被另外两个掩盖。
- **分析真机日志之前，先确定它来自哪个构建**。2026-09-17 白跑了一整轮：拿一份日志去分析「修复为什么没生效」，比对到最后才发现那份日志来自**比修复更早的构建**，前提根本不成立。判据是**构建号 = CI run number**（`Scripts/build-unsigned-ipa.sh` 取 `GITHUB_RUN_NUMBER`），所以构建号唯一对应一个提交。没有构建号时只能**比对日志文案的措辞**去反推（本轮就是用 `安装后旧描述文件清理（<bundleID>）` vs `（主 <bundleID>，共 N 个 Bundle ID）` 定位到分界线在 run#79）。**这是不可接受的取证成本**，所以日志表头现在自带构建号 —— 以后先 `grep 构建` 定版，再开始分析。
- **「某个日志码零命中」要成立，前提是那个字符串在你分析的那个构建里存在**。要排除**三个**干扰，顺序不能反：
  ①**先 `git show <sha>:<file> | grep <字符串>` 确认它在那个构建里存在**（最容易漏、也最容易致命）；
  ②导出时被类别过滤（确认该类别在导出里确实存在）；
  ③被环形缓冲滚动丢弃（导出文本里会有「滚动丢弃」提示）。
  三者都排除后，零命中才等价于「这条路径从未执行」。
  2026-09-17 就是漏了第 ① 条：拿 `SEAL-PROFILE-320` 零命中去论证「维护期清理从来没跑过」，
  而 `git show 0c16174:…/AppMaintenanceJob.swift | grep -c profileSweeper` = **0**
  —— 那个构建里根本没有第 4 步，零命中只是平凡真。
  **正确用法**：先定版（见下一条），再用「同一个作业里所有相关日志码一起数」区分
  「没跑到」与「跑到了但中途退出」；但每个码都要先确认它在该构建里存在。

- **`Optional` 返回值把「失败」和「没有」折叠成同一个 `nil` 时，绝不能拿它当删除/覆盖的判据**。
  `Minimuxer.lookupApp(bundleId:) -> String?` 就是这样：`try?` 吞掉错误、
  `Device.getFirstDevice()` 失败也 `return nil` ⇒「没装」与「查询失败」无法区分。
  用它当「没装就删 profile」的判据，隧道一抖动就会把**正在用**的读成「没装」，
  删掉对应 profile，那个 App 立刻起不来。
  **判据**：凡是「返回可选值」的查询，先看它的实现里有没有 `try?` / `guard let … else { return nil }`
  —— 有就说明这个 `nil` 是双重含义，必须换成会**抛错**的变体
  （这里对应 `Minimuxer.isAppInstalled(bundleId:) throws -> Bool`）。
  **再加一层**：抛错只能抓到「报错的失败」，抓不到「静默返回 nil 的失败」。
  所以删之前先做**阳性对照** —— 拿一个**确定存在**的对象去问
  （这里用 Seal 自己：这段代码正在它里面跑），答错了就整轮不删。
  纯函数 `ProfileReclaimPolicy.decision(probe:positiveControlPassed:)` 把这条规则钉住，
  守卫另有 7 个变异锚点证明它真的会红。

- **工具报「编辑成功」不等于内容落盘**。本仓在 OneDrive 同步目录里，
  出现过两次「Edit 返回成功、文件内容却是旧的」（`if let reclaimAborted` 那段、
  守卫里的 `sweep_clean` 定义）。**改完立刻回读校验**，别等跑测试或提交时才发现 ——
  那时你已经基于错误的心智模型做了后面几步。
  做法：改完用一段脚本把「本轮应该出现的字符串」逐个 `in text` 断言一遍
  （注意一个文案在 check 与变异锚点里各出现一次，计数要按 **2** 而不是 **1**）。
  **并行 Edit 同一个文件也会丢**（2026-09-17：一条消息里对守卫的两个 Edit，
  只有变异锚点落盘、断言本身被静默丢掉，表现成「守卫报 mutation check 失败，
  看着像变异没被抓到，其实是断言根本没加进去」）⇒ **同一文件的编辑串行做，逐个回读**。

- **「一个查询 API 对某类对象恒答同一个值」= 安全网在那类对象上根本不存在**。
  `Minimuxer.isAppInstalled(bundleId:)` 对**扩展** Bundle ID 恒为 `false` ——
  扩展不是独立安装的 App，`installation_proxy` 里没有它。于是「删之前先核验设备上没装」
  这道网，对扩展**完全是瞎的**，而且不报错、不崩、只在真机上删数据。
  **判据**：给一条破坏性操作加「设备端/远端二次确认」时，先拿一个**该类对象**的实例
  问一遍，看它答什么 —— 别只拿主对象验证（主 App 答对了不代表扩展也答对）。
  真机实证：同一个 pass 里主 App 判为已装、它的三个扩展判为未装。

- **「保留集合」与「候选过滤集合」必须分开**。判据是「不在保留集合里 ⇒ 成为候选」时，
  「保留集合漏了谁」会**直接变成「删掉谁」**。两个集合的安全方向相反：
  - **严格集合**（决定留哪份）：宁缺勿滥 —— 拿不到可信 UUID 就整组跳过；
  - **宽松集合**（决定不删谁）：宁滥勿缺 —— 记录里出现过就进，且**不看状态门槛**。
  2026-09-17 真机事故正是只做了前者：`signedArtifactStatus` 一陈旧，扩展 ID 就掉出
  保护范围被当孤儿删掉。**改这类判据时，先问「这个集合漏掉一个成员会发生什么」**——
  答案是「删数据」的话，就不能靠「调用方会把集合填全」这种约定。

- **临时排查脚手架必须写明移除条件**。09-16 为定位「93 秒空白」加的一批
  `[BatchDebug]` 日志，两天后占了**全部日志的 30%（73/244 行）**，把真实信号挤出了
  只保留 1000 条的环形缓冲。**加「轮询型」日志前先算频率**：`load()` 每 9 秒一次，
  一条日志 ≈ 每天上万条。**只记事件，不记轮询**；轮询路径上唯一值得留痕的是**异常**
  （例：`待恢复的数据存在、却被跳过`）。加脚手架时同时写下「什么时候删」。

- **守卫里取「函数体」不能用 `split(marker, 1)[1]`** —— 那会取到**文件尾**，
  于是「函数体里有没有这个字段」悄悄变成了「文件后面还有没有这个字段」，
  断言在有同名变量/注释时假通过。用 `section(text, start, end)`（它找不到标记会
  `raise`，fail loud）。同理，断言「某函数没被改成空壳」要限定在该函数体内。
- **当一批对象共享一个稀缺名额、而「降级」只对其中一部分可用时，创建顺序就是成败本身**。
  免费账号的 App ID 名额是主 App 与扩展**共享**的，而扩展创建失败会「丢弃降级」继续签名、
  **主 App 失败则整个签名抛错**。原实现按 Bundle ID 字母序创建，于是只要有一个扩展的字母序
  排在主 App 之前（`com.x.app-ext` < `com.x.app`，因为 `-` 的码位 0x2D 小于 `.` 的 0x2E），
  它就会先把名额吃掉，轮到主 App 时名额已空 ⇒ **整个 App 签不上，而名额已经白花**。
  ⇒ **问法**：「这批对象里，谁的失败是致命的、谁可以降级？」——致命的那个必须**排在最前**。
  这类错误的隐蔽性在于**名额充足时两种顺序结果完全一样**，所以只能靠单测钉住顺序这个*行为*，
  源码断言（「函数存在」）证明不了它。
- **「名额不够」与「请求过密被限流」在日志里长得一模一样**，必须先埋一条无条件诊断把它们分开。
  两者都表现为 App ID 阶段报会话失效（1100），但处置完全相反：一个是「换账号 / 等 7 天」，
  另一个是「等几分钟重试」。判据要写成「本次需 N 个 / 账号已有 M 个 / 需新注册 K 个」——
  **K 大于剩余名额 = 名额问题，K 很小却仍报 1100 = 限流**。
  缺了这条，「用户把日志发给我，我能看出它失败了吗」的答案是「不能」。
- **⚠️ `count(...) == N` 里的 N 必须从「设计」推导，绝不能从「当时的代码」数出来**
  （2026-09-17，一天内踩到的第二种「守卫把缺陷固化」）。R24 曾断言
  `portal_source.count("withSessionRecovery(") == 3`，那个 **3 就是数出来的** ——
  于是它把「覆盖不全」变成了期望值：`updateFeatures`（`ALTAppleAPI.shared.update`）
  同样是**跑在每个 bundle ID 循环里**的门户写入，却一直没有退避重试，而守卫**全绿**。
  **判据：写下 `== N` 时问一句「这个 N 是怎么来的」—— 答不出「设计上应该有几个」，
  就改成逐个点名**（`for label, why in (...)`），让失败信息直接说出**少的是哪一个**。
  只数个数的话，删掉任意一个都只是「N 变了」，看不出缺谁。
- **改断言文案时，必须同步改变异锚点的「期望文案」**。R24 的检查改成「按操作逐个点名 + 理由」
  之后，变异锚点里那句 `"R24: 创建证书也必须过退避重试"` 就不再是真实断言消息的前缀 ⇒
  守卫报 `FAIL: Guard failed mutation check: R24: 创建证书也必须过退避重试`。
  **这个报错看着像「变异没被抓到」，其实是断言已经触发了、只是消息对不上** ——
  别去改实现或删锚点，先把期望文案对齐。
- **⚠️「同一份代码重跑就绿」= 抖动，不是缺陷；而抖动的 UI 测试比没有测试更坏**（2026-09-17）。
  它让「CI 红」这个信号失去可信度 —— 而本仓**只能靠 CI 验证编译**（本机无 Swift 工具链），
  一次误判要花掉一轮 15 分钟 + 一次人工排查。**判据与动作**：
  1. **先重跑失败的那个 job**（`gh run rerun <run-id> --failed`，**不产生新 run**，所以不会
     `cancelled` 任何东西）。绿了 ⇒ 抖动；仍红 ⇒ 确定性缺陷，别急着改测试。
  2. **别把「UI 测试本来就不稳」当结论** —— 先查历史上有没有同一条测试红过
     （`gh api ".../actions/runs?branch=<b>&per_page=60"` 列失败 run，再逐个
     `gh run view <id> --log-failed | grep <测试名>`）。本次查了最近 40 个 run，
     **没有一条是它**，所以不能靠「向来如此」下结论。
  3. 加固要治因，**不要 `sleep` 魔法数字**：这条测试的机制是「初始 mode 切换是**程序化翻页**，
     pager 动画未结束时 `tap()` 会被吞掉」，所以用「点 → 等 → 没到就再点」
     （`tapStage`）。**它不掩盖确定性缺陷** —— 真坏了重试 4 次之后照样断言失败。
  4. **这类回归只在 CI 上间歇性暴露 ⇒ 值得写进守卫**，把它挡在推送前。
- **「同一规则覆盖一批对象」时，要数清这批对象有几个来源，而不是只数调用点**。
  「遇 1100 退避重试」这条规则的适用对象是「**跑在 per-bundle-ID 循环里**的门户写入」——
  Phase 1 每个 bundle ID 发 2 次写（`addAppID` + `updateFeatures`）、Phase 2 发 1 次
  （`fetchProvisioningProfile`，内部还会 delete）、付费账号再发 App Group 的 3 次。
  只覆盖了其中 3 类时，抖音（9 个 bundle ID）的突发仍有近一半没被保护。
  ⇒ 加链路级规则时，**先把「这类操作」全部枚举出来**（`grep ALTAppleAPI.shared.` 是个好起点），
  再逐个判断「它在不在循环里」。
- **同一条规则只落在「两条链路中的一条」—— 第 7 次，这次是 UI 测试**（2026-09-18）。
  `tapStage`（切 tab 的测试）当天已改成「点 → 等 → 没到就再点 + 断言**选中态**」，
  理由是实测证明「点击被接受了、页面没翻」—— 断言「目标页文字出现」是**不确定信号**。
  而**同一个文件里的滑动测试**（`testTwoStageNavigationSupportsHorizontalSwipe`）
  仍在断言「目标页文字出现」⇒ 构建 131 因此红（`ImportFlowUITests.swift:63`）。
  ⇒ **判据**：改一条路径的测试断言时，先 `grep` 同一文件里还有没有**同一类交互**
  （点 / 滑 / 长按）仍在用被否掉的断言形状；守卫也要覆盖两条，用 `count(...) == N`。
  ⚠️ 「是抖动不是回归」要**组合证据**，单独任何一条都不够：
  ① 失败提交只有 8 张 PNG 删除、**0 个 `.swift` 改动**；
  ② 同一份测试代码在上一轮构建是绿的；
  ③ 同一轮里**已改好的那条**（点击）绿，只有没改的（滑动）红。
- **用 `grep` 数「含方括号的字面串」时必须加 `-F`**（2026-09-18 实际踩到）。
  `grep -c -- 'tapStage(app.buttons["已安装，0 个"])'` 返回 **0**，因为 `[` 被当成
  字符类开头 ⇒ 正则与字面串完全不是一回事 ⇒ **假阴性**。
  危险在于：它看起来正是「我刚写的那行没落盘」的症状，会把你送去重写一遍已经写好的代码。
  ⇒ 数「刚写的代码行」一律 `grep -cF`；只有在用真正的正则时才不加 `-F`。
- **「词表同源」不等于「取词同源」**（2026-09-18 全仓审查抓到）。安装链路两张表的字符串列表
  逐条一致，但重试侧喂给它的文本走 `error as NSError` + `NSLocalizedDescriptionKey`，
  而生产错误是 `MinimuxerError.InstallApp(deviceError)` —— 该枚举只遵循 `Error` +
  `CustomStringConvertible`，**桥接成 NSError 后关联值整个丢失**，于是完美词表恒判「可重试」，
  500MB 整包被空推 3 轮。⇒ 审「两份名单是否一致」时必须连带审**取文本的那只眼睛**；
  Swift 枚举带关联值想拿到原文，只能靠 `CustomStringConvertible`/`LocalizedError` 显式出口。
- **永不满足的判据不得留在 pending/未完成态**（同上审查抓到）。旧版 handoff 迁移出的自替换事务
  缺候选版本与安装前身份，`matches` 与 `installedBefore` 两条判据恒假 ⇒ 每轮都判「需电脑覆盖恢复」，
  而 `requireRecovery` 只改 phase 不设 `settledAt`，`create()` 见 pending 就抛 `alreadySubmitted`
  ⇒ Seal 从此**永久无法自续签**，重启与电脑覆盖安装都清不掉。⇒ 设计"下次再评估"时先证明
  它**存在可达的满足条件**；一开始就不可能满足的，必须在识别出的那一刻落终态并留审计原因。
- **错误码分类禁止用数字区间/前缀段**（同上审查抓到）。`hasPrefix("SEAL-INSTALL-71"/"72"/"73")`
  把 `738`（上一笔安装仍在跑）与 `737`（事务未就绪）算成「重新签名」、`702t`（超时 ≠ 失败）算成
  「重新安装」—— 用户点一下就是全量重签 + 重传 + 并发 installd。⇒ 用显式码集合
  （`InstallFailureActionPolicy`），并配一条「每个码恰好命中一个动作」的表驱动测试；
  同族动作相同时的 `SEAL-INSTALL-` 前缀是安全的，**数字区间**才危险。
- **判据写在 `#if !targetEnvironment(simulator)` 里 = 没有测试**（同上审查抓到）。
  纯文本判定（取词、终态表）应放到 `#if` 之外，才能被 `@testable import Seal` 的单测覆盖；
  这次是把三个函数搬出去之后才补上守卫的。
- **公开仓库的文档同样要掩码**（同上审查抓到）。git author 早已换成 `dev@seal.local`，
  但 `DEBUG_LOG.md` / `docs/qa/*` / **源码注释** / **测试夹具的 `maskedEmail` 字段** 里仍写着真实
  Apple ID 邮箱 —— 一处掩码不等于全部掩码。⇒ 掩码后要按「裸账号名 / 带域邮箱 / 变量注入」
  三种形状各自 grep 一遍（本次 5 处 `318***5***` 就是第一轮只找了带域形式漏掉的）。
- **「从改写产物解析出的字典」必须用改写后的键域查询**（build 138 日志实锤）。`applications`
  是从 `prepared.appURL`（Bundle ID 已被 SigningWorkspace 改写成 mapped ID）解析出来的，
  历史代码却拿 original ID 去查 ⇒ 恒 nil、不报错、守卫全绿，后果是
  **entitlements 整体静默丢失 + 诊断恒报空集**。⇒ 建这类字典时先问一句「这个产物的标识符
  还是不是调用方手里的那个」；改写链路里 original 与 mapped 是两个键域，查错域不会崩、
  只会静默空转。守卫 R24b 钉住「查询必须用 mapped ID」。
- **逐帧 UI 的两条热路径：`TimelineView` 的作用域、和把 struct 挂在 `@Published` 上**。
  ① `TimelineView(.animation(1/30))` 包住整张卡片 ⇒ 每帧重算卡片里所有与动画无关的东西
  （身份行、运行时三行、全部文案判断）；时钟只该包住**真正逐帧的那几个叶子**。
  ② 高频回调（AFC 上传进度）写 `signingSession?.installProgress` —— `SigningSession` 是
  **struct**、宿主是 `@Published` ⇒ **每次赋值让整棵订阅树失效重算**，比第 ① 条更贵。
  ⇒ 高频值要么在源头按"界面能表达的最小粒度"节流（整数百分比 ⇒ 1% 步进），
  要么放进独立的轻量 model。**判据：这条回调一秒能来几次 × 每次会让多少 view 重算**；
  乘积 > 一屏 view 数就是错的，哪怕它"看起来更流畅"了。

---

## 历史记录

### 2026-09-23 · 日志首列是北京时间，签名/profile 业务时间却混用了 UTC

- **现象**：导出日志表头与每条记录首列均标注并输出北京时间，但“描述文件创建/到期”、
  “证书生效/到期”和 Seal 自替换结算的同一时间字段使用默认 `ISO8601DateFormatter`，
  输出 `Z`（UTC）。同一行相差 8 小时，容易被误判为续签日期异常。
- **根因**：日志导出层有 `Asia/Shanghai` 格式化器，而各签名/续签写入点各自直接格式化
  `Date`，默认回落到 UTC；没有共享的“日志业务时间”约定。
- **修复**：新增 `SealLogTextFormatter.diagnosticTimestamp`，固定 `Asia/Shanghai`、
  `en_US_POSIX`、`yyyy-MM-dd'T'HH:mm:ssXXXXX`；完整签名核验、profile-only 批量自证、
  Seal 自替换结算、Portal 描述文件与证书诊断全部改走该入口。
- **涉及文件**：`SealLogEntry.swift`、`SigningCoordinator.swift`、`RenewalCoordinator.swift`、
  `SelfAppRegistrar.swift`、`ApplePortalSigningService.swift`、对应日志单测与发布说明。
- **验证状态**：静态核验已确认没有剩余生产日志 UTC 格式化点；完整 iOS CI 与新构建真机日志待验证。

### 2026-09-22 · Seal 自替换启动对账没有终态日志，无法从导出证据确认是否续签成功

**现象**：`Seal-log(36).txt` 记录了 Seal 新包上传、回主屏与旧进程退出，以及批量结果恢复；
但启动后没有“自替换结算确认”或“仍为旧包 / 需要恢复”的任何终态证据。因此无法据日志判断
新运行中的 Seal 是否真的匹配刚签名候选，批量结果的预先结算也容易被误读为 Seal 已更新。

**根因**：`SelfAppRegistrar.reconcileSelfReplacement` 只在 `.settle` 的后续 profile 清理写日志，
`.closeAsNotInstalled` 与 `.requireRecovery` 完全静默；即使成功，清理没有运行或日志延迟时也没有
直接记录“候选身份已匹配”。

**修复**：三种决定性终态均写入安装日志：候选身份匹配时记录运行包 Bundle、描述文件 UUID、
到期日和证书尾号（`SEAL-SELF-113`）；仍为旧包记录非成功关闭（`SEAL-SELF-111`）；身份无法
确认记录恢复状态（`SEAL-SELF-112`）。不改变安装、事务结算或回退流程。

**涉及文件**：`SelfAppRegistrar.swift`；测试：`SelfAppPendingHandoffTests.swift`。

**验证状态**：🟡 Windows 本机无 Swift 工具链；发布安全守卫通过（484 条源码规则、249 个变异案例）。
GitHub Actions run `35747034884` 两次均在所有 macOS job 尚未分配 runner、steps 为空时失败，
未产生编译/测试日志，属远端执行资源或账户配额问题，不能据此否定代码。真机判据：Seal 自续签后
重开应用，必须在导出日志中看到三种终态之一；只有 `SEAL-SELF-113` 才能作为进入 Seal profile-only
可行性验证的前提。

### 2026-09-22 · profile-only 续签完成，五格轨道却只走到第三格

**现象**：`Seal-log(35).txt` 中 LiveContainer 已确认走“仅更新描述文件”：
21:31:39 进入 App ID 准备，21:31:53 设备端逐份读回 4 份描述文件；整轮没有
重新签名、传输或安装事件。界面五格轨道却仍按完整重签链路分配，后两格留给
`.signing` 与 `.pushing/.installing/.verifying`，因此成功时视觉上停在第三格。

**根因**：`SigningProgressBudget` 只有完整重签的十阶段到五格映射。此前已把实际续签路径
回传给单签和批量 UI 用于文案，但轨道与进度环没有使用它，导致精简链路仍引用不可能发生的阶段。

**修复**：为 `profile-only` 增加六个真实阶段的专用预算：连接、账号、应用身份与证书（共一格）、
App ID、描述文件；完整重签继续走原映射。单签和批量的 `SigningStageTrack`，以及单签进度环，
都传入同一条 `RenewalExecutionPath`。最后一格直接采用 `preparingProfiles` 的真实 `done / total`
回调，不伪造签名、上传或安装进度。

**涉及文件**：`SigningProgressBudget.swift`、`SigningProgressView.swift`、
`BatchRefreshView.swift`、`verify-release-safety.py`；测试：`SigningProgressBudgetTests.swift`、
`SigningWorkUnitsProgressTests.swift`。

**验证状态**：🟡 Windows 本机无 Swift 工具链；首轮 R36 守卫正确拦住旧的单表假设，现已改为
分别核对完整重签与 profile-only 两张预算表，待重跑。其后执行本轮 iOS CI 编译、单测和 UI 回归。
真机判据：日志确认“仅更新描述文件”时，五格依次推进，`已取得 N / N 份描述文件`推进最后一格；
日志仍不得出现 signing、pushing、installing。

### 2026-09-22 · profile-only 状态映射漏 return，首轮 CI 编译拦截

**现象**：提交 `8efc87d` 的 iOS CI 中，`build-package` 和 `swift-regression` 都在
`SigningSession.swift` 报 “Missing return in instance method expected to return 'String'”。

**根因**：`RenewalExecutionPath.stageTitle(for:)` 的 `.profileOnly` 内层 `switch` 只写了字符串字面量，
没有把它们显式返回给外层 `String` 函数。

**修复**：所有 profile-only 阶段分支改为明确 `return`；保留展示测试覆盖。

**验证状态**：🟡 静态守卫待重跑；Swift 编译和测试待下一轮 CI。

### 2026-09-22 · profile-only 已生效，但界面仍说“续签并安装”

**现象**：真机日志已连续确认 LiveContainer / StikDebug 的 profile-only 路径：
没有 signing、pushing、installing，并且描述文件逐份读回成功；但入口、阶段、成功页和日志
仍写“准备签名 / 续签并安装成功”，让用户误以为这条快速路径没有生效。

**根因**：SigningCoordinator 只向 UI 回传阶段，没有回传“本轮实际是仅更新描述文件还是完整重签”；
SigningSession 与 BatchRefreshSession 因此只能按“续签”这一粗粒度状态展示。

**修复**：新增 RenewalExecutionPath，在账号、设备、证书和已安装身份核验后由协调器回传。
profile-only 显示“核对应用身份 / 核验当前证书 / 核对 App ID / 描述文件续签完成”；
完整路径保留重签与安装文案。批量日志同时修复 Bundle ID 被插值成 Optional(...)。
另加门槛：门户缺失任何既有 App ID 时，profile-only 直接拒绝并要求完整重签，绝不新建 App ID。

**涉及文件**：SigningSession.swift、SigningCoordinator.swift、AppsViewModel.swift、
SigningProgressView.swift、BatchRefreshSession.swift、BatchRefreshView.swift、
RenewalCoordinator.swift、ApplePortalSigningService.swift、ProfileOnlyRenewalPolicy.swift，
及对应策略/展示测试。

**验证状态**：🟡 真机已证明旧版 profile-only 的实际设备注入与逐份回读；本次文案回传与
“门户缺失 App ID 不新建”仍待本轮 CI 和真机回归。

### 2026-09-21 · 配对助手的校验清单：哈希对，但 `-c` 跑不通（编码修了，行尾没修）

**现象**：下载配对助手产物后 `sha256sum -c SHA256SUMS.txt` 直接失败：
`sha256sum: 'Seal配对助手.exe'$'\r': No such file or directory`（`FAILED open or read`）。
**哈希本身是对的** ⇒ 不真去跑一次 `-c` 根本发现不了。

**根因**：2026-09-20 只修了**编码**（`Set-Content -Encoding ASCII` → `UTF8`，
避免中文文件名被替换成 `Seal????.exe`），但 `Set-Content` 在 Windows 上
**固定使用 CRLF 行尾** ✗ ⇒ 清单里文件名后面多一个 `\r`
⇒ 目标工具把 `Seal配对助手.exe\r` 当成文件名，报「没有那个文件」。
（同族第二例：PS 5.1 的 `UTF8` 会带 BOM，同样让 `-c` 失败。）

**修复**：`pairing-assistant.yml` 改用
`[System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))`，
文本用反引号 n 拼行 ⇒ **行尾由我们显式指定为 LF、且无 BOM** ✓
（纯 .NET API，PS 5.1 / 7 行为一致）。

**本地实证**（同一台机器、同一份内容）：

| 写法 | 尾部字节 | 头部 | `-c` |
|---|---|---|---|
| `Set-Content -Encoding UTF8` | `\r\n` ✗ | 无 BOM | FAILED |
| `WriteAllText` + `UTF8Encoding($false)` | `\n` ✓ | 无 BOM ✓ | **OK** ✓ |

（另：下载 run `35553633932` 的产物复现了旧行为 —— 清单尾部确实是 `\r\n`。）

**涉及文件**：`.github/workflows/pairing-assistant.yml`（+15/−3）。
**验证状态**：修法已本地实证 ✓；本次**未重新构建助手**（只修生成侧，下次 dispatch 自然带上）；
推送未触发任何工作流（`fix/**` 不在该 workflow 的 `push.branches`，且 `ios.yml` 的 `paths` 不含它）✓。

### 2026-09-21 · 批量续签抽屉加上「当前 App」的轨道；同一轮把「预期说明」整条撤掉

**需求来源**（用户逐字）：「批量续签还是原来的 UI，但在队列上面加一个单独续签的轨道」
+「Seal 自续签逻辑不变，一样回主页，就是加个 UI」。

**为什么值得做**：批量续签里每一格都没有反馈 —— 抽屉只有 `i / total` + 一句阶段名 +
一行 App 名，而**一项在注册 Bundle ID 上可以停 25 秒、准备应用文件上可以停 118 秒**
（抖音）。单签抽屉 09-18 起已经有五格轨道，批量却没有。

**做法（刻意只做 UI）**：
1. 把轨道从 `SigningProgressView` 抽成 `SigningStageTrack`（同文件内，`struct`），
   两个抽屉都用它。**抽出来的理由不是复用好看，是防漂移** —— 格子的填充比例只许
   `SigningProgressBudget.bucketFill` 一处给出；批量自己再画一条就是「同一条规则两份实现」
   （本仓已为此踩过 7 次）。
2. `BatchRefreshSession` 补两个字段：`stageStartedAt`（每个阶段的起点，格内爬动要用）与
   `workUnits`。`advanceStage` 里**换阶段就重置这两个** —— 批量特有的坑：下一项会重走
   同名阶段，上一项残留的 `9 / 9` 会让新 App 的第一格直接画满（与当年 `installProgress`
   切阶段残留是同一类）。
3. `RenewalCoordinator` 新增事件 `appWorkUnits(index:total:app:units:)`，把
   `signAndInstall(onWorkUnits:)` 转出去。**单独一个事件而不是塞进 `appProgress`**：
   它和 `appInstallProgress` 一样是高频回调，混进低频的「阶段推进」会把后者淹掉。
4. 采信规则抽成 `SigningWorkUnits.shouldAccept(_:over:)`，单签的 `updateWorkUnits`
   与批量的 `recordWorkUnits` 都调它 —— 「丢弃同阶段倒退计数」这条规则不许有两份。
5. **Seal 自替换链路一行未动**：`.pushing/.installing` 的 `preparingSealUpdate`、
   `persistPendingBatchResultForSealUpdate` 预记 `completed`、`InstallStageTimeline.Tick`
   闸门、`returnToHomeAfterSealUpload` 全部保持原样。
6. 同一轮按用户决定**整条撤掉「预期说明」**（`SigningStage.expectationText` +
   `SigningProgressBudget.expectationThreshold` + 视图里的第三行 + 4 条相关单测）。
   当初留它的理由是「`.preparingBundle` 被显示成『正在验证 Apple ID』⇒ 用户白等 118 秒
   去重登」，而那个根因已由**阶段名本身**修掉；用一句解释去补一个已经正确的标题，
   只是把抽屉堆满。**教训：文案层不该用来兜住数据层的错** —— 那次真正该修的（也修了）
   是阶段归属，不是多加一行。

**守卫（R64，新增 6 条 + 4 个变异锚点）**：批量抽屉必须出现 `SigningStageTrack(`、
且**不许**自己引用 `SigningProgressBudget`；单签抽屉也必须经由它（抽了没人用＝原地留了两份）；
`RenewalCoordinator` 必须真的传 `onWorkUnits:`（**只声明依赖不等于接上了** —— 不接上界面只是
慢一点，没人会发现）；`BatchRefreshSession` 必须走共用的 `shouldAccept` 并记 `stageStartedAt`。

**涉及文件**：`Seal/Features/Apps/SigningProgressView.swift`、`BatchRefreshView.swift`、
`AppsViewModel.swift`、`Seal/Core/Renewal/BatchRefreshSession.swift`、`RenewalCoordinator.swift`、
`Seal/Core/Signing/SigningProgressBudget.swift`、`SigningStage.swift`、
`SealTests/Signing/SigningWorkUnitsProgressTests.swift`、`Scripts/verify-release-safety.py`。

**验证状态**：⚠️ 未编译（Windows 本机无 Swift 工具链）。静态核对：锚点唯一性逐条 `grep -c` = 1、
R36 四个必需符号仍在 `SigningProgressView.swift` 内（轨道本体就在该文件）、
`overallProgress` 在该文件 0 次、`expectationText` 全仓 0 引用。本地守卫全量（含变异）**PASS：静态断言 468 条 + 变异自检 248 条**
（条数比上一轮 +6 / +4，正好等于 R64 新增的断言与锚点 ⇒ 新守卫真的在跑，不是空挂）；
跑完后又改过一次注释与单测断言，用**最终状态复跑一遍仍然 PASS**。
**真机判据**：批量签抖音时，队列上方五格里第 2 格应在「准备应用文件」期间缓慢爬、
第 3 格应在注册 Bundle ID 时一格一格跳（共 9 个 Bundle）；换到下一个 App 时整条回到起点。

**本轮明确没做**：批量结果的「待确认」态（把 Seal 那行从预记 `completed` 改成结算态）——
它要连恢复链一起改（`persistPendingBatchResultForSealUpdate` + `restorePendingBatchResultIfNeeded`
+ 载荷字段 + `BatchRefreshResult` 计数不变量），单翻载荷一处会造出「同一批次两个结论」，
台账另记（任务 #11）。



### 2026-09-21 · 签名抽屉的进度：从「假预估 vs 全程静止」换成「数工作单元」

> ⚠️ **同一天稍后**：本条目第 5 点的「预期说明」那一行**已被整条撤掉**
> （见上一条 09-21 条目第 6 点）。下面那段留着是为了记清当时的判断与它被推翻的理由。

**背景**（用户要求：按视觉最佳 / 体验最好的方式做，并讨论文案设计）：
2026-09-18 把进度改成「阶段内按 τ 指数收敛」→ 用户 09-19 反馈「圈圈不要假预估」→
撤掉估算弧之后，**10 个阶段里 9 个的环完全静止**（只有 `.pushing` 有 AFC 字节真值），
观感于是从"骗人"变成"像卡死"。两条路都不对，缺的是第三类数据：**可数对象**。

**根因**：界面把「有没有真值」当成二值问题（有估算 / 没估算），而本仓多数阶段其实
**有确定的分母** —— Phase 1 每个 bundle ID 一次循环、Phase 2 每份描述文件一次循环、
重签每个 Mach-O 一次、解压按条目走。循环下标一直存在，只是**没人把它往上报**。

**修复**：
1. 新增值类型 `SigningWorkUnits{stage,done,total}`（`total<=0` 或 `done<0` ⇒ `fraction=nil`
   ⇒ 表示「没有可信信号」而不是「0%」—— 报 0% 会被读成一步没做，方向完全不同）。
2. `SigningProgressBudget` 加 `realFraction / hasRealSignal / confirmedProgress(…workUnits:)`：
   优先级**只有一条**（可数对象 ＞ 字节 ＞ 无）。**字节只在 `.pushing` 采信**，
   跨阶段的残留值由 `workUnits.stage` 挡掉 ⇒ 判据仍只有一处。
   `overallProgress`（估算）**保留但退出生产路径**：轨道格内的兜底爬动仍用它，
   删掉会逼出第二份收敛实现（「同一条规则两份实现」已踩 7 次）。
3. 环改成**两种笔触且只有两种**：有真值 ⇒ 已确认弧 + 环心百分比；
   无真值 ⇒ 72% 弧匀速转、**环心不放数字**（`selfReplacementInstallingRing` 通用化，
   Seal 自替换仍在环心留「替换中」两字）。
4. ⚠️ **性能收敛**（WWDC25 SwiftUI 那两条：Long View Body Updates / Unnecessary Updates）：
   ① 30Hz `TimelineView` 原先包住**整张卡**（每帧重算 App 身份行 + 运行时卡片 + 全部文案）
   ⇒ 现在时钟只留给两个叶子（环、5 格轨道），且**有真值时 `paused: true`**（值由状态驱动，
   根本不需要帧）；② 「本阶段已用时 / 预期说明」是整秒信息 ⇒ 独立 **1Hz** 时钟；
   ③ AFC 上传回调原先逐个写 `signingSession?.installProgress` —— `SigningSession` 是
   **struct**、挂在 `@Published` 上 ⇒ 每个回调都让整张抽屉失效重算 ⇒ 改为**按 1% 步进采信**
   （环只显示整数百分比，1% 就是它能表达的最小粒度）。
5. 文案分层（用户选定「超 20 秒才追加预期行」）：`SigningStage.unitsText(_:)` 只在
   **本阶段 + 有总量**时产出一行；`expectationText(isSealSelf:)` 由 1Hz 时钟在
   `expectationThreshold = 20` 秒后追加。措辞纪律：**只说在做什么、和什么无关**，
   不给 ETA、不说「马上 / 即将 / 已自动重试」。最关键一句是
   `.preparingBundle` 的「这一步只在解压与改写文件，不联网、与 Apple ID 无关」——
   真机上抖音在这一步花 118 秒，用户曾据此判断"Apple ID 验证卡住"去重新验证，
   而那时 Seal 根本没碰 Apple（正是「重新验证 → 又被限流」死循环的入口）。
   ⚠️ **写完当场自查出一处冲突并改掉**：初稿在证书 / App ID / 描述文件三行里写了
   「遇到限流会自动等待重试，不必重新登录」—— 而本仓 09-19 已按 build 141 的证据把
   1100 归回**会话过期**（两个不同 Apple ID、同一形态 ⇒ 不是账号级限流）。
   运行中的说明行没有失败页的上下文，这种断言会把用户从「去『我的』重新验证」这条
   唯一正确的路上劝开 ⇒ 改为中性描述，并加测试
   `expectationTextNeverDissuadesReverificationOrBlamesRateLimit`（禁词：限流 / 不必重新 /
   不需要重新 / 无需重新 / 不是登录）。**教训：新写的文案要和 `DEBUG_LOG` 里最近的
   结论对齐，不能沿用本轮会话开头那份已被推翻的判断。**
6. 生产者先接两处（`.preparingAppID` / `.preparingProfiles`），管道与 `onInstallProgress`
   **同形**：`sign → signOnce → provisioningProfiles` 与 `SigningCoordinator.signAndInstall`
   各加一个带默认值的尾参 ⇒ 既有调用点（含批量 / 续签两条链路）不必改。
7. UI 侧单向钳制：`updateWorkUnits` 丢弃**同阶段的倒退计数**（Phase 1 有"扩展降级 / 跳过"
   分支，跳过后回报会让 `done` 变小 ⇒ 数字往回跳一格，正是「跳着走」的观感来源）。
8. 底部轨道只加**两条由真实事件驱动**的动效（用户在那份 HTML 审核稿上逐项挑定）：
   ① **完成闪** —— 某格从不满跨到满（＝该分段真的全部走完、整格变绿）的那一刻，
   0.45 秒亮度回落一次；它不推进任何数字，也不是循环动效。
   ② **宽度缓动** 0.2s ease-out —— 只在 `animatesFill`（＝本阶段**有真实信号**、
   轨道 `TimelineView` 处于 `paused`、值只在回调时跳一下）时挂；
   没真值时轨道由 30Hz 逐帧重算，再叠一层动画就是两份时间基准互相拖。
   ⚠️ **踩到的 SwiftUI 坑**：原先 `progressSegment` 用 `if/else` 返回
   `CurrentSegmentFill` 或 `Capsule` 两种类型 —— 一格从「当前」翻成「已完成」时
   **视图标识变了 ⇒ 实例被重建 ⇒ `@State` 归零**，完成闪永远慢不到那一拍（表现为干脆不响）。
   ⇒ 分支收进同一个 `StageSegmentCell`（内部再 `if isCurrent`），身份连续，
   `onChange(of: fill >= 1)` 才抓得到那条上升沿。**教训：凡要挂「一次性」动效的元素，
   它的状态必须活过外观切换 —— 别用返回不同类型的方式画它的两种状态。**
   ⚠️ 同一段里还有第二个坑：**「峰值 + 回落」不能写在同一轮** ——
   `flashBrightness = 0.6` 紧跟 `withAnimation { flashBrightness = 0 }` 会被合并成
   「0 → 0」（渲染只看到最终值，动画从旧值 0 走到新值 0）⇒ 峰值根本不上屏，闪等于没有。
   改成回落排到下一个 runloop；用 `DispatchQueue.main.async` 而不是
   `Task.sleep(nanoseconds: 16_000_000)`，因为本 App 的协作线程池常被同步 FFI 占住、
   定时器恢复会推迟（AGENTS.md「安装」一节记过同一族机制），而主队列那一跳是确定性的。
   ⚠️ **被当场否掉的三种形状（别再提）**：格宽按耗时加权（「不是很好看」）、
   每阶段一格＝10 格（「格子太多很乱」）、连续长条＋刻线（回「用 5 个格子的」；
   且它在实测里暴露「安装 8 秒完成 vs 预期 50 秒 ⇒ 剩余预期一次性退出分母 ⇒ 长条猛跳 18%」）。
   轨道在长阶段里的缓慢死停**接受为代价** —— 安抚由环的转弧与「本阶段已用时」的秒数承担。

**守卫**：R36 加反向断言「界面里的百分比只能来自 `confirmedProgress`」
（`overallProgress(` 出现在视图里即失败）+ 变异锚点：把那一行换成 `overallProgress(`
必须报红。**刻意不加**「视图必须调 `hasRealSignal`」那条正向断言 —— 它在视图里出现两次，
删一处仍留一处，断言会假装在守（该情形由编译器负责）。

**涉及文件**：`Seal/Core/Signing/SigningProgressBudget.swift`、`SigningStage.swift`、
`SigningSession.swift`、`Seal/Features/Apps/SigningProgressView.swift`、`AppsViewModel.swift`、
`Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、
`Scripts/verify-release-safety.py`；测试：`SealTests/Signing/SigningWorkUnitsProgressTests.swift`（新增）。

**验证状态**：⚠️ 未编译（Windows 本机无 Swift 工具链）。静态核对已过：R36 四个必需符号在视图里
各自存在、`confirmedProgress` 锚点唯一（`grep -c` = 1）、`overallProgress` 在视图里 0 次；
守卫本地全量（含变异）结果见本轮回复。真机判据：签抖音时「已注册 i / 9 个 Bundle ID」
应逐个跳动，`.preparingBundle` 满 20 秒后出现「不联网、与 Apple ID 无关」那句。

**本轮明确没修（避免半招）**：
- `.signing` 的真值：重签循环在 `Vendor/SideSign` 内部，Seal 侧只有总耗时没有分母
  ⇒ 要接得动上游签名器的 `progress:`（代码注释里已留钩子与 `isUsefulSigningDiagnostic`）。
- `.preparingBundle` 的条目计数：`SigningWorkspace.prepare` 目前没有回调入口，接它要再穿一层；
  该阶段现在靠转弧 + 20 秒后的解释行兜住。
- `.verifying` 的 8 项核对在 `InstalledAppDeviceVerifier` 里，同上未接。
- 白色扫光**不加回来**：2026-09-18 用户实测否掉（「横杠的煽动效果不好看」「圆点走前面
  中间都灰白了」—— 白扫过蓝，中段读成灰白）。动感一律由转弧承担。

### 2026-09-20 · 配对验证「验证中」十几分钟：**就绪探测用了 15 秒的预算**（构建 184）

**现象**：iOS 17.0–17.3.1（lockdown 路径）用配对助手写入文件后，Seal 界面停在「验证中」
**12 分钟以上**没有任何结论，用户直接判成死机 ✗。真机日志里既没有成功行
`LocalDevVPN 通道正常（需连接 Wi-Fi）`，也没有失败行 `LocalDevVPN 检测失败｜…｜…` ✗。

**排查（日志三条事实）**：① `17:51:01` 配对**导入成功** —— 那行写在
`SettingsViewModel.swift:1947 → 1954` 的 `importFile` 成功之后（失败会走另一条
「…无法导入」＋错误码）⇒ **文件类型正确** ✓，item 15 的第一道验收通过 ✓；
② 同一步里 Seal **自动**进入验证（1958 行）⇒「验证中」不用手点按钮 ✓；
③ `[SEAL-PROFILE-320] … 中断于 dump，首个错误：NoDevice` ×3（17:51:18 / 17:53:21 / 17:59:44）
⇒ 那三个时刻设备路径不可用 ✓（`Provision.dumpProfiles → Device.getFirstDevice()`，
轮询满 15 秒才会这么写 ✓）。

**根因**：`diagnose()` 的 36 轮探测循环里，每轮的 `Minimuxer.ready()` 都**无条件**先走
`Device.getFirstDevice()`，而它默认轮询 `deviceFetchTimeoutMs` = **15 秒**；
**且 lockdown 路径会真的走到这一步**（`isrppairing == true` 的远程配对路径才直接返回 ✓）
⇒ 「最坏路径」= 设备不可达 = **最常见的那条** ✗。
**但「15 秒」并不等于「每轮等 15 秒」**：`isReady()` 外面套着 `offThread(5 秒)`
（`blockingCallTimeoutSeconds`）⇒ `HardTimeout` 的计时器**在 5 秒处就赢下竞速**、
`offThread` 返回 nil ⇒ `isReady()` 判假 ⇒ `readyDeviceIdentifier()` 第一行
`guard await isReady() else { return nil }` 立刻返回 ⇒ **每轮 = 5 s ＋ 0.5 s 睡眠 = 5.5 s**
⇒ **名义上限 ≈ 3.4 分钟**（36 × 5.5 s ＋ 固定开销 ~2–7 s）。
⇒ 真正的伤害不在等待，而在**每轮被遗弃的那个还在跑 15 秒的阻塞 FFI** ——
它继续占着 Swift 协作线程池的线程，把后续 `Task.sleep` 与计时器的恢复一并推迟
⇒ **实测 12 分钟以上**（≈ 每轮 20 秒，与「5 秒等待 ＋ 15 秒挤占」同量级）。
**修复的关键那一刀是把被遗弃的阻塞调用从 15 秒缩到 1 秒**，不是那点算术 ✓。
详见下方「这个数字我改过三轮」。

**修复**：
- `Vendor/Minimuxer/Sources/Constants.swift`：新增 `probeDeviceFetchTimeoutMs = 1000` ✓
  （就绪探测专用；**一次性路径（dump / 安装 / DDI / JIT）继续用 15 秒** ✓ —— 它们没有外层重试）。
- `Vendor/Minimuxer/Sources/Device.swift`：`getFirstDevice(timeoutMs:)` 可**显式传预算**，
  默认值不变 ⇒ 其余 15 个调用点行为不变 ✓。
- `Vendor/Minimuxer/Sources/Minimuxer.swift`：`ready()` 与 `fetchUDIDDetailed()` 改用短预算；
  `ready()` 里**便宜判据提到最贵那步之前**（原实现无条件先跑 `getFirstDevice()` ✗）。
- `Scripts/verify-release-safety.py`：**R61** 四条判据（专用常量 ≤ 2 秒 / 可显式传预算 /
  两个探测点都传短预算 / **`ready()` 里下标顺序**）＋ **2 个变异锚点**
  （① 改回默认预算 ⇒ ③ 失败；② 只改预算不改顺序 ⇒ ④ 失败，专门证明 ④ 不空转 ✓）。
  守卫 **452/235 → 456/237** ✓。
- 文档：`docs/qa/device-regression-checklist.md` 第 15 项加「修复前 **名义 ~3.4 分钟 / 实测 12 分钟以上**
  → 修复后 **~20–60 秒**」对照表（含逐项成本推导与「等待 / 代价」两分）；
  `Vendor/Minimuxer/SEAL_VENDOR.md` 记这条本地加固；
  `AGENTS.md` §3 安装加「有外层重试的地方，内层预算必须短」✓。

**验证状态**：守卫 **456 断言 + 237 变异 PASS** ✓；**真机待验** ——
下一个构建要验的是「**设备不可达时 ~20–60 秒内给出失败**」，不是「等更久」✓。

**⚠️ 这个数字我改过三轮，四版全记下来（防止下一轮再犯）**：

1. 第一版按外层 `offThread(5 秒)` 算 ⇒ 「最坏 3.5 分钟」—— **「等待」这一半算对了** ✓，
   但它**解释不了实测的 12 分钟**，于是我在第二版把它当成错的推翻了 ✗。
2. 第二版写成「**9–18 分钟**」✗ —— 改成「36 × 15 秒」直加，**把外层那层 `offThread(5 秒)` 丢了**；
   「18」那半还多算了 `fetchUDIDDetailed()`。
3. 第三版改成「**~9 分钟**」✗ —— 只修掉了「18」那半（`guard await isReady()` 那一处 ✓），
   **继续按 15 秒/轮直加**，外层 `offThread(5 秒)` 仍然漏着。
4. 第四版（本版）= 逐行读**修复前的 `ready()` 原实现**（`git diff d8afe51^ d8afe51`）
   ＋ `HardTimeout` 的竞速语义 ＋ `d8afe51` 的文件清单（**它没碰 Seal 侧通道文件**
   ⇒ `offThread(5 秒)` 修复前就在）⇒ **名义 ≈ 3.4 分钟**（每轮 5 s ＋ 0.5 s）✓；
   差额由**被遗弃的 15 秒阻塞调用挤占线程池**解释（实测 12 分钟以上 ≈ 每轮 20 秒）✓；
   「修复后 **~20–60 秒**」✓ 未变。

⇒ **判据一**：算「最坏耗时」时必须**逐行读控制流**，确认哪些调用真的会到达 ✓ ——
**「可能很贵的调用」不等于「一定会被调用」** ✗。
⇒ **判据二（更贵的那条）：先把「等待」与「代价」分成两个数** ——
外层有界等待只决定「**等多久**」（取 min）；被包住的调用**超时后还会继续跑**，决定「**占多久**」。
我前三版一直在把这两个数混成一个 ✗ ⇒ **数字改来改去，根因是模型错了，不是算术错了**。
⇒ **判据三**：改完数字**别只看算式** —— 拿「实测墙钟 ÷ 轮数」反推每轮实际耗时，
与名义值对不上时，差额本身就是线索（这里是 20 s − 5.5 s ≈ 15 s，正好是被遗弃调用的预算）✓。

### 2026-09-20 · 配对助手把「配对类型」藏了 ⇒ iOS 17.0–17.3.1 生成不出配对文件

**现象**：设备是 iOS 17.0–17.3.1 时，Seal 配对助手的「生成并写入 Seal」必然拿不到配对文件，
而界面只显示「已就绪」，一个字都不说为什么 ✗；App 里「设置 → 设备」还写着
「仅支持 iOS 17 及以上设备配对」，把这些设备算成**支持** ✗。

**根因**：远程配对（RPPairing）依赖 Apple 的 `CoreDeviceProxy`，**它是 iOS 17.4 才引入的** ✓
（两处独立证据：固定上游 `idevice_pair` 0.1.14 的 README 写着 *"RPPairing for **iOS 17.4+**,
Lockdown for older verions"*；pymobiledevice3 文档写着 17.0–17.3.1 *"predate the CoreDeviceProxy
service"*，在 USB 上引导不了 ✓）。而 Seal 的 UI 覆盖层把上游的「配对类型」单选**删掉了**
（`patch_upstream.py` 的 `forbidden` 列表里就有 `seal_pairing_mode` ✓），上游默认值又是硬编码的
`pairing_mode: PairingMode::RemotePairing` ⇒ **只剩远程配对一条路** ✗。
⚠️ 17.0–17.3.1 其实**有**完整可用的第二条链路（minimuxer 的 Lockdown 通道：`LockDownInstall`
的 AFC 暂存 + instproxy 安装 + `post17::mount_personalized_ddi` 走 lockdown 的 usbmuxd ✓），
只是**助手生成不出 Lockdown 文件**，用户拿不到入口 ✗。

**修复**：
- `Tools/SealPairingAssistant/patch_upstream.py`：注入两个纯函数
  `seal_ios_supports_remote_pairing` / `seal_mode_for_ios`（解析 `ProductVersion` 的 major.minor：
  **< 17.4 ⇒ Lockdown**、**≥ 17.4 ⇒ RemotePairing**、**版本读不到 ⇒ 保持上游默认** ✓ ——
  未知时不改变既有行为 ✓），并加 **1 条 Rust 单测**（边界 17.0 / 17.3.1 / 17.4 / 17.7.2 / 18.6.2 / 26.7 / `—`）
  + 4 个 `verify()` 标记。
- `Tools/SealPairingAssistant/seal_ui_tail.rs.txt`：生成前按设备版本选模式；手机卡片在「已就绪」
  下多一行「iOS 17.4 以下：本机配对（Lockdown）」✓。
- `Seal/Features/Settings/PairingSettingsView.swift:96`：文案改成
  「远程配对需要 iOS 17.4 及以上；iOS 17.0–17.3.1 会改用「本机配对」，iOS 16 及以下无法安装 Seal。」

**⚠️ 新增一条坑位（子串守卫会误伤命名）**：`verify()` 的 `forbidden` 是**子串**匹配 ✗ ——
辅助函数一开始叫 `seal_pairing_mode_for_ios`（含被禁串 `seal_pairing_mode`）⇒ 补丁脚本自己报
`Minimal UI still contains removed surface: ['seal_pairing_mode']` ✓。
**⇒ 在覆盖层里命名要避开被禁串**（改成 `seal_mode_for_ios` ✓）。
（顺带证明：**那个报错是守卫在正常工作** ✓，不是误报机制坏了 ✗。）

**格式链核对**（决定「会不会被静默认错类型」✓）：`idevice-0.1.61/src/pairing_file.rs` 里
`#[serde(rename = "UDID")]` ✓、私钥键是 `HostPrivateKey`/`RootPrivateKey`（**没有** `private_key` ✓）
⇒ Seal 侧 `PairingStore.inspect` 认成「本机配对」✓、`Muxer.start` 走 Lockdown 分支 ✓（不会误判成 RPPairing ✓）。

**验证状态**：`python -m py_compile` ✓；按 CI 的方式（固定 commit `e3abb34` → 应用补丁 → `rustfmt
--edition 2024`）解析 **0 error** ✓；对打补丁后的助手 `cargo check` **0 error** ✓
（本机 `build.rs` 要调 `reg.exe` 编图标资源、被沙箱拦 ✗ ⇒ 临时把 build.rs 换空 + 补占位 DDI 文件，
**只影响图标资源与 DDI 下载，不影响类型检查** ✓）；抽出的单测 `rustc --test` **1 passed** ✓；
`Scripts/verify-release-safety.py` **PASS（452 断言 / 235 变异）** ✓。
🔴 **真机待验（本次改动之后的第一件事）**：17.0–17.3.1 上的 **Lockdown 通道在 Seal 里从未跑过** ✗
（`DEBUG_LOG`/`docs` 零记录）—— 配对助手现在会**自动**给这类设备生成 Lockdown 文件，
文件能不能装上、DDI 能不能挂上、续签能不能走通，全部要真机确认 ✓。

### 2026-09-20 · 社群页两张码「贴合圆弧」（用户指定的观感调整）

**现象**（用户指出）：赞赏码是「**一张正方形图片贴在圆弧框里**」✗ —— 150×150 的方图塞进
170×170 的圆角框，四周留 **10pt 白边**，**方图的四个角不跟圆弧走** ✗；
而公众号码是**裸图**（连外框都没有 ✗），两张码**视觉不成套** ✗。

**修复**（两处都在 `Seal/Features/Settings/SealCommunityView.swift`）：

| | 改之前 | 改之后 |
|---|---|---|
| 赞赏码 | `scaledToFit` ＋ 150×150 图 ＋ 170×170 圆角框（10pt 白边 ✗） | `scaledToFill` ＋ **170×170 填满** ＋ `clipShape(RoundedRectangle(16))` ⇒ **四角裁成圆弧** ✓ |
| 公众号码 | 240×240 **裸图** ✗ | 套**同款**圆角白框（`clipShape(RoundedRectangle(20))` ＋ hairline 描边 ＋ 阴影 ✓）⇒ 与赞赏码成套 ✓ |

**⚠️ 两个「别改回去」的要点**：
1. **用 `scaledToFill` 而不是 `scaledToFit`** ✓ —— 后者在短边留白 ✗，
   那正是这次要修的现象（将来换成**非正方形**图也不会再留边 ✓）；
2. 圆角取 **16（170pt 框）/ 20（240pt 框）** ✓ —— 按同一比例放大 ✓，
   公众号码那个 20 与它**原有的「未加载」占位**一致 ✓，别单独调一个 ✗。

**验证状态**：静态守卫通过 ✓；**观感需真机确认** ✗（用户已看过对比图并指定这个方向 ✓）。

---

### 2026-09-20 · ✅ 换签名器**真机验收通过**（构建 175）；顺手修掉一条会误导排查的日志

**真机日志**：`Seal-log(28).txt`，**定版 `构建 1.1.16 (175)`** ✓（换签名器后的包）。

**结论**：`rork-sign` → 上游 `SideSign` ＋ `CodeSignKit` **全部验收通过** ✓✓ ——
编译 ✓ / 单测 ✓ / 签名内核测试 ✓ / **大包签名＋安装** ✓ / **装完能启动** ✓。

**三个预判风险的真实结果**：

| 风险 | 结果 |
|---|---|
| 装完能不能启动（上游不处理 FairPlay `cryptid` 清零 ✗） | ✅ **LiveContainer ＋ 抖音都能打开** ⇒ **排除** ✓ |
| 大包会不会被 CPU 预算杀掉（无签名缓存 ⇒ 全量重签 ✗） | ✅ **没被杀** —— 抖音 657.6 MB ＋ 9 bundle 全程走完：本地准备 44 秒 ＋ **重签 78 秒** ＋ 打包 43 秒 ＋ 安装 121.6 秒 ✓ |
| 日志里能不能看出「死在哪个 bundle」 | ⚠️ 仍是已知退化（本次没崩，没暴露）✓ |

**顺手修的（真机暴露的「日志不可信」）**：
`签名：重签完成…；新算 0 个 / 缓存命中 0 个（续签同一个 App 时命中数应当接近总数）` ✗ ——
那句括号是给**已删除的 `rork-sign`**（有 `SigningCacheOptions` ✓）写的，
而上游**没有签名缓存** ⇒ 这个数**恒为 0** ⇒ 留着会让下次排查**以为「缓存没生效」** ✗。
⇒ 改成「（上游签名器无缓存 ⇒ 每次全量重签）」✓，并**丢弃**那个恒为 `(0, 0)` 的计数 ✓
（`SigningCacheStats` 类型保留，只为不动闭包返回类型 ✓）。
**⚠️ 教训：日志是唯一排障通道 ⇒ 换掉一个能力之后，要回头 grep 一遍「讲那个能力的日志文案」** ✓
（否则日志会理直气壮地说错话，比没日志更坏 ✗）。

**⚠️ 真机另暴露一处（与签名器无关）**：描述文件回收多轮
`回收中止：阳性对照未通过（com.example.seal.<TEAM_ID> 被答成未安装）` ✗

> 🔴 **更正（2026-09-20 09:45）**：我先前写的「**阳性对照挑错了对象**（用了旧 Team 后缀的
> Seal 自己）」是**错的** ✗ —— 代码用的是 `Bundle.main.bundleIdentifier`
>（**当前正在运行的 Seal 自己**）✓，而 `com.example.seal.<TEAM_ID>` **就是**当前 Seal 的 ID
>（自替换的目标 ✓）⇒ **对照 ID 选得对** ✓。**教训：结论要落在代码上，别靠日志里那个字符串猜** ✓。

**真实规律（`Seal-log(28).txt` 逐行核对）**：

| 时间 | 距启动 | 结果 |
|---|---|---|
| 09:14:44 | 冷启动后 **22 秒** | ❌ 中止（同行带 `dump 尝试 3 次`） |
| 09:15:00 / 09:16:48 | 38 秒 / 2 分 | ✅ 正常 |
| 09:18:11 | 自替换重启后 **60 秒** | ❌ 中止 ×2（同行带 `dump 尝试 2 次`） |
| 09:21:19 起 | — | ✅ 正常 |

⇒ **两次中止都在「刚启动」，且都伴随 `dump 尝试 N 次`；16 秒后再跑就正常** ✓
⇒ **强烈指向「启动早期安装通道还没就绪」** ✓ —— fail closed **正确** ✓（**不是数据安全问题** ✓）。

⚠️ 但根因**尚未最终确认** ✗：`InstallProbe.unavailable` 把**超时**（`BlockingCall.bounded` 到点）
与**抛错**（`isAppInstalled` throw）**折叠成同一个值** ✗ ⇒ 日志里分不出是哪一种 ✗。
⇒ **已补诊断**（守卫 **R58**）：探测带**耗时**（超时贴近上限、抛错瞬时 ✓），
并**再问同一个 ID 一次**（分开「瞬时失败」与「通道持续撒谎」✓）⇒ 下一份真机日志即可定性 ✓。


---

### 2026-09-19 · 签名器整个换成上游 `SideSign` + `CodeSignKit`；删掉 `rork-sign`（收尾）

**现象**：签**大包**（抖音 780 MB ＋ 8 扩展）时 Seal 被 iOS **jetsam** 杀掉，
并**连累后台**（用户原话：「网易云播放的音乐被杀掉了，LOCALDevVPN 也被杀掉了」✗）——
真机 `JetsamEvent`：`largestProcess = "Seal"`，`rpages 129697 × 16KB = **2.11 GB**` ✓。
而 **SideStore 同样在手机上签大包没问题** ✓。

**根因**：`Vendor/rork-sign`（`rorkai/rork-sign` 0.6.5 ＋ Seal 的 4 个补丁）走的是
「**整块读 ＋ 原地改**」⇒ Swift COW 在「唯一引用」时不复制 ⇒ **峰值 2×** ✗。
上游 `CodeSignKit` 走的是「**mmap 读 ＋ `subdata` 复制后改**」⇒ **全程 1 份** ✓
（`MachOParser.swift:154,157` / `MachOSigner.swift:301` ✓）。

**修复**（用户死命令：「**一个代码不漏地给我抄 不要打补丁 签名器不一样你就换啊**」＋「**禁止乱发明**」✓）：
① 签名内核 → `Vendor/CodeSignKit`（**只改 `Package.swift` 一行**：`swift-crypto` 4.3.1 → 4.5.2 ✓）；
② 重签层 → `Vendor/SideSign` ＋ 薄适配 `Seal/Infrastructure/Signing/SideSignAppSigner.swift` ✓；
③ **删净 `rork-sign`**：`Vendor/rork-sign/`（2.0 MB）＋ `RorkAppSigner.swift` ＋ `project.yml` 依赖 ✓。

**收尾时补删的两处**（上一层的**必然残留**，不删就编译不过 ✗，而 CI **照样全绿** ⇒ 不会自己暴露 ✗）：
- `Vendor/SideSign/CLI/` ＋ `Package.swift` 的 `sidesign` 产品与 `executableTarget`
  （`CLI/CommandHandler.swift:13` 仍 `import AnisetteKit` ✗）；
- `Tests/SideSignTests` 里 2 个用例（`CertificateRequest` / `DeveloperPortal` ✗；其余 3 个保留 ✓）。

**顺带修掉一个真缺陷**：`Vendor/SideSign/Sources/Logging.swift:10-12` 的注释里两个标识符
（`AnisetteKit` / `AnisetteKitLogging.setLogging`）**消失了** ✗ ——
正是「`python -c` 里的反引号被 bash 先当命令执行」那个事故 ✓，已按上游原文补回 ✓。

**CI 侧**：`ios.yml` 的 `rork-sign-tests` → **`signer-tests`**（测 `CodeSignKit` ＋ `SideSign` ✓，
不是简单删掉 —— 保住「签名内核独立回归门」✓）；`publish-release.needs` 同步 ✓。

**守卫**：移除 R38（签名缓存）/ R46（逐 bundle 诊断）/ R52（FairPlay 补丁）—— **对象已删，但知识全部留档** ✓；
**R50 的判据重定向为 R57** ✓（同一条「mmap 读 ＋ 复制后改」现在钉在上游 `CodeSignKit` ✓，
配一个「改回整块读」的变异锚点 ✓）；**新增 R56** ✓（防「job 名还在、其实什么都没测」✗）。
本机完整守卫：**447 断言 / 230 变异 / PASS** ✓（3 分 03 秒）。

**验证状态**：静态守卫全绿 ✓；**编译与真机未验证** ✗ ⇒ 三个已知风险见
`docs/qa/2026-09-19-signer-swap-to-sidesign.md` 第五节
（**① 装完能不能启动** —— FairPlay `cryptid` 没清零 ✗✗；② 大包 CPU 预算；③ 逐 bundle 可观测性 ✗）。

---

### 2026-09-19 · 「签不了」的根因：**anisette 是一次性快照，被复用到了 120 秒之后**

**现象**（`Seal-log(20).txt`，构建 141，两次尝试、**两个不同 Apple ID**，失败形态完全相同）：
抖音签名在「读取证书列表」撞 5 轮退避（1/4/8/20/40 秒，共 73 秒）后死于 `SEAL-AUTH-102c`。
但把时间线摊开看，**gap 之前的请求全部成功**：

```
23:55:31  Apple ID 已添加                    ← 登录成功
23:56:02  证书检查：远端 1 张                 ← 读证书列表**成功**
23:56:05  证书自动清理完成：撤销 1/1 张非本机证书  ← 写操作**也成功**
23:56:05  「签名：设备环境已就绪」             ← anisette 在这里取
23:56:06 → 23:58:09  本地准备 **120 秒**
23:58:10  第一个 Apple 请求 ⇒ **1100** ✗      ← 失败**从这里才开始**
```

**根因**：anisette 里的 `X-Apple-I-MD` 是**一次性验证码**（有效期只有几十秒），
而 `signOnce` 在**开头**取一次 anisette、建好 `session` 之后**一直用到最后** ✗ ——
本地准备（解压 + 三趟全树遍历）要 105–120 秒 ⇒ 之后所有 Apple 请求用的都是
**两分钟前**那份 anisette ⇒ Apple 判会话异常返回 **1100** ✗。

⇒ 这也解释了**为什么换账号也一样失败**：它是**设备身份级**的，与账号无关 ✓
（当晚一度以为是「限流」，方向是错的 —— 见下一条）。

**修复**（`921fa4e`）：`prepare` 之后**重新取 anisette 并重建 `session`**
（`let session` → `var session`）。守卫 **R43**。
真机验证（构建 147）：签名一路走到了 `signing`（重签）阶段，**比之前远得多** ✓。

**顺带修掉的两条误导**（`7580249`）：
① `withSessionRecovery` 把 1100（会话过期）渲染成「Apple 会话疑似被限流」⇒
   把用户引向「等一会儿再试」（**退避治不好会话过期** ✗），也让日志里看不到 1100 这个真正的码；
   现改为「Apple 会话已过期（1100）」，并在退避全部失败时给出**可执行出路**
   （重新验证 / **换网络节点**）。守卫 **R42**。
② **阶段日志的闸门用错了 API**：`InstallStageTimeline.tick` 只对 `.installing` 返回 `.restart`
   （它是「安装计时起点」的簿记），拿它当闸门 ⇒ **只有 `installing` 会落日志** ✗
   （真机实测整份日志只有 1 条 `SEAL-STAGE-001`，正是 `installing`，完全印证）。
   改为 `stage != currentStage`。守卫 **R39**。
   ⚠️ **教训：用别人的函数当判据之前，先读它的实现** —— 名字像什么不重要。

**涉及文件**：`ApplePortalSigningService.swift`、`AppsViewModel.swift`、
`AppleServiceFailurePolicy.swift`、`Scripts/verify-release-safety.py`

**验证状态**：构建 147 真机确认 anisette 重建 + 阶段日志 + 四段计时**全部生效** ✓；
`SEAL-AUTH-102c` 在构建 147 里**没有再出现** ✓。

---

### 2026-09-19 · 本地耗时归因：**大头是「归一化」，不是解压**（两个猜测都被推翻）

**现象**：抖音的 `prepare` 整体 108–120 秒。

**归因过程**（三次拆分，每次都被数据推翻前一个猜测）：
1. 先猜「打包是最大头」⇒ 实测打包 **1 秒** ✗；
2. 再猜「解压是最大头」⇒ 实测解压 **8–15 秒** ✗；
3. 拆成四段后（构建 147 真机）：

| 段 | 实测（两次） |
|---|---|
| 解压 | 7 / 11 秒 |
| 改写 | **0 / 0 秒** |
| 瘦身 | 2 / 5 秒 |
| **归一化** | **30 / 35 秒** ← 大头 |

**⇒ 结论：`normalizeRootFrameworksIntoFrameworksDirectory` 是本地耗时的大头** ✓
（它要遍历全树、逐个文件读 4 字节判 Mach-O、再改写根目录散落的 framework/dylib 引用）。
下一步优化方向是**减少它的全树遍历次数**，而不是动解压或打包。

**涉及文件**：`SigningWorkspace.swift`、`PreparedSigningWorkspace.swift`、
`ApplePortalSigningService.swift`（守卫 **R41**）

**验证状态**：构建 147 真机确认四段日志落地 ✓。

---

### 2026-09-19 · 描述文件回收被**永久阻断**：阳性对照「系统 App 也查不到」

**现象**（构建 141 真机）：
`回收中止：阳性对照未通过（com.example.seal.<TEAM_ID> 被答成未安装）` ——
Seal 正在运行、它**一定**装着 ⇒ 核验通道在撒谎 ⇒ 阳性对照永远不过 ⇒ **回收永远不执行** ✗。

**排查**：策略本身**正确**（fail-closed ✓），用的是 `Bundle.main.bundleIdentifier`
（正在运行的自己，最可靠的对照 ✓），且 `probeInstalled` 走的是**会抛错**的
`Minimuxer.isAppInstalled(bundleId:)` 且有界 ✓ ⇒ 它返回的是明确的 `false`，
**不是**超时、**不是**抛错。

**判别**（新增诊断 `3da916f`，守卫 **R44**）：失败时再问两个系统 App ——
构建 147 真机结果：

```
通道判别（系统 App）：com.apple.Preferences=unavailable、com.apple.mobilesafari=unavailable
```

⇒ **连系统 App 都查不到** ⇒ **整条查询通道不可信** ✓（不是 Seal 的 ID 问题）。
下一步：在「探测到死」时**重建 RSD 连接**（此前一直缺的正是这条直接证据）。

**涉及文件**：`DeviceProfileCleaner.swift`（守卫 **R44**）

**验证状态**：诊断已生效（构建 147 真机给出判别结果 ✓）；**修复本身待做**。

---

### 2026-09-19 · 构建 147：Seal 在 `signing` 阶段**直接闪退**（待定位）

**现象**（`Seal-log(21).txt`，构建 147，**两次运行断在同一位置**）：

```
08:09:53  [SEAL-STAGE-001] 阶段进入：preparingProfiles
08:10:13  [SEAL-STAGE-001] 阶段进入：signing      ← 重签开始
（日志到此为止：没有打包、没有 installing、没有 error）
```

⇒ **硬崩溃**（日志来不及 flush）✗。

**已做**（`6569269`，守卫 **R45**）：重签前加**分界日志**（带待签描述文件份数 /
appGroups 个数 / 主 Bundle ID）⇒ 下次崩溃能分出「Swift 侧准备」与「`RorkSigner` 内部」。

**顺带查清**：`RorkSigner` **自带**一套 `SigningDiagnostics`（`context.diagnostics.info(...)`
逐 bundle 打），但 `BundleSigningOptions.diagnostics` **默认 `.disabled`**，
而 Seal **从来没设置过它** ✗ ⇒ 这就是「签名阶段一行日志都没有」的原因。
要接上有一个矛盾：它是**同步回调**，而 `SealLogStore` 是 **actor**（写入异步 ⇒
崩溃时挂起的日志会丢 ✗）。

**已排除**：签名器里**没有** `Data(contentsOf:)` 之类的整块载入 ✗（内存风险低）。
**候选**：`Vendor/rork-sign` 里的若干 `precondition`（**Release 下也会崩** ✗），
集中在 CMS / DER / 证书链 —— 但**具体是哪一个必须由崩溃日志确认**，不能猜。

**涉及文件**：`ApplePortalSigningService.swift`（守卫 **R45**）

**验证状态**：**未定位**。等 iOS 崩溃日志（设置 → 隐私与安全性 → 分析与改进 → 分析数据 → `Seal-*`）。

---

### 2026-09-19 · 🔴🔴 **mmap 导致 SIGBUS**（构建 160，我引入的崩溃 ✗）

**现象**：点签名后，日志停在「`阶段进入：preparingBundle`」，**12 秒后闪退** ✗。
用户提供 `.ips`，关键字段：

```
bug_type   = 309
exception  = EXC_BAD_ACCESS (SIGBUS)
subtype    = KERN_PROTECTION_FAILURE at 0x…7d0
vmRegionInfo: 地址落在  mapped file  [288K]  r--/rw-  SM=COW     ← 内存映射的文件
栈：_platform_memmove
    Data._Representation.replaceSubrange(_:with:count:)
    SigningWorkspace.rewriteExecutablePathReferences            ← ★
    SigningWorkspace.normalizeRootFrameworksIntoFrameworksDirectory
```

**根因**：我为了让大包不吃内存，把 `Data(contentsOf:)` 改成
`Data(contentsOf:options:.mappedIfSafe)` ✓ —— **但那个函数会 `replaceSubrange` 原地改写这份 Data**
再 `write` 回盘 ✗。
**Swift 的 COW 判定「这份 Data 唯一引用」⇒ 直接往映射页上写** ✗ ⇒ 写只读页 ⇒ **SIGBUS** ✗✗。
（我当时的推理是「真改写时 COW 会照常复制」—— **对 mmap 的 Data 不成立** ✗）

**修复**：**mmap 只准用在纯读的地方** ✓
- 回退 3 处会被改写的（`SigningWorkspace` / 签名主路径 `input` / `var executable`）✗
- 保留 7 处纯读的 ✓（`readEntitlementsXML` / `inspectMachO` / 缓存条目 decode / 既有两处）

**守卫**：R49 **反转**（`rewriteExecutablePathReferences` 必须普通读取，mmap 形式不许出现 ✓）；
R50 **收窄** + 新增「会被原地改写的 Data 绝不许 mmap」✓。

**⚠️ 教训（两条，都值得记）**：
1. **`mmap` 的 `Data` 不是「省内存的普通 Data」** ✗ —— 它的页是**只读**的，
   任何原地改写（`replaceSubrange` / `withUnsafeMutableBytes` 直写）都会 **SIGBUS** ✗。
   **判据：这份 Data 会不会被改？会 ⇒ 不许 mmap。**
2. **改了断言的文案，必须同步改变异的标签** ✗ ——
   守卫用 `item.startswith(expected)` 匹配，不同步会报成「变异没被抓到」，
   看着像变异失效，其实是**断言已触发、只是消息对不上** ✓（脚本里本来就有这条注释，我又踩了一次 ✗）。

---

### 2026-09-19 · 签名器的 **FairPlay cryptid 补丁**（此前只写在提交信息里，台账缺记 ✗）

> 🔴🔴 **2026-09-19 起这条补丁已经不在仓库里了** ✗ —— 签名器整个换成了上游
> `SideSign` + `CodeSignKit`（用户死命令「**不要打补丁**」✓），`Vendor/rork-sign` **已删除** ✓，
> 而**上游同样不处理 cryptid** ✗ ⇒ **「装完启动崩」的风险重新出现** ✗✗。
> ⇒ 下面这段保留为**原型记录** ✓：真机若出现「装完点开就闪退」，就照它移植到 `CodeSignKit` ✓
> （历史提交 `b548021` ✓ / 守卫 R52 已随目录删除，改为**留档** ✓）。

**现象**：已解密但 `LC_ENCRYPTION_INFO(_64)`（cmd `0x21`/`0x2c`）的 `cryptid` 仍为 1 的镜像，
重签后 **dyld 会用新账号尝试 FairPlay 解密、不匹配而启动即杀进程** ✗。

**根因**：`Vendor/rork-sign` 是 `rorkai/rork-sign` **0.6.5** 的副本，
而上游**没有**处理这个残留标记 ✗。

**修复**（提交 `b548021`，2026-09-04）：新增 `clearFairPlayCryptid`，在**三条平行签名路径**
（`thinSigningCacheInput` / `signThinMachO` / `prepareThinMachOCMSCodeDirectories`）
**计算 CodeDirectory 页哈希之前**统一把 `cryptid@loadcmd+16` 写 0，对齐 ldid / zsign / Sideloadly ✓。

⚠️ **三条路径必须同时清零** ✗ —— detached CMS 的 prepare 与 final 两阶段若看到不一致的 cryptid，
外部预签 CodeDirectory 与最终落盘镜像不符会使 **CMS 失效** ✗；
且 cryptid 位于**被签名的代码区内**，必须先清再哈希 ✓（`cryptoff`/`cryptsize` 不变，仅清 id ✓）。

**涉及文件**：`Vendor/rork-sign/Sources/RorkSign/MachO/MachOSigner.swift`（125+ / 13-）

**验证状态**：补了 `machO64WithFairPlayEncryption` 合成 fixture + 两个回归测试 ✓；
**守卫 R52** 钉住（2026-09-19 加 —— 因为它**不在上游** ✗，同步上游会**静默丢失** ✗✗）。

**⚠️ 教训**：这条补丁此前**只存在于提交信息里** ✗ —— 台账（`DEBUG_LOG.md` / `docs/qa/`）里一条都没有 ✗。
**⇒ 凡是「改了 Vendor 里的上游代码」的补丁，必须同时进本台账 + 加守卫** ✓
（否则同步上游时丢了，真机上只会看到「签完启动就崩」✗）。

---

### 2026-09-19 · 🔴 上游契约：**AnisetteKit 每次调用都产生新数据，从不缓存**

拿 `mahee96/AnisetteKit`（Seal 的 `AnisetteKit` 依赖的上游）进来后看到的接口：

```swift
public protocol AnisetteDataProvider: Sendable {
    func getAnisetteHeaders(libDir:provisioningDir:identifier:adiPb:) throws -> AnisetteDataResponse
    func startProvision(...)
    func endProvision(...)
}
```

**⇒ 它的 API 是「调一次就产生一份新的 headers」**（含一次性码 ✓）
**⇒ 库里没有任何「会话」或「缓存」的概念** ✓✓

⇒ **「把 anisette 取一次、塞进 `ALTAppleAPISession` 用一整轮」完全是调用方的错** ✗ ——
这是 2026-09-19 那个 1100 根因**最硬的证据** ✓（比时间线推理更直接 ✓）。

**⇒ 判据：凡是要发 Apple 请求，就当场调一次 `fetch()`；不要把它当成「会话的一部分」** ✓。

---

### 2026-09-18 · 抖音签名失败链路（build 138 日志）：applications 键错位 + 退避梯度不足

**现象**（`Seal-log(18).txt`，构建 138，2026-09-18 21:35–21:37）：
抖音签名在「读取证书列表」撞限流，1.5/4/8 秒三轮退避**全部耗尽**后死于
`SEAL-AUTH-102c`；同日志里 Seal 自签的 features 诊断恒报
`远端 ["TEAM000011"] vs 本次 []`（本次能力集永远是空的）。

**根因**（三条，前两条直接来自日志）：

1. **`applications` 字典键错位**（同日早间审查已发现、当时按「写入量耦合」暂缓）：
   字典从 `prepared.appURL` 解析建键——SigningWorkspace 在此**之前**已把 Info.plist 的
   `CFBundleIdentifier` 改写成 mapped ID，所以键域是 **mapped**；而 `provisioningProfiles`
   里三处查询（`desiredFeatureKeys` / `desiredFeatureTypeSummary` / Phase 1 的
   `if let application = applications[...]`）全用 **original** ID ⇒ 恒 nil ⇒
   ① `requestedEntitlements` 恒空（签出的包不带任何能力，付费账号不会分配 App Group）；
   ② features 诊断恒报「本次 []」；③「跳过冗余 updateFeatures」优化永远不可能命中。
   **当年「单独修会把写入数从 ~25-35 抬到 ~34-44」的顾虑经复核不成立**：
   免费账号下 `filteredAppIDEntitlements` 把 app groups 与非白名单权限全部剥掉
   （`ALTFreeDeveloperCanUseEntitlement` 只放行 interAppAudio / increasedMemoryLimit 等少数），
   `updateFeatures` 的 `guard features.isEmpty == false || filteredEntitlements.isEmpty == false`
   会在**发请求之前**早退 ⇒ 免费路径请求量零增加；付费路径确实多 9 次写入，换来的是
   App Group 真正被分配（正确性），且付费账号不撞免费限流。
2. **退避梯度不足**：1.5+4+8 = 13.5 秒在 build 138 的日志里被 Apple 的限流窗口
   完全碾压（三连退避耗尽即死）。
3. **连带错配（修复 1 会把它暴露出来）**：免费账号撞 3001 时 `updateFeatures` 内部
   清空能力重发并正常返回，而调用方 `requestedEntitlements` 仍记着原始能力集 ⇒
   事后 `validateEntitlements` 对账必报 `SEAL-ENTITLEMENT-401`「权限缺失」——
   修复前查询恒 nil、两边同时空转，这条错配被键错位掩盖着。

**修复**（全部在 `Seal/Infrastructure/Signing/ApplePortalSigningService.swift`）：
① 三处查询改用 mapped ID（`applications[mappedBundleID]` 等）；
② `updateFeatures` 返回值改元组，新增 `downgradedToEmptyEntitlements` 标志，
   调用方据此同步把 `requestedEntitlements[mappedBundleID]` 清空（对账两边一致）；
③ 退避梯度 `sessionRecoveryBackoffNanoseconds` 从 `[1.5, 4, 8]` 延长为
   `[1.5, 4, 8, 20, 40]`（累计 73.5 秒；签名/证书轮换两条链路共用同一常量，改一处两处生效）；
   session 真死时只有第一个撞上的请求付满梯度、整轮终止，代价一次 ~70 秒；
   每轮退避前有 `Task.checkCancellation()`，可随时取消；
④ 新增「App 能力取证」诊断行（只报数量）：区分「IPA 本身没带 entitlements（砸壳剥掉，
   无解）」与「ldid 读取失败（要修 fork 的 `try? ?? ""` 静默空读）」。
守卫同步：R24b（applications 查询必须用 mapped ID + 禁止 original ID 查法回潮）、
`updateFeatures` 变异锚点更新为元组形状、新增键错位变异锚点（期望文案与真实断言前缀一致，
见常犯坑位「变异检查的期望文案」条）。

**涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、
`Scripts/verify-release-safety.py`。

**验证状态**：⚠️ 静态核对（锚点与源码逐字符比对过），待 CI + 真机。真机判据：
① 日志出现「App 能力取证：共 N 个 bundle…带非空 entitlements 的 M 个」且 M > 0；
② features 诊断的「本次」不再是 `[]`；
③ 抖音签名遇限流时日志出现「退避 20 秒」「退避 40 秒」且**随后成功**。

**本轮明确没修（避免半吊子）**：
- AltSign fork 的 `ALTApplication.entitlements` 静默空读（`try? LdidBridge.entitlements(at:) ?? ""`）：
  先靠取证诊断行区分「IPA 没带」与「读取失败」，确认后者才动 fork。
- 「跳过冗余 updateFeatures」优化：等一条干净日志（本次能力集非空后）再决定，
  键集相等 ≠ 值相等（App Group 列表值）的判据没变。
- 102c 的上游成因（本日志里会话在 2 分钟空闲期内被 Apple 掐死，无法远程定位是
  跨账号连登、anisette 会话失效还是 IP 级限流）：只能靠加长退避缓解 + 文案引导。

### 2026-09-18 · 全仓审查：改掉 4 条「不崩、不报错、只在真机上毁体验/毁发布」的缺陷

**先记一条流程教训**：本轮改动最初落在一份**落后远端 124 个提交**的本地快照上（本地 HEAD 停在
2026-09-15，工作树里 151 个文件其实是远端早已提交的内容）。⇒ 「工作树有一堆未提交改动」
**不等于**「这些改动没被提交过」，先 `git fetch` + `git rev-list --left-right --count` 再下判断。
本批已全部重落到远端真实基线 `3beef2c` 上，四个缺陷在远端逐条复查确认**仍然存在**
（`errorDetail` 仍走 NSError 桥接、`isResignRequired` 仍是 71/72/73 区间、legacy 迁移
`settledAt` 仍为 nil、`HardTimeout` 仍无 cancellation handler）。

**现象**（分链路审查逐条读源码确认，非猜测）：
① 免费账号 3-app 上限与存储不足在真机上从不被判定为终态，大包被反复整包重传；
② 上一笔自替换安装仍在跑时，结果页把「重新启动 Seal」渲染成「重新签名」；
③ 从旧版升级上来的设备只要残留 `SelfSigningHandoff.json`，Seal 就永久不能自续签；
④ 取消一次大包签名/上传后，界面关了，`OperationCoordinator` 的全局单槽还被占好几分钟；
⑤ `RELEASE_NOTES.md` 已删但两份 workflow 仍 `cat` 它 ⇒ publish job 当场 `exit 1`，发不出 Release。

**证据**：
① `Vendor/Minimuxer/Sources/Install.swift:131` 抛 `MinimuxerError.InstallApp(deviceError)`；
`MinimuxerError.swift:11` 只遵循 `Error`（`:86` 的原文只在 `CustomStringConvertible.description`
里）；重试循环取的文本却来自 `error as NSError` + `NSLocalizedDescriptionKey` ⇒ 设备原文丢失、
终态表恒假；而同文件 `installationFailure` 用的是会特判 `MinimuxerError` 的 `diagnostic`
⇒ **两表词表一致、取词不一致**。
② `isResignRequired` 用 `hasPrefix("SEAL-INSTALL-71"/"72"/"73")` ⇒ `738`
（recovery 写的是「重新启动 Seal 后再试」）与 `737` 落进「重新签名」，`702t` 落进「重新安装」
→ `retryInstallationForCurrentSigningSession()` 整包重跑。
③ 迁移出的 candidate 是 `version:""`（`SelfSigningIdentity.swift:118-122`），`matches` 要求
版本相等 ⇒ 恒假；`installedBefore = .unknown` ⇒ 相等判据恒假；`requireRecovery` 不设 `settledAt`
⇒ `loadPending()` 永远返回它 ⇒ `create()` 永远 `alreadySubmitted`。
④ `HardTimeout.run` 只有裸 `withCheckedThrowingContinuation`、无 `withTaskCancellationHandler`，
工作又跑在 `Task.detached`（不继承父取消）。

**修复**：
① `errorDetail` 复用 `diagnostic`，并把 `diagnostic`/`errorDetail`/`isTerminalInstallError`
搬到 `#if !targetEnvironment(simulator)` 之外（internal）⇒ 首次可单测；
② 新增 `InstallFailureActionPolicy`（`Seal/Core/Installation/InstallChannelDiagnostic.swift`）
用**显式码集合**（acknowledge 6 个 / resign 22 个），`SigningProgressView` 三个判定全部转调它；
三条重试循环开头补 `try Task.checkCancellation()`，让取消真正终止而不是回抛后继续下一轮；
③ legacy handoff **迁移即终态**（`phase = .recoveryRequired` + `settledAt` 非空 +
`failureCode = "SEAL-SELF-LEGACY-UNVERIFIABLE…"`），审计记录留在磁盘，槽位当场释放；
④ `HardTimeout` 加 `withTaskCancellationHandler` + `settled` 标志（覆盖 `onCancel` 早于 `store`
的时序），取消按 `CancellationError` 立即恢复，是否连带取消工作仍由 `cancelsWorkOnTimeout` 决定；
⑤ 恢复 `RELEASE_NOTES.md`（顶部条目即当前 `MARKETING_VERSION` 1.1.16 正文），两份 workflow 的
publish 步骤加 `[ ! -s ]` 判空 + `::error::` 注解。
附带：`AppImportTimeFormatter` 的 `DateFormatter` 改按「格式+时区」缓存（原先每行 body 现场构造
1~2 个，`ImportedAppRow.swift:100/135`）；`AGENTS.md` 重写为规范接替文件（订正 SealTunnel 已移除、
自替换 profile 改为结算后清理两条失效规则）；提交前掩码真实 Apple ID 邮箱（含 Swift/py 注释、
docs/qa 与一处测试夹具的 `maskedEmail`）。

**涉及文件**：`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`、
`Seal/Core/Installation/InstallChannelDiagnostic.swift`、`Seal/Features/Apps/SigningProgressView.swift`、
`Seal/Core/Concurrency/HardTimeout.swift`、`Seal/Core/Renewal/SelfReplacementTransactionStore.swift`、
`Seal/Features/Apps/AppPresentation.swift`、`.github/workflows/ios.yml`、`.github/workflows/ios-release.yml`、
`RELEASE_NOTES.md`、`AGENTS.md`；测试：`SealTests/Installation/InstallChannelDiagnosticClassificationTests.swift`、
`SealTests/Concurrency/HardTimeoutTests.swift`、`SealTests/Renewal/SelfReplacementTransactionTests.swift`
（替换原先只断言「能加载成功」的同义反复用例）。

**验证状态**：⚠️ **未验证**。Windows 本机不能编译、`python` 守卫不可执行 ⇒ 只做了静态核对
（`#if/#endif` 配对、括号平衡与基线对照、被删私有 API 无残留引用、`ImportFailure` 成员初始化参数序）。
下一步：① 本分支推 CI 走 `ios.yml` 全量档（编译 + 单测 + UI 回归）；② 真机回归「免费账号第 4 个应用」
与「装到 90% 取消」两条，确认不再重传、租约即时释放；③ 真机确认残留旧 handoff 时仍能自续签。

**本轮明确没修（避免半吊子）**：
- 批量结果里 Seal 项**预写 `completed`**（`AppsViewModel.persistPendingBatchResultForSealUpdate`）：
  这是 2026-09-17 为消除「同一批次三份互相矛盾结论」做的取舍，只翻这一处会把那个 bug 放回来，
  必须连 `recoverInterruptedQueueIfNeeded` 的顺序与「待确认」这一档 UI 一起设计。
- 旧版曾把 `SEAL-EXT-401a` 映射为“移除扩展并重试”；现已废弃该降级策略，扩展失败统一保留完整包并停止本次签名。
- 审查另发现的签名侧结构性问题（`applications` 字典按**改写后** ID 建键、却按**原始** ID 查找 ⇒
  首签第三方 IPA 时 `updateFeatures` 与 entitlement 校验整体空转；Phase 2 丢扩展不回收已建 App ID；
  `removeExtension` 不清理 `SC_Info/Manifest.plist`）**必须与"减少门户写入量"同批处理**——
  单独修正确性会把抖音的写入数从 ~25-35 抬到 ~34-44，限流只会更凶。

### 2026-09-18 · 构建 131 红在滑动路径：同一条规则只落在「点击」这一条链路上

**现象**：`33f00ff0`（chore(icon)：删 8 张旧尺寸图）的 CI 是 `failure` ——
但 `build-package` **success**、`rork-sign-tests` success，只有 `swift-regression` 红：

```
SealUITests/ImportFlowUITests.swift:63: error:
  -[SealUITests.ImportFlowUITests testTwoStageNavigationSupportsHorizontalSwipe] : XCTAssertTrue failed
```

即 `pager.swipeLeft()` 之后 5 秒内「已安装应用」没出现。

**判定「抖动不是回归」的组合证据**（单独任何一条都不够）：

1. `git diff --name-only d571038 33f00ff0 | grep -c '\.swift$'` = **0**
   —— 该提交只删了 8 张 PNG，不可能影响 UI 行为；
2. 同一份测试代码在**上一轮构建 130**（`d571038`）是绿的；
3. **同一轮里**已改好的那条（`testTwoStageNavigationCanBeTappedWithoutChangingHeaderAlignment`，
   走 `tapStage`）是绿的，只有**没改的**（滑动）红。

⇒ 这不是「新提交引入的回归」，而是**同一类断言在两条交互路径上只修了一条**。

**根因**：`tapStage` 当天已经放弃「断言目标页文字出现」，理由写在它自己的注释里 ——
实测证据是「点了 4 次之后仍未出现」，说明**不是 tap 被吞，而是点击被接受了、页面没翻**
（`TabView(.page)` + `selection` 在程序化改 `mode` 时偶发不翻页）。
于是断言改落到**确定性的选中态**（`modeButton` 用
`.accessibilityAddTraits(mode == item ? .isSelected : [])`，直接反映 `mode`）。
**但滑动那条路径没有人回头看一眼** —— 它还在断言同一个已被否定的信号。

**修复**（`SealUITests/ImportFlowUITests.swift`）：

- 新增 `swipeStage(_:to:expecting:)`：与 `tapStage` 同源 ——
  「滑 → 等 → 没到就再滑」（最多 4 次，每次等 3 秒），断言 `selected.isSelected`；
- 滑动测试改为 `swipeStage(pager, to: .left, expecting: app.buttons["已安装，0 个"])`
  与 `swipeStage(pager, to: .right, expecting: app.buttons["待签名，0 个"])`；
- **它不掩盖确定性缺陷**：真坏了 4 次之后照样断言失败。

**守卫**：R28b（两条独立 check + 2 个变异锚点）——

- `private func swipeStage(` 存在，且 `pager.swipeLeft()` / `pager.swipeRight()`
  各**恰好 1 次**（只允许出现在 helper 内部 ⇒ 裸滑动会被抓住）；
- `XCTAssertTrue( selected.isSelected,` 存在（用 `squash` 写成一行式，不数缩进空格）；
- 变异锚点：① 把 `swipeStage(...)` 退回 `pager.swipeLeft()`；② 把滑动断言退回
  「目标页文字出现」。两个锚点的期望文案都刻意写成**真实断言消息的前缀**。

**顺带记录一处本轮踩到的工具陷阱**：`grep -c -- 'tapStage(app.buttons["已安装，0 个"])'`
返回 0（`[` 被当字符类），差点被当成「刚写的行没落盘」。改用 `grep -cF` 后为 1。

**本轮不做（留作候选，无证据不动）**：同文件第 18 行
`app.buttons["待签名，1 个"].tap()` 也是「裸 tap + 等内容出现」的形状。
但它①等到了已稳定的「已安装应用」页才点，②超时是 10 秒而非 5 秒，
③最近 8 轮 CI 全绿 —— **改成 `tapStage` 会把断言从「待签名项可达」偷换成「tab 被选中」**，
反而丢掉这条测试真正要保的东西。⇒ 记录在案，等它真红过一次再动。

---


### 2026-09-18 · 进度条「跳着走」：进度不再是阶段枚举的纯函数

**用户反馈**（原话）：「百分比进度条和底部 5 个横杠都是跳着走的，而不是丝滑的从
0%–1%–2%–…–100%。后端处理时，会造成视觉上让人觉得是卡住了的感觉。」

**根因：不是动效，是信息。** 进度是 `SigningStage` 的**纯函数** ——
`overallProgress` 给 10 个阶段配 10 个写死的常数（6/16/23/30/42/54/68/78→90/93/99），
**没有任何时间项**，所以两次阶段推送之间只能冻结、阶段一变就跳一格。
环上那句 `.animation(.easeInOut(0.45), value:)` 只是把跳变补间成 0.45 秒的滑动。
真实连续信号只有 `.pushing`（AFC 回调），只占环的 **12%**。

**两个长阶段是观感杀手**：`preparingBundle`（抖音 780 MB）**112 秒**全程 23%；
`.installing`（installd 不回进度）全程 93%。前者还造成过实际伤害 ——
它的旧文案是「正在验证 Apple ID」，用户据此去**重新验证 Apple ID**，
正是「重新验证 → 又被限流」死循环的入口（见 `2026-09-18-only-douyin-fails-real-chain.md`）。

**底部轨道是另一处独立缺陷**：`timelinePosition` 把 10 个阶段压成 5 格（1/3/2/1/3），
而格内填充是写死的常数（`segmentFraction`：0.33/0.5/0.67），与该格真实完成度无关 ⇒
当前格看起来像随机卡住，阶段一过又**整条变绿**（轨道上最大的一跳）。

**修复**（`Seal/Core/Signing/SigningProgressBudget.swift` 新增，唯一数值来源）：

- 每个阶段一对「地板 / 天花板」，阶段内 `floor + (ceiling−floor)·(1−e^(−t/τ))`：
  **永不越过天花板**、**单调不减**、**先快后慢**。
- `ceiling_i == floor_{i+1}` 是整套连续性的全部所在（不跳、不回退）。
- 深色弧 = 已确认（不随时间变），浅色弧 = 本阶段估算（永远不自己走到终点）；
  当前格加一条**不推进百分比**的扫光 + 弧前端呼吸点 —— 「后端在干活但界面不动」
  只能靠这个信号消解。
- 轨道填充 = `(格内已完成阶段数 + 本阶段完成比例) / 格内阶段总数`。
- 长阶段显示「本阶段已用时」（>4 秒；`installing`/`verifying` 交给 `InstallWaitNote`，不重复）。
- `TimelineView(.animation(minimumInterval: 1/30))` 逐帧驱动，**撤掉** `.animation(_:value:)`
  与 `repeatForever`（每个 tick 触发补间 = 黏滞 + 抖动）。
- `SigningSession.stageStartedAt` + `InstallStageTimeline.stageStart`（起点规则只许一份）；
  两个绕过漏斗直接赋值 `status` 的入口（`confirmCertificateSacrificeAndRetry` /
  `restartSigning`）统一走 `updateSigningStage`。

**抖音 780 MB 的 `preparingBundle` 现在爬到 37.77%**（不再钉在 23%）；
**`.installing` 在 600 秒时停在 94.9999999999993%** —— 永远不会声称装完。

#### 守卫

R36（逐个阶段点名 + 首尾相接解析比对 + 视图必须用预算表 + 不许再写死常数 +
单测必须真的在守这两条）+ 5 个变异锚点。
**R32 里那条 `count(".preparingBundle") >= 3`（「三处 switch 都要处理」）随三处 switch 合并而删除**
—— 它只能证明「出现了 3 次」，证明不了「10 个阶段都在」，R36 更强。
单测 `SigningProgressBudgetTests` 13 条，数值断言写进测试前先用 Python 离线跑过。

#### 本轮的两条方法论

1. **「进度条卡住」有两种成因，先分清**：① 阶段推进没到（查链路）；② 数值里没有时间项
   （改模型）。现象一样，处置相反 —— 已写进「常犯坑位」。
2. **纯 UI 改动也要过守卫**：视图里写死一个进度常数（哪怕放进死代码）就是「跳着走」的
   原样重演，所以 R36 连**已删除函数名**都作为 `not in` 断言钉住。

**本轮不做**：真实子事件（`prepare` 内部按 Mach-O 逐个回报、门户阶段按 bundle ID 回报）
与「大包签名耗时归因埋点」合并成下一批 —— 预算表的 `τ` 现在是估的，
拿到真机分段耗时后要回头校准。

### 2026-09-17 · 同一族第 6 次：证书轮换路径的 `addCertificate` 也没有 1100 重试

**接着上一轮继续枚举**（`grep ALTAppleAPI.shared.` 的做法可以推广到**整个仓库**，
不只是签名服务那一个文件）：

| 服务 | 路径 | `addCertificate` 有退避重试？ |
|---|---|---|
| `ApplePortalSigningService` | 签名 | ✅ |
| `ApplePortalCertificateService` | **证书轮换 / 孤儿证书清理** | ❌ **漏了** |

守卫**结构上就看不到**这一处 —— R24 的断言只作用在 `portal_source`
（`ApplePortalSigningService.swift`）一个文件上。这正是「只对一条链路做断言」的形态。

**为什么这条的后果最严重** —— ⚠️ **这一句是去代码里读出来的，不是从 `MEMORY.md` 抄的**
（写「后果有多严重」这类结论前必须把那条路径读一遍：凭记忆写会两种错法都犯 ——
夸大把人吓住，或轻描淡写漏掉真风险）。有两条链路确实是「先 revoke、再创建」，
而且都走 `ApplePortalCertificateService`：

| 链路 | 撤销 | 创建 |
|---|---|---|
| `SettingsViewModel.revokeCertificateAndCreateLocal`（622 行起） | 688 | **726** |
| `SettingsViewModel.executeCertificateCleanup` | 944 | 980 |

`revokeCertificateAndCreateLocal` 的完整路径：撤销（688）→ 确认槽位已释放（696–712）→
**把本地 keychain 里那张证书的 P12 / serial 清空（716–724）** → 创建新证书（726）→
失败则 `alertFailure`（748–751，**用户能看到**）。

⇒ 创建失败时：**旧证书已撤销、本地凭据已清空、新证书没建成** ⇒ 账号变成 **0 张可用证书**；
而撤销时 `AppsViewModel:1062-1071` 会记下 `affectedInstalledApps`（`certificateSacrificeResignQueue`）
并**立刻重试签名**，签名没成功就把队列清空、只留一条日志引导手动续签。

**与 `updateFeatures` 那条的差别**：那条是「静默降级成空 entitlements」，这条是「**账号被清空**」
—— 严重性不在一个量级。

**修法**：给 `ApplePortalCertificateService` 加一个 `withSessionRecovery`，
**只复用** `ApplePortalSigningService` 的
`isSessionExpiredError`（哪些错误值得重试）与 `sessionRecoveryBackoffNanoseconds`
（退避多久，访问级别由 `private` 放开为 `internal` 就是为了这一处共用）。
**这两项才是会漂移的东西** —— 抄一份的话，同一个 1100 会在一条链路上重试、在另一条上直接失败。

**已知缺口（未修，已记档）**：该服务没有 `logStore`，所以它的重试**不写日志**。
可接受的理由：重试成功时结果可见；重试耗尽时错误照旧上抛，会变成 `SEAL-CERT-227`
（已写明后果）。要补日志得给它注入 `SealLogStore`（三个构造点都拿得到），属另一轮改动。

**守卫**：新增 R29（2 条断言 + 2 个变异锚点）。
**规模：354 源码断言 + 192 变异 PASS。**

**文档**：`docs/qa/2026-09-17-session-recovery-coverage.md`（把 R27 与 R29 放在一起，
因为它们是同一族的两个实例）。

**顺带修掉创建失败时的文案（R30）**：补了退避重试之后还有一个问题 —— **重试耗尽时用户看到什么？**
原先 1100 会**原样上抛**（`CertificateRequestFailurePolicy.requestFailure` 对它返回 `nil`），
落到调用方的通用 `catch`，变成「无法完成证书处理 … **没有返回明确失败原因**」+
「重新同步证书后确认当前状态」。三处都不对：①「没有返回明确失败原因」是假的（原因就是 1100）；
②没说清这是限流、用户可能跑去重新验证 Apple ID；③**没说「旧证书已经撤销、账号可能没有可用证书」**。
新增 `SEAL-CERT-233` 说清这三点，并刻意用「**若你刚才是在**…」表述 ——
`createLocalCertificate` 也被设置页的「创建证书」按钮直接调用，那时没有任何撤销，
写「撤销已生效」就是新的误导（守卫 R30 同时钉住「必须写明后果」与「不许假设撤销」）。

**守卫踩到的两个坑（都值得记）**：
1. R30 新加的代码里也出现了 `ApplePortalSigningService.isSessionExpiredError(error)`
   ⇒ **R29 那条靠 `in` 的断言当场失去约束力**（变异只删一处、另一处兜住，守卫报
   `Guard failed mutation check`）。修法是把断言**限定到那一段**（`section_or_empty`），
   不是改实现、也不是删锚点。这正是技能规矩 4 说的「片段出现多次时 `in` 失去约束力」，
   **而它会在你新加代码时突然发生**。
2. 变异只把条件改成 `if false`、**文案原封不动** ⇒ 只查文案的断言照样全绿，而分支永远走不到。
   ⇒ **断「分支存在」要同时断言分支条件**（`"if X {" in source`）。

---

### 2026-09-17 · 退避重试漏在第 4 类 portal 写入上：`updateFeatures` 没有 1100 重试

**怎么发现的**：不是在真机上，而是顺着「抖音为什么特别容易撞限流」去**枚举门户写入**。
`grep ALTAppleAPI.shared.` 列出 14 个调用点，其中 **9 个是写入**：

| 原语 | 在哪 | 在 per-bundle-ID 循环里？ | 有 1100 退避重试？ |
|---|---|---|---|
| `addAppID` | Phase 1 | 是（抖音 9 次） | ✅ |
| `update`（`updateFeatures` → `submitUpdatedAppID`） | Phase 1 | **是（抖音 9 次）** | ❌ **漏了** |
| `fetchProvisioningProfile`（内部还会 delete） | Phase 2 | 是（9 次） | ✅ |
| `addCertificate` | 证书阶段 | 否（1 次） | ✅ |
| `addAppGroup` / `assign` / `fetchAppGroups` | `assignAppGroups` | 是（付费账号，每 ID 最多 3 次） | ❌ 漏了 |
| `registerDevice` / `revoke` | 一次性 | 否 | 刻意不覆盖 |

**为什么漏了却一直没被发现**：守卫 R24 的断言是
`portal_source.count("withSessionRecovery(") == 3` —— 那个 **3 是从当时的代码数出来的**，
于是它把「覆盖不全」固化成了期望值。R24 当轮补的是「创建证书」，而
`updateFeatures` 从来没有被纳入过「portal 变更」这个清单。

**漏掉它的两种后果都不报错**（这才是它值钱的地方）：

1. **主 App** 的 `updateFeatures` 撞 1100 ⇒ 落到 `guard mappedBundleID != mappedMainBundleID
   else { throw error }` ⇒ **整个签名失败**，用户看到的只是「Apple ID 失效」；
2. **扩展** 的 `updateFeatures` 撞 1100 ⇒ 走 `catch where mappedBundleID != mappedMainBundleID`
   的降级分支，把 `requestedEntitlements[mappedBundleID] = [:]` **清空**后继续签
   ⇒ 签名「成功」，但扩展在真机上缺权限（静默降级比失败更难查）。

**修复**：`updateFeatures` 与 `assignAppGroups` 的调用点各加一层
`withSessionRecovery`（后者付费账号才走，但同一条规则不该只落在免费路径上）。
副作用是另一条诊断：每次重试都会写
`Apple 会话疑似被限流，退避 N 秒后重试 更新应用能力 <bundleID>（第 N 次重试）`
—— 用户下次的日志能直接看出限流打在**哪个阶段**，而不只是「App ID 阶段」。

**守卫改造**：R24 从「数个数」改成「**按操作逐个点名**」（5 个 label + 1 个计数兜底），
并把「刻意不覆盖 `revoke` / `registerDevice` / `fetch*`」的理由写进守卫 ——
因为「不在循环里、不构成突发」这个判断本身就是设计的一部分，不该只留在某个人脑子里。
新增 2 个变异锚点。

**涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、
`Scripts/verify-release-safety.py`（R24 重写 + 2 变异）。

**验证状态**：守卫 **PASS（351 源码断言 + 189 变异）**；云构建 + 真机待验。

**顺带踩到的坑**：改断言文案后忘了同步变异锚点的**期望文案** ⇒ 守卫报
`Guard failed mutation check`，看着像「变异没被抓到」，其实是断言已触发、消息对不上。
（见「常犯坑位」新增条。）

---

### 2026-09-17 · 「只有抖音签不上」：App ID 创建顺序 + 缺一条能把两种成因分开的诊断

**现象**（用户原话）：`id失效就是签抖音会这样 其他的不会，并且重新添加id签抖音不行，签其他app就行`。

**已知线索**：抖音 = 主 App + 8 扩展，一次签名要连发 **9 次 `addAppID`**；
免费账号「7 天内最多注册 10 个 App ID」是**主 App 与扩展共享**的名额。
用户三个账号里只有 `318***5***@qq.com`（1/10）名额够，而它恰好就是报「失效」的那个。

**根因（两条，互相独立）**

1. **创建顺序**：`provisioningProfiles` 的 Phase 1 用 `mappings.sorted(by: { $0.key < $1.key })`
   遍历，即按 Bundle ID **字母序**创建 App ID。而这段代码的降级规则是**不对称**的：
   - 扩展创建失败 ⇒ `signingWorkspace.removeExtension` + 记入 `droppedExtensionBundleIdentifiers`，**继续签名**；
   - 主 App 创建失败（`guard mappedBundleID != mappedMainBundleID else { throw error }`）⇒ **整个签名抛错**。

   `-` 的码位（0x2D）小于 `.`（0x2E）⇒ 形如 `com.x.app-ext` 的扩展会排在 `com.x.app` **前面**。
   于是扩展先把有限名额吃掉，轮到主 App 时名额已空 ⇒ 整个 App 签不上，**而名额已经白花**。

2. **诊断缺失**：「名额不够」与「请求过密被限流」在日志里**完全同形**（都是 App ID 阶段报 1100），
   但处置相反（换账号/等 7 天 vs 等几分钟重试）。缺一条无条件诊断，用户发来的日志**分不出是哪一种**。

**修复**

- 顺序抽成纯函数 `ApplePortalAppIDResolver.preparationOrder(mappings:mappedMainBundleID:)`
  —— 主 App 排最前，其余按原序**稳定**排序（顺序抖动会让重试时的日志对不上）；Phase 1 改用它。
  主 App 优先之后，最坏是「部分扩展被丢弃」（界面本来就会列出被丢弃的扩展），而不是「签不上」。
- Phase 1 开头无条件写一条名额诊断：
  `App ID 名额：本次需 9 个（主 App 1 + 扩展 8），账号上已有 N 个、其中可复用 M 个，需新注册 K 个`
  —— **K 大于剩余名额 = 名额问题；K 很小却仍报 1100 = 限流**。

**为什么是这两条而不是「加长退避」**：退避重试（`withSessionRecovery`）三个 portal 变更**早就有**，
再加长是「先调参后取证」。这两条一条是确定性的逻辑缺陷，一条是取证手段 ——
拿到用户下一次的日志后，才知道要不要动退避时长。

**涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、
`SealTests/Signing/ApplePortalSigningFailureTests.swift`（+2 单测）、`Scripts/verify-release-safety.py`（R26）。

**验证状态**：守卫 **PASS（349 源码断言 + 187 变异）**；云构建 + 真机待验。
**待真机确认的判据**：用户下次签抖音时，日志里
①有没有 `App ID 名额：…需新注册 K 个`；②K 与账号剩余名额的关系；③有没有 `SEAL-AUTH-107`。

---

### 2026-09-17 · 审计「保护性包装」的覆盖：同步 FFI 有两处**无界阻塞**

**做法**（比逐个碰运气更系统）：把仓库里的保护性包装全列出来，检查**哪些危险原语的调用点
没被包住** —— 前五次「漏一条链路」都是这么发现的。

| 包装 | 用途 | 用了多少次 |
|---|---|---|
| `withAppleTimeout` | Apple 网络请求超时 | 26 |
| `withSessionRecovery` | 遇 1100 退避重试 | 3 个 portal 变更 |
| `offThread` / `HardTimeout.run` | 同步 FFI 挪出主线程 + 硬超时 | 16 / 11 |

**审计出来的问题**：`Minimuxer.isAppInstalled` 有**两处只有 `Task.detached`、没有任何超时**：

| 位置 | 之前 |
|---|---|
| `InstalledAppDeviceVerifier` | `Task.detached` ⚠️ 无超时 |
| `DeviceProfileCleaner.probeInstalled` | `Task.detached` ⚠️ 无超时 |

**这违反了本仓的明文规则**：「同步阻塞 FFI 的等待必须带超时」。
**`Task.detached` 不等于有界** —— 它只是把调用挪出主线程，**阻塞本身仍然无界**：
死会话上不报错、只阻塞到操作系统放弃（与安装路径同一个失败模式）。

⚠️ 其中 `probeInstalled` 跑在**维护期** ⇒ 一次无界阻塞会让**整轮维护永远完不成**，
而且**日志里毫无线索**（`扫描 N，匹配 M` 之后什么都没有）。

**修法**：把 `offThread` 的实现抽成共用的 `BlockingCall.bounded(seconds:_:)`（新增
`Seal/Infrastructure/Installation/BlockingCall.swift`），三处共用：

1. `InstalledAppDeviceVerifier` —— 超时按「不知道」抛错，调用方本来就 fail closed（保守跳过）；
2. `DeviceProfileCleaner.probeInstalled` —— 超时归 `unavailable` ⇒ 按既有约定**整轮中止**；
3. `MinimuxerInstallChannel.offThread` —— 改为**委托**给共用实现（不再保留第二份）。

超时取 **15 秒**（与 `dumpProfiles` 内部的 `deviceFetchTimeoutMs` 同量级）——
查询正常是亚秒级，15 秒已经非常宽松，唯一用途是把「永久阻塞」变成「有界失败」。

> ⚠️ **超时的语义是「本次放弃等待」，不是「取消工作」**：同步 FFI 响应不了取消，
> 它会在后台跑完、结果被丢弃。所以对**查询类**调用安全（没有副作用要撤销），
> 对**有副作用的调用**要按 R05 另行判断。

#### 守卫

**337→342 源码断言、178→181 变异**（R25 段 5 条断言 / 3 个变异锚点）。

---

### 2026-09-17 · 证书创建漏了「遇 1100 退避重试」——这是「只有抖音签不上」的直接成因

**用户反馈**：Apple ID「失效」**只在签抖音时**发生；重新添加该 ID 再签**还是不行**；
**签其他 App 就行**。⇒ 第三条证明**账号没坏**。

**追下去发现两件事**（第二件才是关键）：

1. 证书阶段的**文案**只给「去重新登录」一条路 ⇒ 用户陷入
   「重新验证 → 再签 → 又被限流 → 又被要求验证」的死循环（R23 修）。
2. **证书创建没有过 `withSessionRecovery`** —— 而另外两个 portal 变更都有：

| portal 变更 | 退避重试 |
|---|---|
| 创建 App ID | ✅ |
| 申请描述文件 | ✅ |
| **创建证书** | ❌ **漏了** |

> **这是「同一条规则只落在两条链路中的一条」的第 5 次**（前四次：`InstallStageTimeline`、
> 错误映射的 `detail` 构造、安装心跳、以及 R12/R14 那对）。
> 每次都是「一处有、一处没有」，而且**守卫也只覆盖了有的那一条**。

**为什么这条最要紧**：**证书是整条签名流程里第一个真正落到 Apple 侧的变更**。
多扩展 App（抖音 = 主 App + 8 扩展）的上一次尝试刚连发过一批请求，
这次一上来就可能撞上短时限流 ⇒ 返回 1100 ⇒ 没有重试 ⇒ 直接被 `certificateFailure`
归类成「账号需要重新验证」⇒ 用户去重新验证、再签、又被限流。

**修法**：把 `addCertificate` 也包进 `withSessionRecovery("创建证书")`。
退避重试后仍失败才向上抛（与另外两条一致）。

**顺带的取证价值**：`withSessionRecovery` 每次重试都会写
`Apple 会话疑似被限流，退避 N 秒后重试 创建证书（第 N 次重试）` ——
**此前证书阶段完全看不到这一层**，下次日志就能直接回答「到底是不是限流」。

#### 守卫

**333→337 源码断言、177→178 变异**（R24 段 4 条断言 / 1 个变异锚点）。
断言把**三个 portal 变更全部钉住**（外加一个调用点计数），
防的就是「将来再加一条 portal 调用、却只给其中一条加保护」。

---

### 2026-09-17 · 修掉我自己上一轮引入的**假警报**：超时阈值写死了

**怎么发现的**：想用户下一步要做什么（签抖音，**779.7 MB**），顺手算了一下它的等待上限：

```
mergedInstallBudgetSeconds(ipaMB: 779) = min(1800, 180 + 779×5) + 600 = 1800 + 600 = 2400 秒
```

而 R18 那条「等待已明显超常」的阈值是**写死的 120 秒** —— 那是按「普通小包 7–11 秒」定的。
**大包本来就慢**，等两分钟完全正常 ⇒ 抖音一签就会报一条**假警报** ✅。

> **假警报比没有警报更糟**：它会把真信号埋掉（本仓已经因为「脚手架占 30% 日志」吃过一次亏）。

**修法**：阈值改成**按本次等待上限算**（`max(120, budget / 4)`）—— 小包 804/4 ≈ 201 秒、
抖音 2400/4 = 600 秒。文案也带上「本次等待上限 M 秒」，让读者自己能判断。

⚠️ **两个调用点必须各自传自己的预算**：自替换是 892 秒、普通是 804 秒，**不是同一个数**。
守卫断言把这一点钉住（`beginInstallHeartbeat("自替换安装", budget: budget)` +
`beginInstallHeartbeat("安装", budget: mergedTimeout)`）——
少传一个，那条链路就会退回写死阈值。

#### 顺带

- 改签名会让**已有的变异锚点失效**（本次两个：R14 的「普通路径心跳」锚点）。
  守卫报的是 `Mutation anchor missing`，**这是预期内的** —— 改锚点，不要为了过守卫把签名改回去。
- 守卫耗时因新增的 `all_log_codes()`（一次读 165 个 Swift 文件）从 ~2 分钟涨到 **~3 分钟**；
  文档里的「85–170 秒」已更新。

#### 守卫

**329→330 源码断言、174→175 变异**（R18 段断言与锚点按新形状重写）。

---

### 2026-09-17 · 「证书轮换失败」的文案漏了**后果**：用那些证书签的 App 已经打不开

**发现路径**：构建 105 的日志里，失效账号那条是 `证书检查：远端 0 张` —— **它的证书没了**。
往上追轮换代码：

```swift
try await revokeCertificate(certificate, team: team, session: session)   // ← 先撤销
...
do {
    let identity = try await createSigningIdentity(...)                  // ← 再创建
    return identity
} catch let failure as ImportFailure where failure.code == "SEAL-CERT-204b"
    && index + 1 < candidates.count {                                    // ← 只有这一种情况继续
    ...
}
```

⇒ **撤销成功 + 创建失败（非 3022）⇒ 直接抛出，而证书已经没了。**
后果是：**用那张证书签名的 App 全部无法启动。** 真机上那个账号的 `远端 0 张` 就是这么留下的。

**旧文案的两个缺口**：

```
title:    "证书轮换失败"
reason:   "已释放 N 张不可用证书，但 Apple 仍未允许创建新的本机签名身份。"
recovery: "稍后重试"
```

1. **没说后果** —— 用户不会知道「为什么我的 App 突然打不开了」，只会看到 App 莫名启动不了；
2. **`recovery` 是无效建议** —— 失败原因常常是会话失效（`SEAL-AUTH-102c` 那条路径），
   那种情况下「稍后重试」永远不成功，**必须先重新验证账号**。

**修法**：把后果写进 `reason`，`recovery` 改为「先确认这个 Apple ID 的登录仍然有效
（必要时到「我的」重新验证），再重试」。

> 这条与 3018、安装超时文案同族：**文案必须让用户能做对下一步**。
> 「稍后重试」看起来无害，但当真实原因需要用户做别的事时，它把人**引向死循环**
> （重试 → 还是失败 → 再重试）。

⚠️ 注意这条**只改文案、不改行为**：撤销顺序（先撤后建）是有原因的 ——
免费账号证书数量有限，先建后撤可能直接撞上限。真要改顺序是另一件事，需要先取证。

#### 守卫

**324→326 源码断言、169→171 变异**（R21 段 2 条断言 / 2 个变异锚点：
去掉「后果」那句、把 `recovery` 退回「稍后重试」 —— 均已验证会红）。

---

### 2026-09-17 · 真机（构建 105）：R17/R18 确认生效；补上「anisette 准备」这段静默

#### ✅ 先记战果

| 修复 | 构建 105 实测 |
|---|---|
| R17 续签结果结算 | **`[SEAL-RENEW-026] 上次续签被中断，但 1 个应用的结果已从持久化载荷结算（不再标为未知）`**，且**没有** `SEAL-RENEW-007`（假警报）✅ 抽屉显示 `succeeded: 2, failed: 0` ✅ |
| 扩展随父保护 | `候选 4，回收 0，已装保留 1，扩展随父保留 3，受保护 1` ✅ |
| 时间戳脱敏 | `生效=2026-09-17T12:14:32Z，到期=2027-09-17T12:14:31Z` ✅ |
| 安装 | 4.0 秒 / 4.4 秒 ✅（活性探测零命中 = 会话是活的） |

#### 🔴 新发现：`证书检查` 到失败之间**空白了 2 分钟**

```
20:28:19 签名  准备签名：抖音，Apple ID：318***5***@qq.com
20:28:22 签名  证书检查：远端 0 张，本机有私钥 0 张，…；设备核验已完成
20:28:22 签名  证书自动清理跳过：…
20:30:23 错误  签名  [SEAL-AUTH-102c] 账号需要重新验证：Apple 返回：认证状态无效
```

**121 秒里一行日志都没有。** 而排除了两个常见嫌疑：

- **不是 1100 退避**：`withSessionRecovery` 每次重试都会写「Apple 会话疑似被限流，退避 N 秒后重试」
  —— 日志里没有这一行。
- **不是安装链路**：这一段在签名阶段，与 `MinimuxerInstallChannel` 无关。

**定位**：日志里**没有 `证书决策`** 那一行 ⇒ 失败发生在「证书决策」**之前**。
那一段是 `signOnce` 开头的 `anisetteProvider.fetch()` —— 而代码在 `SEAL-AUTH-107t` 的文案里
自己就写明「**本地签名内核生成设备环境时卡住**」。**这一步此前没有任何日志。**

> 与安装心跳同一条纪律：**长等待必须留下可判读的时间线。**
> 「等了 2 分钟」本身不是问题，**无法归因到哪一步**才是问题。

#### 修法

在 `anisetteProvider.fetch()` **前后各写一条**（成功路径也写，因为耗时是唯一判据）：

```
签名：正在准备设备环境（anisette）
签名：设备环境已就绪，耗时 N 秒
```

⚠️ 刻意**不加周期性心跳**：这一步正常是秒级，只有真的慢时才需要判读，
加心跳会把日志填满（本仓已有一次「脚手架占 30% 日志」的教训）。

#### 守卫

**322→324 源码断言、166→169 变异**（R20 段 2 条断言 / 3 个变异锚点：
去掉「开始」那条、**把留痕挪到 `fetch()` 之后**、去掉耗时 —— 均已验证会红）。
断言用 `section_or_empty` 取 `signOnce` 的函数体，比三个锚点的**相对位置**。

#### 顺带：账号侧的真实现状（来自用户截图，与代码行为一致）

| 账号 | 状态 | 已签名 |
|---|---|---|
| `[已脱敏 Apple ID]` | 有效 | 4 / 10 |
| `249***0***@qq.com` | 有效 | **10 / 10（满）** |
| `318***5***@qq.com` | **失效** | 1 / 10 |

失败用的是失效的那个账号 ⇒ `SEAL-AUTH-102c`（映射 `.credentialsRejected`）✅
**引导正确，不是缺陷**。

⚠️ **一条容易忽略的约束**：代码注释写明 **抖音 = 主 App + 8 扩展，需连发 9 次 `addAppID`**。
所以选账号时要留够名额：**10/10 那个不能用来签抖音**。

---

### 2026-09-17 · Seal 早期的**裸** Bundle ID 也能回收了（`com.mjorb.seal`）

**怎么发现的**：用户发来的 App Expiry 截图里，设备上**同时存在两份都叫「Seal」的 profile**：

```
<TEAM_ID> / com.example.seal.<TEAM_ID>   ← 正在用的
<TEAM_ID> / com.example.seal              ← 早期的，2026-09-23 到期，一直没被清
```

**根因**：那份遗留的 Bundle ID 是 Seal **早期的裸形态** `com.mjorb.seal`，它两头不沾：

| 路径 | 为什么漏掉它 |
|---|---|
| 保留集合内去重（路径 1） | keep-map 的 key 是**当前**形态 `com.mjorb.seal.<team>` ⇒ 不同 key |
| 孤儿回收（路径 2） | 形态判据要求 **`.seal.` 中缀**，而 `com.mjorb.seal` 里没有（结尾无点） |

⇒ **永远回收不掉**。而危害不只是「多一份垃圾」：**两份同名**会让用户手动清理时
**删错正在用的那一份** —— 那对应 Seal 立刻无法启动。

**修法**：在 `isReclaimableOrphan` 里加一条**精确相等**判断
（引用 `SelfManagedSealMigrationPolicy.canonicalBundleIdentifier`，不抄第二份字面量）。

**为什么安全**（两条，缺一不可）：

1. `SelfManagedSealMigrationPolicy.recommendedBundleIdentifier` 只会产出
   `com.mjorb.seal.self` / `com.mjorb.seal.t<team>`（**都含中缀**）
   ⇒ 裸 ID **不是** Seal 当前的 Bundle ID，所以「正在用的那份」不会被这条判成候选
   （何况 keep-map 的守卫先跑）。
2. 它仍要过 `decision` 的**设备端核验** —— 万一那个旧 App 还装着，
   `isAppInstalled` 会答「装了」并保留它。

⚠️ 必须**精确相等**，不能 `hasPrefix`：`com.mjorb.sealX` 不是 Seal 生成过的任何形态，
前缀匹配会把它也放进来（那才是真的会删错东西）。

#### 守卫

**317→322 源码断言、162→166 变异**（R19 段 5 条断言 / 4 个变异锚点）。
其中**最关键的是顺序断言**：用 `section_or_empty` 取 `isReclaimableOrphan` 的函数体，
比 `keepingByBundleID.keys.contains` < `protectedBundleIDs.contains` <
裸 ID 分支的**相对位置** —— 裸 ID 分支若跑到守卫之前，
「正在用的那一份」会被判成候选 ⇒ **删掉 Seal 自己**。

⚠️ 写这条锚点时踩到一个坑：`let lowered = normalized(bundleID)` + 那句 guard 在
**同文件的 `isExtensionBundleID` 里也有一份**，只写这两行**不唯一**（变异会打到别处）。
⇒ 锚点带上函数签名才唯一。**加变异锚点时要检查 `old` 在文件里是否唯一。**

---

### 2026-09-17 · 安装等待「明显超常」时留一条**可判读**的记录

构建 102 的日志里两次安装都是 6–7 秒，**没有复现 9 分钟卡死**，活性探测也零命中
（会话是活的）⇒ 那个假设既没被证实也没被否证。而「慢」与「死」在没有设备端进度信号时
**无法区分**，所以能做的是让**下一次**卡死可判读。

**做法**：等待超过 **2 分钟**（普通安装只要 7–11 秒）时，心跳**多写一条**（只写一次）：

```
安装等待已明显超常：已等待 N 秒（普通安装约 7–11 秒）。
判读：界面仍显示上传百分比 ⇒ 卡在传输；显示「设备正在安装」⇒ 卡在 installd
```

**为什么这条有用**：`installd` 在安装阶段不回报进度，所以日志只能告诉我们「等了多久」。
但**界面**能区分阶段 —— 上传有真实百分比，安装阶段是「此阶段没有进度回报」。
两者要查的方向完全不同（传输 ⇒ 查隧道 / 会话；installd ⇒ 查设备端）。

⚠️ **刻意只记日志、不改变行为**：等待上限按包大小算（小包 804 秒、大包 2400 秒），
在没有设备端进度信号的前提下**不能**据此提前放弃 —— 真正的慢安装会被误判成死。
守卫断言「心跳里不得出现 `throw` / `reset()`」，把这个性质钉住。

**顺带确认两件不是缺陷的事**：

- `SEAL-RENEW-023` 在 3 秒内写了 3 次：`.pushing` / `.installing` **会被重复推送**
  （代码注释自己也这么说）。**不改** —— 加闸门反而引入「闸门没触发 ⇒ 结果没落盘」的风险，
  冗余写入是廉价保险。
- `dump 尝试 2 次` 出现在 8 轮维护中的 4 轮：首次撞 `NoDevice`（内部轮询 15 秒）、
  重试成功。**设计内**（`dumpAttemptLimit = 3` + 4 秒间隔 + `Provision.resetProvider()`），
  不是缺陷。

#### 守卫

**314→317 源码断言、159→162 变异**（R18 段 3 条断言 / 3 个变异锚点）。

---

### 2026-09-17 · 真机（构建 102）：三项修复全部确认生效；新发现「续签结果自相矛盾」

日志 `Seal-log(12).txt`（构建 **102**）+ 用户截图（App Expiry 列表）。

#### ✅ 先记战果 —— 三项修复在生产里确认生效

| 修复 | 上一份日志（构建 97） | 本次（构建 102） |
|---|---|---|
| 时间戳脱敏 | `生效=20****09-17T06:38:18Z，到期=20****09-17T06:38:17Z`（看着像「到期早于生效」） | `生效=2026-09-17T09:01:57Z，到期=2027-09-17T09:01:56Z` —— **完整，且证实是 1 年期证书** |
| 扩展随父保护 | `候选 4，回收 3`（三个扩展被删） | **`候选 4，回收 0，已装保留 1，扩展随父保留 3，受保护 1`** —— 一个都没删 |
| 安装 | 卡住 9 分多钟、日志空白 | `耗时 6.0 秒` / `6.7 秒`，**无卡死**；活性探测零命中（会话是活的） |

截图独立佐证：设备上 LiveContainer 主 App + **三个扩展** profile 都在，到期 2026-09-24。
而 `受保护 1` 也证实了当时的判断 —— **Seal 刚重装，记录里只剩 Seal 自己**，
所以扩展**只能**靠「父 App 已安装」这条与记录无关的判据救下来。

#### 🔴 新问题：同一个批次给出**三份互相矛盾**的结论

```
17:23:07 [SEAL-RENEW-020] 批量续签：第 1/2 项成功 —— LiveContainer
17:23:25 [SEAL-RENEW-023] 批量续签结果已持久化（共 2，成功 2，失败 0，明细 2 项）
17:23:26 安装  Seal 自替换：3 秒内进程仍存活（转场未生效），强制 exit(0)
17:23:39 [SEAL-RENEW-024] 批量续签结果已从持久化载荷恢复（共 2，成功 2，失败 0，明细 2 项）
17:23:40 [SEAL-RENEW-007] 警告  上次续签被中断，1 个应用的结果未知，需要重新核验     ← 假警报
17:23:40 [SEAL-RENEW-021] 警告  待恢复的批量续签结果被跳过：当前有进行中的会话或结果抽屉仍开着
17:23:42 [SEAL-RENEW-025] 批量续签结果抽屉已关闭（completed(total: 2, succeeded: 2, failed: 0))
```

**根因**：Seal **自己替换自己**时，进程**必然**在队列项还是 `running` 的时候被杀。
但那一项的结果**已经写进持久化载荷**了 —— 写入侧第 1668 行明确写着
`"state": item.isSeal ? "completed" : item.state.storageValue`，
因为自替换成功时进程已经死了，没机会写自己的状态。

于是两条恢复机制各说各话：

| 机制 | 它的结论 |
|---|---|
| 队列恢复（`recoverInterrupted`） | 盲目把 `running` 一律降级为 `unknown` ⇒「1 个应用的结果未知」 |
| 载荷恢复（`SEAL-RENEW-023/024`） | 知道是 `succeeded: 2, failed: 0` |

后果三条：**假警报**（要用户去「重新核验」一件已经成功的事）、
**幽灵条目**（队列里那一项永远 `outstanding`）、
**界面自相矛盾**（警告与「成功 2/2」同时出现）。

> **这是「两条链路各说各话」的又一例**（此前是 `InstallStageTimeline`、错误映射的
> `detail` 构造、安装心跳）。区别是这次两条链路**都对**，只是**互不知情**。

#### 修法

1. **顺序**（这条修复的核心）：`recoverInterruptedQueueIfNeeded()` 里
   **先恢复载荷、读出已定论的项，再结算队列**。
2. **结算而不是降级**：`recoverInterrupted(settled:)` 收到 `appID → 状态` 的映射，
   有结论的项按结论结算（`completed` / `failed`），**只有真没结论的才降级为 `unknown`**。
3. **只映射「已定论」的两态**：`settledQueueState` 对 `waiting` / `running` /
   `preparingSealUpdate` 返回 `nil` —— 把 `running` 也映射上等于**替那个正在被杀的项
   宣布结果**。
4. **两个数分开报**：`downgraded > 0` 才发「需要重新核验」的警告；
   `settledFromResult > 0` 是新码 `SEAL-RENEW-026`（info）—— 否则下次只看到
   「0 个未知」，无法判断是「本来就没被中断」还是「被结果结算掉了」。
5. **顺带修掉 021 的重复**：载荷要等抽屉关闭才清，这中间每次 `load()` 轮询都会看到
   「载荷还在 + 会话开着」⇒ 反复报同一条「被跳过」警告（把真警报埋掉）。
   加 `hasRestoredPendingBatchResult` 标志，「**已恢复进会话**」不算「被跳过」。

#### 守卫与测试

- **305→314 源码断言、152→159 变异**。
- ⚠️ **第一次推送把云构建弄红了，原因值得记**：把判据挪到新文件
  `PendingBatchResultPayload.swift` 时，它要用的 `BatchRefreshSession.Item.State` 那组
  状态↔字符串映射当时是 **`private extension`（file 级）**，住在 `AppsViewModel.swift` 里
  ⇒ 新文件**和它的单测**都访问不到：
  `error: initializer is inaccessible due to 'fileprivate' protection level`。
  **修法不是抄一份**（那就成了「同一条规则两份实现」），而是**把映射搬到类型自己的文件**
  （`BatchRefreshSession.swift`）并放开为 `internal` —— 写入侧、读取侧、单测三处共用一份。
  **教训：把判据从「只能内部用」的地方挪出来时，先确认它的访问级别够不够。**
- 顺带修掉一个断言漏洞：`"extension X {"` 是 `"private extension X {"` 的**子串**，
  所以「只在别处查有没有 private」抓不到「被收回成 file 级」这个变异 ——
  两个条件必须都落在**新文件**上。变异已复核会红。
- 两条**既有断言**因行为变更而失效，已更新为**新行为**（而不是把实现改回去）：
  - `G: launch recovery must downgrade…` → 签名带了 `settled:`，文案改为
    「**没有结果的**项才降级」。
  - `R12: the restore poll path must stay silent…` → 条件多了
    `hasRestoredPendingBatchResult == false`。
- 新增 R17 段 9 条断言，其中**最关键的是顺序断言**：用 `section_or_empty` 取
  `recoverInterruptedQueueIfNeeded` 的函数体，比
  `restorePendingBatchResultIfNeeded()` < `settledQueueStates(from:` <
  `recoverInterruptedQueue(settled:` 的**相对位置**。
- 新增 6 个变异锚点（一律降级、**顺序对调**、忘了先恢复、把 `running` 也映射、
  **把映射收回成 file 级**、单测改名），均已验证会红。
- 新增单测：`RefreshQueueStoreTests` +3（结算而非降级、结算过的项离开 `outstanding`、
  陌生 appID 被忽略）；新建 `PendingBatchResultPayloadTests`（6 条：Seal 那项按
  `completed` 结算、只映射已定论两态、空/畸形载荷、后者覆盖前者、`storageValue` 互逆）。

---

### 2026-09-17 · 「安装静默 9 分钟」的机制找到了：缓存 RSD 会话没有任何活性校验

**结论先写**：机制成立、证据链完整，但**还差一条直接证据**，所以这一轮**只加取证、不改行为**。

#### 一、链路本身没有任何一处验证会话还活着

安装复用 `connect_to_rsd_services` 的**缓存隧道会话**（`Install.swift:154` 的注释写着
「走 connect_to_rsd_services 的缓存隧道会话」），而这条链路上：

| 检查点 | 实际查的是 |
|---|---|
| `MinimuxerInstallChannel.start()` 的 900 秒缓存 | `Minimuxer.ready()` —— **内部标志位** |
| `installSignedIPA` 的唯一漏斗 `if !isReady() { start() }` | 同一个标志位 ⇒ **标志为真时连 `start()` 都不调**，更不会重建连接 |

⇒ **一条已经死掉的会话在 15 分钟内永远不会被重建。**

#### 二、本仓自己的注释**三处**都记着这个失败模式

```
Install.swift:645  每次安装前重置Install提供者，避免使用已断开的RSD缓存连接
                   推送大文件后RSD连接可能超时断开，isReady()只检查TCP不检查RSD服务
Minimuxer.reset()  RSD 缓存连接可能已随隧道断开；不复位会让重试一直复用死连接
verifyInstalled()  验证前重置连接，避免用死连接查询
```

**三处都在「重试 / 验证」时补救，没有一处发生在「第一次尝试之前」。**

#### 三、为什么「第一次尝试」才是致命的

死会话上跑同步 FFI **不会立刻报错**，而是**阻塞到操作系统放弃**。所以：

- 重试路径的补救**永远轮不到** —— 它要等一个错误，而这里没有错误，只有沉默。
- 真机实测：普通安装静默 **9 分多钟**（等待上限 804 秒），日志里一行都没有；
  而同一次会话里前一次安装只用了 **10.7 秒** —— 那次会话是刚建立的。

#### 四、顺手澄清一个**不是**杠杆的东西

`Install.resetProvider()` **只清 Swift 侧的 provider 对象**，清不掉 Rust 侧的会话缓存。
真正的杠杆是 `Minimuxer.reset()` 里的 `RustIdevice.invalidateConnection()`。
⇒ 所以「把 `installPushedIpa` 里那句 `resetProvider()` 补到合并路径」**是无效修复**，
写代码前先确认那个调用到底清了什么。

（另：`installPushedIpa` / `pushIpa` 在生产里**没有调用方**，只剩协议与测试桩，
所以它的「每次尝试前 reset」既是遗留、也不能当「已验证的做法」引用。）

#### 五、这一轮做了什么：**有界的活性探测，只记日志**

```
安装前探测：复用已启动 N 秒的缓存会话，5 秒无响应（疑似死连接）      ← 只在异常时写
安装前探测：复用已启动 N 秒的缓存会话，查询报错（疑似死连接）—— …    ← 只在异常时写
```

- **有界**（5 秒）：探测自己也不能卡住 —— 它要验证的正是「死连接会阻塞」。
- **只在会话已启动 > 60 秒时才探**：保住 900 秒缓存的意义，不为每个 App 多问一次设备。
- **只在异常时写日志**：成功路径不写（本仓已有一次「临时脚手架占了 30% 日志」的教训）。
- **只记日志、不重建连接**：重建（`Minimuxer.reset()`）会拆掉**可能仍在跑**的上一笔
  安装连接（R05）。在拿到「会话确实是死的」这条直接证据之前不动行为。

**下一次再卡住，日志里会先出现这一条** ⇒ 假设成立就修，不成立就换方向。

#### 六、守卫

- **299→305 源码断言、148→152 变异**（R16 段 6 条断言 / 4 个变异锚点）。
- 四条断言把「只取证」的性质钉住：必须调、必须在**第一次尝试前**调、必须**有界**、
  必须走**会抛错的真往返**（不能用标志位），且方法体内**不得出现 reset**。
- 四个变异锚点：去掉调用点、把上限放到 600 秒、换成标志位检查、在探测里顺手 reset
  —— 均已验证会红。

---

### 2026-09-17 · 脱敏把日志里**所有 ISO 时间戳的年月都吃掉了**

**怎么发现的**：排查构建 97 的日志时，看到这一段：

```
14:48:20  签名  新证书核验：序列号末尾 …ECE2BA08，生效=20****09-17T06:38:18Z，到期=20****09-17T06:38:17Z
```

**「到期」比「生效」早 1 秒** —— 看上去像「证书刚创建就已过期」，我差点把它当成
证书轮换的 bug 报上去。实际是脱敏把**年份与月份**吃掉了。

**根因**：`LogPrivacyRedactor.redactPhoneNumbers` 的模式

```
(?<![A-Za-z0-9])\+?[0-9][0-9 \-()]{5,}[0-9](?![A-Za-z0-9])
```

字符类里有数字与连字符 ⇒ 在 `2026-09-17T06:38:18Z` 里它会匹配到 `2026-09`
（回溯到 `[0-9]` 落在 `9`、结尾断言看到 `-` 通过）。而 `AppleAccountClient.mask`
对 6 位数字给出 `prefix(2) + "****" + suffix(2)` ⇒ **`20****09`**。

于是 `2026-09-17` → `20****09-17`，`2026-09-24` → `20****09-24`，
**每一行 ISO 时间戳的年月都没了**。证书的 `notBefore` / `notAfter` 相差整整一年，
脱敏后几乎一模一样（只差 1 秒）—— 这正是把我引错的那一步。

> **日志是唯一的排障通道**，时间戳是它最基本的维度。把年月毁掉，
> 「什么时候发生的」「间隔多久」全部不可读，而这两件事是排查的第一手信息。

**修法（两道防线，缺一不可）**：

1. **匹配不能停在日期中间** —— 结尾断言多排除 `-` 与 `:`：
   `(?![A-Za-z0-9\-:])`。否则 `2026-09-17 14:54:02` 里的 `2026-09-17 14` 也会被吞掉。
2. **形状判据**：片段匹配 `^(?:19|20)\d{2}-(?:0[1-9]|1[0-2])(?:-(?:0[1-9]|[12]\d|3[01]))?$`
   时**原样返回**。收紧到「19xx/20xx + 合法月份 + 可选合法日」是为了**不放过真手机号**：
   `1234-5678` / `1234-56` / `020-12345678` / `2026-13` / `2026-09-32` 都不算日期，照旧脱敏。

⚠️ **放宽日期识别 = 给脱敏开口子**，所以两个方向都要有单测：
`keepsISOTimestampsIntact` / `certificateValidityPeriodStaysReadable`（别多脱敏）
＋ `stillRedactsRealPhoneNumberShapes` / `dateShapeDetectorRejectsPhoneLikeNumbers`（别少脱敏）。

**守卫**：**294→299 源码断言、144→148 变异**（R15 段 5 条断言 / 4 个变异锚点）。

> 这类「**脱敏过度**」的错法很隐蔽：它不崩、不编译失败，只是让日志变得**看起来正常但读不出信息**。
> 判据：**脱敏规则改完，拿一条真实日志行跑一遍，确认「该留的还在、该去的没了」**——
> 只测「秘密不出现」是发现不了这个的（本仓 `LogPrivacyRedactorTests` 原本只有那一侧）。

---

### 2026-09-17 · 真机（构建 97）：普通安装静默 9 分钟；扩展 profile 又被删了 3 份

日志 `Seal-log(11).txt`（构建 **97** = run#97，含扩展修复、**不含** 3018 修复）。
时间窗 14:46:52 → 14:54:02，用户截图停在「批量续签 1/2 · 正在安装 LiveContainer ·
此阶段没有进度回报 · 已等待 9:04」。

#### 🔴 一、普通安装卡住 9 分多钟，而日志里**一行都没有**

```
14:54:02  安装  开始安装：com.kdt.livecontainer.seal.TEAM000001，包 4.9 MB，第 1/3 次，等待上限 804 秒
（之后 9 分钟无任何日志，直到用户导出）
```

同一次会话里，**前一次**安装是正常的：`14:50:28 开始安装 → 14:50:39 安装调用已返回，耗时 10.7 秒`。

**根因：心跳只加在「自替换」那条路径上。** `waitForSelfReplacement` 每 15 秒写一条
`自替换安装仍在等待：已等待 N 秒`，而普通安装走 `offThread(seconds:)`，**没有心跳**。
所以一次卡住的普通安装在日志上就是一段完全空白 —— 排查时无法区分「还在装」与「死了」。

> 这条规则的来历本身就写着「真机 93 秒静默就是缺了它」（自替换那次的教训），
> 但当时**只补了一条链路**。守卫 R10 的心跳断言也只钉住了自替换那条，
> 所以普通链路静默时守卫照样全绿 —— 又一个「同一规则只落在两条链路中的一条」。
> 与 `InstallStageTimeline`、错误映射的 `detail` 构造是同一族问题。

**修法**：把心跳抽成共用实现 `beginInstallHeartbeat(_ label:)`，两条路径都走它；
守卫 R14 按 `count("beginInstallHeartbeat(") == 3`（1 定义 + 2 调用点）断言，
R10 的心跳断言改为指向共用实现。

**顺带确认（不是 bug）**：超时**不重试**。`if Self.isTimeoutInstallError(error) { throw error }`
在重试之前就原样抛出，理由（R05：底下那次安装很可能还在跑）写在注释里，设计是对的。
等待上限 804 秒 = `uploadBudgetSeconds(4.9MB) + 600`，对小包确实偏长，
但**先有证据再调参** —— 有了心跳才知道下一次是「慢」还是「死」。

#### 🔴 二、维护清理又删掉 3 份扩展 profile（扩展保护的第二个缺口）

```
14:47:05 [SEAL-PROFILE-320] 扫描 8，匹配 1，删除 0，dump 尝试 2 次；
         旧 Team 变体：候选 4，回收 3，已装保留 1，未能核验 0，
         示例 …TEAM000001.ShareExtension、…TEAM000001、…TEAM000001.LiveProcess、…TEAM000001.LaunchAppExtension
```

主 App 被设备端核验救下（`已装保留 1`），**三个扩展全删**（`回收 3`）——
与构建 95 那次（自替换结算路径）一模一样的形态，但这次发生在**维护路径**上。

**根因**：上一轮加的 `protectedBundleIDs`（宽松集合）来自 **Seal 的记录**。
而这次日志的开头是「手动导入配对文件成功」（14:46:52）——**Seal 是刚装的，记录里只有 Seal 自己**
（`匹配 1` 就是证据）。于是 LiveContainer 的主 App 与三个扩展**全都不在受保护集合里**：

| | 谁救它 | 结果 |
|---|---|---|
| 主 App | 设备端核验（`isAppInstalled` 真的能查） | 保住 ✅ |
| 三个扩展 | **没有人** —— `isAppInstalled` 对扩展恒为 `false` | 删掉 ❌ |

所以「记录里有过的 ID」这道保护对「**根本不在记录里**的 App」是无效的，
而扩展又没有第二道防线。

**修法：扩展随父 App 保留。** iOS 给扩展分配的 Bundle ID 是 `<父 App 的 Bundle ID>.<扩展名>`，
所以「父 App 已确认安装」⇒「这份扩展 profile 是随它一起装上去的」⇒ 必须保留。

- 新增纯函数 `ProfileReclaimPolicy.isExtensionBundleID(_:ofAnyOf:)`，
  **点边界**前缀匹配（`com.foo` 不是 `com.foobar` 的父）。
- `installedBundleIDs` **必须来自本轮候选的探测结果**，不能传「设备上所有已装 App」：
  候选都含 `.seal.` 中缀，所以从候选里取的父一定也是 Seal 生成的 ID；
  若拿任意已装 App 列表，原始 LiveContainer（`com.kdt.livecontainer`）会把
  **全部** `com.kdt.livecontainer.seal.*` 孤儿都「保护」成它的扩展 ⇒ 回收功能整体失效。
- 阶段 B 从「边问边删」改成「**先问完所有候选、再决定**」：扩展判定要等父 App 的探测结果，
  而那个集合只有问完才完整。副作用是**中止时一份都不删**（连已经问过的那几条也不删）——
  比原来更强，也更符合「中止是整轮的」。
- 新增 `reclaimKeptExtension`（扩展随父保留）与 `protectedCount`（受保护 N）两个归因计数。
  后者是「候选为什么这么多」的第一归因：记录读不到时它会是 0/极小。

#### 🔴 三、安装超时的提示在**骗人**：「系统已自动重试」，而实际不重试

排查上面那条时顺手读到的。超时的用户提示原文：

```
安装超时
向设备传输并安装应用超过 10 分钟仍未完成，系统已自动重试。
若多次出现，请检查 LocalDevVPN 连接是否稳定后再试（免费账号需使用外部 LocalDevVPN 软件）。
```

**两句都是错的：**

| 文案 | 实际 |
|---|---|
| 「系统已自动重试」 | 超时路径是**原样抛出、不重试**的 —— `isTimeoutInstallError(error)` 在重试循环里直接 `throw error`，理由写在注释里（R05：底下那次安装很可能还在跑，重试会在同一个 Bundle ID 上造出第二个 installd 命令） |
| 「超过 10 分钟」 | 等待上限按包大小算：`mergedInstallBudgetSeconds = min(1800, 180 + MB×5) + 600`。4.9 MB 就是 **804 秒 ≈ 13.4 分钟**，大包可到 **2400 秒 = 40 分钟** |

**危害**：读到「已自动重试」的用户会**继续等一个并不存在的重试**，而不是去确认 App 是否
其实已经装上 —— 而底层调用确实**不会**被取消，所以「等一会儿再看，它可能已经装好了」
才是正确的下一步。这与 3018 那次同族：**文案把用户引向错误的预期**，
不崩、不编译失败，只在真机上让人做出错误判断。

**修法**：文案改成与实现一致 —— 说明「已停止等待」「调用不会被取消，也不会自动重试」
「可能在你看到这条提示之后仍然完成安装」，恢复建议改为「先等 1–2 分钟，回列表确认
这个 App 是否其实已经装上；确认没装上再重试」。守卫新增 3 条断言
（不得出现「系统已自动重试」、必须说明不取消不重试、超时分支必须 `throw error`）。

#### 四、守卫与测试

- **279→294 源码断言、138→144 变异**（R14 段 15 条断言 / 6 个新变异锚点，
  另改写 2 个因重构失效的既有锚点）。
- 顺手修掉两条**只覆盖单条链路**的既有断言：
  - R10 的心跳断言原来钉的是 `自替换安装仍在等待：` 与 `Self.selfReplacementHeartbeatNanoseconds`，
    普通链路静默时它照样绿 ⇒ 改为指向共用实现（双路径由 R14 断言）。
  - R11 的 `.abortPass` 断言钉的是 `if reclaimAbortReason != nil { break }`，
    形状改成 `guard … else { 记录原因; return }` 后同步更新（语义更强了），
    变异锚点也一并改写为「删掉 `return summary`」。
- 新增单测：`ProfileReclaimExtensionTests`（7 条，含点边界、父未装不保护、空集合不多留、
  大小写不敏感、自己不是自己的扩展）；`DeviceProfileCleanerTests` +4 条（受保护 N、
  扩展随父保留的独立计数、为 0 时不写）。

#### 五、同日稍早：3018（需要双重认证）

见下一条。**run#98（`7bd0325`）三个 job 全绿。**

本轮修复的提交 `2c5fc25`（父 `7bd0325`）→ **run#99**（id `35194612650`），
`build-package` / `swift-regression` / `rork-sign-tests` **全绿**。

---

### 2026-09-17 · 新账号报「3018 / 需要双重认证」，界面却叫用户去核对密码

**现象**（真机日志，构建 95）

```
[SEAL-AUTH-107a] Apple ID 验证失败。
类型：ALTAppleAPIError
Domain：AltStore.AppleDeveloperError
Code：3018
描述：This account requires signing in with two-factor authentication.
```

界面给的恢复建议是「**重试；如持续失败请核对 Apple ID 与密码**」。

**根因**：**密码完全没问题** —— Apple 已经接受了密码，只是要求走第二步（输入验证码）。
`AppleAccountClient` 只 catch 了 `incorrectVerificationCode` / `incorrectCredentials` /
`invalidAnisetteData`，**没有 requiresTwoFactor 分支** ⇒ 3018 落进泛化的
「Apple ID 验证失败」，恢复建议指向一个正确的密码。用户会在正确的密码上反复试，
甚至跑去重置密码。

**修复**：新增 `AppleAuthenticationDiagnosis`（判据与文案放在一起，全纯函数）：

```swift
static let twoFactorRequiredCode = 3018          // 先认码
static func isTwoFactorRequired(_ error: Error) -> Bool   // 描述只做兜底
static func twoFactorFailure(for error: Error) -> ImportFailure   // code: SEAL-AUTH-101a
```

提示改成「**Apple ID 需要双重认证** / 重新添加账号，在弹出的「输入验证码」里填
Apple 发来的六位数字；若始终收不到验证码，先到系统「设置 → 你的名字」用这个 Apple ID
登录一次，再回来重试」。

**为什么判据先认错误码、描述只做兜底**：描述会随 Apple 的措辞与语言变，错误码不会。
兜底的收益是「万一 Apple 换了码，提示至少还是对的」；代价只是可能把别的错误显示成
双重认证提示 —— 这条判据**只影响文案**，不影响任何破坏性行为，所以宁可宽松。

**三个映射入口都要改，顺序也要一致**：

| 入口 | 场景 |
|---|---|
| `AppleAuthenticationFailure.make(stage:error:)` | 新账号登录 |
| `AppleAccountClient.validate(account:secret:)` | 已存 session 重新验证 |
| `AppleAccountClient.failure(from:)` | Anisette 前置失败后的通用兜底 |

后两条理论上不会看到 3018（一个用 session、一个是兜底），但**「只在其中一条链路上加」
是这类修复最容易犯的错**：不崩、不编译失败，只在真机上重新给出错误引导。
`validate` 那条尤其隐蔽 —— 它走已存 session，正常不会要求双重认证，但 session 失效时确实会。

顺序统一为「**双重认证 → 限流 → 网络 → 泛化**」：双重认证是最具体的诊断。
两处顺序不一致时，同一个错误在两条路径上会给出不同提示。

**顺带消掉一份重复实现**：`make` 与 `failure(from:)` 各抄了一份完全相同的
「类型/Domain/Code/描述/调试/嵌套」构造 ⇒ 抽成 `AppleAuthenticationDiagnosis.detail(for:)`，
全仓只此一处。这种重复在本仓库反复漂移成「修了一条、漏了另一条」。

**错误码选 `SEAL-AUTH-101a` 而不是新号段**：`SEAL-AUTH-101` 是「验证码被 Apple 拒绝」，
本条是「验证码这一步没走完」—— 同一族，按前缀扫能一次看全。它**不能**落进
`AppleServiceFailurePolicy.verificationFailureReason` 里 `SEAL-AUTH-102` / `-105` / `-106`
那几组：那几组会把账号标记成「凭据失效」，而这里账号和密码都是好的。

**守卫与测试**

- **265→279 源码断言、132→138 变异**（R13 段 14 条断言 / 6 个变异锚点）。
- 六个变异锚点各自对应一种「绿着坏掉」的改法：换掉 3018、只按描述判断、
  只在一条链路上做分类、把顺序换到限流之后、分支留着但手写泛化提示、
  把「绝不能叫用户去核对密码」的单测改名。
- 新增 `AppleAuthenticationDiagnosisTests`（8 条），其中最重要的是
  `twoFactorFailureNeverTellsTheUserToCheckThePassword` 与
  `makeRoutes3018ToTheTwoFactorFailure` —— 只测分类函数的话，把 `make` 里的分支删掉不会红。
- 顺序断言用 `section()` 取**每个函数体**再比相对位置，不是「文件里有没有这两个字符串」。

---

### 2026-09-17 · 真机日志（构建 95）验证：回收生效 209 份，同时抓到一个**会删数据**的新缺口

**日志**：`Seal-log(9).txt` / `Seal-log(10).txt`，同一时间窗 `13:21:38`–`13:33:39`，
表头 `构建 1.1.16 (95)` ⇒ 定版到 **run#95**（`2c31b46`），是含全部修复的参考构建。

**验收通过**（回归清单第 9/10/11 项）：

```
13:22:01 [SEAL-PROFILE-321] 已清理 16 份设备端旧描述文件
13:22:01 [SEAL-PROFILE-320] 设备端旧描述文件清理：扫描 231，匹配 17，删除 16，dump 尝试 2 次；
         旧 Team 变体：候选 209，回收 209，已装保留 0，未能核验 0
```

`回收 209`（第 11 项的验收数字）、`扫描 231 → 6`（堆积清空）、`dump 尝试 2 次`（重试生效）、
`未能核验 0`（阳性对照通过）。另外 `SEAL-STORAGE-009`、`SEAL-PROFILE-322`、
`3 秒内进程仍存活（转场未生效），强制 exit(0)`、表头构建号 —— 前几轮补的
「静默路径可观测性」与定版机制**全部按预期出现**。

---

**🔴 新缺口：已装 App 的扩展 profile 被当孤儿回收**

```
13:27:59 [SEAL-PROFILE-322] 自替换结算清理：… 候选 4，回收 3，已装保留 1，
         示例 …TEAM000001.ShareExtension、…LaunchAppExtension、…LiveProcess、…TEAM000001
```

LiveContainer **装着**（13:24:30 刚装完，记录 `.installed`）。主 App 被正确保留
（`已装保留 1`），**但它的三个扩展 profile 被删了**（`回收 3`）。

两层根因，都是设计缺口：

1. **`isAppInstalled` 对扩展 Bundle ID 恒为 `false`** —— 扩展不是独立安装的 App，
   `installation_proxy` 里根本没有它。⇒ 这条功能赖以保命的「设备端核验」
   **对扩展完全没有保护作用**，而且不报错、不崩、只在真机上删数据。
   日志实证：同一个 pass 里主 App 判为已装、三个扩展判为未装。
2. **`DeviceProfileCleaner.removeStaleProfiles(_ request:)` 传的 keep-map 是单条目**
   （只有 Seal 自己）⇒ **每次 Seal 自替换，其它所有 App 的 Bundle ID 都变成孤儿候选**。
   主 App 靠设备核验兜住，扩展兜不住。

维护路径有同一类问题：`profileKeepMap` 里扩展 ID **只在 `signedArtifactStatus == .installed`
时才进集合**（09-16 刻意的取舍，理由成立），但那个标记一旦陈旧，扩展 ID 就掉出
**保护范围** ⇒ 13:22:01 那 209 份里也包含 LiveContainer 的扩展与 Seal 自己的隧道扩展。

> 09-16 那处取舍本身没错（安装失败时扩展记录指向设备上不存在的 profile，拿它当保留集合
> 会把真在用的那份删掉）。**错在只考虑了「保留集合」这一侧，没考虑「候选过滤」那一侧。**

**修法**：把两个集合拆开 ——

| 集合 | 用途 | 取值 |
|---|---|---|
| `keepingByBundleID`（严格） | 决定**留哪一份** | 只收有可信 profile UUID 的；宁缺勿滥 |
| `protectedBundleIDs`（宽松） | 决定**不删谁** | 全量记录里所有 Bundle ID（含扩展），不看 `signedArtifactStatus`；宁滥勿缺 |

判据是「**宽松的管不删，严格的管留哪份**」。受保护集合为空时**整轮不回收**（fail closed）：
记录读不到 ⇒ 保护范围未知 ⇒ 宁可这一轮不回收。

**涉及文件**：`ProfileReclaimPolicy`（新增 `effectiveBundleID` / `protectedBundleIDs(records:)`）、
`DeviceProfileCleaner`（`ProfileCleanupRequest` 与两个入口新增 `protectedBundleIDs`）、
`AppMaintenanceJob`、`SigningCoordinator`、`SelfAppRegistrar` 三个调用点各自从记录构造。

---

**🟠 批量续签没有逐项成功日志**（用户困惑的直接原因）

用户续签 LiveContainer 时界面停在「安装中」，取消后看到 App 像是重装了，却无法确认
描述文件是不是新申请的。日志里**一个字都没有** —— 因为批量走 `RenewalCoordinator` →
`SigningCoordinator.signAndInstall`，而「续签并安装成功」只在**单签**的
`AppsViewModel.signAndInstall` 里写。**没有成功日志 ≠ 没成功**（这次实际成功了：
`13:32:45 安装后旧描述文件清理` 只在安装成功路径触发）。

**修法**：新增 `SEAL-RENEW-020` 逐项成功日志，带上**描述文件身份**（UUID + 创建/到期时间）
—— 只写「成功」两个字回答不了那个真正的问题：「换的是新申请的那份，还是旧的那份」。
格式化抽成纯函数 `RenewalCoordinator.describeProfile(_:)` 以便单测。

**🟠 `[BatchDebug]` 刷屏**：36/121 行（**30%**），且 `SEAL-BATCH-DEBUG-3` 是**警告**级、
由 `load()` 每 ~9 秒触发。日志只保留 1000 条 ⇒ 真实信号被挤掉。那批是 09-16「93 秒空白」
排查时加的**临时脚手架**，现已删除；只保留「确实有待恢复的数据、却被跳过」这一个异常信号，
其余改用 `SEAL-RENEW-021`~`025` 正式码。

**🟡 未修（待办）**：新账号报 `Code 3018 / requires signing in with two-factor authentication`，
但 `AppleAccountClient` 只 catch 了 `incorrectVerificationCode` / `incorrectCredentials` /
`invalidAnisetteData`，**没有 `requiresTwoFactor` 分支** ⇒ 落到泛化的「Apple ID 验证失败」，
恢复建议还写「核对 Apple ID 与密码」——对 2FA 是**错引导**。

**守卫**：**257→264 源码断言、123→131 变异**（R12 段：批量日志 5 条 + 轮询降噪 2 条）。
新增单测 `RenewalCoordinatorLogTests`（4 条）。

**验证状态**：静态守卫 PASS；编译与真机回归待云构建。

---

**🔁 补记：run#96 挂在测试 target 的编译错上（第 265 条断言 / 第 132 个锚点由此而来）**

`build-package` 绿、`rork-sign-tests` 绿、`swift-regression` 红，21 条 `error:` 全是同一处：

```
AppMaintenanceJobTests.swift:262:52: error: cannot convert value of type '[Any]' to
    expected argument type 'Dictionary<String, String>.Keys'
```

写的是 `let keptKeys = Set(keepMaps.first?.keys ?? [])`。
**`Dictionary.Keys` 不是 `ExpressibleByArrayLiteral`**，所以 `?? []` 里的 `[]` 无法被推断成
那个类型，Swift 退化成 `[Any]`。

**这是「本机不能编译 ⇒ 测试 target 只能盲写」的又一次代价**，而且 `build-package`
**不编译测试 target** ⇒ 只有 `swift-regression` 会红，一轮白等 13–16 分钟。

修法是先 `guard let` 取出字典再 `Set(dict.keys)`（顺便能用 `Issue.record` 报出
「桩根本没收到 keep-map」这种更有信息量的失败）。

**已做成守卫的静态检查**（本轮新增）：扫 `Seal/` 与 `SealTests/` 里
`\.(?:keys|values)\s*\?\?\s*\[\]` 这个形状，并配变异锚点。
通用判据值得记住：**`??` 的右侧用字面量兜底时，左侧必须是可以从该字面量构造出来的类型**
（`Array` / `Set` / `Dictionary` 可以；`Keys` / `Values` 或其它 `Collection` 不行）。

⚠️ 实现这个检查时踩了一个自己的坑：预筛条件一开始写成 `"??" in raw` —— 几乎每个 Swift
文件都含 `??`，于是每个变异遍都会去注释 200+ 文件，整轮守卫耗时翻倍。
**预筛要用「坏形状」本身**，不要用「坏形状的一个必要但不充分的条件」。
另外命中后仍要用 `strip_comments()` 复核：**注释里写反面示例是允许的**（本轮就写了）。

---

### 2026-09-17 · 旧 Team 后缀的 profile 回收：差点用 `lookupApp` 把「查不通」当成「没装」

**背景**：上一轮量化出堆积的结构性来源 —— 用户轮换多个 Apple ID 突破免费账号
「3 个自签应用」上限，而 `BundleIDMapper` 强制附加**当前** team 后缀 ⇒ 每换一个账号，
每个 App 就多一个 Bundle ID。实测 **19 个 base × 13 个 team = 39 个** Seal 生成过的
Bundle ID，而 `profileKeepMap` 的 key 只有当前在用的那些 ⇒ 历史后缀的 profile
永远进不了 `matched`，`删除` 恒为 0（真机 `扫描 325，匹配 1，删除 0`）。

用户拍板实现回收。**写实现时才发现第一版设计建在一个错误假设上。**

**第一版设计**（已写进 QA 文档）：删除条件 = ①不在 keep-map ②形态属于 Seal 生成
③`Minimuxer.lookupApp` 返回 nil。当时以为 ③ 是「无懈可击」的一条 ——
「App 没装 ⇒ 这份 profile 是死重量，删掉不可能破坏什么」。

**实际读源码才发现**（`Vendor/Minimuxer/Sources/Minimuxer.swift:254`）：

```swift
public static func lookupApp(bundleId: String) -> String? {
    if Muxer.isrppairing {
        return try? RustIdevice.lookupApp(bundleId: bundleId)   // ← try? 吞掉错误
    }
    guard let device = try? Device.getFirstDevice(),            // ← 设备不可达也 nil
          let inst = RustInstProxy.connect(...) else { return nil }
    return inst.lookup(appId: bundleId)
}
```

**「没装」与「查询失败」是同一个 `nil`。** 于是原设计在隧道抖动时会把**所有**候选
读成「没装」⇒ 删掉正在用的 profile ⇒ 对应 App 立刻起不来。
这恰好是整条功能最坏的失败方向，而且**不崩、不编译失败、只在真机上删数据**。

**三处修正**：

1. **换成会抛错的 API**：`Minimuxer.isAppInstalled(bundleId:) throws -> Bool`
   （`InstalledAppDeviceVerifier` 一直用的就是它）。它把「设备/隧道不可达」表达成 throw。
2. **加阳性对照**：抛错只能抓「报错的失败」；`RustInstProxy.lookup` 内部把 RPC 失败
   也返回成 `nil`（`_rust_bridge_instproxy_lookup` 空指针），这种**静默**失败单条看不出来。
   ⇒ 删任何一份之前，先拿 **Seal 自己**（这段代码正在它里面跑，必然装着）去问；
   答错就整轮不删。
3. **中止是整轮的**：第一次 `unavailable` 就停止，不再拿剩下的候选去问一条已经不可信的通道。
   抛错点（`Device.getFirstDevice()` / `RustIdevice.lookupApp`）都是**全局性**的，
   所以「继续问」没有意义。

**决策抽成纯函数**（错法只在真机可见，只能靠单测 + 守卫钉住）：

```swift
static func decision(probe: InstallProbe, positiveControlPassed: Bool) -> Decision {
    switch probe {
    case .unavailable: return .abortPass
    case .installed:   return .keepInstalled
    case .notInstalled: return positiveControlPassed ? .reclaim : .abortPass
    }
}
```

`AppRecord.swift:275` 那条注释（「同一原始 IPA 可用不同 Bundle ID 签出多个副本同时安装」）
决定了 `.installed ⇒ .keepInstalled` 必须是无条件的 —— 用户**可以**故意把同一个 App
用两个 Team 各装一份，那份 profile 不是垃圾。

**顺带**：形态判据用 `.seal.` 中缀而不是「与记录里的 base 比对」。因为
「已从 Seal 列表删掉的 App」在记录里没有 base 可比对，而真机上这类占多数；
其它工具（AltStore / SideStore）用 `<原始>.<teamID>`、**没有**这个中缀，天然不碰。

**另一处刻意的不作为**：`InstalledAppDeviceVerifier` 查询前会 `Install.resetProvider()`
（避免缓存里那条断开的 RSD 连接给出错误答案），这里**不**这么做 —— 本函数跑在
「刚装完一个 App」与「自替换结算」两个时间点上，此刻可能有 installation_proxy 连接正在服务，
重置会把它拆掉（R05）。缓存连接失效的代价已经由阳性对照兜住。

**改动**：`ProfileReclaimPolicy`（新增）、`DeviceProfileCleaner`（阶段 A 本地筛候选 /
阶段 B 设备端核验）、`AppMaintenanceJob` 与 `SigningCoordinator` 两处显式开启、
`ProfileCleanupSummary` 新增四个计数 + `reclaimAborted`。
守卫 **228→246 源码断言、107→118 变异**（11 个新锚点专打这条边界）。
提交 `647bde3`（CI **run#93**，`swift-regression` 红一次，见下）→ 修复后 `2c31b46`
（CI **run#95** 全绿）。

**流程教训**：本仓在 OneDrive 里，这一轮又出现两次「Edit 报成功、内容没落盘」。
改完立刻回读校验，别等测试或提交才发现。

**⚠️ 同一天还踩到一次更严重的：误删远端分支。** 推送脚本里
`NEW=$(git commit-tree "$TREE" -p "$REMOTE" ...)` 因为父对象 `f165ec5`
**瞬时读不到**（`fatal: not a valid object name`，OneDrive 又回滚了 `.git`）而失败
⇒ `$NEW` 为空 ⇒ `git push origin "$NEW:refs/heads/codex/certificate-handoff"`
被 git 解释成**删除请求**，输出 `- [deleted] codex/certificate-handoff` 且 **exit 0**。
`f165ec5` 本地对象其实还在，用 `git push origin f165ec5:refs/heads/<branch>` 立即恢复。
⇒ 推送脚本必须加 `git cat-file -e "$REMOTE" || exit 1` 与
`[ -n "$NEW" ] || exit 1`。事故的样子是 **stderr 的 `fatal:` 与 stdout 的
`[deleted]` 同时出现** —— 只看 stdout 会误判成推送成功。

**CI 当场抓到一个漏洞（run#93 `swift-regression` 红，`build-package` 绿）**：

`currentBundleIdentifierIsNeverACandidate` 挂了 —— 那条单测传了**混合大小写**的
keep-map key（`com.kdt.livecontainer.seal.TEAM000009`），而 `isReclaimableOrphan`
只做精确查表 `keepingByBundleID[lowered]` ⇒ 没命中 ⇒ 把「正在用的那个」
判成了**可回收**。失败方向正是删掉活着的 profile。

- 调用方（`removeStaleProfiles`）确实会把 key 归一化成小写，所以生产路径本来不会触发。
  但**这条判断的错法方向是删数据，不能靠「调用方一定记得转小写」这种约定来保证安全**
  ⇒ 改成大小写不敏感比对（`keys.contains { $0.lowercased() == lowered }`）。
- **更值得记的是守卫为什么没提前拦住**：源码断言只能证明「实现里写了 `lowercased()`」，
  证明不了「单测真的用了一个大小写不一致的 key」。把测试里的 key 改成小写，
  实现与断言双双绿着，行为已经没人守了。⇒ 补了一条**切出那个测试函数体**、
  断言里面确实是混合大小写 key 的检查，并配了对应的变异锚点。
  **「源码断言守形状、单测守行为」还不够，得再补一层「单测里的关键输入形态」** ——
  否则「把测试改宽」这种退化没有任何检查能发现。

### 2026-09-17 · 日志无法定版：让表头带上构建号（= CI run number）

**现象**：复查「描述文件堆积」时，日志文案是
`安装后旧描述文件清理（com.kdt.livecontainer…）：…`，
而当前源码是 `安装后旧描述文件清理（主 …，共 N 个 Bundle ID）：…`。**`主 ` 与 `共 N 个` 零命中。**

**排查**：`Scripts/build-unsigned-ipa.sh:33` 里
`CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-${SEAL_BUILD_NUMBER:-1}}"` ——
**构建号就是 GitHub Actions 的 run number**，因此唯一对应一个提交。
拿文案去比对历史提交，得到分界线：

| CI run | 提交 | 构建时间（北京） | 文案 |
|---|---|---|---|
| run#73 | `aba93cc` | 09-16 19:23 | 旧（无 `主 `） |
| run#75 | `0c16174` | 09-16 22:49 | 旧（无 `主 `） |
| **run#79** | **`bc069e3`** | **09-17 00:48** | **新（含 `主 …，共 N 个 Bundle ID`）** |

而用户最新那份日志最后一条是 **09-16 21:56** ⇒ **用户的构建 ≤ run#75**。

**结论**：§3.1/§3.2（扩展 profile 覆盖）与 09-17 的三处修复**从未在真机上运行过**。
上一轮那句「上轮的修复没生效」要改成「上轮的修复用户还没装上」。

**同一轮里还纠正了一处自己的错误推理**：我先拿「维护作业六个日志码全部零命中」
推出「维护作业从未完成过一轮」。但用 `git show <sha>:<file> | grep` 逐码核对后发现：

| 码 | run#75 里存在？ | 19 份日志命中 |
|---|---|---|
| `SEAL-STORAGE-005` / `006` / `008` | ✅ | 0 |
| `SEAL-PROFILE-320` / `321` | ❌ **不存在** | 0 |
| `SEAL-SELF-REG-001` | ✅ | 0 |

**`SEAL-PROFILE-320` 与 `sweepStaleProfiles` / `profileSweeper` 在 run#73、run#75 里都是 0 处**
—— 维护第 4 步是 run#79 才加的。所以它的零命中是**平凡真**，不构成证据。

修正后的、**真正成立**的结论：
- `SEAL-STORAGE-006`（在 run#75 里存在）零命中 ⇒ 维护作业**从未被打断**（有效）；
- `SEAL-STORAGE-005` 零命中只能推出「没有孤儿目录被删」，**推不出「作业没跑过」**；
- 用户设备上 profile 堆积的完整解释**不需要额外的 bug**：那个构建里只有安装后清理一条路径，
  它只覆盖本次安装的 App，而 Seal 的自更新不走 `installSignedIPA` ⇒ 轮不到 Seal 自己。

**教训**：`git show <sha>:<file> | grep <字符串>` 这一步必须**在做任何「零命中」推理之前**完成。

**修复**（让这类取证不再需要比对文案）：

```swift
static var currentBuildLabel: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    ...
}
```

表头多一行：`构建 1.1.16 (91) · 构建号取自 CI run number，可用于定位对应提交`。
`SealLogStore.exportText()` **显式**透传（不靠默认参数），让守卫的源码断言看得见这条依赖。

**涉及文件**：`Seal/Core/Diagnostics/SealLogEntry.swift`、
`Seal/Infrastructure/Diagnostics/SealLogStore.swift`、
`SealTests/Diagnostics/SealLogTextFormatterTests.swift`（**新文件，5 条**）、
`Scripts/verify-release-safety.py`、`docs/qa/2026-09-16-profile-pileup-and-ui-row-layout.md`（§7.6–§7.7、§7.10）、
`docs/qa/device-regression-checklist.md`（新增「第 0 步」）。

**顺带修正一处过度解读**：`扫描 325，匹配 1，删除 0` 曾被当成「旧 Bundle ID 的 profile
永远回收不掉」的线索 —— 但那也是 run#75 之前的构建，当时 `keep-map` 只有单条
（`for: bundleID, keeping: uuid`），`匹配 1` 是**正常表现**，**这一条不构成证据**。

> 但要分清两件事：**这条证据无效 ≠ 那个结论错**。2026-09-17 用 `.seal.<后缀>` 形态统计
> 19 份日志后确认：18 个 base × 13 个 Team = **36 个 Seal 生成过的 Bundle ID**，
> 而 `profileKeepMap` 的 key 只有当前在用的那些 ⇒ 历史 Team 后缀的 profile
> **确实一份都回收不了**。真正的证据是这条统计，不是 `匹配 1`。
> 详见 QA 文档 §7.8 / §7.9。

### 2026-09-17 · 问题 5 的修复**真机上一次都没跑**：dump 不重试 + 两条静默路径

**现象**：用户反馈「描述文件每次申请，旧的和新的并存，Seal 已有 16 个 UUID 对应的文件」。
上轮（09-16）已经加了 `DeviceProfileCleaner` + `AppMaintenanceJob` 第 4 步，标为「已修」。

**排查**：把用户此前导出的 19 份 `Seal-log*.txt` 里所有「描述文件清理」相关行捞出来 ——
**一共只有 8 条**，这个数量本身就反常。逐条归类后发现：

- 8 条**全部**来自 `安装后旧描述文件清理（…）：…`，即 `SigningCoordinator` 的安装后路径；
- 维护路径的 `设备端旧描述文件清理：`（`SEAL-PROFILE-320`，**无条件**写）**一次都没出现过** ——
  而 `系统` 类别在导出里确实存在（9 条），所以不是导出过滤。
  ⚠️ **但这一条当时被我用错了**：`git show 0c16174:…/AppMaintenanceJob.swift | grep -c profileSweeper`
  = **0**，维护第 4 步是 run#79 才加的，而用户的构建 ≤ run#75 —— **那个构建里根本没有第 4 步**，
  零命中只是平凡真。能成立的那一半是：第 4 步在用户设备上**一次都没跑过**（因为不在构建里）；
- 失败那条是 `16:59:28 … 扫描 0，匹配 0，删除 0，中断于 dump，首个错误：NoDevice`，
  15 秒间隔与 `MuxerConstants.deviceFetchTimeoutMs = 15000` 完全吻合 ⇒ **一次都没重试**。

**根因（三条独立）**：

1. `dumpProfiles` 撞上瞬时 `NoDevice` 就整轮放弃，而两个触发点的时机都不保证设备已连上。
2. `AppsViewModel.runMaintenanceIfIdle` 的 `.skipped` 只有一句 `break`、`.failed` 只弹窗 ——
   **都不写日志**，于是「维护为什么没跑」完全无法归因（而 `.skipped` 恰恰是最可能的分支：
   `MaintenanceGate` 是非阻塞租约，有前台操作就返回 nil）。
3. `SelfAppRegistrar.reconcileSelfReplacement` 的结算清理**只把摘要写进事务审计**
   （`finishCleanup` → `store.close(cleanupSummary:)`），不写日志 —— 而这是**唯一**会回收
   Seal 自己那份堆积的路径（Seal 的自更新不走 `installSignedIPA`）。

**修复**：①`dumpProfiles` 有界重试 3 次，每次前 `Provision.resetProvider()` + 等 4 秒；
②维护作业三个非 `.completed` 分支各自留痕（`SEAL-STORAGE-009` / `010`，`006` 已有）；
③自替换结算清理落日志（`SEAL-PROFILE-322`，写在 `finishCleanup` **之前**）；
④摘要新增 `dumpAttempts` 字段，`logMessage` 在 `> 1` 时输出「，dump 尝试 N 次」。

**涉及文件**：`Seal/Infrastructure/Installation/DeviceProfileCleaner.swift`、
`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Core/Renewal/SelfAppRegistrar.swift`、
`SealTests/Installation/DeviceProfileCleanerTests.swift`（**新文件，6 条**）、
`SealTests/Renewal/SelfAppPendingHandoffTests.swift`（+1 条）、`Scripts/verify-release-safety.py`、
`docs/qa/2026-09-16-profile-pileup-and-ui-row-layout.md`（§七）、`docs/qa/device-regression-checklist.md`（第 9/10 项）。

**验证状态**：守卫 **224 源码断言 + 105 变异 PASS**（约 61 秒）。真机待验：见回归清单第 9/10 项。

**仍未解决**：日志里有 `扫描 325 / 326，匹配 1，删除 0` —— 设备上有 325+ 份 profile，
但只有 1 份的 Bundle ID 在保留集合里。**不在 Seal 记录里的 profile 一律不碰**是有意的保守
（删错一份对应 App 立刻无法启动），但换过 Apple ID 后 Team 后缀变化会产生大量「旧 Bundle ID」
的 profile，它们永远不会被回收。要处理得先回答「哪些 Bundle ID 算 Seal 的」，是设计决策。

### 2026-09-17 · 「续签卡在 93%」的真正根因：`.background` 分支「什么都不做」

**现象**：Seal 自续签进入安装阶段后永久停在 93%，「怎么都没反应」，同一天普通 App 安装 7 秒完成。

**排查**（关键是用**否证**代替猜测）：两份真机日志（`Seal-log(7).txt` / `Seal-log(8).txt`，各含两次自续签）显示安装起点之后进程**既不转场也不退出**、照常写后台日志。把候选路径的**必然后果**对照一遍：`.triggerTransition` 必然调 `suspend`（生效 ⇒ 进程冻结 ⇒ 日志停止）、`.waitForForeground` 超时必然 `exit(0)`（⇒ 进程终止）—— **两者都没发生**，所以动作在到达它们之前就被丢掉了，只剩 `.standDown` 的立即返回这一种解释。

**根因**：`SelfInstallAutoBackground` 里 `case .standDown: return false`（2026-09-16 那次修复只把 `.inactive` 修好了，`.background` 从「不退出」换成了另一种「不退出」）。前提「进程已让出前台 ⇒ iOS 会自己完成替换」对**覆盖安装运行中的自己**不成立 —— iOS 需要旧进程**终止**，而后台进程不会自己终止，自续签还主动开了后台保活。因果链：**进程不退出 ⇒ iOS 不完成替换 ⇒ installd 一直等 ⇒ `stageAndInstall` 一直不返回**。上一轮怀疑的「`suspend` 提前触发截断了 installation_proxy 连接」是**后果**不是原因。

**修复**：`waitUntilExitIsSafe`（返回 `Bool`）→ `waitUntilItIsTimeToExit`（返回 `Void`，因为它总会返回）。`.background` 改为**有界等待 8 秒**（等用户回到前台走转场）+ **超时强杀**（后台强杀用户无感）。把「等多久 / 该不该动手」抽成可测纯函数 `poll(for:waited:rounds:)`，三个状态**全部有界**；日志只在第一轮写一次（否则 8 秒刷 16 行，把刚建立的可观测性淹没）。

**涉及文件**：`Seal/Features/Apps/SigningProgressView.swift`、`SealTests/Apps/SelfInstallAutoBackgroundTests.swift`（5 → 10 条）、`Scripts/verify-release-safety.py`、`docs/qa/2026-09-16-…-freeze.md`（§2.3.1 / §3.11）、`docs/qa/device-regression-checklist.md`。

**验证状态**：守卫 **214 源码断言 + 97 变异 PASS**（约 54 秒）。推理链完整但**仍需真机确认**：把 App 切到后台再等它自己完成替换，日志应出现「当前在后台，等待回到前台再触发转场（最多 8 秒）」→「触发回主屏转场」或「强制 exit(0)」。

**顺带**：修掉两个会在 CI 才暴露的实现细节 —— `let step = step(for:)` 同名变量导致编译失败；`.standDown` 的守卫断言一度用 `"exit(0)" in stand_down`，而那是**日志文案**里的字（控制流删掉也照样通过）。

---

### 2026-09-16（续 5）· 把「模拟器切片缺符号」做成守卫的通用检查：同类错误一天内咬了两次

- **现象（CI，不是用户反馈）**：上一轮的修复推送后，CI run `35168295836` 里 `rork-sign-tests` ✓、`build-package` ✓、**`swift-regression` ✗** —— `MinimuxerInstallChannel.swift:480:56: error: type 'Self' has no member 'isTimeoutInstallError'`。
- **根因**：`waitForSelfReplacement` / `runSelfReplacementInstall` 刻意放在 `#if !targetEnvironment(simulator)` **之外**（模拟器上也要能编译），但它们调用的 `isTimeoutInstallError` 仍定义在 `#if` **之内**。设备切片看得到、模拟器切片看不到。**同一轮里这是第二次**：`diagnostic` 已经因为同样的原因提前挪出去过，`isTimeoutInstallError` 漏了。
- **为什么不能靠「记得小心」解决**：`build-package` 只编设备切片，这类错误在它那里**永远绿**；只有 `swift-regression`（模拟器切片）会红，而一轮 CI 13–16 分钟。也就是说一次疏忽的代价是白等十几分钟 + 一次额外推送。
- **修复**：
  1. 把 `diagnostic(_:)`、`isTimeoutInstallError(_:)`、`isSelfReplacementBusyError(_:)` 全部移到 `#if` 之外（这三段逻辑与平台无关），并在 `#if` 内留指路注释避免重复定义。
  2. **给守卫加一条通用检查**（`Simulator: device-only members must not be referenced by simulator code`）：把「模拟器切片不编译」的行整段抹成等长空白，再找出**只**在被抹掉部分里定义的顶层类型成员、却出现在抹后文本中的那些 —— 那就是模拟器代码引用了设备专属符号。
  3. 配一个变异锚点：把 `isTimeoutInstallError` 的定义包回 `#if !targetEnvironment(simulator)`，守卫必须报红（这条同时证明检查不是空转）。
- **实现细节（两个坑都踩过并修掉）**：
  - **判定必须同时覆盖两种写法**：`#if !targetEnvironment(simulator)` 的整个分支 **和** `#if targetEnvironment(simulator)` 的 **`#else` 分支** —— 两段都不在模拟器上编译。第一版只认前者，于是 `bindTunnelConfiguration()`（定义在 `!simulator` 里、调用点在同文件的 `#else` 里）被误报成缺符号。**误报比漏报更坏：它会逼着后来的人把守卫删掉。**
  - **只认缩进恰好 4 空格的声明**（顶层类型成员）。函数体内的局部变量缩进更深，`let ipaMB` / `let detail` 这类名字在设备专属分支与模拟器分支里各有一份，按「名字出现在抹后文本里」判定会把它们全部误报。
  - 未知条件（`#if DEBUG` / `#if os(iOS)`）按「两片都编译」处理：取值不取决于目标平台，这样既不漏真问题也不制造误报。
  - 循环里先用**未去注释的原文**做一次廉价子串判断再决定是否 `strip_comments`：这个循环要跑遍 200+ 文件、而 `violations()` 总共要跑 90 多遍。
- **结果**：守卫 **204 源码 + 90 变异 PASS**（本轮之前 203 + 89）。
- **涉及文件**：`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`、`Scripts/verify-release-safety.py`。
- **验证状态**：推送 `aa13af1..d1a67b6`，CI run `35169418800` —— `build-package` ✓、`rork-sign-tests` ✓、**`swift-regression` 仍 ✗**，但换了一个错误：见下条。

### 2026-09-16（续 7）· 把「回主屏转场到底有没有触发」变成可观测：CI 绿之后补上最后一段盲区

- **背景**：CI 已在 `0da974c` 全绿。剩下的唯一未决问题是「自替换的 `stageAndInstall` 为什么不返回」，而它**卡在没有证据**上：`SelfInstallAutoBackground`（Seal 自续签的「回主屏」动作）这条链路在 2026-09-16 之前**一行日志都没有**，于是「转场到底有没有触发、是在 `installation_proxy` 返回之前还是之后触发」只能靠猜。
- **读代码读出来的矛盾（仍未定论，但现在是可测的）**：
  - `SelfInstallAutoBackground` 的文档说「iOS 只有在旧进程退出前台后才会完成替换」；
  - `MinimuxerInstallChannel` 里写着「自替换也必须让 `installation_proxy` 完整返回；**提前 suspend 会冻结当前连接并留下旧 profile**」；
  - 而实际的触发时机是**上传完成**（`.installing`，即上传到 100% 的 1.01 哨兵）后 **1.2 秒** —— 那时 `stageAndInstall` 显然还没返回。
  - **这两套时序是冲突的**，但缺设备侧证据无法判定谁对。所以本轮**不动行为**，只让它可观测。
- **修复（纯诊断，零行为变更）**：
  1. `SelfInstallAutoBackground.returnToHomeAfterSealUpload(logStore:)` 接受日志出口（`AppsViewModel` 本来就持有 `logStore`，两条链路都把**真实**的出口传下去）。
  2. 入口、`.standDown` / `.triggerTransition` / `.waitForForeground` 三个分支、以及 `exit(0)` 兜底各留一条日志，**每条立刻 `flush()`**。
  3. 「即将触发转场（suspend）」这条**刻意写在 `triggerHomeTransition` 之前**：`suspend` 一旦生效进程即被冻结，之后写的日志出不来。
- **下一份真机日志即可判定**：`安装 开始自替换安装：…` → 心跳 → `Seal 自替换：触发回主屏转场（suspend）` → `安装 自替换安装调用已返回：…`。**若最后一条永不出现，说明 `suspend` 确实截断了安装**（与安装通道注释一致）；若它出现在转场之前，则问题在 AFC / installd 一侧。
- **守卫**：新增 3 条断言 + 3 个变异锚点 —— ①这条链路必须真的写日志且 `flush()`；②「触发转场」的日志必须排在 `triggerHomeTransition` **之前**（断顺序，不断文案）；③两条链路的调用点都必须传真实出口（`count(...) == 2`）。
  同时把 `.standDown` 的断言从拼接式（`"case .standDown: return false"`）改成 `section()` 切分支后断语义 —— 插一条日志就让拼接式断言失效，而那种失败看着像语义坏了。
- **结果**：守卫 **208 源码 + 93 变异 PASS**，耗时约 50 秒。
- **涉及文件**：`Seal/Features/Apps/SigningProgressView.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Scripts/verify-release-safety.py`。
- **验证状态**：守卫本地 PASS；`swift-regression` 待 CI；**真机回归第 7、8 项仍是本轮修复的验证入口**。

### 2026-09-16（续 6）· 修掉 `#expect` 里的 mutating 调用；顺手把守卫从 117 秒压回 53 秒

- **现象**：run `35169418800` 的 `swift-regression` 报了 **95 条**同一个错误 ——
  `cannot use mutating member on immutable value: '$0' is immutable`，
  全部落在 `SealTests/Installation/SelfReplacementInstallGateTests.swift` 的 `#expect` 宏展开里。
- **根因**：测试写成了 `#expect(gate.acquire())`，而 `acquire()` 是 `mutating` 方法。
  swift-testing 的 `#expect` 是**宏**，会把表达式重写成闭包、把子表达式绑成 `$0`/`$1`…，
  mutating 成员作用在捕获值上编译不过。**与上一条同一个性质**：只在 `swift-regression` 红，
  `build-package` 不编译测试 target。
- **修复**：
  1. 把 mutating 调用提到 `#expect` 外面：`let first = gate.acquire(); #expect(first)`，
     并在测试文件顶部写明「为什么不能挪回去」（否则下一个人「顺手简化」就复现）。
  2. **守卫加第二条通用检查**（`#expect must not call a mutating method ...`）：
     mutating 方法名从 `Seal/` 里**现取**（全仓只有 7 个，名字都很独特），
     不写死；再扫 `SealTests/**` 的 `#expect(...)` 实参里有没有 `<something>.<name>(`。
     同时断言「取到的 mutating 名字不少于 5 个」，防止正则漂移后变成空集 ⇒ 永远绿。
  3. 配变异锚点：把 `#expect(first)` 改回 `#expect(gate.acquire())`，守卫必须报红。
- **顺手修掉的守卫性能问题**：加了新检查后整轮耗时从 61 秒涨到 **117 秒**，
  已经贴到命令默认 120 秒超时。剖析发现单遍只有 0.73 秒（× 91 遍 ≈ 66 秒），
  多出来的时间全在**磁盘读**上 —— 变异检查每遍都把 200+ 文件重新读一遍（≈ 2 万次），
  而本仓在 OneDrive 同步目录里，延迟不稳定。对策：`main()` 里按路径缓存**基准内容**
  （每遍只有一个文件被替换成变异版本，走闭包里的 `changed`，不会读到缓存）⇒ **53 秒**。
  ⚠️ **不要**顺手把 `strip_comments` 也跨遍缓存 —— 那会让被替换的那个文件读到基准版的
  去注释结果，变异检查静默失效（守卫全绿但什么都没检查）。
- **结果**：守卫 **206 源码 + 91 变异 PASS**，耗时 53 秒。
- **涉及文件**：`SealTests/Installation/SelfReplacementInstallGateTests.swift`、`Scripts/verify-release-safety.py`。
- **验证状态**：推送 `d1a67b6..0da974c`，CI run `35170583408` —— **`completed / success`**：`build-package` ✓、`swift-regression` ✓（连续两轮红之后终于转绿）、`rork-sign-tests` ✓、`publish-release` skipped（正常）。真机回归项不变（见 QA 文档 §5）。

### 2026-09-16（续 4）· 用真机日志坐实「卡在 93%」：自替换安装调用从未返回，而这段一行日志都没有

- **现象（用户问题 1）**：续签到安装步骤卡在 93%，「怎么都没反应」。上一轮已经修了三个缺陷（批量收不到 `.installing`、安装期无反馈、`.inactive` 早退），但用户复测仍然卡住。
- **决定性证据（来自用户导出的 `Seal-log(7).txt`，同一份日志内的对照）**：
  - `16:59:06` 开始安装 LiveContainer（4 个 target）→ `16:59:13`「签名并安装成功」= **7 秒**；
  - `16:53:57`「签名产物核验通过」是 **Seal 自替换**的安装起点 → 之后 **93 秒完全空白** → `16:55:30` 才出现下一条日志，而且是无关的后台任务（`[BatchDebug] restore skipped`），**没有任何安装结论**；
  - 之后进程一直活着并继续打后台日志（`16:55`–`17:02`），说明 Seal **从未被替换**，也从未写出「签名并安装成功」。
  - `Seal-log(8).txt`：`19:43:50` 与 `19:45:51` 各有一次 Seal 自替换安装起点，间隔 91 秒，两次都没有结论 —— 第二次是用户在「没反应」之后重试。
- **根因**：`MinimuxerInstallChannel.install(...)` 的自替换分支是裸的 `try await installation.value`，**没有超时、没有任何日志**。`Minimuxer.stageAndInstall` 是同步阻塞 FFI、无取消机制，所以它不返回 = 界面永久停在 93%、日志永久静默、用户无从判断「在装」还是「死了」。普通 App 分支有 `offThread(seconds: mergedTimeout)` 兜底，这就是为什么只有 Seal 自续签会永久卡住。
- **修复**：
  1. **看门狗**：自替换等待改用 `HardTimeout.run(seconds:budget, cancelsWorkOnTimeout: false)` —— 超时**只停止等待、绝不取消**底层 FFI（`offThread` 的默认 `true` 会把取消传给 Rust 侧、可能撤销已下发的 installation_proxy 命令）。超时后**不重试**（R05），并按终态**原样抛出** `installTimeoutFailure`，不再经 `installationFailure` 归类改写文案。
  2. **日志出口**：`MinimuxerInstallChannel` 注入可选 `SealLogStore`（`AppContainer` 里把 logStore 的构造提前到安装通道之前），每次安装写「开始 / 已返回 / 抛错 / 等待超时」，自替换等待期间每 15 秒一条心跳。每条日志立刻 `flush()` —— 自替换的终点是进程被替换，缓冲里的最后几行会随进程消失。
  3. **单飞闸门**：新增纯类型 `SelfReplacementInstallGate`，同一时刻只允许一笔自替换安装；**超时不解锁**（底下那次很可能还在跑），非超时错误才解锁。两条重试路径都把「被闸门拒绝」按终态处理（重试路径里的 `reset()` 会拆掉可能仍在跑的安装连接）。
  4. **消掉重复实现**：无进度的 `install(ipaData:bundleID:isSelfReplacement:)` 改为转发到带进度的实现（进度回调传空实现），不再各维护一份「自替换必须带看门狗 / 必须记日志 / 必须单飞」的规则。
  5. `diagnostic(_:)` 移到 `#if !targetEnvironment(simulator)` 之外：看门狗要在模拟器上也能编译（它不碰 Minimuxer 的安装 API，但抛错日志要用这段文本）。
- **测试**：新增 `SelfReplacementInstallGateTests`(4)（第二笔必须被拒、安装结束后解锁、**超时不解锁**、连续超时永不重开）；`HardTimeoutTests` 补 1 条行为测试 —— 用锁保护的探针断言 `cancelsWorkOnTimeout: false` 时**工作所在任务**的 `Task.isCancelled` 仍为 false（闭包里不能再套一层 `Task.detached`，否则测的是新任务，测试会退化成永远通过）。
- **结果**：守卫 **203 源码 + 89 变异 PASS**（上一轮 189 + 82）。旧的 `count("if Self.isTimeoutInstallError(error) {") == 2` 因重载合并降为 1，已同步改为「唯一的重试循环必须把超时当终态」。
- **涉及文件**：`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`、`Seal/Application/AppContainer.swift`、`SealTests/Installation/SelfReplacementInstallGateTests.swift`(新)、`SealTests/Concurrency/HardTimeoutTests.swift`、`Scripts/verify-release-safety.py`、`docs/qa/2026-09-16-install-stage-feedback-and-self-replacement-freeze.md`。
- **验证状态**：守卫本地 PASS；Swift 编译与单测待 `swift-regression`；真机回归仍待用户执行（本轮新增「安装阶段日志应出现开始/返回/心跳」这条可验证项）。
- **仍未定论**：自替换**为什么**不返回，目前只有日志证据（调用不返回），没有设备侧证据。修复让「永久卡住」变成「有界失败 + 可查日志」，下一轮真机日志应能直接读出是上传卡住、installd 卡住，还是 `SelfInstallAutoBackground` 的 `suspend` 冻结了承载 installation_proxy 的连接（后者与通道里「提前 suspend 会冻结连接」的注释直接冲突，是首要嫌疑）。

### 2026-09-16（续 3）· 修掉「加了取消按钮之后」自己引入的缺陷：回主页触发点被界面带走

- **现象（自审发现，非用户反馈）**：Seal 自续签的「回主页」动作挂在 `SigningProgressView.onChange` 上，而同一版本新加的「取消」按钮是**软取消**（立即关界面，已下发的安装由 installd 跑完）。用户在安装阶段点取消 ⇒ 界面消失 ⇒ 触发点收不到后续阶段推进 ⇒ **「回主页」永远不会发生**，iOS 等不到旧进程让出前台，Seal 的替换静默失败（旧版本继续跑，用户以为更新没生效）。
- **根因**：副作用触发点挂在界面上。批量续签那条链路本来就在状态层触发（`consumeBatchEvent`），单签没有对齐。
- **修复**：触发点搬到 `AppsViewModel.updateSigningStage`，并用 `InstallStageTimeline.Tick == .restart` 闸门保证**只在首次进入安装阶段触发一次**（同一阶段会被重复推送）；界面上的 `.onChange` 只保留视觉转场（`withAnimation` 渲染「正在退回主屏幕」）。守卫新增 3 条断言 + 2 条变异：状态层必须有触发且带闸门、界面里**不得**再出现调用（两处都触发 = 两个转场 + 两个 `exit(0)` 兜底）。
- **顺带记一笔**：批量链路的 `if stage == .installing` 没有 `.restart` 闸门，重复推送时会排出多个「回主页」任务 —— 已知且**良性**（第一个任务触发转场后进程被挂起，后续任务不会执行；转场失败时第一个 `exit(0)` 已结束进程），本轮刻意未动，已记入 QA 文档的「未解决」表。
- **结果**：守卫 **189 源码 + 82 变异 PASS**（上一轮 186 + 80）。
- **涉及文件**：`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Apps/SigningProgressView.swift`、`Scripts/verify-release-safety.py`、`docs/qa/2026-09-16-install-stage-feedback-and-self-replacement-freeze.md`、`DEBUG_LOG.md`。
- **验证状态**：守卫本地 PASS；Swift 单测与真机回归待 CI / 设备侧。

### 2026-09-16（续 2）· 把两条「只在真机上卡死」的分支补上单测，并消掉一份重复规则

- **背景**：上一轮修掉的 `.inactive` 早退（Seal 自续签永久停在 93%）与安装计时起点规则，当时只有守卫里的源码文本断言，**没有单测覆盖**。这两处都属于「错了不崩、只会在真机上卡死」的类型，恰恰最需要测试钉住。
- **改动**：
  1. `SelfInstallAutoBackground` 抽出 `enum ReturnHomeStep { .standDown / .triggerTransition / .waitForForeground }` 与纯函数 `step(for state: UIApplication.State)`，等待循环 `waitUntilExitIsSafe` 改为走它（`.inactive` 等最多 3 秒，仍不恢复才走 `exit(0)` 兜底）。新增 `SelfInstallAutoBackgroundTests`(5)：`.inactive` 必须 `.waitForForeground`、只有 `.background` 才允许 `.standDown`、未知状态按「还在前台」处理、穷举「全部已知状态里恰好一个走 `.standDown`」。
  2. 安装计时起点规则抽成 `InstallStageTimeline.tick(entering:currentStage:)` → `.keep / .clear / .restart`，`AppsViewModel.updateSigningStage` 与 `BatchRefreshSession.advanceStage` 共用；`updateInstallProgress` 的哨兵分支不再自己写 `status` / `installStartedAt`，改为复用 `updateSigningStage(.installing)`。新增 `InstallStageTimelineTests`(5)。
  3. 守卫 R10 从文本匹配升级为结构断言：新增 `squash()` 辅助函数（多行代码压成一行式断言，不再拼换行符 + 数缩进空格）；断言等待循环**真的走** `step()` 且真的 `sleep`、`@unknown default` 不放弃、两个新单测文件里的关键断言确实存在。旧的一条变异锚点锚定的是被删掉的旧写法，已替换为 6 条新锚点。
- **结果**：守卫 **186 源码 + 80 变异 PASS**（上一轮 176 + 75）。
- **涉及文件**：`Seal/Core/Signing/InstallStageTimeline.swift`(新)、`Seal/Core/Renewal/BatchRefreshSession.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Apps/SigningProgressView.swift`、`SealTests/Apps/SelfInstallAutoBackgroundTests.swift`(新)、`SealTests/Signing/InstallStageTimelineTests.swift`(新)、`Scripts/verify-release-safety.py`。
- **验证状态**：守卫本地 PASS；Swift 单测待 `swift-regression`；真机四项回归（见 `docs/qa/2026-09-16-install-stage-feedback-and-self-replacement-freeze.md`）仍待用户执行。

### 2026-09-16（续）· 续签「卡在 93%」与「卡在传输」：安装阶段的反馈缺失 + 自替换的永久冻结

- **现象（用户问题 1、2）**：①续签到安装步骤卡在 93%，「怎么都没反应」；②续签抽屉卡在「传输」那，一直没反应。
- **根因（三个独立缺陷，恰好同时命中「安装阶段」）**：
  1. **批量续签收不到「安装中」阶段**。`installSignedIPA` 的普通 App 分支只发 `.pushing`；上传完成后的 1.01 哨兵（Double）只有单签路径的 UI 订阅得到，而 `BatchRefreshEvent` 只承载 `SigningStage` ⇒ **普通 App 在批量里从上传完成到 installd 装完整段显示「传输中」**（可达数分钟）。这是问题 2 的直接根因。原 `broadcastInstallingForSelfReplacement` 标志只作用于 Seal 分支，名字也误导（它实际表达的是「调用方的进度回调看不到 Double 哨兵」）。
  2. **安装阶段完全没有可见反馈**。installd 安装期间没有任何进度回报，单签只能给出一个静止的 93%，批量连百分比都没有（「传输中」是个没有分母的黑盒）。
  3. **Seal 自续签的「回主页」可能永久不触发**。`SelfInstallAutoBackground.returnToHomeAfterSealUpload` 里 `guard app.applicationState == .active else { return }` 把**瞬时失焦** `.inactive`（控制中心/通知横幅/来电/系统弹窗）当成「用户已离开」，直接 return —— **连 `exit(0)` 兜底一起跳过**。而 iOS 只有在旧进程让出前台后才完成替换 ⇒ 界面永久停在 93%。这是问题 1 最可能的根因。
- **修复**：
  1. `InstallStageBridge.shouldEmitInstalling(uploadProgress:enabled:)` 抽出「上传完成哨兵 → 补发 `.installing`」的规则（`> 1.0` 而非 `>=`，1.0 只是「上传到 100%」）；`SigningCoordinator.bridgedInstallProgress` 让 **Seal 自替换与普通安装两个分支共用同一份包装**，标志改名为 `broadcastsInstallStage`（语义：调用方的进度回调是否只承载 `SigningStage`）。批量续签传 `true`。
  2. 批量事件流新增 `BatchRefreshEvent.appInstallProgress(index:total:app:progress:)`，把安装通道 AFC 的真实上传百分比送进抽屉；`BatchRefreshSession.recordInstallProgress` / `advanceStage` 管好「只在 `.pushing` 采信」与「进入 `.installing` 记一次起点」。
  3. 新增 `InstallWaitNote`（`TimelineView` 秒级计时）：安装阶段明说「此阶段没有进度回报」并给出「已等待 m:ss」，单签进度页与批量抽屉共用。**刻意不编造假百分比** —— 安装耗时与包大小/设备 IO 相关，任何线性假设都会在慢设备上「走完却还没装完」。
  4. 两个抽屉的 footer 改为**常显**并各加一个取消按钮（`cancelSigning` / `cancelBatchRefresh`，软取消 + 日志 `SEAL-SIGN-012` / `SEAL-RENEW-011`），解决「被关在静止弹窗里、没有任何操作」。
  5. `SelfInstallAutoBackground`：只有 `.background` 才算用户离开；`.inactive` 先等最多 3 秒等它恢复，恢复不了照样走 `exit(0)` 兜底，保证 iOS 一定能完成替换。
- **守卫与测试**：新增 **R10**（安装阶段「看得见、退得出」共 11 条断言 + 6 个变异锚点）；**R09 通用化**为可复用的实参顺序校验（覆盖 4 个函数，含「调用点数下限」防绿着坏掉）；修掉守卫自身的性能问题（每遍缓存 `load`/`strip_comments`、`rglob` 只算一次：2m47s → 48s）。新增测试 `InstallStageBridgeTests`(2) / `BatchRefreshSessionTelemetryTests`(5) / `InstallWaitNoteTests`(2)。结果 **176 源码 + 75 变异 PASS**。
- **涉及文件**：`Seal/Core/Signing/InstallStageBridge.swift`(新)、`SigningCoordinator.swift`、`SigningSession.swift`、`Seal/Core/Renewal/{RenewalCoordinator,BatchRefreshSession}.swift`、`Seal/DesignSystem/InstallWaitNote.swift`(新)、`Seal/Features/Apps/{AppsViewModel,BatchRefreshView,SigningProgressView}.swift`、`SealTests/{Signing/InstallStageBridgeTests,Renewal/BatchRefreshSessionTelemetryTests,DesignSystem/InstallWaitNoteTests}.swift`、`Scripts/verify-release-safety.py`。
- **验证状态**：静态守卫 PASS。**待 macOS 编译 + 真机回归**：批量续签时抽屉应显示上传百分比、上传完成即切「安装中」并出现「已等待 m:ss」；单签进入安装阶段应出现同样的等待说明；运行中点「取消」能立即退出界面；Seal 自续签在失焦（下拉控制中心）后仍能完成替换而不是停在 93%。
- **仍未闭环**：安装/上传超时预算偏长（`mergedTimeout = min(1800, 180+ipaMB×5) + 600`，20MB 包 ≈ 878 秒）——是否缩短需要用户拍板，缩短的代价是慢设备上的假超时（超时按确定性拒绝处理、不重试，但底层安装可能仍在跑，会留下「装上了却记为失败」）。另需用户补完问题 6。

### 2026-09-16 · 设备端描述文件只增不减（Seal 自己 17 份）+ 序列号/UUID 版式统一

- **现象（用户报 6 条，第 6 条被截断）**：①续签到安装卡在 93% 无反应；②续签抽屉卡在「传输」无反应；③证书序列号要左右一行、超长中间省略；④描述文件 UUID 同样左右一行；⑤描述文件每次申请旧新并存，Seal 已有 16 个 UUID 对应的文件；⑥「签名、续签」（未写完）。
- **证据来源**：用户随后发的两张截图是 **StikDebug** 的「App Expiry」页（不是 Seal 界面 —— Seal 只有 Apps / Settings 两个 Tab，截图里是三个；`App Expiry`/`Other Profiles` 等字符串在 Seal 代码里搜不到）。但它经 misagent 读的是设备真实 profile 库，数据可信：
- `com.example.seal.<TEAM_ID>` → **17 份**（1 最新 + 16 旧，界面写「Show 16 older profiles」）
  - `com.kdt.livecontainer.seal.TEAM000001` → 3 份
  - `com.kdt.livecontainer.seal666.ShareExtension` → ≥6 份，到期日全在 `2026-09-17`（有效期 7 天 ⇒ **创建于同一天 09-10，一天内重签 6 次以上**）
- **根因（两条独立泄漏路径，清理代码本来就存在，但触发条件与匹配范围都有缺口）**：
  1. **只按主 Bundle ID 匹配**：`SignedArtifactProfileReader` 只认恰好三段的 `Payload/<App>.app/embedded.mobileprovision`，而一次安装会为**每个扩展**各装一份 profile ⇒ 扩展的 profile 从来没被清理过。
  2. **只在安装成功那一刻触发**：`AppMaintenanceJob`（空闲维护）三步里**完全没有**描述文件清理 ⇒ 历史堆积永远回收不了；Seal 自己的自更新走 `SelfReplacementCoordinator` 事务链而非 `installSignedIPA`，清理条件更严、更容易整批跳过。
- **修复**：
  1. `SignedArtifactProfileReader.embeddedProfiles`：枚举**全部**会被安装的位置（主 App + PlugIns/AppClips/Watch），**排除 `Frameworks/*.framework`**；Bundle ID 取自 profile 自身的 `application-identifier`（剥 TeamIdentifier 前缀），不从路径推断。
  2. `DeviceProfileCleaner` 改为「Bundle ID → 保留 UUID」映射：**key 集合之外的一律不碰**（设备上还有 MDM / 企业证书 / 其它工具装的 App）。
  3. `SigningCoordinator` 安装后按整组 profile 清理，扩展不再漏。
  4. `AppMaintenanceJob` 新增**第 4 步**设备端描述文件清理 —— 这一步是清掉历史堆积的关键，它不依赖某一次安装成功。
  5. 两条安全红线：**拿不到可信 UUID 就整条跳过**（宁可留着，删错会让 App 立刻无法启动）；**扩展记录仅在 `signedArtifactStatus == .installed` 时采信**（`applySigningResult` 在签名阶段就写扩展 UUID，安装失败时它是乐观值）。Seal 自己则以运行时读到的真实 profile 覆盖记录值。
  6. 版式统一（问题 3/4）：`AppDetailView.serialDetailRow`/`profileDetailRow`、`InstalledAppActionSheet.metadataValueRow`、`AppSigningSheet.summarySerialRow`、`SigningProgressView.runtimeSerialRow` 五处改为 HStack 左右一行 + `.truncationMode(.middle)` + `.textSelection(.enabled)`。
- **守卫与测试**：`Scripts/verify-release-safety.py` 新增 **R08**（5 条断言）+ **4 个变异锚点**；顺带修掉一处**被自己削弱**的既有断言（`C: the sweep must re-check the lease` 原本用 `in`，删除步骤变 2 处后被掩盖 ⇒ 改为按次数断言 `>= 2`）。新增 `AppMaintenanceJobTests` 4 条 + `SignedArtifactProfileReaderTests` 4 条。结果 **147 源码 + 64 变异 PASS**。
- **涉及文件**：`Seal/Infrastructure/Installation/SignedArtifactProfileReader.swift`、`DeviceProfileCleaner.swift`、`Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Core/Maintenance/AppMaintenanceJob.swift`、`Seal/Application/AppContainer.swift`、`Seal/Features/Apps/{AppsViewModel,AppDetailView,AppSigningSheet,InstalledAppActionSheet,SigningProgressView}.swift`、`SealTests/Import/Fixtures/IPAArchiveFixture.swift`、`SealTests/{Maintenance/AppMaintenanceJobTests,Signing/SignedArtifactProfileReaderTests}.swift`、`Scripts/verify-release-safety.py`。
- **验证状态**：静态守卫 PASS。**待 macOS 编译 + 真机回归**：打开 Seal 静置触发空闲维护后，StikDebug 的 App Expiry 页里 Seal 应从 17 份降到 1 份，日志出现 `设备端旧描述文件清理：扫描 N，匹配 M，删除 K`（`SEAL-PROFILE-320`）；若出现 `stage=dump` 或 `skipped-record-read-failed` 说明隧道/misagent 通道没起来。
- **仍未解决**：问题 1（93% = `.installing`，`installTimeout=600s`、`pushTimeout≈180+ipaMB×5`，可能长停 4.6–10 分钟）与问题 2（「传输」= `.pushing`；抽屉里 Seal 那项应显示「即将更新」，卡在「传输中」的大概率不是 Seal）**都需要卡住那一刻前后 1 分钟的 Seal 日志**；问题 6 待用户补完。
- **详见**：`docs/qa/2026-09-16-profile-pileup-and-ui-row-layout.md`。

### 2026-09-16 · 抖音（8 扩展）签名必失败：Apple 限流被误报成「登录过期」；批量续签解阻塞

- **现象**：签抖音（主 App + 8 扩展 = 9 个 bundle ID）时，**无论怎样都会在「正在验证 Apple ID」报错失效**，反复重新验证 Apple ID 也无效；签其他 App（Kazumi 1 个 bundle ID、Sollin Player 2 个）完全正常。用户认为「id 名额足够」。
- **根因**：`ApplePortalSigningService.prepareProfile` 对 9 个 bundle ID 串行执行 Phase 1（`addAppID` + `updateFeatures` ×9）与 Phase 2（描述文件申请 ×9，每次含 delete + 重取），**短时间二十余次密集请求触发 Apple 对免费账号的限流**，返回 `1100 Your session has expired`。
  - **决定性证据**：每次 `AUTH-107` 报错前 1–3 秒都有一条「证书决策」成功日志（21:15:40→21:15:41、21:18:14→21:18:16、21:31:43→21:31:46）。证书能申请成功说明 session 在服务端仍然有效。
  - **旁证**：同一账号 `mar***7***@gmail.com` 在 21:07:38 刚成功签完 Kazumi，6 分钟后签抖音即报「登录过期」。
  - 代码里原本已有注释提到「1100 在 App ID 创建阶段也会出现（如抖音签名时）」，但只做了错误分类，没有处理限流本身 —— 分类正确了，问题还在，用户被反复引导去重新验证。
- **修复**：
  1. 新增全局 `AppleRequestThrottle`（相邻请求 ≥ 0.4 秒），挂在 **`withAppleTimeout` 开头** —— 它是所有 Apple 请求的唯一入口，一处覆盖全部调用点。节流只在间隔不足时等待，对 500ms 轮询与单 App 签名零影响。
  2. 新增 `withSessionRecovery`：对 `addAppID` / `fetchProvisioningProfile` 命中 1100 时退避重试（1.5s / 4s / 8s），耗尽才抛。**只重试 1100**，网络超时、Bundle ID 冲突（9400）、名额上限（3013）仍立即失败。
  3. **App ID 阶段的 1100 文案与 account 阶段拆开**：前者改为「Apple 暂时拒绝了请求 / 请先等几分钟再重试」，后者保留「去重新验证」。这是打断死循环的关键。
  4. 消除 `diagnostic.contains("1100")` 子串误判，统一走 `isSessionExpiredError`（只认错误码 + 官方文案）。
- **附带修掉**：`SettingsViewModel` 把 `usedBundleIDCount`（已注册存活数）渲染成「N 个可用 App ID」，语义完全反了 —— 日志里「10 个可用」实为**已用满 10 个**，直接造成用户「名额足够」的误判。改为「已注册 N / 10」，与 `CertificatesRootView` 的「已签名 n / 10」统一。
- **同轮做的优化**：`startBatchRefresh` 去掉前置 `await refreshSigningChannel()`（「点续签后卡很久」的第二个入口）。解阻塞的前提是**先在通道层加失败熔断**（60 秒窗口）—— 否则通道不可用会退化成 N×75s 诊断。熔断配合既有 `inFlightStart` 单飞，整轮批量只付一次诊断代价。用户发起的会话显式 `clearFailureCooldown()`，不会被熔断误挡。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`、`Seal/Core/Installation/InstallChannel.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Settings/SettingsViewModel.swift`、`SealTests/Signing/AppleRequestThrottleTests.swift`（新增）、`Scripts/verify-release-safety.py`。
- **待核对的结构性约束**：免费账号 App ID 名额是「7 天窗口内最多 10 个」，**一轮抖音签名就吃掉 9 个**（主 + 8 扩展），7 天后过期又要重注册。这是 Apple 侧限制，代码无解 —— 建议抖音用付费账号签，或接受丢弃部分扩展。本次失败全部是 `AUTH-107`，没有一次 `SEAL-APPID-304`，所以名额不是本次的直接原因，但值得用户核对。
- **验证状态**：静态守卫 PASS（139 源码断言 + 59 变异）。**待 macOS 编译 + 真机回归**（本机无 Swift 工具链）。真机重点：日志里是否出现「Apple 会话疑似被限流，退避 N 秒后重试…」；退避后是否成功；批量续签是否不再长停「正在连接设备」。

### 2026-09-16 · 自续签 7 问：连设备卡顿（真 bug）、证书/描述文件展示统一、关联判定同源、回主屏转场

- **现象（用户报的 7 条）**：
  1. 签名/续签卡在「正在连接设备」很久。
  2. 「Apple ID 证书 · 序列号 xxx」要统一成「证书序列号 + 完整序列号」，且序列号要显示全面。
  3. Seal 自续签的蓝色文案要跟普通 App 一样。
  4. 续签后的证书没关联到 Seal 自己（「此证书已安装 App」里看不到 Seal）。
  5. 要确认用的是真实的 7 天新时间，而不是假数据（怕第二天掉签）。
  6. 续签完回主屏像闪退，要有过渡。
  7. 描述文件「可用」要换成「该应用使用的 UUID」独占一行灰色。
- **根因**：
  1. **真 bug**：`SigningCoordinator` 里「隧道与签名并行」已做过，但 `AppsViewModel.runSigning` 在调用协调器**之前** `await refreshSigningChannel()` → `installChannel.start()`，把整段隧道诊断（reset + 18s RSD 握手 + 36×500ms 轮询，硬超时 75s）又同步等了一遍，并行化对首个调用完全失效；`updateState/.progress(.waitingForChannel)` 又把 UI 钉在「正在连接设备」。
  2. 序列号在标题右侧单行渲染 + `.truncationMode(.middle)` + `.minimumScaleFactor(0.8)`，40 位十六进制必然被截断；「序列号 · 」前缀还白占位置。
  3. Seal 专属 `sealReplacementTip`（「请按 Home 键回到主屏幕」）是「自动回主屏」上线前的产物，现在说反了。
  4. **真 bug**：同一张证书的两处展示不同源 —— 行标签用 `associatedApps`（含扩展 target），下方清单用 `affectedApps`（只看顶层 serial + `state == .installed`），于是「标签说在用、清单说暂无」；Seal 的 `belongsInInstalledList` 恒为真但 `state` 不一定是 `.installed`，被前置条件挡掉。
  5. 代码侧已三重强校验真实 7 天（取到即校验 + 不达标同会话重取 + 成品包 embedded profile 再验），但 UI 不暴露 profile 身份，用户无法自证。
  6. `SelfInstallAutoBackground` 静止 2s 后只走一条 `perform("suspend")`，`responds(to:)` 为假时**静默什么都不做**，最后由 installd 杀进程 → 观感等同闪退。
  7. `描述文件` 行显示的是状态枚举文案（`.available` → 「可用」），只回答「有没有问题」，不回答「是哪一份 profile」。
- **修复**：
  1. 新增非阻塞 `AppsViewModel.beginSigningChannel()`（`runSigning` 改用它，不再 await）；`MinimuxerInstallChannel.start()` 增加单飞合并 `inFlightStart`，避免 ViewModel 与协调器并发重跑诊断；`SigningCoordinator` 安装前 await 通道时不再 `try?` 吞错，只在 `isReady()` 为假时抛底层 `SEAL-VPN-*`/`SEAL-PAIR-*`。
  2. `certificateName(serial:)` → `certificateSerialText(serial:)`（只返回完整序列号，去掉前缀）；行标题统一「证书序列号」；值独占一行、灰色等宽、可长按选中。四个入口（详情页 / 进度页 / 操作面板 / 签名表单）全部统一。
  3. 进行中一律 `keepSealOpenTip`；删除 `sealReplacementTip`，新增 `sealReturningHomeTip` 只在 Seal 进入 `.installing` 后显示。
  4. 新增 `CertificateRevocationImpact.installedAppsAssociated`（= `associatedApps` + `belongsInInstalledList`），证书页清单改用它；**`affectedApps` 语义未动**，撤销影响评估仍走它；守卫新增断言这条分界 + 4 条单测。
  5. 详情页新增 `描述文件` UUID 行与 `描述文件创建时间` 行：续签后 UUID 变、创建时间是刚刚、有效期 = +7 天，即可自证真实生效。
  6. `SigningProgressView` 新增 `isReturningHome`，进入 `.installing` 先 `withAnimation` 渲染「正在退回主屏幕」再触发系统转场；`SelfInstallAutoBackground.returnToHomeAfterSealUpload()` 双路径 suspend（`perform` → `UIControl().sendAction(_:to:for:)`）+ `exit(0)` 兜底；可感知停顿 2s → 1.2s。
  7. `描述文件` 行的值改为 profile UUID 独占一行灰色等宽可选中；仅当状态不是 `.available` 时保留状态标签（`.mismatch` 是安全信号，不能删）。
- **涉及文件**：`AppPresentation.swift`、`SigningProgressView.swift`、`AppDetailView.swift`、`AppSigningSheet.swift`、`InstalledAppActionSheet.swift`、`AppsViewModel.swift`、`CertificateRevocationImpact.swift`、`SigningCertificateSettingsView.swift`、`MinimuxerInstallChannel.swift`、`SigningCoordinator.swift`、`SealTests/Settings/CertificateRevocationImpactTests.swift`、`Scripts/verify-release-safety.py`。
- **验证状态**：`python Scripts/verify-release-safety.py` PASS（Source 129 / Mutation 55）。**待 macOS 编译 + 真机回归**，重点：①单签/续签不再长时间停在「正在连接设备」，且通道真失败时给可操作文案；②Seal 自续签进度→文案切「正在退回主屏幕」→平滑回主屏→重开是最新且设置页自动确认；③证书页 Seal 出现在「本机已安装 App」清单且序列号与详情页逐字符一致；④详情页 profile UUID 与创建时间在续签后都变、有效期 = +7 天。**风险点**：`exit(0)` 仅在 suspend 完全不可用时触发，需确认不会留下旧 profile（若出现，改为「等安装 RPC 返回再退后台」）；1.2s 停顿若导致暂存未落盘被切走，回调到 1.5–2s。
- **详见**：`docs/qa/2026-09-16-renewal-ux-and-cert-issues.md`（含逐条「要求本身合不合理 / 有没有更好的做法」评估）。

### 2026-09-16 · 批量续签 Seal 自动回主页：补发 .installing 信号（含去冗余开关）；签名进度页序列号与详情页同步

- **现象**：
  1. 批量续签里 Seal 到安装阶段不会像单签那样自动回主页。
  2. `SigningProgressView` 的「Apple ID 证书」行只显示「可用」，看不到具体序列号，与应用详情页展示不一致。
- **根因**：
  1. 批量续签的 `progress` 回调（`RenewalCoordinator` → `.appProgress(…, stage:)`）只透传 `SigningStage`，接不到单签用的 1.01 上传哨兵；而 Seal 走 `submitPrepared` 只发 `.pushing`，不发 `.installing` → 批量里 Seal 永无 `.installing`，`consumeBatchEvent` 里 `app.isSeal && stage == .installing` 分支永远不命中。
  2. 两处证书展示各写各的：详情页 `AppDetailView.certificateName` 输出「序列号 · .fullSerial」，签名进度页 `SigningProgressView.certificateDisplayName` 只回「可用」。
- **修复**：
  1. `installSignedIPA` 的 Seal 分支在 `submitPrepared` 上传完成（>1.0）时补发一次 `progress(.installing)`（`SigningCoordinator.swift:1233`），批量经 `.appProgress` 命中 `consumeBatchEvent` 触发 `SelfInstallAutoBackground`。**去冗余**：新增显式开关 `broadcastInstallingForSelfReplacement`（默认 false），仅 `RenewalCoordinator.swift:232` 批量续签传 true；单签续签 Seal 仍靠 `onInstallProgress` 的 1.01 → `SigningProgressView.onChange` 触发，不在此补发，消除对同一事件的双重触发。
  2. `SigningProgressView.certificateDisplayName` 改为复用 `AppSigningPresentationHelpers.certificateName(serial:)`，用 `session.selectedCertificateSerialNumber ?? session.account.certificateSerialNumber` 生成「序列号 · .fullSerial」，与详情页同源同 helper 完全同步；证书未确定仍显示「未准备」。
- **涉及文件**：`SigningCoordinator.swift`、`RenewalCoordinator.swift`、`SigningProgressView.swift`。
- **验证状态**：待 Xcode 编译 + 真机回归（重点：批量续签 Seal 自动回主页、单签不重复回主页；签名进度页显示真实序列号与详情页一致）。

### 2026-09-16 · 自续签 93%：自动回主页 + 安装转圈动效；连接设备并行化不再阻塞签名

- **现象**：签名/续签安装到 93% 后 UI 静止像卡死，要人手按 Home 才让 iOS 完成替换；签名/续签的「连接设备」环节单次也明显卡顿（哪怕只签单个 App）。
- **根因**：
  1. **93% 卡死感**：Seal 自续签=覆盖安装运行中的自己，iOS 只有等旧进程退后台才用新版替换；但进度 UI 把 `.installing` 定成静止 93%，没有任何动效反馈。
  2. **连接设备卡顿**：`signAndInstall` 在签名**前**同步 `installChannel.start()`，整段隧道诊断（reset + 18s RSD 握手 + 36×500ms 轮询）阻塞签名；签名所需的 UDID 其实配对缓存就有，根本不必等隧道就绪。
- **修复**：
  1. **自动回主页**：进入 `.installing`（上传完成哨兵 1.01 触发 `.pushing→.installing`）后，`SigningProgressView.onChange` 对 Seal 自续签自动 `suspend` 切后台（`NSSelectorFromString("suspend")`+`responds` 守卫，不可用则静默降级），installd 在后台任务保护下完成替换，结果由重开的新进程对账——不再手按 Home。
  2. **转圈动效**：Seal 自续签 `.installing` 阶段进度环改为持续转圈的「替换中」动效（`selfReplacementInstallingRing`），不再静止 93%。
  3. **连接并行化**：`signAndInstall` 隧道改 `Task { try await installChannel.start() }` 后台平行启动；签名 UDID 从配对缓存 `storedDeviceIdentifier()` 快速读取（描述文件只认 UDID 与隧道无关），无人工痕迹的首次未配对场景仍等一次隧道。安装唯一漏斗 `installSignedIPA` 开头 ensure 通道就绪（`!isReady() → start()`，命中 900s 缓存近乎零等待），覆盖缓存/新签/续签三条路径，避免 `install()` 因通道冷而直接抛 channelNotReady。
- **涉及文件**：`Seal/Features/Apps/SigningProgressView.swift`（转圈动效 + 自动回主页）；`Seal/Core/Signing/SigningCoordinator.swift`（连接并行化 + 安装漏斗 ensure 通道）。
- **验证状态**：待 Xcode 编译 + 回归样本真机验证（重点：①Seal 自续签到 93% 转圈、数秒后自动回主屏完成替换、重开已是最新并自动确认；②单/批量签名「连接设备」不再停顿、签名完成即装；③普通 App 签名安装互不影响、不误触发自动回主页）。`suspend` 为私有 API，若系统不可用必须静默回退到旧「按 Home」路径，不得报错中断。
- **已知边界（已补齐）**：自动回主页原来只在**单 App 续签**的 `SigningProgressView` 触发；批量续签 Seal 走 `BatchRefreshView`，其 `progress` 回调只透传 `SigningStage`、接不到 1.01 上传哨兵，导致批量里 Seal 永远收不到 `.installing`。补齐方式：`installSignedIPA` 的 Seal 分支在 `submitPrepared` 上传完成（>1.0）时补发一次 `progress(.installing)`，`AppsViewModel.consumeBatchEvent(.appProgress)` 对 `app.isSeal && stage == .installing` 触发 `SelfInstallAutoBackground`（已改为 internal 供两处复用）。**注意**：Seal 自续签必然替换运行中的自己、进程会被新包终止，其后排队的续签项会一并中断（与手按 Home 相同），这是 Seal 自更新的固有语义。

### 2026-09-16 · 自续签安装卡 93%、连接设备卡顿、检查安装结果要手动——三处连点优化

- **现象**：用第三方工具签的 Seal（Bundle ID 已带 `.<TEAM_ID>`）能正常自续签，但安装停在 93%；只有手动退回主屏幕才真正完成替换。签名/续签都在「正在连接设备」环节卡顿。证书页的「检查安装结果」要人手点，不会自动确认。
- **根因**：
  1. **93% 卡顿**：Seal 自续签=覆盖安装正在运行的自己，iOS 只有等旧进程退到后台才用新版完成替换。MinimuxerInstallChannel 为不让 installation_proxy 连接被冻结而刻意不切后台，于是 `.installing` 阶段被定死在 93% 干等，直到手按 Home 触发 swap 才落盘。进度 UI 的「是否保持前台」提示在这个场景下正好说反了。
  2. **连接设备卡顿**：`MinimuxerInstallChannel.start()` 的设备标识缓存窗口只有 60s。批量续签在两次 start 之间每个 App 都要签名、申请描述文件，一超过 60s 缓存过期就整体重跑诊断（reset + 18s RSD 握手 + 36×500ms 轮询），于是每个 App 都要在「连接设备」重卡一次。
  3. **检查安装结果要手动**：自替换 `reconcile(…)` 在「当前进程 == 提交进程」时固定返回 `.awaitNextLaunch`，必须由「重新打开的新进程」在启动维护里对账结算；设置页只支持点按钮重读本地状态，没有等待确认态下自动刷新，等新进程结算完成后 UI 不会自己切到已完成。
- **修复**：
  1. 进度文案区分 Seal 自续签与普通续签：Seal 显示「进度走完后按 Home 回到主屏幕，iOS 会用新版替换；替换完再重新打开」（新增 `AppSigningPresentationHelpers.sealReplacementTip`），不再误导「保持前台干等」；`awaitingReplacementConfirmation` 的 detail 同步改为「回主屏幕让 iOS 完成替换，再重新打开，本页会自动确认」。
  2. `MinimuxerInstallChannel` 缓存窗口 `60s → 900s`（整场签名/续签会话），命中仍要求 `isReady()` 为真，设备真断了不会用到陈腐缓存。
  3. 设置页等待确认态 `.task(id: state)` 自动每 2s 重读 `refreshSelfManagementState`，新进程结算/关闭事务后本页自动切到已完成，保留「检查安装结果」按钮作兜底。
- **涉及文件**：`Seal/Features/Apps/AppPresentation.swift`、`SigningProgressView.swift`；`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`；`Seal/Features/Settings/SettingsViewModel.swift`、`SigningCertificateSettingsView.swift`。
- **验证状态**：待 Xcode 编译 + 回归样本真机验证（重点：Seal 自续签 93%→退后台→重新打开→设置页自动确认；批量续签连设备不再逐 App 卡顿；「检查安装结果」无需手动）。注意：本改动未触碰自替换对账/结算核心语义，`reconcileAtLaunch`/`settle` 仍由启动维护的 `SelfAppRegistrar` 负责。

### 2026-09-16 · 签名模型改动后旧单测断言被替代行为，导致 CI swift-regression 红

- **现象**：推送签名三改动（身份识别放宽 / 单槽位证书接管 / Bundle ID 团队后缀）后，云构建 `swift-regression` 在 12m27s 失败（exit 65），而 `build-package` / `rork-sign-tests` 均绿。
- **根因**：`BundleIDMapperTests.requestedMainBundleIdentifierWins` 断言「requested 原样胜出」（旧行为）；`CertificateTakeoverPolicyTests.singleRemoteCertificateWithFreeSlotCreatesLocal` 断言「两槽位下 1 张远程证书仍视为有空槽→createLocal」（旧两槽位语义）。两处都被本次故意改动的核心语义取代，单测没同步，实现行为变了、测试仍验旧行为。
- **修复**：单测对齐新设计——① requested 不再原样胜出，改为「未带当前 team 后缀则换算成 recommended（自动补 `.seal.teamID`）、已带则原样复用、大小写不敏感」；② 证书接管改为单槽位语义，「空槽（无远程证书）→ createLocal」，删除旧「单张远程证书当空槽」用例（其场景已由 `fullSlotsWithOnlySignerBlocks` 覆盖）。
- **涉及文件**：`SealTests/Signing/BundleIDMapperTests.swift`、`SealTests/Signing/CertificateTakeoverPolicyTests.swift`。
- **验证状态**：提交 `c37b378` 推送后重跑，run 68 三 job 全绿（build-package 3m25s / swift-regression 13m49s / rork-sign-tests 2m49s）。IPA `Seal_1.1.16.ipa`（sha256 `1c824466…`）已落盘 `Desktop/Seal_IPA/` 并二次校验通过。

### 2026-09-16 · 自续签身份源改为 Keychain/描述文件推断——评估后回退（守卫拦截）

- **提议**：问题2 想对齐 SideStore，让自续签在 Mach-O 读不出真实 signer（第三方工具签的非标准结构）时，用「描述文件授权证书 ∩ 本机 keychain 私钥证书，恰好 1 张」兜底确认 Seal 签名者，从而不再卡 SEAL-CERT-232 / SEAL-SELF-105。
- **回退原因**：实现后 `Scripts/verify-release-safety.py` 立即 FAIL 两条 Seal 自保护断言——本库硬性纪律是**绝不用描述文件授权列表推断 Seal 签名者**（2026-09-15 真机变砖血教训：授权列表含「并未实际签名」的证书，推断会保护错证书）。细想确有致命场景：Seal 由第三方工具签名时，profile 授权可能同现「本机 keychain 有私钥的旧证书」与「第三方签名证书」，交集恰好 1 张会保护错旧证书，放行撤销真正在用的第三方证书 → Seal 变砖。**守卫拦得对**。
- **处置**：回退 ApplePortalSigningService（`resolveSigningIdentity`）、SigningCoordinator 一键全撤、自动盘活清理三处兜底改动，恢复「只信 `installedIdentity`（真实 CMS 签名者），读不出即停止/SEAL-CERT-230/`.unavailable`」的既有安全模型；删除临时 helper。守卫恢复 PASS（128 + 54）。
- **结论**：第三方工具签的 Seal 自续签，仍按要求走「电脑原签名工具覆盖安装」这一既有安全兜底（SEAL-CERT-232 恢复文案），不因本次问题2 放宽。若真要做 Keychain 身份源，需重新设计并过安全评审（如电脑覆盖前把签名身份正确留存进 keychain，而不是设备端拿 profile 授权列表推断）。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、`Seal/Core/Signing/SigningCoordinator.swift`（均已回退至基线）。
- **验证状态**：`verify-release-safety.py` PASS。改动未遗留，无编译期新符号。

### 2026-09-16 · Bundle ID 未带团队后缀导致跨设备互相占用

- **现象**：同一个（原始）Bundle ID 只要被某台设备/账号注册过，其他设备就无法再注册使用，报 `bundleIdentifierUnavailable`。
- **根因**：`BundleIDMapper.mainBundleID` 在 `requested` 非空时**直接原样返回**，不附加 `.seal.{teamID}` 后缀。UI 默认推荐值虽带后缀，但当用户手动输入、或沿用旧的 `preferredBundleIdentifier`（历史数据不带后缀）时，最终签名/注册的 Bundle ID 就没有「团队隔离后缀」。不同 Apple ID（不同 team）的设备就会用同一个字符串 bundle ID 去注册，先注册的占用后注册的。Apple 的 App ID 在团队维度隔离，靠后缀把不同账号签成不同字符串才能天然避免冲突。
- **修复**：`BundleIDMapper.mainBundleID` 对 `requested` 统一换算——已带 `.seal.{当前teamID}` 后缀（续签复用已安装 / UI 默认推荐）则原样保留；否则用 `BundleIDPolicy.recommendedBundleIdentifier(for:teamID:)` 统一附加当前团队后缀（会剥离多余 `.seal` 中间缀，避免 `xx.seal.seal.team`）。与上游 AltStore/SideStore「原始+teamID」策略对齐。
- **涉及文件**：`Seal/Core/Signing/BundleIDMapper.swift`。
- **验证状态**：待 Xcode 编译 + 回归样本（微信 / 黄豆短剧 / LCSign / lanmanga）真机验证，重点核对首次签名、手动改 Bundle ID、同 Apple ID 多设备三种路径最终签名 ID 均带当前 team 后缀。

### 2026-09-16 · 合法第三方签名被误判为 inconsistentArchitectures

- **现象**：Sideloadly 的 bundle mangle / 爱思非标准结构产生的合法签名，`AppBundleSigningIdentityReader` 因 CodeDirectory 全量哈希校验失败而判 `inconsistentArchitectures`，Seal 读不出身份，连锁触发 SEAL-CERT-232 / SEAL-SELF-105，无法自续签。
- **根因**：`inspectWithRorkSign` 把「CMS 密码学校验 + CodeDirectory 哈希校验」作为识别身份的双重硬条件；第三方工具持有合法证书 CMS 签名，但修改了二进制结构导致代码目录哈希对不上，被误判为无法识别。
- **修复**：**仅放宽 CodeDirectory 全量哈希校验**——改为以「能读出一致签名证书 serial」为识别身份的依据（多架构 serial 一致才通过），CMS/哈希校验状态如实记入 evidence 供诊断；`readTarget` 的 `signerNotAuthorizedByProfile`（signer serial 必须落在描述文件授权证书内）校验保持不变，防误撤销自身证书的原始目的仍未放松。
- **涉及文件**：`Seal/Infrastructure/Renewal/AppBundleSigningIdentityReader.swift`。
- **验证状态**：待 Xcode 编译 + 回归样本真机验证。

### 2026-09-16 · iloader 非标准签名导致 Seal 无法自续签

- **现象**：设备上续签 Seal 时，证书页读不出完整证书；点续签后弹出「无法确认当前 Seal 的签名证书」，恢复文案「先用电脑的原签名工具覆盖安装一次 Seal，再回来续签」。日志另出现 SEAL-SELF-105「无法确认当前 Seal 的签名身份」。
- **根因**：当前正在运行的 Seal 由 iloader 用非标准签名结构签名，主程序/网络扩展的真实 CMS 签名者无法被 `AppBundleSigningIdentityReader` 读出。身份读不完整 → 既不敢撤销（SEAL-CERT-232）、也不敢覆盖装自己（SEAL-SELF-105）。这是设备现实状态，不是代码 bug，且不能靠弱化身份校验绕过。
- **修复/处置**：电脑覆盖安装（不卸载），保持同一 Apple ID、Team 与主/扩展 Bundle ID 一致，改用能产出标准签名的签名工具。
- **涉及文件**：`Seal/Infrastructure/Renewal/AppBundleSigningIdentityReader.swift`、`Seal/Core/Renewal/SelfReplacementCoordinator.swift`。
- **验证状态**：待用户电脑覆盖安装后，回读新日志确认身份读取完整。

### 2026-09-16 · 证书轮换在无法确认 Seal 真实签名证书时仍撤销

- **现象**：续签 Seal 时，即使读不出运行中 Seal 的 signer，日志仍出现「证书轮换：撤销 …序列号，原因=无本机私钥，运行中Seal=否」，把唯一一张无本机私钥的证书当普通孤儿撤了，随后创建新证书签名，但安装被 SEAL-SELF-105 拦住。
- **根因**：`rotateCertificatesAndCreateIdentity` 未区分「签名/续签 Seal 本身」与「签名普通 App」。读不出 signer 时把 `sealActualSignerSerials` 置空，导致运行中 Seal 证书被误标为「运行中Seal=否」进入可撤销集合。
- **修复**：新增 `sealSignerConfirmed` 标志；`isSeal == true` 且读不出运行身份时，前置抛出 `SEAL-CERT-232`（无法确认当前 Seal 的签名证书），在撤销发生前就止步。普通 App 不涉及 Seal 身份，不受影响。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`。
- **验证状态**：`Scripts/verify-release-safety.py`（128 源码回归 + 54 变异）全过，CI build-package / rork-sign-tests / swift-regression 全绿；真机日志确认旧版误撤、新版已止步于 SEAL-CERT-232。

### 2026-09-16 · SelfReplacementFailure 被兜成笼统 SEAL-SIGN-500

- **现象**：自更新安装分支抛出的 `SelfReplacementFailure` 未被映射为 `ImportFailure`，被 `AppsViewModel.unexpectedSigningFailure` 兜成笼统「SEAL-SIGN-500」，用户拿不到可操作指引。
- **根因**：`SelfReplacementFailure` 四种 case（runningIdentityUnknown / bundleShapeChanged / localSigningIdentityUnavailable / candidateChanged）未做错误码映射。
- **修复**：在 `SigningCoordinator` 新增 `selfReplacementFailure(_:)`，映射为 SEAL-SELF-105～108，兜底 SEAL-SELF-109，标题统一「Seal 自更新中止」；自更新安装分支 try/catch 捕获并转 `ImportFailure`。
- **涉及文件**：`Seal/Core/Signing/SigningCoordinator.swift`。
- **验证状态**：提交 `edc7971`，CI build-package / rork-sign-tests / swift-regression 全绿，回归测试未破坏。

---

### 2026-09-21 · iOS 17.0–17.3.1 已生成 Lockdown 文件仍不能安装/续签

- **现象**：此前只修复了 Windows 配对助手按系统版本生成 Lockdown 文件；Seal 端仍可能导入仅含 UDID 的无效占位文件、没有把底层 usbmuxd 指向自己的本地监听器，并且主安装链路固定调用 RSD 专用的 `stageAndInstall`。因此 iOS 17.0–17.3.1 即使拿到 Lockdown 文件，也无法完成端到端安装。
- **根因**：Lockdown 与 RPPairing 的协议边界没有贯彻到导入、启动和安装三处。前者需要完整 pair-verify 主机身份，依赖本地 usbmuxd 代理，且安装必须走 AFC 暂存加 installation_proxy；RSD 合并调用只适用于远程配对。
- **修复**：① `PairingStore` 强制校验 UDID、HostID、SystemBUID 和四项证书/私钥材料；② `Muxer.start` 在 Lockdown listener 启动前设置 `USBMUXD_SOCKET_ADDRESS=127.0.0.1:27015`；③ `MinimuxerInstallChannel` 按配对类型分流，Lockdown 使用 `yeetAppAfc` + `installIpa`，远程配对保留 `stageAndInstall`；④ 助手未读到系统版本时禁用生成，避免误产出远程配对文件；⑤ 新增 R62 守卫与单测。
- **涉及文件**：`PairingStore.swift`、`Muxer.swift`、`Minimuxer.swift`、`MinimuxerInstallChannel.swift`、对应 Pairing/Installation 测试、`verify-release-safety.py`、配对助手覆盖与发布说明。
- **验证状态**：守卫 PASS；**CI ✓**（run `35557258917`：`build-package` ✓ 含守卫步骤、`swift-regression` ✓ 编译与用例全过、`signer-tests` ✓）。iOS 17.0–17.3.1 的**真实设备回归仍是最终验收条件**。
- **补审计（2026-09-21 二轮，只读，为了不再重复审）** —— 逐条确认下列路径**本来就按配对类型分流、无需改动** ✓：
  - `Install.getProvider()`：`Muxer.isrppairing ? RPInstall() : LockDownInstall()` ✓；
    `yeetAppAfc`/`installIpa`/`removeApp` 都经它转发 ⇒ **这两个入口一直是正确的**。
  - `Jit.getProvider()`、`Mounter.getProvider()`、`Provision.getProvider()` 同样都有 `isrppairing` 分流，
    且 `LockDownMounter` / `LockDownProvision` 是**真实实现**（`Device` + `RustLockdown`/`RustMounter`/`RustMisagent`），不是空壳 ✓。
  - **`Minimuxer.stageAndInstall` 是唯一没有分流的入口**（无条件 `RustIdevice.stageAndInstall`，RSD 专用）
    ⇒ 这才坐实了「第三个断点」：旧代码对 Lockdown 调它必然失败 ✓（同文件里 `lookupApp` 都有分流，对比明显）。
  - `LockDownMounter.startAutoMounter` 会等 `Muxer.usbmuxdReady`，再按 `ProductVersion` 分 `<17` / `>=17`；
    **17.0–17.3.1 落在 `handlePost17Mount`**，它调 `rustBridgeMountPersonalizedDDI(… muxerAddr: MuxerConstants.usbmuxdSocket, deviceIp: DeviceEndpoint.shared.ip())`
    —— 用的正是本轮修的那个本地 socket ✓，且显式传参、不依赖环境变量 ✓。
  - 进度哨兵：本仓约定 `>1.0`（1.01）表示「上传结束、installd 即将安装」。Lockdown 分支发 `progress(1.0)`，
    经 `syncProgress` 的 `if p >= 1.0 { onProgress(1.01) }` 正确转成哨兵 ✓（`>=` 与 `InstallStageBridge` 里
    `>` 的差别是有意的：桥接那层收的是已转换过的值）。
  - ⇒ **没有第四个功能性断点**；剩下的不确定性只在运行时（会话能否建起来、installd 认不认）。

### 2026-09-21 · `Minimuxer.reset()` 的 RSD 复位判据**恒为假** —— 那条恢复手段从未执行

**现象（审计发现，非真机）**：`Minimuxer.reset()` 里写着

```swift
Muxer.reset()
...
if Muxer.isrppairing { RustIdevice.invalidateConnection() }
```

而 `Muxer.reset()` 内部的 `teardownLocked()` 已经把 `_isrppairing` 清成 `false`
⇒ 那个 `if` **永远不成立** ⇒ `RustIdevice.invalidateConnection()` **从未被调用过**。

**为什么后果严重**：本仓**三处**注释都指着它是「清掉 Rust 侧死连接」的唯一杠杆 ——
`Install.resetProvider()` 只清 Swift 侧对象、**清不掉 Rust 的会话缓存**
（`MinimuxerInstallChannel` 的 `probeCachedSessionIfStale` 注释、`Install.resetProvider()`
调用点注释、以及 `MEMORY.md` 的「安装静默优先怀疑缓存的 RSD 连接」）。
⇒ 重试一直复用同一条死连接，真机形态就是「安装静默卡住 / 大包空推」
（2026-09-17 那 9 分多钟的成因之一）。

**修法**：在 `Muxer.reset()` **之前**读出 `let wasRemotePairing = Muxer.isrppairing`，
用这个快照做判据。语义完全不变，只是让原本声明的行为真的发生。

**守卫 R63**（1 条断言 + 2 个变异锚点）：
⚠️ 光断言「有 `invalidateConnection`」不够 ✗ —— 旧代码**也有**它，只是永远走不到
（「代码看起来有恢复逻辑、其实恒假」是最容易漏掉的一种退化）。
⇒ 按**下标顺序**判：读取点必须在 `Muxer.reset()` 之前（R61④ 同款手法）。
变异锚点：① 把读取挪到 `Muxer.reset()` 之后；② 把 `if wasRemotePairing` 改回
`if Muxer.isrppairing`。两者都已复核会红。

**涉及文件**：`Vendor/Minimuxer/Sources/Minimuxer.swift`、`Scripts/verify-release-safety.py`。

**验证状态**：守卫 PASS（460 源码断言 / 242 变异）；⚠️ **行为变化待真机确认** ——
修复后 `Minimuxer.reset()` 在远程配对下会真的重建 RSD 连接，这正是注释声明的意图，
但它是本轮唯一「改变了既有运行时行为」的改动。

### 2026-09-21 · 透传闭包给 `@escaping` 目标：参数必须显式声明 `@escaping`（CI 实报）

**现象**：本轮推送（`6d990e4`）的 iOS CI **5m20s 早失败**，两个 job 同一条错：

```
Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift:51:88:
  error: passing non-escaping parameter 'progress' to function expecting an '@escaping' closure
```

**根因**：新增的 `installIPAUsingActivePairingTransport(...)` 把 `progress` 声明成
`@Sendable (Double) -> Void` —— 而 **Swift 的闭包参数默认 non-escaping** ✗。
它要透传给 `Minimuxer.stageAndInstall(bundleId:ipaBytes:progress:)`，那个参数是
`@escaping (Double) -> Void` ⇒ non-escaping 传不进去。

**修法**：`progress: @escaping @Sendable (Double) -> Void`
（`@Sendable` 可以弱化成非 Sendable，方向安全；反过来不行）。

**教训（值得记的通用形式）**：**本机没有 Swift 工具链 ⇒ 「透传闭包」这类错误
只会在云构建暴露，而一轮 CI 是 5–16 分钟。**
⇒ 写「把闭包参数转手传给另一个函数」的代码时，**先去看目标签名有没有 `@escaping`** ——
这比 `?? []` 的类型推断陷阱更容易踩，因为**默认值恰好是反的**（默认 non-escaping）。

**顺带确认**：同轮 CI 里 `ApplePortalSigningService.swift:754`（`unzipSeconds` 未使用）
与 `SigningWorkspace.swift:897`（`fileManager` 未使用）两条 warning 是**既有**的，
不在本轮改动文件里。

**涉及文件**：`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`。

**验证状态**：待下一轮 CI 确认编译通过。

### 2026-09-21 · `#expect` 第二参数是 `Comment?`：`String` 变量传不进去（CI 实报，仅 `swift-regression` 红）

**现象**：推送 `bc7fcc9` 的 CI（run `35554045362`）—— `build-package` ✓（6m57s）、
`signer-tests` ✓（1m0s），**只有 `swift-regression` 红**（4m28s），注解重复 20 次同一条：

```
SealTests/Pairing/PairingStoreTests.swift:182:82:
  error: cannot convert value of type 'String' to expected argument type 'Comment?'
```

**根因**：swift-testing 的 `#expect(_:_:)` 第二个参数类型是 `Comment?`。
`Comment` 遵循 `ExpressibleByStringLiteral` / `ExpressibleByStringInterpolation`
⇒ **字符串字面量（含 `"\(变量)"` 插值）能构造 `Comment`，`String` 变量不能** ✗。
我写的是 `#expect(PairingStore.isCompleteLockdownPairing(incomplete) == false, key)`
—— 目的是用 `key` 标出「是哪个键被删掉后判定失败了」，结果把 `String` 变量直接塞进 `Comment?` 位置。

**修法**：`#expect(..., "缺少 \(key) 时不应判定为完整的 Lockdown 配对文件")` ✓
（本仓既有先例：`IPAParserServiceTests.swift` 的 `"…实际耗时 \(elapsed) 秒"`、
`ProfileReclaimPolicyTests.swift`）。
⚠️ 顺带确认：`sourceLocation:` 是**带标签**参数，也不能当第二参数位置参数传
（`#expect(failure.code == code, sourceLocation: sourceLocation)` 才是对的 ✓）。

**教训（与上一条同族，且更隐蔽）**：这又是一条**只在云构建暴露**的错误 ——
`build-package` 根本不编译测试 target ⇒ **本轮 `build-package` 照绿**，只有 `swift-regression` 红。
⇒ **给 `SealTests/**` 加带上下文的断言时，第二参数一律写成字符串字面量或插值**，
不要传 `String` 变量 ✓。

**已加守卫**：`Testing:` 段新增通用检查
`#expect must not pass a bare identifier as its comment`，判据是
「`#expect(...)` 的实参**以「, 裸标识符」结尾**」—— 只认结尾形态，所以既不误伤
嵌套调用里的逗号（`#expect(State(id: "", p: "") == nil)`），也不误伤带标签参数
（`#expect(x, sourceLocation: loc)` 结尾是 `: loc`）。
⚠️ **加之前先在**全仓 **1185 处 `#expect`**（86 个测试文件）上跑过一遍只读扫描：
**零误报** ✓ —— 这条「先量基数再上闸」的顺序不能省，否则新判据会把守卫自己弄红。
另配变异锚点（把带插值的注释换回 `key`）证明该检查不是空转。

**⚠️ 同一个检查还踩到第二个坑：守卫自己的运行时**

新检查第一版对**所有含 `#expect(` 的测试文件**都调 `strip_cached` —— 而 `SealTests/` 里
有 **80 个**这样的文件。`violations()` 在变异检查里要跑 **243 遍** ⇒ 每遍多剥 80 个文件
（约 1.5 MB 纯 Python 字符循环）⇒ 守卫总时长从 4.6 分钟涨到 **9 分 26 秒**（实测）✗。
⚠️ 守卫超时被 SIGTERM 时**没有任何输出**，很容易被误判成「脚本崩了」
（见「常犯坑位」里 `守卫脚本自己也会慢到被超时杀掉` 那条）。

⇒ 修法是加 **raw 文本前置过滤**：先看原文有没有 `,\s*标识符\s*(?:\)|//)`，命中才去注释。
实测 **86 个文件 → 只剩 6 个（66 KB）** ✓ —— 干净文件零成本跳过，变异文件仍命中
（用「把锚点文本替换成 `key` 后再问一次过滤」验证过）。

**判据：往 `violations()` 里加任何「遍历全部测试文件 + 去注释」的检查之前，
先数一遍它会命中多少个文件。** `violations()` 的调用次数 = 变异条数（200+），
单遍多 1 秒就是总时长多 4 分钟。

**顺带核对（同一轮做的防回归检查）**：收紧 `PairingStore.inspect` 后，逐条核对了
`SealTests/Pairing/PairingStoreTests.swift` 里所有构造配对字典的地方 ——
`standardPairingDictionary` 已含全部 7 个键（3 String + 4 Data）⇒ 既有「导入/校验/保护/删除」
与「设备不匹配」两条测试不会被误伤 ✓；另两处故意造的不完整文件（`UDID`+`HostID`、
只有 `HostID`）本来就断言抛 `ImportFailure` ✓。同时确认 `hasRemotePrivateKey` 用的是
**精确键名**匹配（`private_key`/`privateKey`/`PrivateKey`/`Private Key`），
不会把 Lockdown 的 `HostPrivateKey` 误判成远程配对文件 —— 这条由既有绿测试
`importsValidatesProtectsAndRemovesStandardPairingFile`（断言 `isRemotePairing == false`）反证 ✓。

**涉及文件**：`SealTests/Pairing/PairingStoreTests.swift`、
`Scripts/verify-release-safety.py`（新增通用检查 + 变异锚点）。

**验证状态**：守卫 **PASS（461 源码断言 + 243 变异）** —— 比加检查前多 1 条断言、1 个变异锚点，
说明新检查确实在跑、变异锚点确实会红 ✓。
**CI ✓**（run `35557258917`：`swift-regression` ✓ ⇒ 编译与用例都过；`build-package` ✓ ⇒ 守卫在提交树上也过）。
⚠️ 加检查时把守卫从 4.6 分钟拖到 **9 分 26 秒**（见上「守卫自己的运行时」），
已用 raw 文本前置过滤修回。

### 2026-09-21 · 推送 `522e877` 的守卫在 CI 上红：共享守卫文件里混进了并行会话的锚点

**现象**：`522e877` 的 iOS CI（run `35555995119`）—— `swift-regression` ✓、`signer-tests` ✓，
但 `build-package` 的**第一步** `Check release safety invariants` **FAIL**：

```
Source regression checks: 462
Guard mutation checks: 244
FAIL: Mutation anchor missing: Seal/Features/Apps/SigningProgressView.swift
  anchor='    private func stageElapsed(at now: Date, startedAt: Date?) -> TimeInterval {'
```

**根因（两层）**：

1. 我在本地实测是 **461 断言 / 243 变异**，CI 上是 **462 / 244** ⇒ 守卫文件在「本地跑完」与「提交」之间**被改过**。
2. 改它的是**另一个会话**：它加了 1 条 `SigningProgressBudget.overallProgress(` 反向断言 + 1 个配套变异锚点，
   **并把一条既有锚点的文本从 `stageElapsed(_ now: Date)` 改写成新签名 `stageElapsed(at now: Date, startedAt:)`**。
   我这次只提交自己的 3 个文件（`git add -- <paths>`，刻意排除对方的 7 个在制品）⇒
   守卫里带着**指向对方新代码**的锚点，而对方的 `SigningProgressView.swift` 没进提交 ⇒ 锚点在提交树里找不到 ✗。

**为什么第一版防护不够**：我只查了「守卫文件里有没有 `workUnits`」，而对方的锚点用的是
`stageElapsed` / `overallProgress` —— **不含 `workUnits` 字样** ⇒ 关键词检查漏过。
⇒ **判据：核对「共享文件有没有被对方改过」不能用对方功能的**关键字**去 grep**，
要么把本地文件与「上一个远端尖端」逐行 diff（`-` 行必须为零），要么走隔离副本重做。

**修法**：按技能用 `git worktree add --detach <远端尖端>` 建**隔离副本**（另开新路径，不动
`git worktree list` 里上一轮遗留的副本），在副本里撤掉对方那 3 处改动（用「任一锚点不匹配就整体不写」
的脚本，断言 7 项后落盘），在副本里跑守卫，再从副本推送 ✓。

**教训**：见「常犯坑位」新增的那条。核心判据：**本地守卫 PASS ≠ 提交树的守卫 PASS**；
提交前用 `git cat-file -e <提交>:<路径>` 核对守卫 `load()` 的全部路径（本次 93 条，0 缺失），
并把提交里的守卫与上一个尖端逐行 diff（**`-` 行必须为零** —— 本次致命的正是「既有锚点被改写」，
它藏在 `-` 行里，只看 `+` 行会漏）。

**涉及文件**：`Scripts/verify-release-safety.py`。

**验证状态**：隔离副本里守卫 **PASS（461 断言 / 243 变异）** —— 计数与本地实测一致
（CI 那次是 462 / 244），证明对方那 1 条检查 + 1 个锚点确已撤净 ✓。
**CI ✓**：run `35557258917` 全绿（`build-package` 4m49s 含守卫步骤 / `swift-regression` 9m0s / `signer-tests` 1m3s）。

---

### 2026-10-08 · iPad 7（A10）「登录 Apple ID → 点添加 → 秒退」：预编译件带了 A10 没有的 LSE 指令

**现象**：iPad 第 7 代（A10，iPadOS 18.7.10）上爱思助手签名的 Seal 1.3.45，
Win 配对成功后用 WiFi 登录 Apple ID，**输入完账号密码、点「添加」就闪退到桌面**。

**崩溃日志（决定性）**：

- `EXC_BAD_INSTRUCTION` / `SIGILL`，例外交付子码 `0xC8E9FD56`
- 出错指令 `casal x9, x22, [x10]`，崩在 **`thread 5`（后台线程）**
- `codeSigningFlags=570434309`

`casal` 是 **ARMv8.1 的 LSE（Large System Extension）原子指令**。
**A10 是 Apple 唯一一颗「对外标示 ARMv8.1-A、实测却没实现 LSE」的芯片** ——
LLVM `AArch64Processors.td` 里 `AppleA10 = [HasV8_0aOps, SHA2, AES, FPARMv8, NEON,
PerfMon, CRC, RDM, PAN, LOR, VH]`，**没有 `FeatureLSE`**；`AppleA11` 起才有。
⇒ 走到这条指令就是 SIGILL，与「设备太老」无关（A10 在 iOS 17.4 的最低支持范围内）。

**排除代码缺陷**：Apple 官方文档明确 —— ARM 上 Swift 运行时错误（强解包 nil）报
`SIGTRAP`，**不报 `SIGILL`** ⇒ 不是 Seal 自己的 Swift 代码。

**三重实证定位到 Unicorn**：

1. 崩溃日志的指令字 `0xC8E9FD56` 与 `casal x9, x22, [x10]` **逐位一致**
2. 本地 `Seal_1.3.8.ipa` 主程序反汇编：`_cpu_exec_aarch64 @ 0x100866ff0` 就是同一条指令、
   **连寄存器都一样**（`casal x9, x22, [x10]`）
3. 解包 Unicorn 官方预编译包：`ios-arm64` 切片含 **93 条 LSE**
   （`cputlb.c` 84 / `bitmap.c` 4 / `translate-all.c` 4 / `cpu-exec.c` 1）

**根因（上游构建脚本的漏洞）**：`mahee96/unicorn` 的 `build_xcframework.sh`
**没有设 `CMAKE_OSX_DEPLOYMENT_TARGET`** ⇒ clang 按 SDK 默认版本选目标 CPU：

    clang/lib/Driver/ToolChains/Arch/AArch64.cpp: getAArch64TargetCPUByTriple
      // "iOS 26 only runs on apple-a12 and later CPUs"
      if (!Triple.isOSVersionLT(26)) return "apple-a12";     ← 带 LSE

`apple-a12` 有 LSE ⇒ 生成的**宿主代码**带 LSE ⇒ 在 A10 上走到就 SIGILL。

⚠️ **换版本解决不了**：`2.1.4-multiarch`（当前用的）与更新的 `2.1.4-xcf-a53ddc9`
**两个官方包都是 93 条 LSE** ⇒ 必须自己从源码重编。

⚠️ **归属纠正**：`libCoreADI.so` 里那 94 条 LSE **不是元凶** —— 它是被 Unicorn
**软件模拟执行**的 guest ELF 代码；真凶是 Unicorn 自己的宿主代码（`cputlb.c` 等）。

**修复**：`Scripts/ensure-unicorn.sh` 从 pinned commit
（`62d0155ffd4c886d14cf7aa26b7f3ed759617c71` = 上游 `2.1.4-multiarch` 对应提交，
**除指令集基线外行为与现状完全一致**）重编，只改两处：

    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IPHONEOS_DEPLOYMENT_TARGET"   # ① 显式部署目标
    -DCMAKE_C_FLAGS="-mcpu=$UNICORN_TARGET_CPU"                   # ② apple-a10（无 LSE）

`IPHONEOS_DEPLOYMENT_TARGET=17.4` ⇒ 目标 CPU 正好钉在 A10（17.4 能跑的最老芯片）。
装 `ensure-rustbridge.sh` 同一套路数：指纹命中早退、指纹不符重编、**通过守卫才写指纹**。

**本次一并查出的问题**：

1. ⚠️ **`verify-no-lse.py` 的 minOS 断言一直失效**（自己写的 bug）：
   `build_version_command` 的 `minos` 在 **`+12`**，我写成了 **`+16`（= `sdk`）**。
   实测 `RustBridge.xcframework`：`off+8=2(iOS) / off+12=16.0(minos) / off+16=0.0(sdk)`，
   而 `min_os()` 返回 `0.0`。⇒ Rust 目标文件读 0.0（静默假绿灯）、
   asn1 目标文件读 26.5（假报警）。**已修**，并补上 `platform` 字段：
   只有 iOS 家族（platform 2/7）参与 `--max-ios-version` 断言。
2. ⚠️ **切片数从 7 降到 2**：上游出 mac / tvOS / visionOS / iOS（设备+模拟器，
   模拟器含 x86_64）共 7 个切片，本方案只出 `ios-arm64` + `ios-arm64-simulator`（均 arm64）。
   CI 全在 macos-26(arm64) 上跑 ⇒ **不影响 CI**；但**Intel Mac 的模拟器构建**会缺 x86_64 切片，
   `Package.swift` 声明的 `.macOS(.v12)` 也会没有对应切片。**待补**（见下）。
3. ⚠️ **本守卫不能扫 Rust 产物**：`RustBridge.xcframework` 稳含约 **8980 条 LSE**
   （Rust `compiler_builtins` 的 outlined atomics，靠
   `is_aarch64_feature_detected!("lse")` 运行时分派，A10 永远走不到）
   ⇒ 拿它扫整个 `Seal_*.ipa` 会得到纯假报警。**已写进守卫的 docstring 与坑位 8**。
4. ⚠️ **CI 扇出**：本分支上一次推送同时命中 `ios-fast.yml`（**无 paths 过滤**）、
   `ios.yml`（paths 含 `Scripts/**`）与新加的 rebuild 工作流 ⇒ 2–3 个 run 挤在一起，
   后一次推送的 `cancel-in-progress` 把前一个刚起的 run 杀掉（实测只活 1m10s）。
5. ⚠️ **`b11b080`（#102）从未构建成功**：其 `fast-ipa` job `started_at=08:27:44 →
   completed_at=08:42:46`、`conclusion=cancelled`、**`steps=[]` 且日志 blob 不存在**
   （`BlobNotFound`）⇒ 在队列里等了 15 分钟、一个步骤都没跑就被取消了。
   **artifact 数量 = 0**；现存最新的可用包是 `Seal-101`（来自 `9b97f57`）。
   `b11b080` 相对 `9b97f57` **只领先 1 个提交**（25 个文件）。

**涉及文件**：`Scripts/verify-no-lse.py`（新增）、`Scripts/ensure-unicorn.sh`（新增）、
`.github/workflows/rebuild-unicorn-ios.yml`（新增）、`docs/knowledge/PITFALLS.md`。
**待办**：切片补回 `ios-arm64_x86_64-simulator`（+ `macos-arm64_x86_64`）；
给 rebuild 工作流加 `concurrency`；`Package.swift` 的 remote binaryTarget 改本地 path
（**须等产物入库后**，否则 SPM 解析会因缺目录直接失败）。

**验证状态**：本机无 macOS ⇒ **无法本地编译**，`-mcpu=apple-a10` 能否编过 + LSE 是否归零
只能由云端 rebuild 工作流实测（产物下载后本地跑 `verify-no-lse.py` 复量：
必须 **0 条 LSE** 且 arm64 对象数非 0，防"全空假绿"）。
守卫基线：`Checks: 831, Failures: 0`（本地 Windows 实跑）。

### 2026-10-08 · rebuild 工作流"一直 Queued"：macOS 机器池枯竭 + Intel 宿主不等价（两次失败后成功）

**现象**：`Rebuild Unicorn (armv8.0 / no LSE)` 在 Actions 页面上一直 `Queued`，23 分钟不变。
**第一层诊断（不是编译慢）**：`in_progress = 0`、`queued = 1`，即**一步都没跑**；
两条独立 job 都是入队后**恰好 15 分 02 秒**被回收（`conclusion=cancelled`、`steps=[]`、
`runner_name` 为空、日志 blob 直接 `BlobNotFound`）。GitHub 状态页全绿、仓库 public
（标准 runner 免费不限量）、账号级 macOS 并发 0/5 占用 ⇒ 只剩一种解释：**该镜像池没有机器**。

**定位手法（受控实验，不猜）**：往临时分支 `ci/probe-runner` 推一个只有 `runs-on` + `sw_vers`
的矩阵探针（`macos-26` / `macos-15` / `macos-15-intel` / `macos-26-intel`），20 秒出结论，用完删分支：

| 标签 | 分配耗时 | 结果 |
|---|---|---|
| `macos-26` | — | 一直 queued，从未拿到 runner |
| `macos-26-intel` | 4s | success |
| `macos-15` | 8s | success |
| `macos-15-intel` | 4s | success |

**第二个错误（我自己犯的）**：据此把 `runs-on` 改成 `macos-26-intel` —— 理由写的是
"本作业只做交叉编译，与宿主架构无关"。run `37757816680` 秒级拿到 runner，却在第 6 步真实失败：

```
CMake Error at CMakeLists.txt:394 (message):
  qemu/configure failed (1): "…/clang" cannot build an executable (is your linker broken?)
```

读上游源码定位（`CMakeLists.txt:384-392` / `293-342` / `option(UNICORN_FUZZ … OFF)` 第 85 行）：
它把 `qemu/configure` 当**本机**编译跑，`--extra-cflags` 里**只有 `-isysroot`、没有 `-arch`**
（`${CMAKE_C_FLAGS}` 仅在 `UNICORN_FUZZ=ON` 时才拼进去）⇒ configure 的探测按**宿主机架构**编译
⇒ Intel 宿主得到 `x86_64-apple-ios`，iPhoneOS SDK 没有 x86_64 切片 ⇒ 链接测试失败。
**教训**：`CMAKE_OSX_ARCHITECTURES` 对**嵌套的 autoconf configure** 不生效；
判断"能不能换 Intel"必须读构建脚本，不能只看自己传的 flags。

**修复**：`runs-on: macos-15`（arm64，探针实测 8 秒可用），并把 Xcode 选择放宽为
"有 `Xcode_26.5.app` 就用它，否则取最新 `Xcode_26*.app`"（`macos-15` 只装到 26.3/26.4），
断言主版本为 26。run **`37758408740` 十步全绿**。

**产物事实（回读，非推断）**：
- 实际用 **Xcode 26.3**（Build 17C529）+ cmake 4.4.3，源码 pinned `62d0155f…`
- 两个切片都是 **3.0M**；`.source-fingerprint` = `2b583d60ab06…`（完整值 `2b583d60ab0677ebc519470ec63e4dbaa9a8503be71ac9a8ea82b28fca9b60a5`）
- zip sha256 = `1babf1e68be49ab764e61d68775acf3102e84f85f9c8e80d7b1813d8b46bd041`（下载后本地复算一致）
- `verify-no-lse.py`：**`arm64 Mach-O=146`（对象数非 0 ⇒ 不是全空假绿）、0 条 LSE、iOS 家族 minOS ≤ 17.4`**
  —— CI 内（步骤 7）与下载后本地复量，两处一致
- **正对照**：同一脚本扫上游 `2.1.4-multiarch` 仍报 **558 条 LSE**（含
  `ios-arm64/libunicorn.a(cpu-exec.c.o) @0x53c 0xC8E9FD56 cas/casp ← _cpu_exec_aarch64`，
  与用户崩溃日志逐位一致）⇒ 扫描器没坏，确实是产物变干净了

**本轮提交**：`7346df0`（换 `macos-26-intel` + 修 `verify-no-lse.py` 的 minOS 偏移）、
`b4c2aa0`（换回 arm64 `macos-15` + 放宽 Xcode 选择）。守卫 `Checks: 831, Failures: 0` 保持。

## 2026-10-10 — 错误帮助目录 Swift 编译失败

**症状**：GitHub Actions run `38034517600` 在 Swift regression 阶段失败，编译器报告
`Cannot find ')' to match opening '(' in string interpolation` 与 `Unterminated string literal`，定位到
`ErrorKnowledgeAction.id`。

**根因**：字符串插值表达式中的空字符串被误写为 `\\\"\\\"`；插值内部应使用普通 `\"\"`。

**修复**：改为 `"\\(title)|\\(route ?? \"\")"`，并添加 route 为 `nil` 时标识符为 `标题|` 的回归测试。

## 2026-10-10 — 协议门控 UI 回归用例文案失配

**症状**：GitHub Actions run `38037596205` 的 862 个单元测试通过，但
`AgreementGateUITests.testFirstLaunchBlocksTheAppUntilTheAgreementsAreAccepted` 失败，找不到旧标题“欢迎使用 Seal”。

**根因**：当前首次协议抽屉的正式标题已是“欢迎使用”；协议链接用例同时通过，证明门控与抽屉存在，只有 UI 用例仍断言旧文案。

**修复**：将门控存在性断言同步为“欢迎使用”，保留同意、暂不使用和主界面不可见的原有门控断言。

## 2026-10-10 — 安装失败设置跳转从错误码猜测迁移为结构化语义

**症状**：设置页导航仍按 `SEAL-INSTALL-*` 等错误码前缀判断。相同前缀会同时覆盖设备存储不足、安装仍在进行、签名包无效、配对失效和本地隧道不可用，导致“恢复”将用户带到无法解决问题的页面。

**根因**：`ImportFailure` 已具备 `condition`、`action`、`route` 和 `retryDisposition`，但安装通道生产失败时未填充这些字段，UI 只好重新解析历史错误码。

**修复**：新增 `InstallFailureSettingsRoute.route(for:)`，只消费 `FailureRoute`；安装通道中已确认的配对、设备信任、隧道、存储不足、安装仍在执行与签名包拒绝路径补齐结构化语义。设备“未响应”不再无证据地归因到 LocalDevVPN，而是要求解锁后重试。旧错误码路由仅为兼容旧记录保留，新的 UI 调用点不再使用。

**验证**：新增路由不猜测错误码的测试，以及配对/隧道/设备未响应的语义回归断言；本机 Windows 没有 Xcode，Swift 编译与完整测试待 GitHub macOS CI 验证。

## 2026-10-10 — 设备存储不足误报

**症状**：用户曾在设备并非空间不足时看到“设备存储空间不足”。

**根因**：安装错误分类将裸 `code 28`、泛化 `space left` 和宽泛中文“空间不足”直接等同于安装服务的 ENOSPC；这些片段可来自 HTTP、重试预算或其他组件，缺少“设备文件系统已满”的证据。

**修复**：新增单一判据 `isDeviceStorageExhaustion`，仅接受 `No space left on device`、`ENOSPC`，或带写入/安装上下文的 `errno 28`，以及明确的“设备存储空间不足”。安装终态判定与最终用户文案共用该判据；无法证实空间满时保留为一般安装失败，不要求用户清理空间。

**验证**：补充 `code 28`、HTTP 状态、重试预算等反例和明确 ENOSPC 正例；本机无 Swift/Xcode，待 GitHub macOS CI 编译测试。

## 2026-10-10 — iOS 安装拒绝被过度归因为上限或重签

**症状**：`ApplicationVerificationFailed` 被同一分支同时解释为“免费账号应用上限”或“签名包无效”，于是用户会收到互相矛盾的卸载/重签建议。

**根因**：该系统返回本身不足以区分上限、签名校验和其他系统拒绝；原分类把所有词合并后给出确定性操作。

**修复**：只有明确 `maximum` / `limit` / “应用上限”时才提示卸载一个自签应用；只有完整性、签名、描述文件过期等证据存在时才提示完整重签；其余 `ApplicationVerificationFailed` 保留为无法确定的系统拒绝并引导导出诊断，不猜测用户应该卸载或重签。

## 2026-10-10 — 移除 App 内静态错误帮助页

**症状**：App 内“错误帮助”只依据离线错误码目录展示泛化内容，无法保证与当前实际失败路径一致，用户反馈没有实际帮助。

**处理**：按产品决定删除该页面及所有入口：设置页、签名弹层、应用详情、列表全局弹层与日志页均不再打开 `ErrorHelpView`；删除随 App 打包的错误目录、数据源、测试与项目资源引用。日志错误仍可查看与复制原始错误信息。官网目录生成器只保留网站产物，不再把同一份静态 JSON 打进 App。

**验证**：错误目录 Python 单测 9/9 通过，源码检索确认 App/测试目标不再引用 `ErrorHelpView`、`ErrorKnowledgeStore` 或“查看解决办法”。

## 2026-10-10 — 日志页把 Documents 镜像缺失误作无日志

**症状**：日志页可能显示空白，导出时出现“日志文件不存在”。

**根因**：日志页直接读取 `Documents/Seal-log.txt`；该文件只是为文件 App/分享准备的节流镜像，刚启动、刚清理或镜像未完成时可以暂不存在，即使 `SealLogStore` 的实际缓冲中已有日志。

**修复**：日志页改从 `SealLogStore.exportText()` 读取唯一真实来源，Documents 镜像不再决定页面内容；清理改为直接等待 `SettingsViewModel.clearLogs()`，不再通过异步通知与手工删文件竞争；导出仍先物化并校验分享文件。导出错误区分“日志服务未就绪”和“导出文件写入失败”。

**验证**：补充空日志存储也必须物化可分享文件的回归用例；Swift/iOS 编译测试待 macOS CI。

## 2026-10-11 — 启动数据失败被误导为设备空间不足

**症状**：Seal 启动时本地数据库或文件初始化失败，会直接提示用户检查设备剩余存储空间。

**根因**：启动容器在捕获所有初始化异常后拼接旧式字符串文案；失败没有结构化语义，且“本地数据打不开”不能证明设备空间不足。

**修复**：新增 `StartupFailurePolicy`，将未分类启动异常统一为 `SEAL-APP-001` / `localStorageWriteFailed` / `restartSeal`。界面只说明本地数据暂时无法读取，并给出关闭后重新打开 Seal 的操作；保留已有结构化失败，不覆盖其具体语义。

**验证**：新增回归用例断言 Core Data 初始化异常不会出现“存储空间”误导文案，且已分类失败原样保留；Swift/iOS 编译测试待 macOS CI。

## 2026-10-11 — 发布守卫仍断言已废弃的错误码路由

**症状**：完整 iOS CI 在 `verify-release-safety.py` 的 R83/R96 失败，尽管生产代码已经改为使用 `ImportFailure.route` 与可测试的多行 `signingFailure` 声明。

**根因**：守卫与变异测试仍匹配迁移前的 `route(forCode: failure.code)` 及单行函数签名；它们把正确的结构化失败合同当作回归。

**修复**：R83 改为验证 UI 使用 `route(for: failure)`，变异锚点以该调用替换为 `return nil`；R96 改为正则识别 `nonisolated static signingFailure`，不依赖格式化后的单行文本，并同步变异锚点。

**验证**：待完整发布守卫与 macOS CI 复核。

## 2026-10-11 — 结构化导航类型混用导致 Swift 编译失败

**症状**：完整 iOS CI 的 Swift 回归构建报 `Extraneous argument label 'for:' in call` 与 `Cannot convert value of type 'FailureRoute' to expected argument type 'SettingsRoute'`。

**根因**：`SigningProgressView` 直接把 `ImportFailure.route`（领域层 `FailureRoute`）传给只接受界面层 `SettingsRoute` 的 `openSettings`，绕过了唯一转换边界 `InstallFailureSettingsRoute.route(for:)`。

**修复**：失败恢复改为先通过 `InstallFailureSettingsRoute.route(for:)` 取得 `SettingsRoute` 再导航。同步更新发布守卫中已过期的设备连接失败文案变异锚点。

**验证**：待 macOS Swift 编译、单元/UI 回归和完整发布守卫复核。

## 2026-10-11 — 单操作错误弹窗使用了不完整的 SwiftUI 构造器

**症状**：完整 iOS CI 在 `AppDetailView.swift:55`、`AppSigningSheet.swift:522` 和 `AppsRootView.swift:556` 报 `missing argument for parameter 'secondaryButton' in call`，测试与 IPA 构建均无法继续。

**根因**：这三处单操作错误弹窗使用 `Alert(primaryButton:)`；SwiftUI 的该重载要求同时传入 `secondaryButton`，而这里只需要一个会执行恢复动作的按钮。

**修复**：统一改用单按钮的 `dismissButton:` 重载，保留原有恢复动作；新增静态回归测试，禁止三处重新使用不完整的 `primaryButton:` 调用。

**验证**：Python 静态回归测试已先红后绿；待完整 iOS CI 复核 Swift 编译、单元/UI 回归与 IPA 构建。

## 2026-10-11 — 通道诊断追加详情时丢失恢复语义

**症状**：完整 iOS CI 的 `InstallChannelDiagnosticClassificationTests` 中，隧道不可达被降级为 `.unexpected` / `.copyDiagnostics`，设备未响应也不再提供“重试”。

**根因**：`discoveryFailure` 的两个兜底分支为追加底层详情重新构造 `ImportFailure`，却只复制了标题、原因、恢复文案和错误码，遗漏了 `condition`、`action`、`route`、重试策略、操作和来源字段；初始化器于是套用了默认的未知错误语义。

**修复**：新增仅追加诊断详情的复制助手，完整保留失败合同的所有结构化字段，保证诊断文本不会改变用户下一步操作。

**验证**：现有安装通道回归测试在 CI 中先失败；待完整 iOS CI 复核修复。

## 2026-10-11 — 结构化恢复标题函数调用与返回值不符合 Swift 语法

**症状**：完整 iOS CI 在 `SigningProgressView` 报 `Extraneous argument label 'for:' in call`；同一函数的 `switch` 分支产生未使用字符串警告。

**根因**：`semanticPrimaryRecoveryTitle` 的参数没有外部标签，却以 `for:` 调用；函数体的 `switch` 也没有作为函数返回值返回。

**修复**：改为无标签调用 `semanticPrimaryRecoveryTitle(failure)`，并使用 `return switch failure.action` 返回每个用户动作对应的标题。

**验证**：待 macOS Swift 编译、单元/UI 回归和完整发布守卫复核。

## 2026-10-11 — 错误码扫描把日志标签和多段标识混为一谈

**症状**：旧错误码扫描只接受两段数字尾号，漏掉 `SEAL-UPDATE-DL-501`、`SEAL-IPA-ROLLBACK-001` 等多段标识；同时把 `SEAL-OP`、`SEAL-RENEW-ROUND` 等内部日志标签统计成用户错误，导致“未分类错误”数量失真。

**根因**：扫描器把字符串格式当作错误语义，没有保留发生位置、调用上下文或标识用途；静态目录也被误当作完整错误事实来源。

**修复**：新增源码审计清单生成器，逐次记录标识类型（标准错误码、遗留错误标识、诊断标签）与来源角色（失败候选、内部日志、注释、可执行引用）。任何未完成触发链审计的条目只标为 `unreviewed`，不生成用户解决办法。

**验证**：新增 Python 回归测试覆盖多段标识、注释、日志 `code:` 字段、可选日志调用、遗留错误标识和直接失败合同字段；本地 10/10 通过。完整 iOS CI 待后续实际错误合同改动一并验证。

## 2026-10-11 — HTTP 503 被错误推断为用户网络线路问题

**症状**：`SEAL-NET-503` 在只收到 HTTP 503 或 “service temporarily unavailable” 时，提示用户切换“非国内梯子（海外节点）”。这既不是 HTTP 503 能证明的事实，也会把 Apple 服务端暂不可用误导成用户必须修改网络。

**根因**：`AppleServiceFailurePolicy.isRateLimited` 的判据仅检查 `503` 与服务暂不可用文本，但旧失败工厂将该有限事实扩展成了具体线路／地区结论；`FailureClassifier` 也把同一判据标成 `.appleRateLimited`。

**修复**：将这条边界收敛为已证实的 `.appleServiceUnavailable`，唯一动作为 `.waitThenRetry`，文案为“稍后重试”；没有把 Wi‑Fi、VPN、海外节点或限流当作确定原因。双重认证 `SEAL-AUTH-101a` 同时补齐了明确的 `.twoFactorAuthenticationRequired`、账户路由和“输入新验证码”动作，防止 UI 再靠错误码前缀推断。

**验证**：静态合同回归测试先红后绿（2/2）；扫描基线更新为 424 个唯一标识、798 次出现、139 个直接失败出口，其中 25 个已显式合同化、114 个仍待逐条审计。macOS Swift 编译和完整 iOS CI 待本批提交后一并复核。

## 2026-10-11 — 账户拒绝仍依赖错误码前缀推断账号状态

**症状**：验证码被拒绝、首次添加账号时凭据被拒绝、以及已保存账号验证时凭据被拒绝，虽然触发源已经不同，旧逻辑仍主要通过 `SEAL-AUTH-102*` 等前缀决定是否把账号标为需重新验证。

**根因**：这些直接 `ImportFailure` 出口没有携带条件、动作、路由、操作和来源字段；同一个错误号段也包含历史的二义出口，前缀无法成为账号状态的可靠事实来源。

**修复**：为三个 Apple 明确拒绝的出口分别写入 `verificationCodeRejected` 或 `credentialsRejected` 合同；验证码动作是“输入新验证码”，凭据动作是“重新验证 Apple ID”，均明确路由到账号页。新增 `authenticateAccount` / `validateAccount` 操作边界；`AppleServiceFailurePolicy` 对已结构化失败优先读取条件，旧前缀规则仅继续服务于历史未迁移记录。

**验证**：合同静态回归与错误库存测试本地 13/13 通过；扫描基线为 424 个唯一标识、799 次出现、139 个直接失败出口，其中 28 个已有显式合同、111 个仍待逐条审计。Swift 编译与完整 iOS CI 尚未执行。

## 2026-10-11 — “没有账号”与“账号需要验证”共用了同一错误语义

**症状**：签名、续签和“换账号”入口都用 `SEAL-AUTH-104a` / `104d` 同时表达“没有任何 Apple ID”和“已有 Apple ID 但全部需要重新验证”。两种状态对应不同下一步，界面却只能显示模糊的“去我的”。续签日志也可能写旧码、弹窗显示另一种状态。

**根因**：可选账号检查只返回空数组，调用点将 `accounts.isEmpty` 三元文案直接嵌在 `ImportFailure` 中，既没有可复用的失败合同，也没有保证日志码与实际弹窗码一致。

**修复**：新增 `AccountAvailabilityFailure` 单一出口：`SEAL-AUTH-104h` 表示没有签名账号，唯一动作为“添加 Apple ID”；`SEAL-AUTH-104i` 表示账号存在但都需要重新验证，唯一动作为“重新验证 Apple ID”。三个入口统一使用该工厂，续签留痕取生成失败对象的实际错误码；签名进度抽屉也识别“添加 Apple ID”动作并通过账户路由打开对应页面。

**验证**：新工厂的静态合同测试先失败后通过；本地 14 项 Python 审计／合同测试通过。替换旧码后重新生成的真实库存为 424 个唯一标识、797 次出现、139 个直接失败出口，其中 30 个已显式合同化、109 个仍待审计。Swift 编译和完整 iOS CI 尚未执行。

## 2026-10-11 — 续签原账号状态没有进入失败合同

**症状**：续签解析器已能区分“原账号仍在但需要重新验证”（`SEAL-AUTH-104f`）和“原账号已删除且找不到同 Team 账号”（`SEAL-AUTH-104g`），但弹窗仍只靠普通文本表达，界面层无法可靠判断前者应验证、后者必须补回原团队账号。

**根因**：两条 `ImportFailure` 直接构造没有结构化字段；若后续 UI 继续按错误码或标题推断，容易把后者错误地引导到任意账号续签，破坏同 Team 才能保留签名身份的安全边界。

**修复**：`104f` 设为 `accountVerificationRequired → reauthenticateAccount → account`；`104g` 设为 `recordedSigningIdentityUnavailable → addAccount → account`，两条均标注为 `renew` / `authentication`。文案明确后者需要添加原团队 Apple ID，而不是换任意账号继续。

**验证**：静态回归测试先红后绿；本地 15 项 Python 审计／合同测试通过。库存为 424 个唯一标识、797 次出现、139 个直接失败出口，其中 32 个已显式合同化、107 个仍待审计。Swift 编译和完整 iOS CI 尚未执行。

## 2026-10-11 — 添加账号超时与团队查询失败包含未经证实的网络推断

**症状**：`SEAL-AUTH-107t` 在认证超时时直接要求检查或更换网络；`SEAL-AUTH-105f`（验证码已接受但团队查询未返回）也没有明确的失败合同。这两条都可能被旧 UI 按 AUTH 前缀误作账号失效。

**根因**：前者唯一可靠事实是 `HardTimeout.TimeoutError` 在 240 秒内先返回，无法从该信号确认 Wi‑Fi、VPN、线路或 Anisette 的具体责任；后者来自认证成功之后的 team lookup 失败，与“Apple ID 没有开发团队”的空列表分支不同。

**修复**：超时改为 `authenticationTimedOut → waitThenRetry`，仅提示等待后重新添加账号；团队查询失败改为 `developerTeamLookupFailed → retry`。两条均标明 `authenticateAccount` 操作与实际来源，不再让用户修改未经证实的网络设置。

**验证**：静态合同测试先红后绿；本地 16 项 Python 审计／合同测试通过。库存为 424 个唯一标识、797 次出现、139 个直接失败出口，其中 34 个已显式合同化、105 个仍待审计。完整 iOS CI run `38093455221` 正在执行 Swift 回归和 IPA 构建。

## 2026-10-11 — Anisette 工厂的局部错误码让审计器低报失败出口

**症状**：`AnisetteV3Error` 的五个枚举分支在运行时已经返回失败对象，但先将错误码保存到局部变量，静态审计只能看到一个 `code: code`，无法把 `SEAL-ANI-110…114` 逐一关联到真实合同；库存因此低报已审计出口。

**根因**：审计器的证据标准是失败构造点必须同时可见具体错误码与合同字段。变量间接赋值会丢失这层关联，不能作为“已审计”的可靠依据。

**修复**：把五个枚举分支改为直接构造 `ImportFailure`：设备环境被拒绝、环境生成不可用、认证服务暂不可用各有明确条件；动作只保留重试或稍后重试，不自动重置环境、不将其写成 Wi‑Fi/VPN 故障。工厂开放为纯静态分类函数以供真实单测调用。

**验证**：静态合同测试先红后绿；本地 17 项 Python 审计／合同测试通过。库存为 424 个唯一标识、797 次出现、144 个直接失败出口，其中 39 个已显式合同化、105 个仍待审计；总数变化是审计盲点被消除后的校正，并非新增运行时错误。完整 iOS CI run `38093455221` 仍在执行。

## 2026-10-11 — 认证握手被拒绝时建议了未经证实的网络与时间操作

**症状**：`SEAL-AUTH-107h` 只确认 Apple 返回 `authenticationHandshakeFailed`，原文案却要求用户更换网络或核对系统时间。

**根因**：认证握手失败并不包含网络线路或本机时间的确定诊断；将可能因素呈现为恢复操作会制造无效操作，并掩盖真正的“应稍后再次认证”边界。

**修复**：将该出口结构化为 `authenticationHandshakeRejected → waitThenRetry`，操作为 `authenticateAccount`、来源为 `authentication`；用户文案只说明 Apple 拒绝认证握手并引导稍后重新添加账号。

**验证**：静态合同测试先红后绿；本地 18 项 Python 审计／合同测试通过。库存为 424 个唯一标识、797 次出现、144 个直接失败出口，其中 40 个已显式合同化、104 个仍待审计。此前 CI run `38093455221` 因新推送自动取消；run `38093961809` 正在执行。

## 2026-10-11 — 错误库存的审计状态全部固定为未审计

**症状**：库存已经记录直接失败构造与合同字段，但每个标识仍输出 `unreviewed`；这让已具备明确条件／动作／来源的代码和纯日志标签看起来相同，审计报告无法用于安排剩余工作。

**根因**：生成器只保存来源角色，没有从直接失败出口是否具备语义字段推导状态。

**修复**：库存生成器现在以证据计算状态：所有直接出口有字段为 `contracted`，同码同时包含合同化与旧出口为 `mixed`，无字段的直接出口为 `unreviewed`，纯诊断标签为 `diagnostic_only`，其他无直接出口引用为 `reference_only`。该状态不生成任何用户操作，只表达源码证据完整度。

**验证**：新增状态分类回归测试先红后绿；本地 19 项 Python 审计／合同测试通过。当前 424 个标识中 33 个 `contracted`、2 个 `mixed`、97 个 `unreviewed`、286 个 `reference_only`、6 个 `diagnostic_only`。完整 iOS CI run `38094053805` 仍在排队。

## 2026-10-11 — 描述文件目标集合不完整被误作不可操作的提示

**症状**：描述文件续签在写入本地待确认快照前发现主应用、扩展或完整目标集合缺失时，`SEAL-PROFILE-340/341/342` 只显示“知道了”。这既没有告诉用户本次续签没有完成，也可能让上层继续按旧错误码分支猜测为 App ID 缺失或需要完整重签。

**根因**：这三个出口位于 `ProfileOnlyRenewalRecordUpdater`，发生在同一次 profile-only 续签结果与已安装目标集合不一致时；代码没有表明它们与 `SEAL-PROFILE-337`（确认找不到 App ID，必须完整重签）是不同事实。

**修复**：将三条出口统一标注为 `provisioningProfileIncomplete → retry`，操作为 `renew`、来源为 `provisioning`，且只提示“重新续签”。不把该局部结果不完整扩展成 App ID 丢失、网络故障或删除签名包。

**验证**：新增 Swift 回归测试覆盖主描述文件缺失与目标集合缺失；新增静态合同测试覆盖 340/341/342 的统一语义。Python 审计／合同测试待提交前执行；完整 iOS CI 将在推送后验证 Swift 编译。

## 2026-10-11 — 一个稳定安装错误码承载了三种互斥恢复动作

**症状**：`SEAL-INSTALL-702l` 同时用于免费账号应用数达到上限、签名包完整性校验失败、以及 iOS 未返回具体原因的安装拒绝。三个场景分别应卸载一个自签应用、完整重签、或导出诊断；同码会使日志规则和旧 UI 无法可靠选择动作。

**根因**：旧审计器只检查“是否填写合同字段”，没有比较同码的具体 `condition` / `action` 值，因此把该冲突错误地标成 `contracted`。

**修复**：保留历史明确含义的 `702l` 给应用数上限；签名包校验失败改为 `SEAL-INSTALL-702v`，原因未知的 iOS 拒绝改为 `SEAL-INSTALL-702u`。安装动作策略同步拆分。审计清单 schema 升为 2，逐个输出合同枚举值，并新增 `conflicted`：只有同字段存在多个明确枚举值才判冲突，参数化的操作/来源透传不被误报为冲突。

**验证**：Python 生成器与合同回归测试待本批修改后执行；完整 iOS CI 待 GitHub 连通后验证。

## 2026-10-11 — 已确认的配对拒绝没有进入配对恢复合同

**症状**：安装通道从底层错误文本识别到 `pair`、`pairing`、`lockdown`、`hostid` 或无效 host 后，`SEAL-INSTALL-703` 已明确说明配对信息不可用，但没有结构化路由；UI 只能依赖旧码集合兜底，后续新入口容易重新把它当作“重新安装”。

**根因**：错误构造点缺少 `condition`、`action`、`route`、操作和来源字段，尽管底层判据本身已足以确认“配对不可用”。

**修复**：`703` 现在声明 `pairingRequired → repairPairing → pairing`，操作为安装、来源为设备通道。该合同会优先让现有 UI 打开配对页；没有把不明确的连接失败一并归为配对问题。

**验证**：新增静态合同测试。完整 iOS CI 将在下一次推送后编译验证。

## 2026-10-11 — 发布安全校验把合法访问修饰符调整误判为失败

**症状**：完整 iOS CI run `38095175602` 的 `build-package` 在编译前退出，报 `section start marker not found: private nonisolated static func failure(from error: Error) -> ImportFailure {`。

**根因**：`verify-release-safety.py` 用完整函数声明（包括 `private nonisolated`）切分双重认证的错误映射函数。源码为满足并发调用改为 `nonisolated static` 后，函数语义和测试保护不变，但校验器将访问修饰符当成了业务边界。

**修复**：安全校验改为以稳定的 `static func failure(from error: Error) -> ImportFailure {` 签名定位函数体，继续验证双重认证优先于限流和网络的实际业务顺序，不再绑定无关修饰符。

**验证**：运行发布安全校验及错误合同回归测试；下一次完整 iOS CI 将验证打包流程。

## 2026-10-11 — 安装后验证把“确实未安装”和“设备服务不可查询”混在旧码动作里

**症状**：安装完成后若目标 Bundle ID 未被 iOS 服务查到，旧 UI 的动作来自错误码兜底；当 Seal 自身也无法查询时，用户仍可能把“无法确认”误解成需要重新安装。

**根因**：`verificationFailure` 已使用 Seal 自身作为阳性对照区分两种事实，但两个 `ImportFailure` 尚未声明该判据与动作，界面只能继续依赖历史错误码集合。

**修复**：`SEAL-INSTALL-707a`（阳性对照可查、目标不可查）声明为 `installationVerificationFailed → reinstallFromSignedArtifact`；`707b`（阳性对照也不可查）声明为 `deviceServiceUnavailable → checkInstallationResult`，并明确“暂不重新安装”。两条均标注安装操作和设备通道来源。

**验证**：新增 Swift 单元测试断言合同字段，并新增静态合同测试；本地 Python 错误审计／合同测试 23 项通过。完整 iOS CI 运行中，待其完成后再推送本地这一批。

## 2026-10-11 — App ID 七天注册窗口被误当作网络或通用创建失败

**症状**：免费账号连续注册 App ID 达到 Apple 的七天滑动窗口上限后，`SEAL-APPID-304` 虽有正确文案，却未进入结构化合同；上层无法可靠区分它和通用 App ID 创建失败。

**根因**：`appIDFailure` 已依据 Apple 错误码 1009 / 3013 和限额文本识别这一事实，但 `ImportFailure` 没有声明该判据。该窗口不能靠删除当前 App ID 或检查网络解除。

**修复**：将 `304` 声明为 `appIDRegistrationLimit → waitThenRetry`，操作为签名、来源为 Apple Portal；不新增猜测式网络动作。

**验证**：新增静态合同回归测试；本地 Python 错误审计／合同测试 24 项通过。完整 iOS CI 将在推送后验证 Swift 编译。

## 2026-10-11 — 已保存账号验证的未分类异常没有明确恢复边界

**症状**：`SEAL-VERIFY-500a` 表示 Apple 账号验证返回了未能分类的异常，已有文案正确说明账号状态未改变，但缺少结构化条件、动作、操作和来源。UI 只能依赖旧错误码兜底，无法和“凭据被拒绝”或“验证码错误”等已确认事实稳定区分。

**根因**：这是 `AppleAccountClient.validate` 的最终兜底分支；在网络、双重认证、验证码与已知认证错误均已排除后，源码没有更多可证明的具体原因。把它写成网络、VPN、账号失效或要求立即重登都会超出证据。

**修复**：将该出口标注为 `unexpected → waitThenRetry`，操作为 `validateAccount`、来源为 `authentication`、手动重试；保留“账号状态未改变，稍后重试；持续失败再重新验证 Apple ID”的原始恢复顺序。

**验证**：新增静态合同回归测试，断言代码、合同字段和“账号状态未改变”的透明文案；本地 Python 错误审计／合同测试 25 项通过。完整 iOS CI run `38109505934` 仍在执行，完成后才会提交此批修改，避免取消正在验证的 App ID 限额修复。

## 2026-10-11 — IPA 本地文件失败被笼统写成存储空间不足

**症状**：导入中的应用目录不可访问、复制源 IPA 失败、待提交暂存目录丢失、文件提交失败和暂存文件越界，均缺少失败合同；其中两条文案要求检查存储空间，但捕获边界包含权限、文件系统和事务异常，源码不能证明设备空间已满。

**根因**：`AppFileStore` 在每个文件操作边界保留了用户恢复文案，却没有把已确认的本地存取事实、操作范围和来源交给 UI。旧错误码兜底无法区分“重开 Seal”“重新选择 IPA”和“重新导入”。

**修复**：为 `SEAL-IPA-201/203/212` 标注 `localStorageWriteFailed`，但不标为 `deviceStorageFull`；为 `202/204/211a` 标注 `unexpected`，避免从宽泛 catch 推测根因。分别保留源码已有的 `restartSeal`、`reimportIPA` 或 `retry` 动作，全部限定在 `importIPA / fileStore`。

**验证**：按测试先红后绿新增静态合同测试，覆盖六个出口并断言该文件不产生 `deviceStorageFull`；本地 Python 错误审计／合同测试 26 项通过，`git diff --check` 通过。完整 iOS CI 需在这批改动推送后验证 Swift 编译。

## 2026-10-11 — 已迁移的导入恢复动作仍可能被旧错误码分流覆盖

**症状**：`AppsViewModel.performAlertRecovery` 原先以 `SEAL-IPA-` 前缀决定是否重新打开文件选择器。导入失败增加结构化合同后，如果 UI 仍先看错误码，后续同前缀新错误会再次被强制导入；反之若直接把 `reimportIPA` 视作“知道了”，用户又无法执行源码承诺的“重新选择 IPA”。

**根因**：恢复出口没有先消费 `FailureAction`。`SEAL-IPA-203/212` 的“检查后重试”也没有独立的原地重试事务，唯一真实可执行的下一步是重新选择 IPA 并重新导入。

**修复**：结构化失败优先按合同分流：`.reimportIPA` 直接打开导入器，带 `route` 的失败仅按 `FailureRoute` 跳转，其余合同不再落到错误码前缀猜测；未迁移的历史错误才保留旧兼容分支。`203/212` 的动作改为 `reimportIPA`，但继续保留 `localStorageWriteFailed` 条件，不伪造“设备空间已满”。

**验证**：新增先红后绿的静态回归测试，验证六个 IPA 合同以及结构化 `.reimportIPA` 不依赖错误码前缀即可打开导入器；本地 Python 错误审计／合同测试 27 项通过，`git diff --check` 通过。完整 iOS CI 将在推送后验证。

## 2026-10-11 — 不合格的导入文件缺少可执行的统一出口

**症状**：`SEAL-IPA-207/208/209/210` 分别表示文件类型不支持、压缩包不可读、压缩包内没有唯一 IPA、以及解压失败。旧实现只有文案；UI 只能依赖错误码前缀猜测是否打开导入器。

**根因**：四个失败均发生在 `AppFileStore` 读取用户刚选取的本地文件时，源码没有证据指向 Apple 服务、设备通道或网络，但也没有把“重新选择 IPA”作为合同动作提供给界面。

**修复**：四条出口统一标为 `unexpected → reimportIPA → importIPA / fileStore`，保留各自原始原因和更具体的操作提示（例如先解压再选择具体 IPA），不伪造格式损坏、存储不足或网络故障。

**验证**：扩展本地 IPA 合同回归测试，先红后绿；Python 错误审计／合同测试 27 项通过，生成库存已从 54 个升至 58 个显式合同出口。完整 iOS CI 将在下一次推送后验证。

## 2026-10-11 — 发布安全变异测试引用了已迁移的旧文案

**症状**：完整 iOS CI run `38110171515` 的发布安全校验运行约 8 分钟后失败，报 `Mutation anchor missing`。守卫仍在 `MinimuxerInstallChannel.swift` 中寻找一条已经不存在的“确认 LocalDevVPN 已连接、开发者模式已开启后重试”文案。

**根因**：该旧文案实际位于 `SigningCoordinator.swift` 的历史路径，且已被更准确的设备通道分类替代；变异测试的意图是验证“不能把非通道问题写成检查 LocalDevVPN”，但锚点文件和文本没有随迁移更新，导致守卫先因找不到锚点退出，未验证真正的不变量。

**修复**：变异锚点改为 `MinimuxerInstallChannel` 中确实存在的 `SEAL-INSTALL-702s`（设备存储不足）恢复文案；把它突变为“检查是否打开 LocalDevVPN”时，R83③b 的同源闸门会正确检测 702s 不在本地隧道错误集合。没有恢复旧的误导性文案。

**验证**：已用源码检索确认新锚点唯一存在且替换目标由 R83③b 消费；完整 iOS CI 在推送后将执行全部 836 条源码守卫和 593 条变异检查。

## 2026-10-11 — 导入确认抽屉把“重新选择 IPA”误执行为重试旧事务

**症状**：`SEAL-IPA-217` 在覆盖目标于确认期间被删除或状态变化时，源码要求用户重新选择并确认目标；但 `ImportConfirmationView` 对任何失败都调用 `retryImport()`。这会带着同一个已失效的目标 ID 重试，无法完成用户看到的恢复动作。`SEAL-IPA-205` 也把任意应用记录保存异常写成“检查存储空间”，但 catch 边界没有空间不足判据。

**根因**：导入确认页没有消费 `FailureAction`，错误码／文案与实际执行函数脱节；导入工作流的解析、记录保存和覆盖目标复核出口均未形成完整合同。

**修复**：`200`（IPA 解析）与 `217`（覆盖目标变化）声明为 `unexpected → reimportIPA`；确认抽屉按合同选择动作：`retry` 仅重提当前事务，`reimportIPA` 会先安全取消当前草稿、再打开文件选择器。`205` 声明为 `unexpected → retry`，仅提示“重新尝试导入”，不再臆测空间不足。三条均标记为 `importIPA`，来源未知而不伪造不存在的细粒度原因。

**验证**：新增测试先红后绿，覆盖三个合同和抽屉按 `.retry` / `.reimportIPA` 分流；本地 Python 审计／合同测试 29 项通过。生成库存为 426 个标识、799 次引用、61 个显式合同出口、83 个待迁移出口。完整 iOS CI run `38111046262` 正在验证上一批发布安全修复，结束后再推送本批，避免取消正在运行的完整构建。

## 2026-10-11 — 未分类的 App ID 创建失败混入了未经证实的处理建议

**症状**：`SEAL-APPID-303` 是 Apple Portal 创建 App ID 的最终兜底出口，但旧文案同时要求检查网络、重新验证 Apple ID、修改 Bundle ID 或更换账号。用户会把一条没有可识别原因的错误当成确定的网络或账号故障处理。

**根因**：该出口位于会话过期、Bundle ID 冲突和七天 App ID 限额三个可识别分支之后；源码没有留下进一步判别网络、账户、Bundle ID 或设备通道的证据。旧文案跨越了这些已经排除或未证实的边界。

**修复**：将 `303` 收敛为 `unexpected → waitThenRetry → sign / applePortal`，明确说明不能从该结果推断网络、账号或 Bundle ID 问题；恢复步骤仅保留“稍后重新签名，持续出现则导出日志联系支持”。

**验证**：新增回归测试先红后绿，断言合同字段，并禁止该出口重新出现“检查网络”或“重新验证 Apple ID”的猜测式建议；本地 Python 错误审计／合同测试 30 项通过，`git diff --check` 通过。完整 iOS CI 将在当前构建结束后验证。

## 2026-10-11 — App ID 注册阶段的“会话过期”被错误推导为已确认的服务限流

**症状**：`SEAL-AUTH-107` 收到 Apple 的“会话已过期”后，旧文案将前序证书申请成功推导为“登录状态其实还在”，并称“更常见”原因为多扩展 App 的短时限流。这让用户把尚未证实的限流当作确定原因。

**根因**：该分支唯一可验证事实是 Apple 在 App ID 注册阶段返回会话过期；前序步骤成功不能证明之后的 Apple 会话、服务限流或本地传输状态。旧注释和文案跨越了转换边界。

**修复**：改为 `unexpected → waitThenRetry → sign / applePortal`，文案只陈述 Apple 返回的原始事实：先等待后重新签名；若同一提示持续出现，再到「我的」重新验证 Apple ID。未归因于网络、VPN 或已确认限流。

**验证**：新增测试先红后绿，断言合同字段并禁止“登录状态其实还在”“更常见的原因”再次进入该出口；完整 iOS CI run `38111925127` 正在验证已推送的上一批导入恢复修复。

## 2026-10-11 — 证书阶段的宽泛认证和准备失败把网络／限流推测写成了原因

**症状**：`SEAL-AUTH-102c` 仅因 Apple 返回 `unauthorized`、`authentication`、`session` 或 `forbidden` 等宽泛文本，就将问题描述为“登录失效或 Apple 限流”；`SEAL-CERT-203` 则把最终兜底写成“检查网络”。二者都没有源码判据确认该归因。

**根因**：认证关键字和最终 catch 都只划定了 Apple Portal 的失败转换边界，并未提供凭据、限流、网络或设备存储的可区分证据。旧文案将恢复假设误写成失败事实。

**修复**：`102c` 与 `203` 均迁移为 `unexpected → waitThenRetry → sign / applePortal`，明确告诉用户 Apple 未提供可识别原因；前者仅在同一提示持续出现后再建议重新验证，后者仅建议稍后重签、持续失败导出日志。没有增加 WiFi、VPN、换账号或空间不足等未经证实的动作。

**验证**：针对两个出口新增测试先红后绿，覆盖合同字段并禁止“两个常见成因”“检查网络”“存储空间”等回归；本地 Python 错误审计／合同测试 33 项通过，`git diff --check` 通过。完整 iOS CI run `38111925127` 仍在执行。

## 2026-10-11 — 证书请求连接失败被不当地引导到本地网络设置

**症状**：`SEAL-CERT-205` 由 `NSURLErrorDomain`、超时或“无法连接”文本触发，旧恢复动作是“检查网络后重试”。这把 Apple 请求未完成误写成用户本地网络已被确认有问题，也容易被误解为需要 LocalDevVPN。

**根因**：该转换边界只能观察到 Apple 证书服务请求没有完成，不能从 NSError 文本区分本地 Wi-Fi、DNS/TLS、Apple 服务或账户状态；并且签名门户请求不依赖设备安装通道。

**修复**：迁移为 `unexpected → retry → sign / applePortal`，保留“稍后重新签名”的手动恢复，并明确不据此判断 Wi-Fi、LocalDevVPN 或账号问题；持续失败才导出日志。

**验证**：新增测试先红后绿，断言合同字段且禁止“检查网络”或“打开 LocalDevVPN”重新成为该出口动作；本地 Python 错误审计／合同测试 34 项通过，`git diff --check` 通过。完整 iOS CI run `38111925127` 正在打包 IPA。

## 2026-10-11 — Apple 请求传输中断与 Apple 服务不可用被混为一类

**症状**：认证、账号验证、签名门户和通用失败分类都把 `URLError`／超时一类 Apple 请求未完成提示为“检查网络或梯子”；同时 `FailureClassifier` 还把它标为 `appleServiceUnavailable`，与 HTTP 503 的服务端不可用事实混淆。

**根因**：NSError 的请求传输失败只能证明请求没有完成，无法区分本地网络、DNS/TLS、远端服务或账号；而 HTTP 503 才能确认 Apple 服务暂不可用。旧公共工厂没有自己的事实条件和操作域，调用点只能各自编写猜测式文案。

**修复**：新增 `appleRequestTransportUnavailable`，公共 `networkFailure` 统一输出 `retry → manual → applePortal`；认证与验证调用点标明各自操作，签名门户标记 `sign`。`FailureClassifier` 的网络分支改用新条件，503 分支仍保持 `appleServiceUnavailable → waitThenRetry`。恢复文案仅为“稍后重试”，不再建议梯子、Wi-Fi 或 LocalDevVPN。

**验证**：测试先红后绿，断言新条件、动作、来源并防止“梯子／检查网络”回归；更新 Swift 单元测试对公共合同字段的断言。Python 错误审计／合同测试 35 项通过，`git diff --check` 通过；完整 iOS CI run `38112750896` 正在验证上一批。

## 2026-10-11 — 批量续签的已删除本地记录提示“重新导入”却没有实际导入出口

**症状**：批量续签 `SEAL-RENEW-404` 在本地应用记录已删除时提示“重新导入 IPA 并签名安装”，但没有失败合同；即便迁移为 `reimportIPA`，签名结果抽屉此前也将该动作归为“知道了”并关闭，仍不能执行承诺的恢复。

**根因**：同一队列项会在首轮预取后、自动重试前两次读取本地记录；记录消失后，重试原 UUID 永远不可能恢复。`SigningProgressView` 的语义动作只支持重新签名／重新安装，没有消费 `.reimportIPA`。

**修复**：抽出单一 `missingRenewalRecordFailure`，标注 `unexpected → reimportIPA → batchRenew / unknown`；签名结果抽屉将 `.reimportIPA` 的按钮命名为“重新选择 IPA”，关闭当前结果后打开真实文件选择器，不再重试已删除项目。

**验证**：新增测试先红后绿，断言合同字段和结果抽屉确实调用 `presentImporter()`；本地 Python 错误审计／合同测试 36 项通过，`git diff --check` 通过。完整 iOS CI run `38112750896` 仍在执行，结束后再推送本批。

## 2026-10-11 — R23 发布安全守卫错误截取了默认分支

**症状**：完整 iOS CI 的发布安全校验在 R23 失败，提示 `SEAL-AUTH-102c` 缺少结构化合同和“等待后重新签名”文案；但实际 Swift 源码已包含该分支及合同字段。

**根因**：守卫从 `certificateFailure` 函数开头截取到第一个默认 `return ImportFailure`，得到的是前置网络分支，而非 `unauthorized`／`authentication` 等宽泛认证分支。因此守卫检查和变异检查均没有针对真实的 `SEAL-AUTH-102c` 出口。

**修复**：R23 改为以认证条件为起点、以默认兜底返回为终点，只检查 `SEAL-AUTH-102c` 实际分支；保留“未分类事实、等待后重签、持续出现才验证”的合同，并继续阻止把限流写成已确认原因。

**验证**：基础守卫重新执行为 `837` 项、`0` 失败；两项 R23 变异（直接要求重新登录、声称已确认限流）都被准确拒绝。完整 593 项变异复验将重新运行后再推送。

## 2026-10-11 — Apple 请求传输失败的 Swift 回归仍断言旧服务端状态

**症状**：完整 iOS CI run `38131866585` 的 `swift-regression` 失败 4 项：Apple Portal、单应用签名、批量续签和通用分类的超时测试仍期望 `.appleServiceUnavailable`；另一个测试仍期望旧文案“已签应用不受影响”。

**根因**：`39d774c` 将 `URLError`／超时从可证实的 HTTP 503 服务端不可用中拆出为 `.appleRequestTransportUnavailable`，但四个既有 Swift 测试没有同步。请求未完成也不能证明所有已签应用状态，因此旧文案断言超出了转换边界。

**修复**：四项测试更新为传输未完成条件；Portal 测试改为仅断言“请求未完成、已保存 Apple ID 状态未改变”以及不泄露底层 NSError，而不再断言未证实的已签应用结论。

**验证**：本地错误合同测试将重新执行；完整 iOS CI 用于编译和运行更新后的 Swift 测试。

## 2026-10-11 — 快捷指令续签通知进入后，结果抽屉未出现且已安装列表失去响应

**症状**：快捷指令后台续签完成后，用户点系统通知回到 Seal，结果抽屉有时不出现；此时点已安装应用也没有反应，只有杀掉 Seal 后重新打开才恢复并出现抽屉。

**根因（源码证据）**：`SealNotificationPresenter` 过去只实现 `willPresent`，没有处理 `UNUserNotificationCenterDelegate.didReceive`，所以通知点击没有明确路由。与此同时，启动任务和场景切换会直接调用 `presentSettledBackgroundBatchResultIfNeeded()`；该调用能先将 `isBatchRefreshSheetPresented` 置为真，而 SwiftUI 的 sheet host 在通知冷启动／inactive 阶段尚未可呈现。`AppsRootView.openApp` 看到这个状态后会按互斥策略拒绝应用操作，形成“列表被结果状态锁住、抽屉没有显示”的事务死锁。

**修复**：为后台续签通知添加唯一标识路由与 `didReceive` 回调；根视图把通知／启动／回到前台统一为待呈现请求，只在 root host 已挂载且 `scenePhase == .active` 后的下一主循环恢复结果抽屉。已安装列表发现已结算结果时只排队呈现，不再直接写 sheet 状态；批量结果仍保持对应用操作抽屉的独占优先级。

**回归保护**：新增通知标识路由测试；新增三态呈现策略测试，覆盖「请求存在 + host 就绪 + active 才能写呈现状态」，阻止 inactive 或 host 未挂载时再次锁住列表。

**验证状态**：Windows 主机没有 Swift/Xcode 工具链；已完成静态检查和 Python 合同测试，等待下一轮完整 iOS CI 编译及 Swift 测试。真机验收：快捷指令成功通知→点通知→结果抽屉一次出现；关闭后已安装列表可立即打开应用操作，不需杀后台。

## 2026-10-11 — 完整 iOS CI `38139124010` 的两项可复现构建失败

**现象**：`signer-tests` 已通过，但完整 CI 的 `build-package` 被 R56 安全守卫拒绝；`swift-regression` 在 `ProfileOnlyRenewalPolicyTests.swift:97` 因 `Date?` 传给 `Date` 编译失败。

**根因**：R56 仍保留“不得测试 SideSign”的过时假设，和当前已新增、且通过的 SideSign 签名边界测试相冲突；新测试夹具的 `AppRecord.expiryDate` 是可选值，传给要求非可选日期的辅助构造器前未作测试前提校验。

**修复**：R56 更新为同时要求 `Vendor/CodeSignKit` 与 Seal 实际使用的 `Vendor/SideSign` 签名边界回归门，仍明确禁止已删除的 `Vendor/rork-sign`；测试改用 `try #require(app.expiryDate)`，将夹具不变量写成明确测试失败而非 Swift 编译错误。

**验证状态**：下一轮完整 iOS CI 将重新验证发布守卫、Swift 编译与测试；不会检查或触发 Fast IPA。

## 2026-10-11 — CI `38140406484` 的通知路由测试隔离与错误编号清单漂移

**现象**：完整 CI 的签名内核门和 R56 发布安全守卫已通过，但 `swift-regression` 在新通知路由测试中报 `BackgroundRenewalNotifier.identifier` 是 MainActor 隔离属性；`build-package` 的错误编号审计则因源码行号变化拒绝未更新的生成清单。

**根因**：`BackgroundRenewalNotifier` 是 `@MainActor` 类型，测试中的纯路由断言不应读取它的静态成员；错误编号清单是受版本控制的生成物，前序源码插入改变了记录位置，生成结果必须同步更新。

**修复**：将通知标识的唯一来源移到非隔离的 `BackgroundRenewalNotificationRoute`，notifier 继续复用该值；重新生成 `docs/qa/generated/error-code-inventory.json`。

**验证**：错误编号清单测试 11 项、错误合同测试 25 项及差异检查通过；下一轮完整 iOS CI 负责验证 Swift 编译与完整包。

## 2026-10-11 — LiveContainer 相同 App Group 集合的重复绑定仍可能让签名边界漂移

**症状**：LiveContainer 主包与 LiveContainer2 的 App Group 集合相同而原始顺序相反时，运行时若把第 0 项当共享目录，会分别落到不同容器。此前重建 LC2 的 Apple App ID 能改变当时的门户绑定顺序，但不能保证后续重签、续签或另一份带重复 group 的 IPA 保持同一输入。

**根因**：现有修复已经在门户绑定、Info.plist 元数据和 SideSign 二进制 entitlement 三处按字母排序；但 Seal 门户边界仍把重复的原始 App Group 值直接交给 `assign`，而预期 entitlement / 元数据 / 诊断各自实现排序。重复项可能生成重复的 Apple 绑定输入，并让三处规范化规则再次漂移。

**修复**：新增单一 `AppGroupOrderingPolicy`，以「去重后稳定字典序」作为 Seal 所有门户边界的唯一规范化规则。它用于请求 entitlement、Apple 绑定输入、写入 `ALTAppGroups` 和诊断读取；SideSign 仍在最终二进制写入前独立做同一规范化，因而既能修复既有 App ID 绑定顺序不可靠的问题，也能保证最终安装包的 entitlement 顺序。

**验证**：新增 LiveContainer 主包／LC2 反向顺序与重复绑定输入两项纯函数回归测试；本机错误编号审计 11 项、错误合同 25 项和 `git diff --check` 通过。Windows 主机无 Swift/Xcode 工具链，完整 iOS CI 负责 Swift 编译、签名内核与回归测试。

## 2026-10-12 — 扩展准备失败把未知 Apple 返回伪装成 7 天窗口，并给出相反的“移除扩展”动作

**症状**：扩展 App ID 或描述文件准备失败时，`SEAL-EXT-401`／`SEAL-EXT-401a` 不论 Apple 实际返回什么，都会说“等待 7 天窗口、不要移除扩展”；旧版签名结果抽屉还曾对 `401` 显示“移除扩展并重试”。这既可能把未知错误误说成 App ID 限额，也让用户在同一页面收到相反指引。

**根因**：扩展分支绕开了 `ApplePortalSigningFailure.make` 的统一事实分类，自行制造了两个没有结构化语义的错误码；UI 又按其中一个旧错误码触发会改变 IPA 功能集的降级重试。

**修复**：扩展 App ID／描述文件失败现在与主 App 走同一门户分类：仅在 Apple 明确给出限额、限流或传输事实时展示该事实；未识别失败为 `unexpected → waitThenRetry → sign / applePortal`。删除旧码、矛盾按钮和无入口的“去扩展重试”方法；本轮失败始终保留原 IPA 的全部扩展。

**验证**：新增回归测试先红后绿，覆盖两条扩展边界、描述文件合同字段、旧码／旧动作及用户文档的移除；错误编号清单重新生成，合同增量测试与编号清单测试 12 项通过，`git diff --check` 通过。完整 iOS CI 将负责 Swift 编译与回归测试。

## 2026-10-12 — 部分手动操作在事务闸门超时后静默结束

**症状**：导入 IPA、确认覆盖更新、重试导入、从本地签名包重新安装、删除应用在其他签名／续签／证书操作占用全局事务闸门超过 30 秒后直接返回。用户只看到点击没有结果；批量续签和单项签名已对同一情况给出可见反馈，行为不一致。

**根因**：这些入口调用 `acquireOperation` 后将空租约直接转换为 `return`／`false`，没有消费 `OperationCoordinator.conflictFailure`。后台去重清理复用删除方法，因此不能简单地对所有调用弹窗。

**修复**：为 AppsViewModel 添加统一冲突失败工厂。导入文件、安装本地签名包和前台删除会写入全局提示；导入确认／重试会保留导入抽屉并显示失败；后台去重仍静默跳过，不会抢占前台界面。所有路径继续保留单飞闸门，不会改成并发执行。

**验证**：新增回归测试先红后绿，断言五个手动入口都消费统一冲突失败，而后台删除不走前台提示；完整 iOS CI 将验证 Swift 编译和现有事务测试。

## 2026-10-12 — 旧的“已移除扩展”记录会授权后续续签继续删扩展

**症状**：某条历史记录只要保存过 `removedExtensionBundleIdentifiers`，旧版后续签名或续签即使没有任何“移除扩展”确认，仍会把删除扩展开关设为真；新的扩展准备失败可能再次被当作可丢弃处理。

**根因**：AppsViewModel 把“以前发生过降级”的历史状态与“本轮用户授权降级”混为同一个布尔值。旧记录只是描述当前安装产物，并不构成本轮改变产品功能的授权。

**修复**：删除历史状态对本轮删扩展行为的隐式提升，并彻底删除删扩展 API 与门户实现。旧记录若无法完整重签会如实失败，而不会继续静默删减功能。

**验证**：扩展失败合同回归测试先红后绿，新增断言防止 `removedExtensionBundleIdentifiers` 再次变成自动降级开关；与事务闸门增量测试共同通过。

## 2026-10-12 — 设置中的手动操作在事务闸门超时后会像“没有点到”

**症状**：在签名、续签、安装等操作持续占用全局事务闸门超过 30 秒时，用户从“我的”页手动创建／撤销／清理／重置证书，添加／删除 Apple ID，导入或启动设备配对，或清理存储，部分入口会直接返回。没有提示，容易重复点击或误以为数据已经修改。

**根因**：这些设置入口虽然已接入 `OperationCoordinator.beginWaiting`，但取得空租约后将其直接转换成 `return`、`false` 或 `nil`；与已修复的应用页导入、安装和删除路径不一致。自动接收配对助手 Inbox 是后台维护，不应反过来抢占或打断前台，需保留静默让位。

**修复**：SettingsViewModel 统一消费 `OperationCoordinator.conflictFailure`。十五个前台入口在等待超时后都显示“暂时无法执行／等待当前操作完成后重试”；启动手机配对同时写入失败状态，避免配对界面停留在不准确的等待状态。后台 Inbox 自动导入仍静默跳过，下一次加载再试。

**验证**：新增静态回归测试，逐一锁定证书、账号、配对、存储的十五个前台入口及其对应操作类型；测试先红后绿。后续完整 iOS CI 负责 Swift 编译、UI 回归与安装包构建。

## 2026-10-12 — 编辑应用资料可与签名完成写回互相覆盖

**症状**：用户在签名或续签仍在执行时，修改 Bundle ID、显示名或图标会直接以抽屉打开时的旧 `AppRecord` 保存；签名完成也会保存自己的完整记录。两次写入没有共同事务边界，最后到达的写入可能覆盖另一方的字段。

**根因**：三项“编辑应用资料”入口没有申请 `OperationCoordinator` 租约，而签名完成会写回同一条 `AppRecord`。此前导入、安装、删除受单飞闸门保护，资料编辑却形成旁路。

**修复**：新增 `updatingApp` 操作类型，三个编辑入口均按应用 ID 取得租约；等待超时后显示已有操作的准确提示，不再保存旧快照。签名、导入、安装和批量续签均与它互斥。

**验证**：新增回归测试先红后绿，逐一断言 Bundle ID、显示名与图标编辑均获取 `updatingApp` 租约并消费冲突提示。完整 iOS CI 将负责 Swift 编译、UI 回归与安装包构建。

## 2026-10-15 — Apple ID 登录 503：从本机 ADI 规则迁移到 SideInstaller RemoteV3

- **现象**：构建 16 真机日志中，添加账号在密码和验证码之前立即记录 `SEAL-NET-503`。
- **根因**：前版只对齐了 GrandSlam 的请求格式，却保留 Seal 的「认证强制本机 AnisetteKit ADI」规则；而用户提供的 SideInstaller 默认使用 RemoteV3。Seal 因而没有执行参考实现最关键的凭证来源，Apple 在 SRP 前拒绝该身份。
- **修复**：认证、验证码、认证后校验和门户请求统一改为 RemoteV3；优先使用 SideInstaller 默认 `ani.jkcoxson.com`，并把远程 provisioning 状态置于独立钥匙串 service，保留旧本机 ADI 和稳定 identifier。
- **验收**：CI 必须通过；真机添加 Apple ID 应从即时 503 进入密码/双重认证流程，随后完成团队验证和一次签名。

## 2026-10-17 — 签名预检、Apple App ID 额度取证与设置文案

- **症状**：设备通道可能在 Apple 侧签名准备之后才暴露不可用；用户看到有效 App ID 数量少于 10，却仍被 Apple 拒绝注册；支持及协议页面还有重复/不准确的说明。
- **根因**：签名时只并行启动设备通道，门户准备阶段没有等待通道就绪；App ID 当前列表数与 Apple 返回的滑动注册额度不是同一指标；隐私文案将本地数据与网络服务边界混为一谈，并将卸载描述成可保证清除钥匙串数据。
- **修复**：签名在创建证书、App ID 和描述文件前等待设备通道就绪；保留并展示 Apple 同次响应的 `availableQuantity`，Apple 拒绝创建后绕缓存强制刷新并记录原始额度；更新隐私/用户协议和支持文案，修正钥匙串卸载说明与协议生效日期，将协议版本升至 2；协议卡片使用实色表面。
- **验证**：新增库存额度保留及旧缓存兼容测试；`git diff --check` 通过。Windows 环境无法编译 Swift，最终编译与测试需由 iOS 云 CI 验证；Apple 实际额度和签名结果仍需真机账号测试。

## 2026-10-17 — Seal 版本序列重置为 0.1.x

- **需求**：正式展示版本从 `0.1.0` 起，后续迭代按 `0.1.1`、`0.1.2` 递增；协议版本维持 1；Seal 页面不展示 CI 构建号。
- **改动**：主 App 与 Live Activity target 的 `MARKETING_VERSION` 同步为 `0.1.0`；About、设置和 Seal 应用行只显示营销版本；版本规则写入 `AGENTS.md`。导入当前运行的 Seal 时，仅在 CI 构建号更高的情况下允许从旧 `1.x` 迁移到 `0.1.0`，普通 IPA 的降级规则不变。
- **验证**：新增对旧 `1.0.0` 与 `1.3.x` Seal 记录迁移的导入回归用例；协议门禁版本保持 1。`git diff --check` 通过；Swift 编译和测试待 iOS 云 CI。

## 2026-10-17 — 「+」导入 Seal 更新后自动进入签名

- **现象**：关于页下载的 Seal 更新会自动打开签名抽屉，但通过「+」导入同一 Seal 更新包后只留在待安装列表，需要用户再手动找到更新。
- **根因**：自动打开签名抽屉只由关于页下载入口传入的临时标记控制，没有根据已识别的 Seal 自身更新记录统一处理。
- **修复**：导入完成时，Seal 自身更新与关于页下载更新都会选中对应待安装记录并打开同一签名抽屉；普通已安装 IPA 更新逻辑不变。版本推进到 `0.1.1`。
- **验证**：`git diff --check` 通过；Windows 环境无法编译 Swift，云 CI 负责编译验证。

## 2026-10-15 — Apple ID 登录仍 503：SRP 请求缺 X-Apple-App-Info / X-Xcode-Version

- **现象**：迁移到 RemoteV3 之后，真机添加账号仍在密码与验证码之前立即记录 `SEAL-NET-503`。
- **REA 证据**：对用户提供的 `sideinstaller-v1.5.1` 二进制做静态字符串分析，`vendor/isideload/src/anisette/remote_v3/mod.rs` 相邻的 `base_headers` 常量块依次为 `<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>` / `X-Mme-Client-Info` / `Content-Type` / `Accept` / `User-Agent` / `14.2 (14C18)` / `X-Xcode-Version` / `com.apple.gs.xcode.auth` / `X-Apple-App-Info`，即 `X-Xcode-Version: 14.2 (14C18)` 与 `X-Apple-App-Info: com.apple.gs.xcode.auth` 出现在**每一个** `GsService2` 请求上（`init`、`complete`、`apptokens`、2FA）。同一二进制的默认服务器字符串为 `DEFAULT_ANISETTE_V3_URL = "https://ani.stikstore.app"`。
- **根因**：Seal 的 `sendAuthenticationRequest`（SRP `init` / `complete`）只带 `Content-Type` / `X-MMe-Client-Info` / `Accept` / `User-Agent` / `Connection: close`，**缺失** `X-Xcode-Version` 与 `X-Apple-App-Info`；同时默认服务器仍为 `ani.jkcoxson.com`，其 `/v3/client_info` 返回 Windows/iTunes 身份 `<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>`，与固定的 `X-Apple-App-Info: com.apple.gs.xcode.auth` 不属于同一个应用，指纹自相矛盾 ⇒ Apple 在密码校验前回 HTML 503。
- **修复**：① `ALTAppleAPI+Authentication.swift` 的 `sendAuthenticationRequest` 补上 `X-Xcode-Version`（`14.2 (14C18)`）与 `X-Apple-App-Info`（`com.apple.gs.xcode.auth`），复用文件中已有常量；② `AnisetteServerCatalog.official` 首位改为 `https://ani.stikstore.app`（返回 macOS/Xcode 身份 `<MacBookPro13,2> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>`，与 Xcode 指纹自洽），`ani.jkcoxson.com` 降为末尾兜底。
- **验收**：CI 必须通过；真机添加 Apple ID 应从即时 503 进入密码/双重认证流程，随后完成团队验证和一次签名。

## 2026-10-17 — CI 125：泛型标签组件的静态存储属性导致 Swift 编译失败

**现象**：CI 125 的 `swift-regression` 在 `CaterpillarSegmentedTabs.swift` 编译失败，错误为“static stored properties not supported in generic types”；同时错误编号清单因本轮 UI 文件行号变化未同步而使 `build-package` 失败。

**根因**：`CaterpillarSegmentedTabs<Item>` 是泛型 SwiftUI 视图，却声明了静态存储属性 `labelSpacing`。Swift 不允许泛型类型持有静态存储属性。错误编号清单是版本控制的生成物，源码位置变化后必须重新生成。

**修复**：将 `labelSpacing` 改为等值实例常量，保留原有标签几何；重新生成 `docs/qa/generated/error-code-inventory.json`。

**验证状态**：Windows 主机无法编译 Swift；已完成错误编号清单生成与差异检查，下一轮 iOS CI 负责 Swift 编译、回归测试及打包。

## 2026-10-19 14:13:28 — 修复 CI #55 编译错误与过期守卫变异锚点

- **现象**：Swift 回归构建因 `String?` 未解包失败；发布守卫的扩展拓扑、导入覆盖更新锚点和续签错误文案前缀与当前源码不一致，导致变异测试失败。
- **修复**：在 `ProfileOnlyRenewalPolicy.swift` 显式绑定非空证书序列号；在 `verify-release-safety.py` 将扩展共享检查限定到 IPA 拓扑解析段，更新导入策略锚点与 R82/R84 预期文案前缀。应用签名和续签行为没有改变。版本推进到 `0.1.32`。
- **验证**：仅运行本次修改相关的 Swift 源码/守卫锚点定向检查，全部通过；`python -m py_compile Scripts/verify-release-safety.py` 和 `git diff --check` 通过。Windows 无 Xcode/iOS SDK，Swift 编译由下一次 macOS CI 验证。
- **修改路径**：`Seal/Core/Renewal/ProfileOnlyRenewalPolicy.swift`、`Scripts/verify-release-safety.py`、`project.yml`、`RELEASE_NOTES.md`、`DEBUG_LOG.md`。
