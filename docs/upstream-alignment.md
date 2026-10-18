# 上游对齐（Seal 是二开，必须跟上游）

- 建立：2026-09-19
- 依据：`AGENTS.md` 第 1 节「改动前自查清单」**第 5 条** ——
  「上游是否已有 —— Seal/AltStore/SideStore/jas/zsign 已有等价实现则**优先对齐/复用**，不自造轮子」
- 起因：用户指出「**seal 就是二开上游的，当然需要上游已经实现的方法**」✓

---

## 一、上游是谁（用户 2026-09-19 明确）

**上游 = AltStore + SideStore** ✓

两者的关系：**SideStore 是 AltStore 的 fork**，官方描述是
> *"SideStore is a fork of AltStore that doesn't require an AltServer."*（AGPL-3.0，6.5k stars）

**⇒ 这句话和 Seal 的定位一字不差** ✓（设备内签名 + LocalDevVPN，不需要电脑）
⇒ **SideStore 是更近的上游**，它的做法比 AltStore 更有参考价值 ✓

### 补充：另外两类「上游」

| 上游 | 关系 | 处置 |
|---|---|---|
| **`rileytestut/AltSign`** | **SwiftPM 依赖**（`ALTAppleAPI` / `ALTTeam` / `ALTCertificate`） | 跟版本号 + 对照**用法** ✓（Seal 实际用的是 `SideStore/AltSign`，见第三节） |

---

## 二、为什么不能靠 `git merge upstream`

Seal 的 git 历史**被重建过** ✗：全部 659 个提交都是同一个作者（`Seal Developer`），
**历史里没有上游的任何提交** ⇒ 与上游**没有共同祖先** ⇒ `git merge` / `git rebase` **不可用** ✗。

⇒ **只能做「语义对照」**：把上游的关键文件拉下来读，
对照的是**做法**而不是文本（语言/结构/框架都不同，文本 diff 没有意义 ✗）。

---

## 三、依赖层的上游（`project.yml` 指向的用户 fork，均为**未改动镜像** ✓）

| Seal 的依赖 | 用户 fork | **真正的上游** | 版本 |
|---|---|---|---|
| `AltSign`（`project.yml:17`） | `sunuannian1/AltSign` | **`SideStore/AltSign`** | `35b68f1a…`（2026-08-26） |
| `AnisetteKit`（`project.yml:20`） | `sunuannian1/AnisetteKit` | **`mahee96/AnisetteKit`** | `db8b4102…`（2026-09-18） |

### 🔴 `AnisetteKit` 的接口契约（2026-09-19 实测）

```swift
public protocol AnisetteDataProvider: Sendable {
    func getAnisetteHeaders(libDir:provisioningDir:identifier:adiPb:) throws -> AnisetteDataResponse
}
```

**⇒ 「调一次产生一份新 headers」，库里没有任何会话/缓存概念** ✓
⇒ **⇒ 把 anisette 存进会话复用**就是**调用方的错** ✗（1100 根因最硬的证据 ✓）。

⚠️ **注意**：Seal 的 `Seal/Infrastructure/Accounts/AnisetteClient.swift` 与
`AnisetteDataProvider.swift` **与上游同名但角色不同** ✗ ——
Seal 的是**自己的 wrapper**（`struct AnisetteV3Client: AnisetteEnvironmentManaging`），
上游的是**库本身** ⇒ **同名不代表同角色，别按名字配对** ✓。

---

## 四、对照台账（**改签名/续签链路前先查这里**）

> 规矩：**对照过就记一条** —— 免得同一个问题重复查 ✓。
> 结论分两种：**「跟」（上游更对 ✓）** 与 **「不跟」（Seal 已更好 / 上游没有 ✓）**。

