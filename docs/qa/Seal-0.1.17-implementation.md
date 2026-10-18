# Seal 0.1.17 审计问题修复记录

源码：`D:\Seal_Develop\Source\Seal-0.1.8-log26`
仓库：`3188447354/MJorb-0.1.0`；分支：`fix/ios-370-log26`
基线：`1a0bc88`；产品版本：`0.1.17`；构建号沿用 `3`。
审计依据：`D:\Seal_Develop\Research\Audits\Seal-0.1.15-20261018\run-1\REPORT-updated.md`
状态：源码改动未提交、未推送、未触发 CI；`artifacts/` 是原有未跟踪目录，未动。

## 总体结果

F01–F32 中能由源码直接修复的逻辑已落地。F25 的 AltSign 分发权、F32 的真实设备身份/覆盖范围，以及 V01–V08 的 Apple 服务、设备、性能和后台行为仍须外部条件验证，不能写成已验收。灵动岛源码已改为系统 leading/trailing 安全区域并增加 IPA 资源目录守卫；最终图标是否在目标 IPA 正常显示仍待构建和实机确认。

## F01–F32 逐项结果

| 编号 | 结果与主要路径 |
|---|---|
| F01 | 已修：证书撤销按序列号持久记录，撤销后的签名/重启流程可接续恢复受影响应用；手动撤销先保存恢复记录再清本地证书绑定。`Seal/Core/Signing/CertificateRecoveryJournal.swift`、`Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Features/Settings/SettingsViewModel.swift` |
| F02 | 已修：扩展共享比较规范化权限键和值及 App Groups，不再只比权限名称。`Seal/Core/Signing/AppExtensionProfileStrategy.swift`、`Seal/Infrastructure/Signing/ApplePortalSigningService.swift` |
| F03 | 已修：Mach-O/entitlement 解析失败与“确实没有权限”分开；Portal 预检和实际 SideSign 签名均使用 throwing reader，损坏权限不会变成空集合继续签。`upstream/AltSign/Sources/Model/ALTApplication.swift`、`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、`Vendor/SideSign/Sources/Models/AppBundle.swift`、`Vendor/SideSign/Sources/CodeSigning/CodeSignerAPI.swift` |
| F04 | 已修：Apple 拒绝必要能力或 App Groups 时不再清空权限后假成功。`Seal/Infrastructure/Signing/ApplePortalSigningService.swift` |
| F05 | 已修：按每个目标的能力决定共享/独立，不再把 Seal 或 LiveContainer 的所有扩展整体写死为独立。具体是否可共享仍由签后系统验证。`Seal/Core/Signing/AppExtensionProfileStrategy.swift`、`Seal/Core/Signing/SigningTargetRecord.swift` |
| F06 | 已修：遇到不支持的子目标时在签名前给出具体失败，不静默删掉 Watch/App Clip/扩展。`Seal/Infrastructure/Signing/SigningWorkspace.swift` |
| F07 | 已修：SIM、ADI 与 503 恢复纳入单一有界流程，取消和总次数受控；不清除账号 identifier。Apple 真实登录仍待账号实测。`Seal/Infrastructure/Accounts/AppleAccountClient.swift` |
| F08 | 已修：确定性 thinning 拒绝不再重试；IPA 明确声明不支持当前机型或最低系统版本时，在 Apple 资源操作前拦截，不明信息不猜。`Seal/Core/Signing/IPADeviceCompatibility.swift`、`Seal/Core/Import/IPAParserService.swift`、`Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift` |
| F09 | 已修：profile-only 续签将设备 reset、注入和逐份读回放在同一设备临界区，超时不提前释放仍在运行的原生调用。`Seal/Infrastructure/Renewal/ProfileOnlyProvisioningProfileInstaller.swift`、`Seal/Infrastructure/Installation/BlockingCall.swift` |
| F10 | 已修：Seal 重启登记区分 IPA 内旧 profile 与设备已注入的新 profile，保留设备读回的有效绑定。真实设备 profile-only 循环待测。`Seal/Core/Renewal/SelfAppRegistrar.swift`、`Seal/Core/Renewal/ProfileOnlyRenewalRecordUpdater.swift` |
| F11 | 已修：安装 attempt 与 native 在途结果关联；取消/超时后迟到结果可结算，不因界面退出而重复下发。设备端迟到结果待测。`Seal/Core/Installation/InstallChannel.swift`、`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`、`Seal/Core/Concurrency/HardTimeout.swift` |
| F12 | 已修：Seal 自替换事务采用有界恢复窗口并核对实际运行身份，避免提交后无返回时永久等待；不把超时直接当成功。`Seal/Core/Renewal/SelfReplacementPolicy.swift`、`Seal/Core/Renewal/SelfReplacementCoordinator.swift` |
| F13 | 已修：配对 native listener 有取消/超时路径，Swift host 释放会话与租约，旧回调按 run ID 隔离。真机连接/断开场景待测。`Vendor/Minimuxer/RustBridge/src/phone_pairing.rs`、`Seal/Infrastructure/Pairing/PhonePairingHost.swift`、`Seal/Features/Settings/SettingsViewModel.swift` |
| F14 | 已修：成功/失败先更新 Live Activity 终态，再按期限结束；展开态品牌和状态分别使用 leading/trailing 区，正文在 bottom 区，避开摄像头开孔导致的挤压。系统实际渲染待测。`Seal/Infrastructure/Pairing/PairingLiveActivityController.swift`、`SealLiveActivity/PairingLiveActivityWidget.swift` |
| F15 | 已修：应用启动时结束无法恢复原生监听的孤儿活动，避免旧码和重复活动。`Seal/Infrastructure/Pairing/PairingLiveActivityController.swift`、`Seal/Features/Settings/SettingsViewModel.swift` |
| F16 | 已修：已签名 App 展示真实软件名、完整 application-identifier、签后 Bundle ID 和对应 profile 到期时间，不再拿 Portal 资源号冒充 App ID。历史记录缺失时不伪造名称。`Seal/Infrastructure/Signing/PortalSigningResult.swift`、`Seal/Core/Apps/AppRecord.swift`、`Seal/Features/Settings/AppleAccountDetailView.swift`、`Seal/Features/Apps/AppDetailView.swift` |
| F17 | 已修：版本检查、确认与提交复用同一覆盖候选，避免拿待安装副本和已安装副本交叉比较。`Seal/Core/Import/ImportWorkflow.swift`、`Seal/Core/Import/ImportDraft.swift` |
| F18 | 已修：原 IPA 丢失或重装接管时允许同版本重新导入；正常健康记录仍按最新版本处理。`Seal/Core/Import/ImportWorkflow.swift`、`Seal/Features/Apps/AppsViewModel.swift` |
| F19 | 已修：加密检查通过 `CFBundleExecutable` 定位 Mach-O，不再用 `.app` 文件夹名猜可执行文件。`Seal/Core/Import/IPAParserService.swift` |
| F20 | 已修：色相滑块方向和 HSV 状态一致，拖动预览不经 HEX 往返丢色相；是否消除实机卡顿须用 Instruments 测量。`Seal/Features/Settings/CustomAccentColorEditor.swift` |
| F21 | 已修：下载 generation/session 隔离进度、取消、失败和旧任务回调。`Seal/Features/UpdateNoticeView.swift` |
| F22 | 已修：更新下载源文件纳入导入事务所有权，确认、取消、失败及重试路径有明确保留/清理。`Seal/App/RootTabView.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Core/Import/ImportWorkflow.swift` |
| F23 | 已修：Core Data 迁移验证或恢复完成前保留备份；`Signed.ipa` 替换有 journal 和启动恢复。强退注入验证待 CI。`Seal/Infrastructure/Persistence/CoreDataAppStore.swift`、`Seal/Infrastructure/Storage/AppFileStore.swift`、`Seal/Core/Recovery/AppRecordRecovery.swift` |
| F24 | 已修：后台续签意图返回“已接收/正在准备”而非未获接纳就声称已开始。iOS 是否唤醒仍受系统调度限制。`Seal/Features/Intents/SealRenewalIntent.swift`、`Seal/Core/Renewal/RefreshPlanner.swift` |
| F25 | 源码清单已与当前声明依赖对齐为 13 项，并明确 AltSign 锁定版本没有许可证文件。**未解决：公开分发权须由权利方/法律依据确认，不能靠改 UI 解决。**`Seal/Features/Settings/OpenSourceLicensesView.swift`、`Seal/Resources/ThirdPartyNotices.txt` |
| F26 | 已修：主 workflow 的 push paths 包含 `Shared/**` 与 `SealLiveActivity/**`。路径触发需 CI 验证。`.github/workflows/ios.yml` |
| F27 | 已修：协议展示/同意版本按产品约定为 1，并处理既有版本迁移。新装与升级提示需实机确认。`Seal/Features/Settings/AgreementOnboardingView.swift` |
| F28 | 已修：keepalive sleep 响应任务取消，不再吞取消后循环；此服务目前没有接入续签业务，不新增调用。`Seal/Infrastructure/Renewal/ProfileOnlyProvisioningProfileInstaller.swift` |
| F29 | 已修：撤销失败保留证书条目，只在 Apple 确认成功后移除。`Seal/Features/Settings/SettingsViewModel.swift` |
| F30 | 已修：P12 外部打开及配对文件导出处理系统返回结果，失败可反馈；打开目标不代表对端已接收。`Seal/Infrastructure/Accounts/CertificateExportHandler.swift`、`Seal/Features/Settings/PairingSettingsView.swift` |
| F31 | 已修：换图/恢复原图与记录写入增加补偿，失败时还原旧文件。设备签后图标待测。`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Infrastructure/Storage/AppFileStore.swift` |
| F32 | 部分完成：读取设备上 `ProfileValidated` 的用户应用并与本地记录/IPA 接管流程关联；未知团队、真实签名者读取与系统级完整发现能力不能由 profile 猜出，需真机继续验证。`Seal/Infrastructure/Installation/DeviceInstalledAppScanner.swift`、`Seal/Core/Recovery/AppRecordRecovery.swift`、`Seal/Core/Recovery/InstalledRecordRecoveryPolicy.swift`、`Seal/Features/Apps/AppsViewModel.swift` |

## V01–V08 外部验证清单

| 编号 | 当前缺少的决定性验证 |
|---|---|
| V01 | 用真实主 App + 多扩展产物比较每个签名 Mach-O、profile、application-identifier 与 App Groups；安装并启动全部扩展。 |
| V02 | 目标 IPA 中 Live Activity `.appex/Assets.car` 含 Seal 图标、设备上图标全彩可见；真实配对码更新、成功/失败终态展示。 |
| V03 | 同一设备在更新/爱思重签前后核对账号容器、Keychain access group 与登录记录。 |
| V04 | 同一次 Apple 响应记录 `availableQuantity`、ID 列表、此次目标数及创建拒绝，解释“8 个却报满”。 |
| V05 | Instruments 采样自定义颜色拖动 CPU/帧时间，并检查切回前台后的全局 trait/主题。 |
| V06 | 真机慢拖、快甩、反向分页及通知冷启动返回路径。 |
| V07 | 大 IPA、磁盘不足、中文显示名、目录名与 `CFBundleExecutable` 不同的真实包。 |
| V08 | 锁屏、强退、权限开关及外部签名情况下后台任务实际触发；系统不承诺任意时刻唤醒。 |

## 验证状态

- `git diff --check`：通过（静态差异检查；不验证 Swift/Rust 语义）。
- Python 错误码目录测试：11 项通过；错误目录测试：9 项通过。它们在本机未隔离环境运行，只作为初步结果，不作为安全审计合格证据。
- Swift/Xcode：本机 Windows 无 Xcode，未编译。
- Rust：本机没有 `cargo fmt` 子命令；先前 `cargo test` 因目标标准库未安装不能执行。
- 按安全审计执行规范，当前环境没有 OS 级测试隔离，故本轮不继续运行项目目标代码。需要 GitHub macOS CI 与真机完成验收。

## 发布阻塞与执行边界

1. `F25`：AltSign pinned revision 无许可证文件；未确认前不能声称公开分发权已解决。
2. `F32`：设备扫描仅能把可核验资料作为已确认事实；未知身份保持未知，不能安全推测证书签名者。
3. `V01–V08`：均需指定真机/Apple 账号/性能工具或 CI；源码逻辑不等于实机通过。
4. 当前没有提交、推送、Release 或 CI 运行；源码基于 `MJorb-0.1.0`，没有使用 `MJorb-CI`。

## 修改文件精确时间

时间使用工作区文件系统的 `LastWriteTime`，格式为北京时间 `yyyy-MM-dd HH:mm:ss`。表中仅列本次跟踪的源码、配置、测试和记录文件；原有未跟踪 `artifacts/` 未列入且未修改。

| 路径 | 修改时间 |
|---|---|
| `.github/workflows/ios.yml` | 2026-10-18 23:22:00 |
| `DEBUG_LOG.md` | 2026-10-19 02:34:03 |
| `docs/qa/generated/error-code-inventory.json` | 2026-10-19 02:25:06 |
| `docs/upstream-alignment.md` | 2026-10-19 02:32:30 |
| `project.yml` | 2026-10-19 02:24:08 |
| `RELEASE_NOTES.md` | 2026-10-19 02:32:43 |
| `Scripts/verify-ipa.sh` | 2026-10-19 02:31:12 |
| `Seal/App/RootTabView.swift` | 2026-10-19 01:01:11 |
| `Seal/Application/AppContainer.swift` | 2026-10-19 01:16:09 |
| `Seal/Core/Apps/AppRecord.swift` | 2026-10-19 02:06:29 |
| `Seal/Core/Apps/PendingSignedSnapshot.swift` | 2026-10-19 01:15:18 |
| `Seal/Core/Concurrency/HardTimeout.swift` | 2026-10-19 01:26:47 |
| `Seal/Core/Import/ImportDraft.swift` | 2026-10-19 00:13:45 |
| `Seal/Core/Import/ImportWorkflow.swift` | 2026-10-19 00:13:45 |
| `Seal/Core/Import/IPAParserService.swift` | 2026-10-19 02:12:22 |
| `Seal/Core/Installation/InstallChannel.swift` | 2026-10-19 01:49:53 |
| `Seal/Core/Recovery/AppRecordRecovery.swift` | 2026-10-19 00:50:21 |
| `Seal/Core/Recovery/InstalledRecordRecoveryPolicy.swift` | 2026-10-19 01:43:19 |
| `Seal/Core/Renewal/ProfileOnlyRenewalRecordUpdater.swift` | 2026-10-19 00:23:53 |
| `Seal/Core/Renewal/RefreshPlanner.swift` | 2026-10-19 01:56:28 |
| `Seal/Core/Renewal/SelfAppRegistrar.swift` | 2026-10-19 00:26:22 |
| `Seal/Core/Renewal/SelfReplacementCoordinator.swift` | 2026-10-19 02:05:00 |
| `Seal/Core/Renewal/SelfReplacementPolicy.swift` | 2026-10-19 00:39:00 |
| `Seal/Core/Signing/AppExtensionProfileStrategy.swift` | 2026-10-19 02:06:29 |
| `Seal/Core/Signing/CertificateRecoveryJournal.swift` | 2026-10-19 01:15:57 |
| `Seal/Core/Signing/IPADeviceCompatibility.swift` | 2026-10-19 02:12:22 |
| `Seal/Core/Signing/SigningCoordinator.swift` | 2026-10-19 02:12:22 |
| `Seal/Core/Signing/SigningTargetRecord.swift` | 2026-10-19 00:22:31 |
| `Seal/Features/Apps/AppDetailView.swift` | 2026-10-19 01:56:28 |
| `Seal/Features/Apps/AppsViewModel.swift` | 2026-10-19 02:24:21 |
| `Seal/Features/Apps/ImportedAppRow.swift` | 2026-10-19 01:33:15 |
| `Seal/Features/Apps/InstalledAppActionSheet.swift` | 2026-10-19 01:56:28 |
| `Seal/Features/Import/ImportConfirmationView.swift` | 2026-10-19 00:15:49 |
| `Seal/Features/Intents/SealRenewalIntent.swift` | 2026-10-19 02:24:21 |
| `Seal/Features/Settings/AgreementOnboardingView.swift` | 2026-10-19 00:40:30 |
| `Seal/Features/Settings/AppleAccountDetailView.swift` | 2026-10-19 00:24:18 |
| `Seal/Features/Settings/CustomAccentColorEditor.swift` | 2026-10-18 23:46:07 |
| `Seal/Features/Settings/OpenSourceLicensesView.swift` | 2026-10-19 00:42:38 |
| `Seal/Features/Settings/PairingSettingsView.swift` | 2026-10-19 00:40:30 |
| `Seal/Features/Settings/SettingsViewModel.swift` | 2026-10-19 01:59:08 |
| `Seal/Features/UpdateNoticeView.swift` | 2026-10-19 01:01:01 |
| `Seal/Infrastructure/Accounts/AppleAccountClient.swift` | 2026-10-19 01:36:33 |
| `Seal/Infrastructure/Accounts/CertificateExportHandler.swift` | 2026-10-19 00:40:30 |
| `Seal/Infrastructure/Installation/BlockingCall.swift` | 2026-10-19 01:10:40 |
| `Seal/Infrastructure/Installation/DeviceInstalledAppScanner.swift` | 2026-10-19 00:58:17 |
| `Seal/Infrastructure/Installation/DeviceProfileInspector.swift` | 2026-10-19 01:50:02 |
| `Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift` | 2026-10-19 01:50:11 |
| `Seal/Infrastructure/Pairing/PairingLiveActivityController.swift` | 2026-10-19 02:03:40 |
| `Seal/Infrastructure/Pairing/PhonePairingHost.swift` | 2026-10-18 23:29:25 |
| `Seal/Infrastructure/Persistence/CoreDataAppStore.swift` | 2026-10-18 23:23:37 |
| `Seal/Infrastructure/Renewal/ProfileOnlyProvisioningProfileInstaller.swift` | 2026-10-19 01:50:49 |
| `Seal/Infrastructure/Signing/ApplePortalSigningService.swift` | 2026-10-19 02:28:24 |
| `Seal/Infrastructure/Signing/PortalSigningResult.swift` | 2026-10-19 00:22:31 |
| `Seal/Infrastructure/Signing/SigningWorkspace.swift` | 2026-10-19 00:04:15 |
| `Seal/Infrastructure/Storage/AppFileStore.swift` | 2026-10-18 23:36:03 |
| `Seal/Resources/ThirdPartyNotices.txt` | 2026-10-19 00:42:38 |
| `SealLiveActivity/PairingLiveActivityWidget.swift` | 2026-10-19 02:30:02 |
| `SealTests/Concurrency/HardTimeoutTests.swift` | 2026-10-19 01:13:42 |
| `SealTests/Import/Fixtures/IPAArchiveFixture.swift` | 2026-10-18 23:45:30 |
| `SealTests/Import/IPAParserServiceTests.swift` | 2026-10-19 00:05:10 |
| `SealTests/Import/ImportWorkflowTests.swift` | 2026-10-19 00:15:02 |
| `SealTests/Installation/InstallChannelDiagnosticClassificationTests.swift` | 2026-10-18 23:22:00 |
| `SealTests/Persistence/ModelMigrationTests.swift` | 2026-10-18 23:23:37 |
| `SealTests/Recovery/InstalledRecordRecoveryPolicyTests.swift` | 2026-10-19 01:43:19 |
| `SealTests/Renewal/ProfileOnlyOperationLeaseTests.swift` | 2026-10-19 01:51:20 |
| `SealTests/Renewal/RefreshPlannerTests.swift` | 2026-10-19 01:56:45 |
| `SealTests/Renewal/SelfAppRegistrarTests.swift` | 2026-10-19 02:08:56 |
| `SealTests/Renewal/SelfReplacementCoordinatorTests.swift` | 2026-10-19 02:05:00 |
| `SealTests/Settings/AgreementVersionTests.swift` | 2026-10-19 00:42:38 |
| `SealTests/Settings/AppleAccountAppNamePolicyTests.swift` | 2026-10-19 00:24:59 |
| `SealTests/Signing/AppExtensionProfileStrategyTests.swift` | 2026-10-19 02:06:05 |
| `SealTests/Signing/CertificateRecoveryJournalTests.swift` | 2026-10-19 01:24:16 |
| `SealTests/Signing/IPADeviceCompatibilityTests.swift` | 2026-10-19 02:12:22 |
| `SealTests/Signing/PendingSignedSnapshotMigrationTests.swift` | 2026-10-19 01:24:16 |
| `SealTests/Storage/AppFileStoreTests.swift` | 2026-10-18 23:37:15 |
| `upstream/AltSign/Sources/Model/ALTApplication.swift` | 2026-10-18 23:56:59 |
| `Vendor/Minimuxer/RustBridge/Cargo.toml` | 2026-10-19 00:45:06 |
| `Vendor/Minimuxer/RustBridge/MinimuxerBridge.swift` | 2026-10-19 00:45:29 |
| `Vendor/Minimuxer/RustBridge/MinimuxerBridgeIdevice.swift` | 2026-10-19 00:45:29 |
| `Vendor/Minimuxer/RustBridge/src/bridge.rs` | 2026-10-19 00:45:06 |
| `Vendor/Minimuxer/RustBridge/src/bridge_idevice.rs` | 2026-10-19 00:45:06 |
| `Vendor/Minimuxer/RustBridge/src/idevice_support/install.rs` | 2026-10-19 00:45:06 |
| `Vendor/Minimuxer/RustBridge/src/phone_pairing.rs` | 2026-10-18 23:33:09 |
| `Vendor/Minimuxer/Sources/Minimuxer.swift` | 2026-10-19 00:45:29 |
| `Vendor/SideSign/Sources/CodeSigning/CodeSignerAPI.swift` | 2026-10-19 02:19:35 |
| `Vendor/SideSign/Sources/Models/AppBundle.swift` | 2026-10-19 02:22:40 |
| `Vendor/SideSign/Tests/SideSignTests/AppBundleEntitlementReadTests.swift` | 2026-10-19 02:22:49 |
