# 2026-10-18 功能闭环追踪

记录生成时间：2026-10-18T07:53:11+08:00；版本号更新至 `0.1.2`：2026-10-18T09:18:01+08:00

这份记录只列出本次核对后实际存在的代码与本次新增修改，供后续通过路径和时间快速定位。

| 问题 | 结论 | 路径 | 最后修改时间 |
| --- | --- | --- | --- |
| 签名失败后没有“撤销并继续签名” | `204b/204e` 进入撤销选择和二次确认；`204f/204g` 只允许重新读取候选列表，避免错误撤销 | `Seal/Core/Signing/CertificateRequestFailurePolicy.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Apps/SigningProgressView.swift`、`Scripts/verify-release-safety.py` | 2026-10-18T08:21:36+08:00、2026-10-18T08:21:51+08:00 |
| 待安装 / 已安装分组标签 | 现有等宽标签和毛毛虫指示器保留；本次将分页改为连续拖动进度，手指移动时下划线同步伸缩，松手按预测位移吸附到最近页，点击标签同步切页 | `Seal/Features/Apps/AppsRootView.swift`、`Seal/DesignSystem/CaterpillarSegmentedTabs.swift` | 本次 `AppsRootView.swift` 修改时间见下方“最终文件时间”；组件既有：2026-10-17T09:45:10+08:00 |
| 检查更新总是显示失败 | 已区分无 Release、GitHub 限流、服务错误、无效发布和网络错误；当前仓库实际返回 404，属于“暂未发布可用更新”。入口右侧不再固定写“检查失败”，改为对应原因 | `Seal/Infrastructure/UpdateChecker.swift`、`Seal/Features/Settings/AboutView.swift` | 2026-10-18T07:49:26+08:00、2026-10-18T08:00:09+08:00 |
| Apple ID > 已签名 App 信息不全 | 每项现在明确显示应用名称、Apple 返回的 App ID、Bundle ID、有效期至 | `Seal/Features/Settings/AppleAccountDetailView.swift` | 2026-10-18T07:49:44+08:00 |
| 已安装应用详情没有按定稿显示 | 已改为 App ID、Bundle ID、有效期至，移除描述文件创建时间 | `Seal/Features/Apps/AppDetailView.swift` | 2026-10-18T07:48:07+08:00 |
| 灵动岛图标和通知返回 | Live Activity 已有四个状态和锁屏展示；本次为 Seal 图标加入资源缺失兜底。配对码通知改为只做回退展示，点击不再强制切 SwiftUI 路由，避免通知点击闪退 | `SealLiveActivity/PairingLiveActivityWidget.swift`、`Seal/Infrastructure/Pairing/PairingCodeNotification.swift`、`Seal/Infrastructure/Notifications/SealNotificationPresenter.swift`、`Seal/App/RootTabView.swift` | 2026-10-18T07:51:51+08:00、2026-10-18T07:53:04+08:00 |
| 签名失败阶段被误标 | 申请描述文件前显式切换为 `provisioningProfile` 阶段，使后续失败按实际环节分类，不会被误写成 App ID 错误 | `Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、`Scripts/tests/test_failure_contract_source.py` | 2026-10-18T07:54:31+08:00 |

## 实机约束

`Seal-log(23).txt` 显示当前安装包的 `SealLiveActivity.appex` 缺少 `embedded.mobileprovision`。这代表第三方工具没有完整签好扩展；该情况下 iOS 不会加载 Live Activity 扩展。必须使用能为主 App 和 `SealLiveActivity.appex` 都嵌入描述文件并签名的安装方式，源码不能绕过 iOS 的扩展签名验证。

## 验证范围

- 源码差异检查：`git diff --check`
- 单元测试已覆盖证书名额错误进入撤销恢复集，以及 Release HTTP 状态分类。
- 本地 49 项源码契约测试通过；Swift 编译与 IPA 内容须由本次最新 GitHub Actions run 验证。

## 最终文件时间

精确修改时间统一使用工作区文件系统记录的 `Asia/Shanghai` 时区，到秒；删除文件用包含删除的提交时间记录。

| 路径 | 修改时间 |
| --- | --- |
| `Seal/Core/Signing/CertificateRequestFailurePolicy.swift` | 2026-10-18T08:21:36+08:00 |
| `Seal/Features/Apps/AppsRootView.swift` | 2026-10-18T09:11:26+08:00 |
| `Seal/Features/Apps/AppsViewModel.swift` | 2026-10-18T07:48:07+08:00 |
| `Seal/Features/Apps/SigningProgressView.swift` | 2026-10-18T08:21:36+08:00 |
| `Seal/Features/Apps/AppDetailView.swift` | 2026-10-18T07:48:07+08:00 |
| `Seal/Features/Settings/AboutView.swift` | 2026-10-18T08:00:09+08:00 |
| `Seal/Features/Settings/AppleAccountDetailView.swift` | 2026-10-18T07:49:44+08:00 |
| `Seal/Infrastructure/Signing/ApplePortalSigningService.swift` | 2026-10-18T07:54:31+08:00 |
| `Seal/Infrastructure/UpdateChecker.swift` | 2026-10-18T07:49:26+08:00 |
| `Seal/Infrastructure/Pairing/PairingCodeNotification.swift` | 2026-10-18T07:56:55+08:00 |
| `Seal/Infrastructure/Notifications/SealNotificationPresenter.swift` | 2026-10-18T07:53:04+08:00 |
| `Seal/App/RootTabView.swift` | 2026-10-18T07:53:04+08:00 |
| `SealLiveActivity/PairingLiveActivityWidget.swift` | 2026-10-18T07:51:51+08:00 |
| `Scripts/tests/test_failure_contract_source.py` | 2026-10-18T07:54:31+08:00 |
| `Scripts/verify-release-safety.py` | 2026-10-18T08:21:51+08:00 |
| `SealTests/Signing/CertificateRequestFailurePolicyTests.swift` | 2026-10-18T07:49:51+08:00 |
| `SealTests/Update/UpdateCheckerAssetTests.swift` | 2026-10-18T07:49:58+08:00 |
| `docs/qa/generated/error-code-inventory.json` | 2026-10-18T09:11:33+08:00 |
| `.github/workflows/ios.yml` | 2026-10-18T08:47:21+08:00 |
| `project.yml`（主 App 与 Live Activity 版本 `0.1.1` → `0.1.2`） | 2026-10-18T09:18:01+08:00 |
| `RELEASE_NOTES.md`（新增 `0.1.2` 更新说明） | 2026-10-18T09:18:01+08:00 |
| `SealTests/Notifications/PairingCodeNotificationRouteTests.swift` (删除) | 2026-10-18T08:02:16+08:00（删除提交） |

追踪文档本身以文件系统的最终写入时间为准；修改完成后读取该文件的 `LastWriteTime`。