| 日期 | 对照对象 | Seal 侧 | 上游做法 | 结论 |
|---|---|---|---|---|
| **2026-10-18** | **新签名 Bundle ID 默认值与已安装身份复用** | Seal 原先由 mapper 隐式改写输入值，并追加 `.seal.<TeamID>`；签名面板显示值不一定等于最终签名值，恢复扫描还依赖 Seal 自己的格式 | SideStore 的 `appendTeamID` 选项会在新签名默认 ID 后追加 `.<TeamID>`；同 Team 已安装 App 复用持久化的 `resignedBundleIdentifier`，扩展继承主 ID 并保留原后缀。AltStore 同样优先复用同 Team 的已保存 ID | **跟身份可见与续签复用原则**：新导入的签名面板显示 `原 Bundle ID.<TeamID>`，用户可编辑；mapper 只使用输入框实际值，不再暗中改写或追加 `.seal`。本地只拦空值和 Apple 文档明确不支持的字符，反向域名样式交给用户，注册是否成功由 Apple 裁定。覆盖更新/续签沿用已记录身份，扩展沿用主 ID。恢复只剥离与可信 Team 完全匹配的 Team 后缀或历史 `.seal.<TeamID>`，其余格式保留；扩展关系交由设备安装查询，不按前缀推断。 |
| **2026-10-16** | **SideInstaller 当前 Anisette `client_info` 归一化** | Seal 会把旧 Mac/Xcode 或 Android 声明身份当作不可用服务器跳过，缩小可用服务集合 | SideInstaller/isideload 的 `client_info_to_use` 将这类旧身份统一替换为 Windows iTunes 身份，并让 provisioning、登录和后续认证共用该有效身份 | **跟**：Seal 按同一规则归一化身份和 User-Agent，再将归一化结果写进 ADI 身份戳；不替换 Rust 登录模块，不清 identifier 或既有账号会话。2026-10-16 对 `ani.jkcoxson.com`、`ani.sidestore.io`、`ani2.stikstore.app` 的 `/v3/client_info` 连通性均为 HTTP 200。 |
| **2026-10-16** | **扩展描述文件与 App ID 名额** | 原策略将所有含扩展 IPA 默认独立，浪费 App ID 名额 | SideStore 按 target 分别准备身份，优先保证运行时扩展完整性 | **按扩展分配**：普通应用（含 Seal）的扩展默认共享主描述文件；确实不兼容时单独申请并报告原因。LiveContainer 按其独立扩展方案默认单独申请。签名日志列出每个不兼容扩展与本次所需 App ID 数，门户写入前按 Apple 返回的可用名额预检。 |
| **2026-10-19** | **扩展权限读取与共享决策** | Seal 的共享判断曾只比权限键，AltSign 与 SideSign 的实际签名读取又可能把解析失败降成空权限 | SideStore 为目标分别准备 profile；上游没有可直接套用的“任意多个扩展一定共用主 profile”保证。SideSign 的签名准备需要真实目标权限参与 profile 匹配 | **按目标能力混合分配**：比较权限键和值以及映射后的 App Groups；仅不能由主 profile 授权的目标独立申请。Portal 预检与 SideSign 实际 Mach-O entitlement 读取都在解析失败时抛错，不以空权限继续签名。目标拓扑与权限真机验收仍待 CI/设备验证。 |
| **2026-10-17** | **SideStore 证书名额满后的撤销交互** | Seal 原来在签名失败后由一个确认动作自动撤销账号下所有本机无私钥的证书；用户看不到逐张影响，也可能一次撤多张 | `CertificateProvisioningFlow.replaceCertificate` 只筛 iOS Development 证书，调用 `resolveRevocation` 让用户选择要撤的证书；用户选择后才逐张撤销并继续申请新证书 | **跟交互与单张撤销**：失败抽屉打开逐张选择器，显示到期时间、Team ID 和本机可确认影响；二次确认后重拉 Apple 清单，只撤用户所选且仍满足条件的一张，再重试签名。所有运行中 Seal 的真实签名目标都从候选中排除；受影响应用按已有 `CertificateRevocationImpact` 判据恢复。 |
| **2026-10-15** | **SideInstaller / isideload 客户端身份来源** | Seal 曾把服务器 `/v3/client_info` 返回的身份原样当 `X-Mme-Client-Info`（默认服务器返回 Xcode 身份 ⇒ SRP 前 HTML 503）；随后改成「按桌面/非 Xcode 过滤」，又因设备上的 ADI 仍是旧身份建的而收到 `-80045` | REA 主二进制 + 逐台实测其内置目录 15 台服务器：二进制里只有一条非 Android 身份字面量 `<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>`，其中 8 台服务器返回被边缘拒掉的 Xcode 身份而它仍能登录 ⇒ 身份不取服务器返回值 | **跟身份单一事实来源**：固定声明该 macOS/akd 身份，服务器只提供 `user_agent`；ADI 状态带身份戳，不匹配即作废并重新 provisioning。身份与服务器解耦后，多台兜底列表可安全保留，stikstore 这类 Xcode 身份服务器也不再是必失败。 |
| **2026-10-15** | **AltSign 原生子模块锁定** | Seal 已把 AltSign 切为本地 SwiftPM path，但嵌入源码树不含 `ldid`、`minizip-ng` 两个 Git 子模块；ldid 还锁定了 `libplist` 子模块，未初始化时 CI 找不到 `plist/plist.h` | AltSign 的 `NativeBridge` 直接包含其 `.gitmodules` 中锁定的 ldid/minizip-ng 代码，ldid 再以 Gitlink 锁定 libplist | **跟完整锁定树**：所有 iOS 构建工作流先拉取 AltSign 记录的两个精确提交，再初始化 ldid 的递归子模块后解析本地 SwiftPM 包；不拉取浮动最新版。 |
| **2026-10-14** | **SideInstaller / isideload App ID 名额预检** | Seal 只读取 `appIds`，丢弃 Apple 同一回复的 `availableQuantity`。因此日志可见“当前存活 8 个”，却不知道 Apple 当前只允许新建 0 个；多扩展应用会按目标逐个创建，额度不足时可能留下部分新建的 App ID | SideInstaller 的 `list_app_ids` 解析 `maxQuantity` / `availableQuantity`；只有 Apple 返回非负可用数且不足时，才在任何 `add_app_id` 前停止；字段缺失或负数时仍让 Apple 最终裁决 | **跟**：AltSign 返回 App ID 清单及 Apple 配额，Seal 在创建前比较本次真实新增数量和 `availableQuantity`，不足时零写入结束；保留原有 Apple 错误兜底。 |
| **2026-10-14** | **AltSign 构建来源一致性** | `upstream/AltSign/**` 触发 CI，但 Seal 的 SwiftPM 包仍锁定远程 revision，仓库内认证修复不会参与编译 | SwiftPM 本地 path 依赖会把受版本控制的当前源码直接交给 Xcode 构建 | **跟本地源码构建原则**：AltSign 改为 `path: upstream/AltSign`，CI 的触发路径和实际编译输入一致。 |
| **2026-10-15** | **SideInstaller / isideload 双重认证端点契约** | Seal 曾混入 Xcode/BuddyML 与 plist 手机验证码格式，导致部分账号在输入回调前报 `-22411` | isideload 使用同一 Android `akd` 请求身份；可信设备为 XML plist，手机验证码为 JSON，路径为 `PUT /auth/verify/phone` 与 `POST /auth/verify/phone/securitycode` | **跟**：所有认证请求使用同一 `akd` 身份；可信设备保持 XML plist，手机验证码为 JSON `PUT`/`POST`，并保留 `hsc=409` 时直接显示输入。 |
| **2026-10-15** | **SideInstaller / isideload Android ADI 认证身份** | Seal 曾把不同项目的 Pixel 8 / Apple Music 与 Xcode 身份混进本地 Android ADI 流程，真机构建 15 在密码验证前连续收到 HTML 503 | SideInstaller/isideload 的可工作组合是 Pixel 7 / Android 14 `com.apple.akd/1.0` 与 `akd/1.0 CFNetwork/808.1.4`；所有认证请求关闭空闲连接复用 | **跟**：本地 ADI、GrandSlam 和验证码端点统一到此组合；每次认证请求走新连接；不主动清除 `adi.pb` 或设备标识，只有 Apple 明确 `Device not provisioned` 时重新 provision。 |
| **2026-10-14** | **SideInstaller / isideload GrandSlam 连接生命周期** | `ALTAppleAPI` 用一个长期 ephemeral `URLSession` 发送所有 GrandSlam `init` / `complete` 请求，仍会复用该 session 的空闲连接 | SideInstaller 依赖的 isideload 在 `GrandSlam::build_reqwest_client` 中设置 `pool_max_idle_per_host(0)`，注释明确为每个请求使用新连接，以规避 GSA 在复用连接上返回认证失败 | **跟连接隔离原则**：仅认证请求改用每请求一个短生命周期 `URLSession`，完成即 `finishTasksAndInvalidate()`；不改 `client_info`、不更换本地 Anisette 策略。 |
| **2026-10-14** | **SideInstaller / isideload 429 重试** | Seal 已把 Apple 的临时拒绝归类为可恢复错误并提示用户等待后手动重试 | SideInstaller 对部分 GrandSlam 请求自动等待 2 秒、5 秒后重发 | **不跟**：账号刚被拒绝后自动连续重登会放大 Apple 限流；保留一次操作一次请求的行为。该差异不参与 `-80045` 的身份校验。 |
| **2026-10-14** | **SideInstaller / isideload URL Bag** | Seal 仅使用已验证的 GrandSlam 和认证固定端点，失败发生在初始 GrandSlam 登录之前 | SideInstaller 先以 Mac 身份读取 URL Bag，再取得部分认证 URL | **不跟**：当前请求端点明确且初始登录早于 URL Bag 所覆盖的步骤；引入动态端点会扩大认证面，不能解决本次 `-80045`。 |
| **2026-10-14** | **GrandSlam `-80045` 的 Anisette resync 字段** | Seal 已能对 `-80045` 取出状态字典，但最初误把 `X-Apple-I-MD-DATA` 当作 `Status` 的字段，因而拿不到 Apple 要求同步的 SIM，自动重试未触发 | GrandSlam 协议参考将 `X-Apple-I-MD-DATA` 列为认证 `Response` 的同级 resync 字段；SideStore 当前故障报告也表明这轮 Apple 登录变化并非单一 Apple ID 状态 | **跟协议字段层级**：从 `Response` 取 SIM、保留 `Status` 回退；SIM 本身是同步指令，不能只依赖部分响应存在的 `hsc=434`。不改 client info 身份、不清 adi.pb 或标识。 |
| **2026-10-12** | **LiveProcess 运行时注册（LC2 多任务）** | 已验证 IPA 含 `LiveProcess` 并不足以代表系统已注册该扩展：普通扩展包默认共享主 profile，旧记录还可 profile-only 延续此拓扑 | SideStore 的签名目标按 bundle 分别准备并保留；没有“扩展能力被主包覆盖即可共用描述文件”的运行时注册假设 | **跟其逐 target 完整性原则**：任何原始 `.appex` 默认独立 App ID/profile，Group 按 target 绑定；旧共享或无策略记录不走 profile-only，先完整重签迁移一次。 |
| **2026-10-12** | **扩展 / App Group 完整性（LiveProcess）** | 共享 profile 判据只看门户可提交 feature，未映射的 `increased-memory-limit` 被忽略，LiveProcess 错用主 profile；遗留失败分支可删除 `.appex` 后继续安装，profile-only 无法修复已删二进制 | SideStore 保留所有签名目标，不以删扩展换取表面成功；公开 feature API 同样不能表达全部原始 entitlement | **跟其保留目标原则，Seal 自有拓扑判据**：原始非 signer-managed entitlement 决定 shared / independent profile，门户仍只提交支持 feature。删除移除扩展能力，任何扩展 App ID/profile 失败不产出 IPA，签后校验完整 bundle 集；历史缺扩展记录强制完整重签。 |
| **2026-10-12** | **导入 Seal IPA 的覆盖安装结算** | 导入 Seal 更新会新建一条带 `replacesInstalledAppID` 的记录；新进程已确认候选身份时，`SelfAppRegistrar` 却只把运行身份写回旧记录，且用普通 `save` 留下新记录的替换标记。该标记是待签名页的可见性边界，因此用户每次点签名都会回到待签名 | AltStore / SideStore 的自更新由各自的 update/install operation 收束，未找到可直接复用的、同时维护 Seal 本地双记录与自替换事务的实现 | **不跟（上游没有同一持久化模型）⇒ Seal 自有事务修复**：只在新进程已确认候选安装的 `.settle` 分支，选择指向旧 Seal 的导入替换记录，以 `commitInstalledReplacement` 原子删除旧记录、清空替换标记并保存真实运行身份；安装未确认路径完全不动。 |
| **2026-10-10** | **签名／续签原始异常的失败语义** | 单次签名与批量续签分别把未包装异常压成 `SEAL-SIGN-500`／`SEAL-RENEW-500`；Apple 超时被用户看成“未知错误”，日志也无法稳定关联到同一次失败 | AltStore / SideStore 的操作层直接抛底层错误给各自 UI；未发现可复用的、跨签名入口的语义失败合同 | **不跟（上游没有）⇒ Seal 自有边界**：新增 `FailureClassifier`，只对已确认的 Apple 限流／网络错误赋予动作；已有 `ImportFailure` 原样透传，未知错误保持“未确认 + 复制诊断”。单签与批量续签都通过同一分类器；诊断使用关联 ID、邮箱和请求 URL 脱敏。 |
| **2026-10-10** | **App Group 数组确定性排序**（LiveContainer 主包/LC2 共享目录不一致） | Seal 把原包 group ID 映射成 `*.seal.<TeamID>` 后，两包 `com.apple.security.application-groups` 集合相同但顺序相反（主包 [SideStore, AltStore]、LC2 [AltStore, SideStore]）；LiveContainer 取第 0 个当共享目录 ⇒ 各写各读。第一轮修法（`assignAppGroups` 内排序 + Info.plist 落盘排序）真机无效：重签时 App ID「能力已满足」跳过更新，且 Apple 的 `assignApplicationGroupToAppId.action` 不重排已有绑定；实测还证实 LiveContainer 读的是**二进制 entitlements** 而非 Info.plist | AltStore/SideStore 没有 Seal 式 group ID 映射（它们的 App Group 即原包 ID），`CodeSignerAPI.prepare` 原样用 profile 顺序，无排序概念 | **不跟（上游没有）⇒ Seal 自有**：上游签名器 `AppBundleSigner.prepare` 在序列化写二进制前对 app-groups 按字母排序（`upstream/SideSign/.../CodeSignerAPI.swift` 内注记），不依赖 Apple 侧顺序；安全依据是 iOS 与 Seal 自检（`permits`）均按集合校验、顺序无语义。`assignAppGroups`/Info.plist 两处排序保留以保三处一致。 |
| **2026-10-03** | **签名/续签再提速三件套**（用户需求「速度特别快」） | ① 批量续签逐 App 重拉 `fetchTeams`/`ensureDevice`/`fetchAppIDs`（3 App=9 次冗余 RTT）；② `CodeSignKit` 全仓 `import Crypto`（swift-crypto 纯 Swift SHA-256，无硬件加速）；③ 快捷指令后台轮每轮**全量**续签所有已安装应用 | ① SideStore `FetchProvisioningProfilesOperation` 用 `TaskChainCoalescer` 合并请求、复用 `sharedContext.appIDs`（思想同源，但它是单 App 内合并，Seal 是跨 App 批量去重）；② 上游同样 `import Crypto`，没有 CryptoKit 分支；③ 上游后台刷新同样全量（`BackgroundRefreshAppsOperation` 直接 `refresh(...)`，无过期窗口过滤） | **三处都是「不跟（上游没有）⇒ 本仓自研」** ✓：① portal actor 内 5 分钟 TTL 读缓存（`addAppID` 成功即失效、`bundleIdentifierUnavailable` 恢复性重拉 bypass）；② 新增 `FastSHA256`（`#if canImport(CryptoKit)` 走 ARM SHA 硬件加速，Linux 保持 swift-crypto，输出逐字节一致，public API 零改动）；③ `PredictiveRenewalPolicy`（后台轮只续 48h 内到期的，窗口按上次间隔自适应放宽，手动「续签全部」照旧全量）。**安全边界**：只缓存读（`fetchProvisioningProfile` 是写操作，逐目标真发）；未知过期时间 fail open；后台 total==0 静默不弹 `SEAL-RENEW-001`。守卫 **R112**（8 断言 + 9 变异）。 |
| **2026-10-02** | **导入 Seal 自身 IPA、版本号相同时能否覆盖更新**（用户需求） | `hasPendingUpdateSource` 只比较营销版本 ⇒ 同版本导入的新包被判「无更新」⇒ 走 profile-only（只换描述文件、从不安装）⇒ 新包永远装不上 ✗ | **上游没有这个概念** ✗：SideStore 的自更新走**版本号驱动**的更新通道（`UpdateAppOperation` / 内置更新检查比 `CFBundleShortVersionString` 与更新源），不存在「导入同版本 IPA 文件覆盖安装」这条路径；它的自替换只出现在 install / update / resign 管线里（见 2026-09-25 那行） | **不跟（上游没有）⇒ Seal 自有机制** ✓：`hasPendingUpdateSource` 在版本一致时再看**源包内容指纹**（导入时流式算源 IPA 的 SHA256，存 `AppRecord.pendingUpdateSourceFingerprint`；自替换结算成功后由 `SelfAppRegistrar.atomicallyApplyInstalledIdentity` 清掉，自愈）。**安全边界**：指纹为空（老记录 / 已结算）时回落为纯版本比较 —— 续签时没导入新包不会触发重装，1.3.17「续签全都要重装」的坑不会回来；不能用 `hasPendingSelfUpdateSource` 那个标志代替（自替换走不到清它的普通安装路径，对 Seal 恒为真）。 |
| **2026-10-01** | **已存在 App ID 的能力更新**（Seal 自替换完整重签失败） | Seal 能从 `fetchAppIDs` 读到 `ALTAppID.features`，并在诊断中识别“完全一致”，但仍无条件调用 `updateAppId.action`。真机日志显示 Seal 的目标 App ID 已可复用且能力一致，重复写入被 Apple 以临时错误拒绝，外层误显示为“App ID 创建失败” | SideStore `FetchProvisioningProfilesOperation.updateFeatures` 逐项比较 `targetFeatures` 与 `appID.features`；全部满足时直接返回既有 App ID，不发 `updateAppId`。它不关闭门户上已有的额外能力，只补本次需要而缺失/关闭的开关 ✓ | **跟** ✓：Seal 新增同义纯判据，已满足时跳过重复能力写入；首次签名、能力变更及 App Group 关联保持原路径，不把短路扩大到 profile-only 以外的缺失身份场景。 |
| **2026-10-01** | **签名与续签帮助内容** | 旧帮助仍写成仅电脑配对，未交代 iOS 27 手机端配对、LocalDevVPN 验证、profile-only 回退与快捷指令续签，和实际链路脱节 ✗ | SideStore 将首签与 refresh 分成独立操作：首次准备身份和 profile，续签仅更新 profile；配对与通道就绪是前置条件 ✓ | **跟其流程分层，不新增行为** ✓：Seal 保留原有折叠卡 UI，将快捷指令自动续签收进“使用指南”末尾；不承诺后台必然成功，身份或设备端核验不成立时明确回退完整重签。 |
| **2026-09-30** | **iOS 27 手机端首次配对（无需电脑）** | Seal 仅有电脑配对助手写入或手动导入配对文件；已装到手机后不能自行开启 Remote Pairing Host ✗ | **SideInstaller `PairingController.swift` + `rust-core/src/pairing.rs`**：Rust `PairableHost` 监听端口、生成 pairing file；Swift `NetService` 发布 `_remotepairing-pairable-host._tcp` 及 TXT 记录，系统在「设置 > 隐私与安全性 > 开发者模式」确认配对和 PIN；成功后才把文件交给后续连接链路 ✓ | **跟其协议 Host 和 Bonjour 广播，不照抄其凭据落盘方式** ✓：Seal 把 Host 文件作为候选导入现有 `PairingStore`，继续用既有的「验证失败恢复上一份配对」事务和 `MinimuxerInstallChannel.diagnose()`，不引入第二套安装通道；iOS 27+ 隐藏电脑助手、导入和导出入口，iOS 26 及以下保持原路径。`LocalDevVPN` 是配对完成后的通道验证，不参与生成系统配对码。SideInstaller 代码受其非商业源码许可约束，仓库与 App 的开源许可页均保留归属；协议库 `jkcoxson/idevice` 为 MIT。 |
| **2026-09-30** | 🔴 **profile-only 首项 `NoConnection` 与快捷指令冷通道** | `start()` 只核验 RSD/UDID；其 900 秒缓存未能证明 `misagent` 描述文件服务可写，真机首个 `installProvisioningProfile` 仍会 `NoConnection`，外层再固定等 8 秒重试 ✗ | SideStore `BackgroundRefreshAppsOperation` 只在后台刷新前固定等待 1 秒；`MinimuxerWrapper.ensureMinimuxerReady` 只检查核心 ready，`installProvisioningProfiles` 直接调用 `minimuxer.core.installProvisioningProfile`。它有 RemotePairing 端口持久化/失败重查，但没有 RSD + misagent 的短时健康租约 ✓ | **不照抄固定等待，保留上游端口自愈并补 Seal 的服务级判据** ✓：`dumpProfiles` 和 `installProvisioningProfile` 在 RustBridge 中同经 `connect_to_rsd_services::<MisagentClient>()`，因此仅以无副作用 `copy_all` 预热实际服务；20 秒租约内复用，预热与 Portal 请求并行，且与注入同受单飞保护。普通探测失败时只 `RustIdevice.invalidateConnection()` 废弃 RSD 缓存，保留配对/provider 并即时重建一次；探测**超时**时不并发重试，而交由既有污染闸门在下一轮 `reset + start` 后继续。真正注入若仍遇瞬时通道错误，仅对同 UUID 的幂等写入立即窄恢复后重试一次。设备 profile 枚举**绝不**参与 profile-only 准入，写后逐份读回核验仍为最终正确性判据。 |
| **2026-09-29** | 🔴 **profile-only 续签为什么慢**（用户「续签必须快」，一字一码读 SideStore 续签几秒成功的原因） | `prepareProfileOnlyRenewal` 无条件 `prepare(.layoutOnly)` 解压 IPA（大包 30–35 秒，可续签从不产出新 IPA）；并复用完整签名的 `provisioningProfiles` 对每个目标 `registerAppID`+`updateFeatures`+`assignAppGroups` —— 这些首签已建好，续签纯冗余、徒增限流 ✗ | SideStore `PipelineStepDefinition.refresh` 只 5 步（`updateAppCertificate`/`verifyCertificate`/`fetchProvisioningProfiles`/`cacheResignedMetadata`/`refreshApp`）、**不解包**；`FetchProvisioningProfilesOperation` 用 `TaskChainCoalescer` 合并 `fetch_app_ids`/`fetch_app_groups` 请求、复用缓存 `sharedContext.appIDs`；`updateFeatures` 有「`appID.features` 已满足则跳过」短路（`:276-286`）；`updateAppGroups` 无 group 直接跳过 ✓ | **跟其「换 profile、不重发能力写请求」的骨架，且更彻底** ✓：① `SigningTargetRecord` 由「存权限键」升级为持久化 `entitlements` 键值对（自定义 Codable 向后兼容）；② 续签从记录重建权限集、**免解压**（`reconstructProfileOnlyRenewalTargets`，记录缺失才回落慢路径）；③ 新增 `renewalProvisioningProfiles` **根本不碰** register/updateFeatures/updateAppGroups（SideStore 短路后仍会发 updateFeatures/updateAppGroups），只「读 App ID 列表 + 下载 profile」。**两处刻意不照抄**：① 不照 SideStore `appID.features` 回填短路 —— Seal 的 `ALTAppID.features` 只写不读、回填无证明，照抄有静默丢能力风险；改以 `validateEntitlements` 逐键对账兜底（`valuesManagedBySigner` 白名单外的键缺了/值变了报 401/402 引导完整重签），把「盲跳过」升级成「有条件跳过」。② 远端缺已装目标 App ID 仍拒绝并引导完整重签（不借「续签」名义新建 App ID、消耗免费名额）✓ |
| **2026-09-29** | 🔴 **后台保活是否要靠「后台定位」第二路**（锁屏续签被音频中断挂起的根因，用户「按最牛的方式来」） | `BackgroundKeepAliveService`（静音音频）单一保活，音频被来电/闹钟/路由变更/媒体重置打断后自愈有空窗，进程被挂起则续签半途而废；对照 6 个依赖 LocalDevVPN 的同类 IPA（AirCard / Eagle / Husk / LocalDevVPN / StikDebug / 定位）拆包，稳定者普遍 `audio + location` ✗ | SideStore `BackgroundServices/BackgroundLocationService.swift`：`allowsBackgroundLocationUpdates = true` + `pausesLocationUpdatesAutomatically = false` + `showsBackgroundLocationIndicator = false`（三个关键开关齐备）；`AltStore/Info.plist` 声明 `UIBackgroundModes` 含 `location`；授权处置 notDetermined→`requestAlwaysAuthorization`、authorizedAlways/WhenInUse→`startLocationUpdates` ✓ | **跟其技术、不跟其互斥** ✓：Seal 复用上游定位保活的三个关键开关与授权分级，新增 `LocationKeepAliveService`。**两处有意不同**：① 上游 `BackgroundAudioService` 与 `BackgroundLocationService` **互斥二选一**（各自 `start()` 里先 `stop()` 对方，由 `backgroundServiceMode` 用户选择）；Seal **同时跑** audio + location 双保险 —— 锁屏续签不允许「音频被中断就挂起」，而上游是用户手动挑一种。② 上游用 `kCLLocationAccuracyThreeKilometers` + `distanceFilter = 4`（省电档）；Seal 用 `kCLLocationAccuracyHundredMeters` + `kCLDistanceFilterNone` —— 静止锁屏设备也要**持续回调**才算「进程被系统维持调度」，省电档会因定位长时间不动而回调稀疏，保活不可靠 |
| **2026-09-29** | 🔴 **更新 App ID 该发 feature 开关还是 entitlements 值**（免费账号 3001/1200 根因） | `updateFeatures` 把 `updated.entitlements = filteredEntitlements` 写进 App ID，AltSign `update`（`ALTAppleAPI+Operations.swift:345`）把 entitlements 值连同 feature 开关一起提交 `updateAppId.action` ⇒ 免费账号被 3001 拒；3001 降级清空 feature 后仍无条件 `assignAppGroups` ⇒ 1200 ✗ | SideStore `FetchProvisioningProfilesOperation.swift:233` 的 `updateFeatures` 只建 `targetFeatures: [ALTFeature: String]`（"true"/"false"），**从不设 entitlements**；App Group 由 `APG3427HIY` 开关启用 + 单独 `updateAppGroups`（assign 端点）✓ | **跟** ✓ —— `updateFeatures` 只发 feature 开关、不再写 `updated.entitlements`；`assignAppGroups` 加 `if downgraded == false` 跳过 1200；isEnabled 判据抽成 `featureEnabled` 纯函数对齐上游 |
| **2026-09-29** | 🔴 **免费账号能否用 App Group**（LiveContainer 多任务根因） | `ApplePortalSigningService.swift` 三处 `team.type == .free` 闸门把 App Groups 整条剥掉：`filteredAppIDEntitlements` 直接 `continue`、`updateFeatures` 不 toggle、`assignAppGroups` 不调用 ✗ ⇒ 免费账号签 LiveContainer 的 `application-groups` 为空 ⇒ `appGroupID` 退化为 `"Unknown"` ⇒ 多任务/内置 SideStore 不可用（真机诊断页 + 样本取证三证实锤） | SideStore `Feature.freeFeatures` 含 `.appGroups`（`APG3427HIY`）；`FetchProvisioningProfilesOperation.swift` 的 `updateFeatures`/`updateAppGroups` 对免费账号**无条件执行**；`Entitlement.freeEntitlements` 白名单也放行 appGroups ✓ | **跟** ✓ —— 放开三处闸门，免费与付费同样保留/分配 App Group；`increased-memory-limit` 维持现状（已知被 Apple 3001 拒、降级清空，非本次目标） |
| **2026-09-29** | 🔴 **`filteredAppIDEntitlements` 该保留哪些能力、App Group ID 是否要映射**（免费账号 401/402 根治） | ① 把 `increased-memory-limit` 等查不到 `ALTFeature` 的能力也塞进 `requestedEntitlements` ⇒ 描述文件不带它们 ⇒ 签后 `validateEntitlements` 必报 **401**；② App Group 的 group ID 保留**原始**值，而 `assignAppGroups` 提交、描述文件返回的却是 `bundleIDMapper.appGroupID` 映射后的 `group.<x>.seal.<teamID>` ⇒「原始」对「映射后」⇒ 必报 **402** ✗ | `Entitlement.swift:28` 定义 appGroups；SideStore `updateFeatures` 只对 `Feature.entitlement` 能映射到的能力发开关（`Entitlement.swift:224` 只映射 appGroups/interAppAudio）；`CodeSignerAPI.prepare:95-123` 以 **profile 授权集**为起点、与 app 原始 entitlements 取交集（签名器按描述文件裁剪，portal 拿不到的能力**本就写不进包**）✓ | **跟** ✓ —— `filteredAppIDEntitlements` 加 `guard ALTFeature(entitlement:) != nil else { continue }` 只保留可经门户提交的能力，并对 `.appGroups` 值经 `bundleIDMapper.appGroupID` 映射，与 `assignAppGroups` 同源一致；于是 `requestedEntitlements` 与描述文件两侧 group ID 逐字一致、非 feature 能力不再残留在期望授权集 ⇒ 401/402 两枪一并消除 |
| **2026-09-24** | 🔴 **扩展是否单独注册 App ID / 请求 profile** | 过去主 App 与每个扩展都进 Portal：多扩展 IPA 会把 Apple 网络窗口放大到 N 份 profile，且占用额外 App ID 名额 ✗ | SideStore `PipelineHandler` 的 **Keep App Extensions (Use Main Profile)** 路径：先准备主 App profile，随后直接返回，不创建扩展 profile TaskGroup；`PrepareAppExtensionBundleIDsOperation` 仍把扩展 Bundle ID 按主 ID 后缀改写；`ResignAppOperation` / `AltSign` 用同一份 profile 重签主 App 与扩展 ✓ | **跟，并设为普通 IPA 的强制默认** ✓：Seal 只向 Portal 提交主 App ID / 一份新主 profile；本地仍逐个重签所有 Bundle。没有 UI 选项，也不以旧记录推断回独立模式。**补齐 Seal 自有护栏**：每个扩展仍嵌入 profile、逐项验证证书/设备/新鲜度/entitlement；共享 profile 的 App Group 元数据同步写入扩展；签名记录键保持实际扩展 Bundle ID，避免缓存与安装前校验失配。Seal 自身暂保留独立内部路径。 |
| 2026-09-19 | **anisette 的取用时机** | `signOnce` 取一次、用一整轮 ✗ | AltStore `AppManager`：本地打补丁**之后**、第一个 Apple 请求**之前**刷新，并**显式声明依赖** | **跟** ✓ → 已修（`921fa4e`）；因 Seal 的 Apple 窗口更长（9 个 App ID × 2 次写 ✗），**加了更多刷新点**（`83084d0`） |
| 2026-09-19 | **证书轮换的撤销判据** | **必须 `sealSignerConfirmed`** ✓ + 撤销后**立刻持久化、立刻重建、成功即停** ✓ | AltStore 只看 `machineName` 前缀是否 `"AltStore"` | **不跟** ✓ —— Seal 的判据更严、顺序更谨慎 |
| **2026-09-19** | 🔴 **免费账号只有「一张」活动证书（Apple 硬限制）** | `CertificateTakeoverPolicy.swift:28` 已记录：「免费团队只有一个『活动 iOS 开发证书』槽位（Apple 硬限制，非两个）」✓ | SideStore `CertificateProvisioningFlow` 同样是「先创建、失败才撤销」—— **在免费账号上「先创建」必然 3022** ✗ | **关键约束，必须记住** ✓：<br>① **只有 1 张 ⇒「先创建」在免费账号上必然失败** ✗ ⇒ **必须先撤销** ✓；<br>② ⇒ **「撤销 → 创建」的窗口无法消除** ✗（腾槽位才能建 ✓）；<br>③ ⇒ 能做的只有：**撤销后立刻创建** ✓ + **失败给清晰说明** ✓ + **撤销前确保会话新鲜**（anisette ✓）；<br>④ ⇒ 本轮的 anisette 修复**顺带**降低了这个风险 ✓（会话过期是创建失败的主因之一 ✓） |
| **2026-09-19** | **证书的整体策略（顺序 / 谁来撤）** | **先撤销旧证书、再创建** ✗ —— 撤销成功但创建失败 ⇒ **账号变 0 张证书** ⇒ 用它签过的 App 全部打不开 ✗✗ | **SideStore `CertificateProvisioningFlow`**：<br>① 先找活跃证书/embedded 复用 ✓<br>② 否则**先尝试创建** ✓<br>③ 创建失败才进 `replaceCertificate`：候选 = `name` 含 `ios development`/`iphone developer` ✓；**弹窗让用户选** `keepExisting`（不撤，直接再试 ✓）/ `revokeSelected` ✓<br>⇒ **「先创建」⇒ 不存在「撤了没建成」的窗口** ✓✓ | **跟** ✓ —— 按用户指示「**Seal 比 SideStore 严格就去除，按 SideStore 来**」<br>⇒ 改成「**先创建；失败才处理撤销，且由用户选**」<br>⇒ **顺带消灭「0 张证书」这个灾难** ✓✓<br>**已实施 `ff718d9`** ✓（**自动撤销能力保留** ✓ —— 撞 3022 后仍自动撤销 + 重建）<br>⚠️ 那条既有守卫的文案本就写着 **`or`**（「rotate before a free-team request **or** after exact 3022」），实现却写成 `and` ✗ ⇒ 按意图更新 ✓ |
| **2026-09-26** | 🔴 **「运行中 Seal 正在用」的证书能否进轮换候选** | 1.3.17 曾在调用点加闸门「签非 Seal 时**剔除**运行中 Seal 的证书」✗ ⇒ 免费账号（只有 1 个活动槽位，而 Seal 的证书覆盖安装后**必然**丢本机私钥）**永久死锁**：签任何 App 都报 `SEAL-CERT-204b`（3022），构建 47 真机三条路径全被拦死 ✗ | SideStore `CertificateProvisioningFlow`：**先创建** → 撞 3022 → 才 `replaceCertificate`（撤销 → 再创建）；它**从不把自己排除在候选之外** ✓（Seal 没有内嵌证书，也就没有上游 `CacheSigningCertOperation` 那套自身跳过） | **跟** ✓ —— 与上游一致：**候选不排除自身，只把自身排到最后**。<br>⇒ 落地：删除闸门（`SigningCertificateRotationGate`），调用点恢复 `candidates: candidates`；安全性由**三条**保证 —— ① `rotationRank` 把 Seal 的证书排最后（`isRunningSealCertificate ⇒ 3`，普通证书 0/1/2）；② 撤销前必须发 warning 说清「Seal 将在本事务末尾重装」；③ 撤销后由 `resignAppsAffectedByCertificateRotation(includeSeal: true)` 恢复。<br>⚠️ 同族：`CertificateTakeoverPolicy` 的**规格**原写「真实签名者 A 永远不能成为撤销候选」＋单测 `fullSlotsWithOnlySignerBlocks` 断言「只剩 A 时 blocked」—— **把死锁钉成了契约**；已改为「A 排最后但仍进候选」。<br>⚠️ 变砖的真凶是**自替换安装失败**（构建 38 / 46 的 `SEAL-SELF-109`），不是撤销本身 ⇒ 修错了环节。 |
| **2026-09-19** | **扩展的 App ID 准备顺序** | 主 App **排最前** ✓（`ApplePortalAppIDResolver.preparationOrder`）；扩展**串行**、且每请求**节流 0.4 秒**（`AppleRequestThrottle`）✗ | SideStore `FetchProvisioningProfilesOperation`：<br>① **主 App 先准备** ✓（`provisionAndFetchProfile(for: targetAppBundle, parentAppBundle: nil)`，在扩展之前）<br>② 扩展用 **`withThrowingTaskGroup` 并发** ✓<br>③ **没有节流** ✓<br>（`PrepareAppExtensionBundleIDsOperation` 只做「扩展 BundleID 跟着主 profile 改写」✓，不涉及注册顺序） | **一半一致、一半已定** ✓：<br>① **主 App 先 = 上游一致** ✓ ⇒ **不用改** ✓；<br>② **串行 + 节流 vs 并发无节流** ⇒ **暂不跟并发** ✓（2026-09-22 定）：节流是为「1100 短时频率限制」加的，先收集「无 1100」的大包样本再评估 ✓<br>（并发能**缩短 Apple 窗口** ⇒ 对 anisette 寿命有利 ✓，条件成熟再上 ✓） |
| **2026-09-19** | **证书「有效性」的判据** | **本机有私钥 + 剩余有效期 > 7 天** ✓（`SigningCertificateMaterialPolicy` / `CertificateTakeoverPolicy`） | SideStore `VerifyCertificateOperation`：先看证书在不在 **portal 列表**里 ✓，不在才退到 **OCSP** 校验 ✓ | **保留 Seal 的判据** ✓ —— 两者**目的不同**：SideStore 问「这张证书还有效吗」（可否**继续用**）✓；Seal 问「这张证书够不够签**满 7 天**」✓<br>⚠️ **7 天那条不是「多余的严格」** ✗ —— 只判「当下未过期」会把**次日到期**的证书签进新包 ⇒ iOS 判「尚未验证」**闪退** ✗（`AGENTS.md` 第 3 节有记载 ✓）<br>⇒ 按判据属于「**更完整/防缺陷**」⇒ **保留** ✓（不是「更严格」✗）|
| **2026-09-19** | **描述文件批量安装** | **不逐个装 profile** ✗ —— 走 `installPushedIpa` / `install(ipaData:)`（**profile 随 IPA 一起进设备** ✓） | SideStore 的 `InjectBatchProfilesOperation` + `addPendingProfileBatch` **只在 `isCellularRefreshGroup` 时触发** ✗ —— 那是**蜂窝网络下批量续签**的场景，目的是**少切几次数据网络**（`turnOffDataIfNeeded` ✓） | **不用跟** ✓ —— **Seal 里没有「蜂窝」这个概念** ✓（grep 为空 ✓），也没有对应场景；而且两边装 profile 的路径本来就不同（Seal 随 IPA 装 ✓） |
| **2026-09-22** | **profile-only 的 App ID 能力更新与提速** | profile-only 复用完整签名的 `provisioningProfiles`：读取既有 App ID、更新能力、逐份申请 profile；真机日志显示 Apple 返回的 `features` 持续为空，4 目标 App 约 24–55 秒 | SideStore `FetchProvisioningProfilesOperation` 同样始终 `registerAppID → updateFeatures → updateAppGroups → downloadProvisioningProfile`；没有“直接跳过能力更新”的 profile-only 分支 | **不跟“盲跳过能力更新”** ✓：远端空 `features` 不能证明能力已一致，跳过会静默丢 entitlement。继续保留串行与节流，先收集无 1100 的大包样本再评估并发。Seal 的 profile-only 额外规定：远端缺失已装目标 App ID 时**拒绝**并要求完整重签，绝不借“续签”名义新建 App ID / 消耗免费名额 ✓。<br>⚠️ **已由 2026-09-29 推翻**（1.3.41）：`renewalProvisioningProfiles` 续签专用路径**跳过了** register/updateFeatures/updateAppGroups —— 但**不是「盲跳过」**：安全兜底改为 `validateEntitlements` 对「新描述文件 vs 旧描述文件实授权限」逐键对账（`valuesManagedBySigner` 白名单外的键缺了/值变了报 401/402 引导完整重签），不再依赖「远端 features 回填」这种无证明的取证，故「跳过会静默丢 entitlement」的顾虑不再成立。 |
| **2026-09-19** | **会话过期（1100）的重试与退避** | `withSessionRecovery`：退避重试 + 重建会话 ✓ | **两个上游都完全不处理** ✗ —— `AltSign` 里没有 1100/retry/backoff/sessionExpired 任何一处 ✓；`SideStore` 里唯一的 "1100" 是个**端口号** ✓ | **保留** ✓ —— **上游「没有」≠「更好」** ✗：上游把会话过期完全交给**用户手动重试** ✗，而 Seal 自动恢复是**必要的健壮性** ✓（今天的 1100 就是证据 ✓） |
| **2026-09-19** | 🔴 **签大包的内存峰值** | **整块读 + 原地改（COW 复制）⇒ 峰值 2×** ✗<br>真机 `JetsamEvent`：Seal `rpages 129697 × 16KB = **2.11 GB**` ⇒ 被杀 ✓ | **`CodeSignKit`（SideStore 用的签名器）**：<br>① `MachOParser.swift:154,157` **`Data(contentsOf:…, options: .mappedIfSafe)`**（mmap 读，0 内存 ✓）<br>② `MachOSigner.swift:301` **`workingData.subdata(in: 0..<codeLimit)`**（复制出新 Data 再改，1× ✓）<br>⇒ **全程只有 1 份** ✓<br>⚠️ **上游也没有流式** ✗（`InputStream`/`FileHandle(forWriting` 全空 ✓）⇒ 说明 **1× 就够** ✓ | **跟** ✓ 已实施 `db2463a` —— 把 `BundleSigner` 的 `input` 与 `var executable` 改成 mmap 读 ✓ |
| **2026-09-19** | 🔴🔴 **mmap 的统一判据**（今天所有纠结的答案 ✓） | — | — | **不是「哪里该用 mmap」，而是「这份 Data 会不会被原地写」** ✓<br>· **只读 ⇒ mmap 安全** ✓（签名器 input/executable ✓ / `readEntitlementsXML` ✓ / `inspectMachO` ✓ / 缓存条目 ✓）<br>· **原地写 ⇒ 必须整块读** ✓（`SigningWorkspace.rewriteExecutablePathReferences` ✓ —— R49 钉住 ✓）<br>⚠️ 违反它的后果：**SIGBUS 崩溃** ✗（构建 160 ✓） |
| **2026-09-19** | **`ALTAppleAPISession` 与 anisette 的关系** | 认证时建会话，之后**替换/重建**它来更新 anisette ✓ | `AltSign` 的 `authenticate(... anisetteData: ALTAnisetteData ...)` 把 anisette 当**入参** ✓；`ALTAppleAPISession(dsid:authToken:anisetteData:xcodeVersion:)` 在**认证那一刻**建会话 ✓ ⇒ **库不管 anisette 的生命周期** ✗ | **已跟** ✓ —— `anisetteData` 只是会话的**一个字段**，调用方必须在**每次 Apple 工作前**替换它 ✓（AltStore 的做法：`session?.anisetteData = anisetteData` ✓）|

| **2026-09-19** | 🔴🔴 **整个签名器（内核 ＋ 重签层）** | `Vendor/rork-sign` ＋ Seal 自写的 `RorkAppSigner` ✗ | **`SideSign` → `CodeSignKit`**（SideStore 在手机上签大包用的就是它 ✓） | **跟** ✓ —— 用户死命令「**签名器不一样你就换啊**」⇒ 整个换掉 ✓（详见**第九节** ✓）<br>⚠️ 代价：签名缓存 ✗、逐 bundle 诊断 ✗、FairPlay 补丁 ✗（**三个已知风险** ✓） |
| **2026-09-20/21** | 🔴 **配对助手该生成「哪种」配对文件** | 覆盖层把上游的「配对类型」单选**删掉了** ✗ ⇒ 只剩硬编码默认值 `PairingMode::RemotePairing` ⇒ **iOS 17.0–17.3.1 的设备必然生成失败** ✗，且界面不说原因 ✗ | `idevice_pair` **README（固定版 0.1.14 也一样）**：*"RPPairing for **iOS 17.4+**, Lockdown for older verions"*；上游界面用 `radio_value` **让用户自己选** ✓ | **跟** ✓ —— 判据照上游，但按 Seal 的极简 UI **不做单选**，按设备版本自动选：**< 17.4 ⇒ Lockdown** / **≥ 17.4 ⇒ RemotePairing**。版本未知时禁用生成，不能把不确定设备送进远程配对。另补齐 Lockdown 端到端前提：导入必须含完整 pair-verify 身份；启动前重定向 usbmuxd；安装/续签走 AFC + installation_proxy，不能误走 RSD 合并入口。<br>**根因**：iOS **17.4 才引入 `CoreDeviceProxy`** ✓（上游 README ＋ pymobiledevice3 文档双向印证 ✓）⇒ 17.0–17.3.1 在 USB 上引导不了远程配对 ✗ |

| **2026-09-21** | 🔴 **Lockdown 配对文件的字段（助手生成 ↔ Seal 校验）** | 新增完整性校验 `PairingStore.isCompleteLockdownPairing`：要求 **7 个键** —— `UDID`/`HostID`/`SystemBUID` 为 `String`，`HostCertificate`/`HostPrivateKey`/`RootCertificate`/`RootPrivateKey` 为 `Data` ✓ | 生成侧 = `idevice_pair` @ `e3abb34` → **`idevice` crate 0.1.61**：`PairingFile::serialize()` → `RawPairingFile`，键名由 **`#[serde(rename_all = "PascalCase")]` 派生**（`SystemBUID`/`HostID`/`UDID`/`WiFiMACAddress` 另用显式 `rename`）；四份证书/私钥声明为 plist **`Data`** ✓。与 `Vendor/DeviceSupport/libimobiledevice`（`userpref.h` 的 `USERPREF_*_KEY` ＋ `lockdown.c` 的 `plist_new_data`）标准 pair record 一致 ✓ | **一致 ⇒ 不用改** ✓ —— 键名**逐字相同**、类型匹配（3 String ＋ 4 Data）、`UDID` 由助手显式赋 `Some(dev.udid)` 不会缺 ✓ ⇒ **导入校验不会误拒**。<br>⚠️ **查法教训**：直接 `grep HostCertificate` 在上游源码里**命中为 0** ✗ —— 键名是 serde 从字段名派生的，不是字面量。**「grep 不到」≠「不存在」**，要读 serde 属性才对 ✓（同族：Seal 自己的中文文案常写成 `\u{...}`，grep 中文同样会零命中 ✓） |

| **2026-09-24** | 🔴 **撤销旧证书后「自动重签受影响应用」的判据** | 过滤器要求 `candidate.accountID == accountID` ✗ ⇒ 与「本机无私钥」（必须**删过**账号）**互斥** ⇒ 恢复**从未执行过** ✗（构建 33 连续两轮真机「自动续签 0 个」实证）；且两处调用点都在**成功路径**上、撤销记录又是**局部量** ⇒ 后续失败时后果**无人负责** ✗ | **AltStore / SideStore 都没有这个能力** ✗ —— 上游的 `UpdateAppCertificateOperation` / `VerifyCertificateOperation` / `CacheSigningCertOperation` 只管「证书本身要不要换」，撤销后**不会回头重签已装应用**（用户得自己逐个重装） | **不跟** ✓ —— 这是 **Seal 独有的保护**（撤销会让用它的 App **立刻打不开**，自动重签是必需的补偿）。本轮修的是 Seal **自己的判据失效**：<br>① 判据只留**证书序列号**（全局唯一）＋安装态＋`includeSeal`＋`excludingAppID`，**去掉 `accountID`**；<br>② 恢复子流程回传**真实恢复结果**，三条出口（`ImportFailure` / 意外错误 / 取消）统一算出「谁还没恢复」、写 `SEAL-CERT-240`、把后果写进用户可见的 `reason`（**保留原 code / recovery**，否则按钮动作会被换掉）。<br>⚠️ 刻意**不自动补跑恢复**：失败多半意味着通道不可用，此刻重签只会再失败一次、把真因埋掉。<br>⚠️ 另一条独立约束见 `docs/upstream-alignment.md` 上行「免费账号只有一张活动证书」——「撤销 → 创建」的窗口无法消除，所以「撤销后必须有人负责」不是可选项。 |

| **2026-09-24** | 🔴 **续签时用哪个账号 / 记录里的账号失效了怎么办** | 每个应用记录 `accountID` ＋ `signingTeamID`（可以「钉住当初签它的那个账号」✓）；但 `deleteAccount` **刻意保留**绑定 ⇒ 删账号后 `accountID` 变成**悬空 UUID（非 `nil`）**，而三处续签入口都**直接采用**它 ✗ ⇒ 除 Seal 自己（`SelfAppRegistrar` 每次启动回补 Team/账号）外**全部无法续签** ✗；界面还显示「未记录·自动选择」，与行为**正好相反** ✗；失败出口**一行日志都不写** ✗ | **AltStore / SideStore 根本没有「应用 ↔ 账号」关系** ✗ —— `InstalledApp` 模型里没有 account 字段（只有 `signingCertificateURL`）；账号侧只有一个**全局** `Account.isActiveAccount`（只在 `SignInOperation` 登录时置位、其余清空），签名证书也**全局**存在 Keychain（`signingCertificate` / `signingCertificatePrivateKey` / `signingCertificateSerialNumber`）⇒ 续签时**不存在「按应用解析账号」这一步** ⇒ **压根没有悬空引用这类故障** ✓<br>代价：**无法按应用钉住账号，也不会拒绝换 Team** ✗（`activeTeam` 只是个全局标记） | **不跟** ✓ —— Seal 的「按应用绑定账号」属于**更完整**那一类（同 Team 才能保证 Bundle ID 前缀 / Keychain 访问组 / App Group 不变），必须保留；本轮修的是它**自己的判据失效**：<br>① 记录里的账号**必须真的存在于账号库**，否则不再直接采用；<br>② 失效时按 `signingTeamID`（大小写 / 首尾空白不敏感）在**可选**账号里找**同 Team** 的替代 —— 粒度与上游 `activeTeam` 一致，但**限定在同一 Team 内** ✓；<br>③ 有 Team 信息却匹配不上 ⇒ **拒绝并说明原因**（绝不静默换 Team）；只有旧数据**完全没有** Team 信息时才退回「传入账号 / 第一个可选账号」；<br>④ 失败按原因**分码**（`SEAL-AUTH-104f` 需重新验证 / `SEAL-AUTH-104g` 原账号已删除且无同 Team 账号）并**逐条留痕**（原来零日志）；<br>⑤ 界面文案改走**同一个判据**，失效状态用告警色。<br>⚠️ 顺带统一一处不一致：旧实现「按 Team 匹配」**只给 `isSeal` 开小灶**，而风险与判据对所有应用完全相同 ⇒ 现在对所有应用生效。 |

| **2026-09-25** | 🔴 **Seal 自身续签要不要重新安装自己** | 准入判据第一句按**身份**排除 Seal（`guard app.isSeal == false else { … .sealSelfReplacement }`）⇒ Seal 续签**永远**走完整重签 + 自替换安装 ⇒ 进程被系统换掉 ⇒ 批量续签队列项留在 `running` 变成未知（`SEAL-RENEW-007`）、自替换安装报 `SEAL-SELF-109`（构建 44 真机，同一轮连报两次）✗ | `PipelineStepDefinition.refresh` 只有 `fetchProvisioningProfiles` / `cacheResignedMetadata` / `refreshApp` **三步，不含重签、不含安装**；`RefreshAppOperation` 对每个目标只做 `installProvisioningProfiles(_:)`（misagent 注入描述文件），**对 SideStore 自己同样如此**；自替换（`handleSelfReinstallation`）只出现在 install / update / resign 管线里 ✓ | **跟** ✓（2026-09-25 实施）—— 删掉身份豁免与只为它存在的 `FullResignReason.sealSelfReplacement`；**安全边界不放松**：记录不完整（缺已装产物 / 缺签名身份 / 缺目标记录）时照旧回落完整重签。<br>**同时修掉下游的旧假定**（否则只是「改了一半」）：`RenewalCoordinator` 结算原按 `updated.isSeal` **无条件**「不计成功、等新进程核验」⇒ 快路径成功后仍会变回 `SEAL-RENEW-007`；改为按**实际路径** `currentRenewalExecutionPath != .profileOnly` 判断（信号缺失时退回保守行为）。守卫 **R82**（7 断言 + 8 变异）。 |

| **2026-09-26** | 🔴 **「不打开 App 的后台自动续签」（后台保活 ＋ 快捷指令触发）** | 1.3.21 及更早**三层全都没有** ✗：全仓 `Seal/` 下 `BGTaskScheduler` / `AppIntent` / `SiriKit` / `Shortcuts` / `UIBackgroundModes` **零命中**；唯一的「后台保活」是 `UIApplication.beginBackgroundTask`（约 30 秒、一次性，`SigningCoordinator.swift:306-320` / `:1813-1821`），**只在已经在前台发起的续签里兜底**，没有任何东西能让 App 在后台长期活着 ✗ | **SideStore 三层都在**（2026-09-26 逐行核实）：<br>① 保活 `SideStore/Core/BackgroundServices/BackgroundAudioService.swift` —— `setCategory(.playback, options: [.mixWithOthers])`（`:49`）＋ **运行时生成静音 WAV** `generateSilentWAV()`（`:53` / `:120-146`，8000 Hz 单声道 16 bit 1 秒纯 0）＋ `numberOfLoops = -1`（`:55`）＋ **`volume = 0.01` 而不是 0**（`:56`）＋ **中断恢复**（`:79-98`，`interruptionNotification` 的 `.ended` ⇒ `setActive(true)` ＋ `play()`）✓；备选 `BackgroundLocationService`（需「始终允许定位」）✗；`Info.plist` 声明 `audio`/`fetch`/`location`/`remote-notification`（`upstream/SideStore/AltStore/Info.plist:230-235`）✓<br>② 触发 `AppIntent` ＋ `AppShortcutsProvider`（`AppShortcuts.swift:12-36`）＋ 旧式 background fetch（`AppDelegate.swift:408`）✓；后台窗口只有约 30 秒，上游把 deadline 硬编码成 **27 秒**（`RefreshAllAppsIntent.swift:145`），超时就 `requestToContinueInForeground()` ✓<br>③ 网络：`MinimuxerWrapper.swift:196-200` 明写**蜂窝刷新 ＋ WireGuard 不行**（iOS 会在关蜂窝时暂停隧道）✓ | **跟** ✓（2026-09-26 实施，1.3.22）—— 三层照上游做：**① 保活**（`BackgroundKeepAliveService`：运行时生成静音 WAV、无限循环、`volume = 0.01`、中断恢复；`project.yml` 声明 `UIBackgroundModes: [audio]`）＋ **② 触发**（`RefreshAllAppsIntent`，`openAppWhenRun = false` ＋ `SealAppShortcuts`）＋ **③ 网络**沿用现成的 LocalDevVPN（`LocalDevVPNOnDemandActivator.probeTunnel()` 的注释说明「探测顺带拉起 VPN」）。<br>**两处刻意不照抄**：① **不加 `fetch`** —— 上游用旧式 background fetch（`AppDelegate.performFetchWithCompletionHandler`），而 Seal **还没有 AppDelegate** ⇒ 声明了不处理只会让系统白唤醒、并让排查时误以为有这条路径（要加时「声明 ＋ 处理回调」两件事一起做）；② **不用 `ForegroundContinuableIntent`** —— 它**已被 Apple 废弃**（官方改用 `supportedModes` 的 `.foreground(.dynamic)`）。<br>**Seal 侧另有的约束**：`SealAppEnvironment` 只允许**读**容器（第二个 `AppContainer.live()` 会造出第二份 CoreData store 与安装通道实例，绕过 `OperationCoordinator` 的单飞闸门，见 R05）；触发层必须**复用** `AppsViewModel.refreshAll()`，不得另起一套。守卫 **R90**（13 断言 ＋ 13 变异）。<br>⚠️ **上游自己承认做不到 100% 无人值守**（`AppDelegate.swift:419` 通知原文 *"The more you open SideStore, the more chances it's given to refresh apps in the background."*）⇒ **不向用户承诺「装完永远不用碰」**，真实目标是压低「必须手动打开」的频率 ✓ |

| **2026-09-26** | 🔴 **签名 / 续签的「白做功」**（首签 165 秒、续签快路径 44 秒里有多少是纯浪费） | ① 签名器把「量尺寸」与「真签名」都做成**全量**：Pass 1 先造一份和二进制一样大的全零缓冲、再逐页哈希一遍（**结果只用来取长度** ✗）；页哈希**每页复制一份**再算；签名输入**整块读**；证书 `.p12` **每次访问重解**（一个 33 二进制的包约 99 次 PBKDF2 ✗）。<br>② Seal 侧：分块扫描**每块复制 256 KB** 再搜（抖音全树 1.46 GB 白搬 ✗）；打包**一律 deflate**（png / jpg / mp4 / `Assets.car` 再压一遍几乎不变小 ✗）；**profile-only 续签照样做「瘦身 arm64e」与「ESign 布局归一化」**（后者在根目录有 `.framework` 时要**遍历全树**，抖音实测 30–35 秒 ✗ —— 而这条快路径**根本不产出新 IPA** ✗）。<br>③ 同一份「打包」规则有**两份实现**（`SigningWorkspace.package` 与 `SelfAppRegistrar` 各一份 `zipItem` ✗） | **上游也没有这些优化** ✗（2026-09-26 逐处核实）：`CodeSignKit` 的 Pass 1 就是 `Data(count: codeLimit)` ＋ `build()`；`CMSSigner.leafCertificate` 是计算属性、`sign()` 各自 `try PKCS12Parser(...)`；`CodeSigner` 用 `Data(contentsOf:)` 整块读。<br>打包侧：`FileManager+ZIP.swift` 的 `zipItem` 把**同一个** `compressionMethod` 透传给每个条目（上游默认 `.none` ＝ 完全不压 ✗），且 `Archive.addEntry` **没有**「压完更大就退回 store」的回退。<br>续签侧：SideStore 的 `PipelineStepDefinition.refresh` **压根不解包**（`fetchProvisioningProfiles` → `cacheResignedMetadata` → `refreshApp`，见上一行）⇒ **不存在**这一步浪费 | **不跟（上游也没有）⇒ 本仓自研** ✓（2026-09-26 实施，1.3.23）。<br>**改 `Vendor/CodeSignKit` 的 6 处**（逐处清单见 [`docs/upstream/codesignkit-perf-1.3.23.md`](upstream/codesignkit-perf-1.3.23.md)）：Pass 1 只算尺寸（新增 `CodeDirectoryBuilder.size()`，与 `build()` 共用 `layout()`）、页哈希零拷贝、追加 SuperBlob 前 `reserveCapacity`、签名输入 `.mappedIfSafe`、PKCS#12 实例级缓存。<br>**改 Seal 自己那层**：`containsBytes` 零拷贝（`bufferContains`，保留跨块 overlap 与 `memmove`）、打包**逐条目**选压缩方法、`SigningWorkspace.writeIPA` 收成**唯一**打包实现（`SelfAppRegistrar` 复用）、`prepare(purpose: .layoutOnly)` 让 profile-only 续签跳过瘦身与归一化。<br>⚠️ **安全边界一处都不放松**：`layoutOnly` 只跳「不碰 `Info.plist` / entitlements / 扩展集合」的两步（守卫 R91⑨b 钉住开关只许包住这两处）；压缩只对**已压过**的类型改 store，未压过的一律照旧 deflate。<br>⚠️ 这 6 处对上游**向后兼容**（只新增了一个 `public func size()`）⇒ 后续可给上游提 PR ✓。守卫 **R91**（13 断言 + 18 变异） |

| **2026-09-26** | 🔴 **后台触发时「设备通道还没就绪」怎么办**（构建 53 真机：快捷指令在后台触发后**逐项** `Minimuxer.MinimuxerError 1`＝`NoConnection` 全失败，而同构建几分钟前**前台手动续签 2/2 成功**） | 1.3.23 及更早：触发层**记一条 `SEAL-BACKGROUND-006` 就直接点火** ✗（不检查通道）；`RenewalCoordinator.isRetryable` 只认 `SEAL-NET-*` 与 `AppleServiceFailurePolicy.isNetworkError` ⇒ **通道类失败一次即弃** ✗；且 `SEAL-SIGN-500` / `SEAL-INSTALL-500` / `SEAL-SELF-109` 的 reason 是固定文案「技术信息已写入脱敏日志」，而**全仓没有任何地方记录那个原始 error**（`grep -rn "technicalDetail\|rawError\|underlyingError"` = 0 命中）⇒ **单应用续签失败时根因在导出日志里根本不存在** ✗ | `BackgroundRefreshAppsOperation.execute()`（`upstream/SideStore/SideStore/Core/Operations/StandaloneOperations/BackgroundRefreshAppsOperation.swift:56-99`）：① 先 `executePreconditionCheck`；② 需要时 `startEMProxy()`；③ **固定 `Task.sleep(1 秒)`** 后直接 `refresh(...)`（注释自述目的是「给发现 AltServer / 让别的进程回 `requestAppState` 留时间」）✗；④ 失败 ⇒ `scheduleFinishedRefreshingNotification(for: .failure(error))` ＋ 直接 `throw` —— 该文件与 `RefreshAppOperation.swift` 里 `retry` / `backoff` **零命中** ✗ | **不跟** ✓（2026-09-26 实施，1.3.24）—— 上游那个「固定睡 1 秒」是**时间估计**、不是就绪判据（Seal 真机上通道恢复要 ≈3–20 秒，睡 1 秒必踩空）⇒ 改成**等到真就绪**：`installChannel.start()`（900 秒成功缓存 ＋ 单飞合并并发启动）＋ 成功/超时都留痕（`SEAL-BACKGROUND-007/008/009`）。⚠️ **等不到也照常点火**是刻意的：宁可让它试一次（失败项还有重试兜底），也不要整轮跳过让用户看到「后台续签什么都没发生」。<br>**补「通道瞬时错误」这一类可重试**：新增纯函数 `DeviceChannelTransientPolicy`，把 `Minimuxer.MinimuxerError` 的 `0`(`NoDevice`) / `1`(`NoConnection`) **显式列为可重试**（按序号判，因为 `SealTests` target 看不到 `Minimuxer`）并给 **8 秒**起步退避（比网络的 2 秒长 —— 通道恢复是秒级），**刻意不含 `2`(`PairingFile`)**（配对文件失效重试多少次都一样）。判定**必须排在网络判定之前**（通道错误的 domain 与网络错误不同，但顺序写反会让分支永远走不到）。<br>**失败可观测**：上述三个码的 reason 统一追加 `[错误域 错误码]`（对齐 `RenewalCoordinator.normalize` 与 `AppMaintenanceJob:289` 早就有的写法）—— 在**没有落点**的地方写「技术信息已写入脱敏日志」等于骗下一个人 ✗。守卫 **R92**（9 断言 ＋ 15 变异）。 |

| **2026-09-27** | 🔴 **RemotePairing 服务端口是否固定**（真机：LocalDevVPN 通、隧道也通，但续签 / 安装**始终**连不上设备，重试多少轮都一样） | Seal 把端口**硬编码**成 `49152`（`MuxerConstants.rsdPort`），Rust 侧 `SocketAddrV4::new(Ipv4Addr::new(10, 7, 0, 1), 49152)` 写死 ✗ ⇒ 设备侧 `_remotepairing._tcp` 守护进程换端口后，就变成「隧道通、这个端口不通」，每一轮重试都撞同一个死端口 ✗ | **SideStore `MinimuxerWrapper`**：`isRetriableRemotePairingError` 判定失败可重试后 → `resolveDiscoveredRemotePairingPortThrottled`（**Bonjour 重查 `_remotepairing._tcp` 端口**，带节流）→ 端口变了就换 → **重试一次**；服务类型常量在 `MinimuxerConstants`（`_remotepairing._tcp` / `-pairable-host` / `-manual-pairing`）✓ | **跟** ✓（2026-09-27 实施，1.3.27）—— 按同一机制对齐：新增纯函数 `RemotePairingPortPolicy`（**只在「端口不对同义」的那一类失败上重查**：就绪失败码 `SEAL-INSTALL-710`，或 `connection refused` / `no route to host` / `connection timed out` 这类**端口层**原文；**显式集合**，不用数字区间 —— 否则 `709`「安全握手未完成」也会被算进来）＋ `RemotePairingPortDiscovery`（`NWBrowser` 并发浏览三个服务类型、`NWConnection` 解析端口，`project.yml` 已声明 `NSBonjourServices`；缺它 `NWBrowser` **不报错、只是永远没有结果**）＋ 通道在**两处**接线（诊断失败后 / 安装失败后，且换端口**赶在 `reset()` 之前**）＋ **发现到不同端口才采纳**（同步给 Rust 侧并作废按旧端口建的 RSD 缓存），留痕 `SEAL-VPN-004`。<br>**一处刻意不同**：Seal 只取**端口**、不取主机 —— RSD 对端固定是 LocalDevVPN 网关 `10.7.0.1`，只有端口是变量；上游连的是发现到的主机。守卫 **R95**（6 断言 ＋ 10 变异）。 |

| **2026-09-27** | 🔴 **「设备通道瞬时失败」在单应用续签路径上要不要重试**（真机：自替换后新进程自动续签 Seal，先 `SEAL-PROFILE-363`、约 30 秒后硬失败 `[SEAL-SIGN-500] MinimuxerError 1`＝`NoConnection`） | 批量 / 后台续签走 `RenewalCoordinator` + `DeviceChannelTransientPolicy`（同一份词表 ＋ 8 秒退避）⇒ 通道抖动能自愈；**单应用**走 `AppsViewModel.startSigning → runSigning`，**没有**任何重试，`signAndInstall` 的异常**直接抛给用户** ⇒ 同一个抖动，批量自愈、单签整轮白做 ✗。且底层裸 `MinimuxerError` 一律包成 `SEAL-SIGN-500`「未预期错误」，**既无下一步动作、也看不出是通道问题** ✗ | **上游根本没有「重试」这个概念** ✗ —— `RefreshAppOperation.swift` / `BackgroundRefreshAppsOperation.swift` 里 `retry` / `backoff` **零命中**（失败即 `throw`）；SideStore 把重试完全交给用户手动再点一次 | **不跟（上游没有）⇒ 本仓自有机制补齐到单签路径** ✓（2026-09-27 实施，1.3.28）。不是新造一套：把 `DeviceChannelTransientPolicy` 从「批量专用」提为**共用** —— `singleAppMaxAttempts`（= 3，与批量 `maxAttempts` 一致）、`shouldRetry(afterAttempt:maxAttempts:error:)`、`retryDelayNanoseconds(forAttempt:)`（8 秒 × 尝试序号）、`requiresChannelResetBeforeRetry(_:)`（通道类先 `reset()` 拆死会话；描述文件超时类只清熔断，交给 `renewProfilesOnly` 的污染闸门自己 reset + start）全部是**纯函数**；`runSigning` 的调用抽进 `signWithChannelRetry(...)`，留痕 `SEAL-SIGN-503`。失败归类抽成 `nonisolated static signingFailure(for:)`（可单测）：通道类给**带码可引导**的 `SEAL-SIGN-504`（跳 LocalDevVPN 设置页），其余才是 `SEAL-SIGN-500`。守卫 **R96**（4 断言 ＋ 9 变异）。 |

| **2026-09-28** | 🔴 **批量续签的重试要不要先恢复设备通道**（真机：快捷指令后台触发与手动续签整轮全失败，日志里同一项重试多次仍撞同一个 `NoConnection`） | 批量的重试循环只 `Task.sleep` 后 `continue`，**不恢复设备通道** ✗ ⇒ `MinimuxerInstallChannel.start()` 的 900 秒成功缓存把已被隧道抖动顶掉的**同一个**死会话原样还回来 ⇒ 「重试三次全失败、用户以为续签坏了」✗。而单签路径（2026-09-27 刚补）会 `reset()` —— 两条链路**各写一份**，必然漂移（本仓反复踩过的「两张表同源」坑）✗ | **上游没有重试、也没有「会话缓存」这套** ✗ —— SideStore 每次 `refresh` 都重新走 `MinimuxerWrapper` 的发现/连接，不存在「900 秒缓存还回死会话」这一类问题 | **不跟（上游没有）⇒ 把恢复动作收敛成唯一一份** ✓（2026-09-28 实施，1.3.29）。新增 `SigningCoordinator.prepareInstallChannelForRetry(after:)`：判据仍是纯函数 `DeviceChannelTransientPolicy.requiresChannelResetBeforeRetry`（通道类 ⇒ `reset()`；描述文件超时类 ⇒ 只清熔断），单签（`AppsViewModel.signWithChannelRetry`）与批量（`RenewalCoordinator.process`）**都调它**；批量只在**通道类**失败时动通道（Apple 网络错误的通道本来是好的），并留痕 `SEAL-RENEW-503`（这条链路在后台跑、界面无输出，日志是唯一证据）。守卫 **R97**（3 断言 ＋ 2 变异）。<br>**同日同批另修四处（非上游对照项）**：R98 安装失败取词与终端判定同源（`installationFailure` 改用 `errorDetail`，否则 `ImportFailure` 只经 `NSError` 桥接拿到 `title`、`No space left` 等设备原文全丢）；R99 `DeviceProfileCleaner` 的 dump 目录枚举失败 fail closed（不得退化成空清单、与「设备上确实没有」同形）；R100 日志 `exportText()`（镜像到 Documents 的 `Seal-log.txt`）也过脱敏；R101 已安装列表 / 签名历史的剩余天数改**四舍五入**（免费 profile 恰好 7 天，刚签完读到的 6.99 天向下取整会显示「6天」），且天数颜色与显示数字**同源**（`days <= 3`）。守卫 **R98–R101**。 |

| **2026-09-28** | 🔴 **2026-09-27 那条端口自愈在真机上为什么**没生效**（用户：Wi-Fi 与 LocalDevVPN **都连了**，签名 / 续签 / 配对校验仍失败，报 `SEAL-INSTALL-708`「设备未响应」） | 1.3.27 的端口自愈**只接在两处**（`startOnce` 诊断失败后 / 安装失败后），两条都够不到：① `readyDeviceIdentifier()` 用**裸 `isReady()`** ⇒ `.tunnelUnreachable` 原因被丢光 ⇒ `lastDiscoveryDetail` 恒空 ⇒ 最终失败落到 `discoveryFailure(tunnelReachable: true, detail: nil)` ⇒ 归成 **708** ⇒ 自愈只认 **710**（`RemotePairingPortPolicy.reprobeFailureCodes`）**永不触发** ✗；② 配对校验路径（`SettingsViewModel.runInstallChannelCheck`）**直接调 `diagnose()`、不走 `start()`** ⇒ 连 `startOnce` 的外层那次重试都没有 ✗ | **上游 SideStore 的做法本身没问题**（`MinimuxerWrapper.isRetriableRemotePairingError` → 重查端口 → 重试一次 ✓）—— 症结在 Seal **没把「就绪原因」接进这条判据**：上游的就绪判据自带 `Result<Bool, MinimuxerError>`，失败原因天然可用 ✓ | **跟** ✓（2026-09-28 实施，1.3.29 续）—— ① 新增 `lastReadinessIssueRaw`；`readyDeviceIdentifier()` 用 `readinessVerdict()` 替换裸 `isReady()`（判定**完全等价** `readyVerdict().isReady == ready()`，只多出原因）；② `diagnose()` 诊断循环内接一次端口重查（`readinessFailure` → `shouldReprobe(failureCode:)` → `reprobeRemotePairingPortIfNeeded`），**让配对校验路径也能自愈**；③ 拿不到设备标识的最终失败据就绪原因归码（710 而非 708），隧道本身不可达时保持 701 / 708。判据复用唯一那份表，不在通道里再抄一张。守卫 **R104**（4 断言 ＋ 4 变异）。 |

| **2026-09-28** | 🔴 **钥匙串条目的可访问性等级**（真机：锁屏下用快捷指令续签，日志说成功、抽屉全红，日志只剩一句 `Seal.KeychainError 1`） | `KeychainVault`（账号密钥）与 `KeychainAnisetteProvisioningStore`（anisette）都写 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` ✗ ⇒ **锁屏下读不到**。而不打开 App 的续签由快捷指令在**锁屏**时冷启动触发（`RefreshAllAppsIntent.openAppWhenRun = false`），这条链路**每次都现读钥匙串**（`SigningCoordinator.signAndInstall` 进来就 `keychain.load(accountID:)`；每次 Apple 请求都要 anisette），进程里没有任何内存缓存 ⇒ 抛 `KeychainError` ⇒ `RenewalCoordinator.isRetryable` 不认 ⇒ 不重试、直接失败 ✗ | **AltStore/SideStore `Keychain.swift`（`ss-clone/AltStore/Core/Components/Keychain.swift:47-49`，逐行核实）**：`KeychainAccess.Keychain(service:)` 用 **`.accessibility(.afterFirstUnlock)` ＋ `.synchronizable(true)`** ⇒ 锁屏可读 ✓ | **跟「可访问性」这一半，不跟「同步」那一半** ✓（2026-09-28 实施，1.3.31）。<br>① 改用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`；<br>② **保留 `ThisDeviceOnly`** —— 上游的 `synchronizable(true)` 是为了让它自己的 App 与 App Extension 共享账号，而 Seal 的**死命令是「禁止证书导入/导出」**（AGENTS.md §4）⇒ 口令与私钥**不随 iCloud 钥匙串同步**；<br>③ **上游没有迁移**（它一直就是这个值，不存在老条目）⇒ 这半是 **Seal 自有**：`KeychainAccessibilityMigrator` 一次性把升级前的 `WhenUnlocked` 条目改成目标值（改写入常量只影响**新写入**的条目，而 profile-only 续签**根本不写钥匙串**，老设备会一直是旧值 ✗）；<br>④ 顺带把 `KeychainError` 的 `CustomNSError` 补上（上游用 `try?` 吞错误，Seal 必须能分辨「设备锁定」与「条目不存在」）。守卫 **R106**（5 断言 ＋ 7 变异）。 |

| **2026-09-28** | 🔴 **快捷指令后台续签结束后「发不发系统通知、发什么」**（真机：全失败那一轮「共 3，成功 0，失败 3」什么都没发，用户以为成功了） | 1.3.31 的通知判据是 `shouldNotify == (succeeded > 0)` ⇒ **只报喜、失败整轮沉默** ✗；且 `awaitingConfirmation`（待核验）**根本没被带进通知** ⇒ 正文「已续签 1/3」看不出另外 2 个是待核验 ✗；本轮「根本没跑起来」的三档（让位给非续签操作 / 取锁等满 30 秒 / 整轮抛错）**一条都不发** ✗ | **SideStore `BackgroundRefreshAppsOperation.scheduleFinishedRefreshingNotification(for:delay:)`**（`upstream/SideStore/SideStore/Core/Operations/StandaloneOperations/BackgroundRefreshAppsOperation.swift:160-225`，逐行核实）：① 成功且结果**非空** ⇒ `Refreshed Apps` / `All apps have been refreshed.`（`:170-179`）；② **失败也发** ⇒ `Failed to Refresh Apps` / `error.localizedDescription`，`shouldPresentAlert = true`（`:190-195`）✓；③ **例外静默**：`OperationError.noConnection / .noVPN / .noInstalledApps` ⇒ `shouldPresentAlert = false`（`:180-184`）；④ `delay > 0` 时用 `UNTimeIntervalNotificationTrigger`，**App 仍在前台运行就反复重排同 identifier** 把通知往后推（`:204-216`）；⑤ identifier 用每次操作的 `refreshIdentifier`，先 `cancelFinishedRefreshingNotification()` 再 `add`（`:163`、`:247-249`） | **跟「失败也发」这一半，其余按 Seal 结构取舍** ✓（2026-09-28 实施，1.3.32）。<br>① `shouldNotify` 改 `total > 0`（有项要续签就发，**含全失败**）—— 与上游「失败也发」一致 ✓；`total == 0` 不发，与上游 `.noInstalledApps` 静默一致 ✓；<br>② **不跟**「`.noConnection`/`.noVPN` 静默」：Seal 的通道瞬时错误在**轮内就重试**（`DeviceChannelTransientPolicy`，见上行 1.3.29），能走到「整轮抛错」的多半是重试后仍失败 ⇒ 按用户要求**要报**（用户死命令：失败必须让用户知道，不能静默）；<br>③ **不跟**「前台反复重排、不弹」：Seal 这条通知只服务**快捷指令后台触发**那一轮（`openAppWhenRun = false`，用户通常不在 App 内），且用**固定 identifier 覆盖**而非延迟重排（`:147` 注释已写明「不做结果指纹去重」）；<br>④ **Seal 额外补上游没有的三档**：让位给非续签类操作（导入配对文件 / 管理证书）/ 取锁等满 30 秒 / 整轮抛错 —— 上游**没有 `OperationCoordinator` 单飞闸门**，不存在「让位」这一类（`SEAL-BACKGROUND-016`）。<br>守卫 **R106** 扩展（④ 判据改写 ＋ 新增 ⑥；断言 5→6、变异 7→8）。 |
| **2026-09-29** | 🔴 **RemotePairing 端口要不要持久化**（真机：每次进 Seal 续签/安装第一下先撞默认端口 49152 再 Bonjour 重查，进来的卡顿 =「续签慢」） | 1.3.38 之前 `Minimuxer.remotePairingPort`（`private static var`）冷启动恒回 `MuxerConstants.rsdPort`＝49152；`setRemotePairingPort` 只写内存 + 通知 Rust（作废旧端口 RSD 缓存）、**不落盘**；Bonjour 发现只在失败后触发、采纳后也不持久化 ⇒ 设备端口一变，每次冷启动都「撞 49152 → 就绪失败 710 → 重查（浏览 1.8s + 解析 1.2s）→ 换端口」✗ | **SideStore `MinimuxerWrapper`**（`upstream/SideStore/SideStore/Core/DeviceApi/MinimuxerWrapper.swift:14-29、:65`，逐行核实）：冷启动从 `UserDefaults.standard.lastDiscoveredRemotePairingPort` 恢复（`> 0 && <= 65535` 才用，否则回落 `MinimuxerConstants.remotePairingPort`）；`resolveDiscoveredRemotePairingPort` 成功后 `UserDefaults.standard.lastDiscoveredRemotePairingPort = Int(resolved.port)`；另有 `remotePairingPortOverride`（手动覆盖）与 `isAutoRetryRemotePairingPortEnabled`（默认 true）两键 ✓ | **跟** ✓（2026-09-29 实施，1.3.38）—— 按 Seal 结构改造：端口单一事实源本就在 `Minimuxer.swift`（static var，不同于上游放在 wrapper 的 `remotePairingPortCache`），故把持久化**内聚到 `Minimuxer.swift`** 三处 —— ① 冷启动 `restoredRemotePairingPort()` 从 UserDefaults 恢复（非法值回落默认）；② `setRemotePairingPort` 采纳新端口后写回 + `synchronize`（后台进程被回收也不丢）；③ `resetRemotePairingPort` 换设备/重新导入配对时 `removeObject` 清掉（避免残留上一台设备的死端口）。<br>**不跟**上游的 `remotePairingPortOverride`（手动覆盖）与 `isAutoRetryRemotePairingPortEnabled`（开关）两键 —— Seal 端口全自动自愈、不暴露手动覆盖/开关，符合「完全自动化、不增加操作复杂度」的用户约束。守卫 **R109**（1 断言 ＋ 2 变异）。 |

> **⚠️ 分清两种「Seal 多出来的东西」**（用户 2026-09-19 指示「比 SideStore 严格就去除」时）：
>
> | 类型 | 例子 | 处置 |
> |---|---|---|
> | **更严格**（额外的**限制/保守** ✗） | 白撤证书 / 过度节流 | **去掉** ✓ |
> | **更完整**（额外的**健壮性/恢复** ✓） | `withSessionRecovery` / 守卫 | **保留** ✓ |
>
> **上游「没有」不等于「更好」** ✗ —— 今天的 1100 恰恰证明：上游不处理它，Seal 必须自己处理 ✓。

---

## 五、SideStore 流水线的对照入口（27 个操作，按相关度排序）

SideStore 的签名/刷新是一条**显式流水线** ✓（`SideStore/Core/Operations/PipelineOperations/`）：

| 与 Seal 的哪个问题相关 | SideStore 的操作 |
|---|---|
| **证书轮换**（「0 张证书」风险区） | `UpdateAppCertificateOperation` / `VerifyCertificateOperation` / `CacheSigningCertOperation` / `EmbedSigningCertOperation` |
| **扩展的 App ID**（Seal 写死顺序 ✗） | `PrepareAppExtensionBundleIDsOperation` / `RemoveAppExtensionsOperation` |
| **Apple 请求窗口**（anisette 寿命） | `FetchProvisioningProfilesOperation` |
| **安装 / 上传** | `StageAppOperation` / `SendAppOperation` / `InstallAppOperation` / `CleanStagedAppOperation` |
| **自定义名称 / 图标** | `UserCustomizationOperation` / `ChangeAppIconOperation` |
| **前置检查** | `PreflightChecksOperation` |

另外 SideStore 把 anisette 单独做成一个模块 ✓：
`SideStore/Core/Anisette/{AnisetteProvider, OnDeviceAnisetteManager, AnisetteServersManager}.swift`
（Seal 对应 `AnisetteClient` / `AnisetteServerStore` ✓ —— 命名都几乎一样 ✓）

---

## 六、怎么执行（每次改签名/续签链路之前）

1. **查台账**（第四节）：有相关条目 ⇒ 直接用结论 ✓；
2. **没查过** ⇒ 用下面第七节的命令把上游对应文件拉下来读；
3. **读完写台账** ✓（一行：日期 / 对象 / 两边做法 / 跟或不跟 ✓）；
4. **如果「跟」** ⇒ 按 Seal 的结构改造（**不是照抄** —— 语言与结构不同 ✓）；
5. **跑守卫** ✓（守卫是「本仓已踩过的坑」的沉淀 ✓）。

---

## 七、拉取上游文件（`gh` 已登录）

```bash
# AltStore
gh api "repos/altstoreio/AltStore/contents/<路径>" --jq '.content' | base64 -d

# SideStore
gh api "repos/SideStore/SideStore/contents/<路径>" --jq '.content' | base64 -d
```

落盘建议放 `build/upstream/`（`build/` 不进版本库 ✓）。

---

## 八、不要对齐的部分（Seal 独有，别去「跟」）

- 免费账号 **App ID 名额**与主 App/扩展的**准备顺序**策略；
- **设备端描述文件回收**（含「扩展随父保留」的判定）；
- 「**两张表同源**」「**同一规则只落一条链路**」这类本仓历史坑的守卫；
- 自替换 / 续签事务（`SelfReplacementTransaction`）；
- 本地准备的**分段时间日志**（解压 / 改写 / 瘦身 / 归一化 —— 为 CPU 预算服务 ✓）。

---

## 九、🔴 **签名器已换成上游**（2026-09-19，用户死命令）

> 原话：「**一个代码不漏地给我抄 不要打补丁 签名器不一样你就换啊 这个签名不是签不了大包吗**」
> ＋「**禁止乱发明**」＋「**照抄吧**」。
> 方案 **B**：**只抄 SideSign 的签名能力**，不带它的 anisette / 门户 ✓。

### 9.1 换之前 → 换之后

| | 换之前 | 换之后 |
|---|---|---|
| 签名内核 | `Vendor/rork-sign`（`rorkai/rork-sign` 0.6.5 ＋ **4 个文件**的 Seal 补丁 ✗） | **`Vendor/CodeSignKit`**（`mahee96/CodeSignKit`，**原样 vendor** ✓） |
| 重签层 | `Seal/Infrastructure/Signing/RorkAppSigner.swift`（Seal 自写 ✗） | **`Vendor/SideSign`**（`mahee96/SideSign` ✓）＋ 薄适配 `SideSignAppSigner.swift` ✓ |
| 内存策略 | 整块读 ＋ 原地改 ⇒ 峰值 **2.11 GB** ⇒ jetsam 批量杀后台 ✗ | **mmap 读 ＋ `subdata` 复制后改 ⇒ 全程 1 份** ✓（**R57** 钉住 ✓） |
| 签名缓存 | `SigningCacheOptions`（`rork-sign` **独有** ✓） | **没有** ✗ ⇒ 每次**全量重签**（`SigningCacheStats` 恒 `(0,0)` ✓） |
| 逐 bundle 诊断 | `AppSigningOptions.diagnostics` ✓ | **没有** ✗（上游 `verboseLog` 走 `print` ⇒ **进不了导出日志** ✗） |
| FairPlay cryptid 清零 | 有补丁 ✓ | **没有** ✗ ⇒ **可能「装完启动崩」** ✗✗（**最高风险** ✓） |
| 签名身份读取 | `RorkSigner.checkMachOCodeSignatures`（**整块读** ✗） | `CodeSignKit.MachOParser`（**mmap** ✓）—— **R55** 钉住 ✓ |

### 9.2 为什么「整个仓库拿来」

用户指示「**直接整个仓库拿来，不允许你有什么什么太大、什么什么太多的想法**」✓
⇒ 上游仓库已放进 `upstream/`（7 个：`AltSign` / `AltStore` / `AnisetteKit` /
`CodeSignKit` / `SideSign` / `SideStore` / `rork-sign` ✓），
实际参与编译的是 `Vendor/` 下的**副本** ✓（`project.yml` 用 `path:` 引用 ✓）。

### 9.3 `Vendor/SideSign` 的删减（方案 B）

| 删掉 | 为什么 |
|---|---|
| `Sources/Anisette/`、`Sources/DeveloperPortal/` | Seal 用自己的 anisette（`AnisetteClient`）＋ `AltAppleAPI` ✓ |
| `Models/{AnisetteData,Session,AuthSession,AuthDevice,CertificateRequest,CertificateType,DeveloperPortalResponses,AppID,AppGroup,ProfileType}.swift` | 属于上面两层 ✓ |
| `Compatibility.swift`、`Constants.swift` 的 `Anisette` 段 | 同上 ✓ |
| `Logging.swift` 的 `import AnisetteKit` ＋ `AnisetteKitLogging.setLogging` | 同上 ✓（⚠️ 注释里两个标识符曾被 `python -c` 的**反引号**掏空 ✗，2026-09-19 已修 ✓） |
| `CLI/` ＋ `Package.swift` 的 `sidesign` 产品与 `executableTarget` | 整段建立在已删的门户层上 ⇒ **根本编译不过** ✗ |
| `Tests/SideSignTests` 里 2 个用例（CSR / DeveloperPortal） | 同上 ✓（其余 3 个：`Device` 模型 ＋ 两个 `Archive` 往返 ⇒ **保留** ✓） |

### 9.4 `Vendor/CodeSignKit` 的改动

🔴 **2026-09-26 起不再是「只有 `Package.swift`」** —— 本仓在这份上游副本上做了
**6 处性能改动**（首次签名 / 续签提速，1.3.23）。**改动清单与逐处理由见
[`docs/upstream/codesignkit-perf-1.3.23.md`](upstream/codesignkit-perf-1.3.23.md)** ✓，
守卫 **R91** 钉住「不得静默回退」✓。

⚠️ **同步上游之前必须先读那份清单**：本仓不能 `git merge` / `git rebase` 上游
（历史被重建过、没有共同祖先）⇒ 只能语义对照 ⇒ 一次「照抄上游」就会把这些优化全部回退 ✗。

`Package.swift` 的改动（早先那一处，仍然有效）：`swift-crypto` 由 `4.3.1` → **`4.5.2`** ✓
—— 不改会与根包冲突，CI 实报「gsacryptokit depends on swift-crypto 4.3.1 and root depends
on 4.5.2」✗。

除上述之外，其余文件**逐字节原样** ✓（2026-09-26 复核：未改动文件
`RequirementsBuilder.swift` / `SuperBlobBuilder.swift` / `Constants.swift` 与上游 `diff -q` 全 SAME ✓）。

### 9.5 🔴 换签名器带来的三个已知风险 → ✅ **真机已验证**（2026-09-20，构建 175）

> 真机日志 `Seal-log(28).txt`，**定版 `构建 1.1.16 (175)`** ✓

1. ✅ **装完能不能启动** —— **两个 App 都能打开**（LiveContainer 4.8 MB ＋ 抖音 657.6 MB）
   ⇒ **FairPlay `cryptid` 这条风险排除** ✓
   （上游 `CodeSignKit/MachOParser.swift:555` 仍只有「读」没有「清零」✓，
     但实测**不影响启动** ✓；若将来出现「装完点开就闪退」，原型补丁见历史提交 `b548021` ✓）；
2. ✅ **大包会不会被 CPU 预算杀掉** —— **没被杀** ✓：抖音（657.6 MB ＋ 9 bundle）全程走完
   —— 本地准备 44 秒（解压 7 ＋ 归一化 37）＋ **重签 78 秒** ＋ 打包 43 秒 ＋ 安装 121.6 秒 ✓
   （对比构建 147：签抖音 90 秒 CPU / 166 秒 ⇒ 撞「180 秒内 50%」上限被系统杀掉 ✗）；
3. 🟡 **日志里还能不能看出「死在哪个 bundle」** —— ⚠️ **仍是已知的能力退化** ✓
   （上游 `verboseLog` 走 `print` ⇒ 进不了 Seal 的导出日志 ✗；本次没崩所以没暴露 ✓）。

**⚠️ 真机暴露的另一处（与签名器无关）**：描述文件回收多轮 `回收中止：阳性对照未通过` ✗
> 🔴 **更正（2026-09-20）**：阳性对照用的是 `Bundle.main.bundleIdentifier`
>（**当前正在运行的 Seal 自己** ✓）⇒ **选得对** ✓；早先写的「挑错了对象」是**错的** ✗。
> **真实规律**：两次中止都在**刚启动**（冷启动后 22 秒 / 自替换重启后 60 秒），
> 同行都带 `dump 尝试 N 次`，16 秒后再跑就正常 ✓
> ⇒ 强烈指向「**启动早期安装通道还没就绪**」✓ —— fail closed **正确** ✓（**保护，不是回归** ✓）。
> ⚠️ 根因未最终确认（`unavailable` 把**超时**与**抛错**折叠成一个值 ✗）
> ⇒ 已补诊断（守卫 **R58**：探测带**耗时** ＋ **再问同一个 ID 一次**）⇒ 下份日志即可定性 ✓。

### 2026-10-15 — GrandSlam 503、2FA 与 SideInstaller 对齐

| 对照项 | 上游结论 | Seal 处置 |
|---|---|---|
| Android Anisette 指纹 | 用户提供且已能登录的 SideInstaller IPA 及其 isideload 源码使用 Pixel 7 / Android 14 / `com.apple.akd/1.0` | **跟**：`AnisetteClient.fetchLocal` 使用相同身份，并和本机 CoreADI 数据同源 |
| GrandSlam 与 2FA 请求契约 | SideInstaller/isideload 使用 `akd/1.0 CFNetwork/808.1.4`；初始与可信设备请求为 XML plist，短信端点为 JSON PUT/POST | **跟**：不再混入 SideSign 的 Xcode/buddyml 或 Apple Music 身份 |
| `Status.hsc = 409` | Apple 已发送可信设备验证码时可能省略 `au`；上游把它视为 `pushedCode` 并直接显示验证码输入 | **跟**：AltSign 识别顶层/Status `au` 和 `hsc=409`，复用 Seal 现有验证码 broker |
| 认证会话与重复提示 | 上游每次 GrandSlam 请求关闭连接；已处理 pushed code 后阻止循环再次提示 | **跟**：短生命周期会话 + `Connection: close`；单次登录上下文记录已处理状态 |
| 503 分类 | 503 是 Apple 登录服务/边缘响应，不是账号状态或 Anisette 服务器事实 | **跟**：`SEAL-NET-503`，只提示稍后重试，不清除现有账号/ADI 标识 |

对照来源：用户提供 `sideinstaller-v1.5.1-d85d59dab8cd.ipa` 的 REA 静态字符串，以及 `nab138/isideload` 当前源码（本地检出 `C:\Users\Administrator\AppData\Local\Temp\isideload-reference-20261015`）；对照 IPA 使用 REA 完整性证据 `ev_f165b8f040e17eae45e6bc955f29b119bc591d84d41114bf3ef3ce31139da671`。

### 2026-10-17 — 签名、覆盖安装与续签闭环复核

对照版本：SideStore `d97ec133719d79916675bdaf722b82a8d091d545`、AltStore `56854e66fef2eac32dad88dcbad1dc131d430e60`、SideInstaller `3ef96cef53f415a908e8dc8ead02bb0bde0f0438`。

| 环节 | Seal 现状 | 上游对照与结论 |
|---|---|---|
| 完整签名前置 | 先校验账号、设备 UDID、安装名额并行预热设备通道；在门户签名准备证书、App ID、描述文件前等待通道就绪；随后签全部目标、逐目标校验并打包。另有孤儿证书自动清理在门户本地准备之前执行。 | SideStore 在操作步骤前确保 minimuxer 就绪；AltStore 通过 AltServer 完成门户/安装环节，不能直接照搬到纯设备端。Seal 保留并行预热，并在任何 Apple 签名资源操作前等待并检查设备通道，设备不可达时提前失败。孤儿证书预清理仍是独立风险项，未混入本次修改。 |
| 覆盖安装与重试 | 签名包独立落盘，保存哈希；安装前验证文件、哈希、有效期、Bundle ID、主包与扩展 profile。安装失败保留原已安装记录和失败签名包，可单独重试安装。 | SideStore 也将 resign、send、install 分为步骤。Seal 的安装前验证与失败产物保留是额外保护，本轮未发现需要照搬上游的缺口。 |
| 只更新描述文件续签 | 仅在签名身份、目标拓扑和本机私钥满足条件时使用；从 Apple 获取新 profile，注入后逐份读回验证，最后才更新本地记录。条件不满足走完整重签。 | SideStore refresh 仅安装新 profile 并更新记录，不重签 IPA；AltStore 同样通过 AltServer 注入 profile。Seal 的逐份设备读回比这两个上游更强，应保留。 |
| Seal 自身覆盖续签 | 通过自替换事务暂存候选包；新进程启动后核验实际安装的 CMS 身份，再结算成功/失败，批量队列等待新进程确认。 | SideStore 有 staged self-reinstall 状态恢复，但判定模型不同。Seal 依赖本项目的自替换路径，不应直接替换成 SideStore 的数据库标记方式。 |
| 扩展共享策略 | 现已按目标分配：主 App 与兼容扩展共用主 profile；只有能力超出主 App、或读取不到能力声明的扩展各自申请 App ID/profile。映射、签名嵌入、逐目标 profile 校验、降级影响范围和 profile-only 续签均使用同一份独立扩展集合；每个目标的 profile UUID 已保存在既有 `signingTargets`，没有新增持久化字段。 | SideStore 的 `useMainProfile` 与 isideload/SideInstaller 的共享实现是整包模式，没有逐扩展混合分配可直接复用。**不照搬整包开关**：Seal 按已确认的 LiveContainer 需求加入目标级分配；兼容扩展不额外占名额，不兼容扩展只单独占自己的名额。源码级单测已补，Swift 云 CI 和真机仍待验证。 |
| SideInstaller 适用范围 | 其 Rust 流程能参考设备端 Apple ID/证书/App ID/profile 与签名操作。 | SideInstaller 不是与 Seal 等价的完整续签/覆盖管理器；其源码说明真实 Apple 登录与账户相关端到端行为未完全验证。只借鉴其已验证的具体请求/签名做法，不把整个工具链视为已验证标准。 |

本轮首次审计未改 Seal 源码；后续已按逐扩展 profile 绑定方案实现，尚未推送 CI。2026-10-17 后续修订已在签名门户准备证书、App ID 和描述文件前等待安装通道就绪；并行预热仍保留，避免把连接等待全部移到串行路径。

### 2026-10-17 — 前置设备检查、App ID 额度取证与设置文案

| 项目 | 上游实际做法 | Seal 修改 |
|---|---|---|
| 签名前设备就绪 | SideStore `PipelineRunner` 在执行操作步骤前调用 `ensureMinimuxerReady()`；AltStore 通过 AltServer 处理门户/设备流程，不能直接复制为设备端门禁；SideInstaller 的 Rust sideload 流程将 Apple 门户签名与设备安装分开。 | 保留通道并行预热，但签名在进入证书、App ID、描述文件操作前等待同一预热结果并执行通道就绪判定。设备不通时提前失败，不会继续申请 Apple 签名资源。 |
| App ID 名额 | AltSign 的 `ALTAppIDInventory` 保留 Apple 同次列表响应的 `maxQuantity` 与 `availableQuantity`，且允许字段缺失或负值；AltStore 文案也把免费账号限制描述为 7 天注册窗口。SideInstaller 的 `addAppId` 以 Apple 门户返回作为最终结果。 | 将 Apple 返回额度与可见/有效 App ID 数量分开存储和显示；仅在 Apple 明确返回非负可用额度且不足时预拦截。注册被拒后绕缓存强制重读并记录 Apple 返回值，用于查明“列表只有 8 个但拒绝新建”，不再把列表数推算成剩余额度。 |
| 支持、协议、关于 | Apple 隐私要求关注实际数据流及第三方 SDK/服务的数据处理；SideStore/AltStore/SideInstaller 没有可复用的 Seal 文案或页面。 | 协议卡片改为不透明内容表面；补齐 MJorb 个人开发者身份、Apple/Anisette/更新服务数据流、钥匙串卸载边界和准确的支持文案；实质更新协议版本并触发重新同意。 |

上游依据：`upstream/SideStore/SideStore/Core/Operations/PipelineRunner.swift`、`upstream/AltSign/Sources/Model/ALTAppIDInventory.swift`、`upstream/AltSign/Sources/ALTAppleAPI+Operations.swift`、`upstream/AltStore/AltStore/Operations/Errors/OperationError.swift`，以及 SideInstaller/isideload `dev/app_ids.rs` 与 `sideload/sideloader.rs`。此处只移植可对应的机制，不把其他项目的产品文案当作 Seal 事实。

### 2026-10-15 — SideInstaller RemoteV3 作为唯一 Apple 门户会话

| 对照项 | SideInstaller / isideload | Seal 处置 |
|---|---|---|
| Anisette 默认来源 | 上游源码 `RemoteV3AnisetteProvider::default()` 默认 `https://ani.jkcoxson.com`；但**用户提供的 sideinstaller-v1.5.1 二进制**中 `DEFAULT_ANISETTE_V3_URL = "https://ani.stikstore.app"` | **跟二进制**：默认服务器置首位改为 `ani.stikstore.app`（返回 macOS/Xcode 身份，与 `X-Apple-App-Info: com.apple.gs.xcode.auth` 自洽）；`ani.jkcoxson.com`（Windows/iTunes 身份）降为末尾兜底 |
| GrandSlam 请求指纹 | `base_headers` 在**每个** `GsService2` 请求（`init` / `complete` / `apptokens` / 2FA）上发送 `X-Xcode-Version: 14.2 (14C18)` 与 `X-Apple-App-Info: com.apple.gs.xcode.auth` | **补齐**：此前这两项只出现在 2FA 请求上，SRP `init` / `complete` 缺失 ⇒ Apple 在密码校验前即回 HTML 503（1.2.7 (16) 真机日志）；现已在 `sendAuthenticationRequest` 补全 |
| 会话连续性 | 登录与后续请求由同一 RemoteV3 provider 的持久状态生成 | **跟**：远程 provisioning 独立保存；认证、验证码、团队验证、签名均取同一远程状态 |
| 本机 ADI | 不参与该参考实现的默认认证路径 | **不删除**：旧本机 ADI 与稳定 identifier 仍保存，避免升级时破坏既有本地数据 |
