# 2026-10-18 功能闭环追踪

记录生成时间：2026-10-18T07:53:11+08:00；版本号依次更新至 `0.1.2`（09:18:01）、`0.1.3`（09:37:05）、`0.1.4`（09:43:55）、`0.1.5`（09:56:35）和 `0.1.6`（本轮），均为 +08:00。

这份记录只列出本次核对后实际存在的代码与本次新增修改，供后续通过路径和时间快速定位。

| 问题 | 结论 | 路径 | 最后修改时间 |
| --- | --- | --- | --- |
| 签名失败后没有“撤销并继续签名” | `204b/204e` 进入撤销选择和二次确认；`204f/204g` 只允许重新读取候选列表，避免错误撤销 | `Seal/Core/Signing/CertificateRequestFailurePolicy.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Apps/SigningProgressView.swift`、`Scripts/verify-release-safety.py` | 2026-10-18T08:21:36+08:00、2026-10-18T08:21:51+08:00 |
| 待安装 / 已安装分组标签 | 改为系统横向分页滚动；按实际滚动偏移连续驱动毛毛虫下划线。CI #18 发现自定义拖动手势在嵌套列表中无法可靠滑回待安装页，0.1.3 已改用原生分页滚动 | `Seal/Features/Apps/AppsRootView.swift`、`Seal/DesignSystem/CaterpillarSegmentedTabs.swift`、`SealUITests/ImportFlowUITests.swift` | `AppsRootView.swift` 与 UI 测试于 2026-10-18T09:36:59+08:00 修正；组件既有：2026-10-17T09:45:10+08:00 |
| 检查更新总是显示失败 | 已区分无 Release、GitHub 限流、服务错误、无效发布和网络错误；当前仓库实际返回 404，属于“暂未发布可用更新”。入口右侧不再固定写“检查失败”，改为对应原因 | `Seal/Infrastructure/UpdateChecker.swift`、`Seal/Features/Settings/AboutView.swift` | 2026-10-18T07:49:26+08:00、2026-10-18T08:00:09+08:00 |
| Apple ID > 已签名 App 信息不全 | 每项现在明确显示应用名称、Apple 返回的 App ID、Bundle ID、有效期至 | `Seal/Features/Settings/AppleAccountDetailView.swift` | 2026-10-18T07:49:44+08:00 |
| 已安装应用详情没有按定稿显示 | 已改为 App ID、Bundle ID、有效期至，移除描述文件创建时间 | `Seal/Features/Apps/AppDetailView.swift` | 2026-10-18T07:48:07+08:00 |
| 灵动岛图标和通知返回 | Live Activity 已有四个状态和锁屏展示；本次为 Seal 图标加入资源缺失兜底。配对码通知改为只做回退展示，点击不再强制切 SwiftUI 路由，避免通知点击闪退 | `SealLiveActivity/PairingLiveActivityWidget.swift`、`Seal/Infrastructure/Pairing/PairingCodeNotification.swift`、`Seal/Infrastructure/Notifications/SealNotificationPresenter.swift`、`Seal/App/RootTabView.swift` | 2026-10-18T07:51:51+08:00、2026-10-18T07:53:04+08:00 |
| 签名失败阶段被误标 | 申请描述文件前显式切换为 `provisioningProfile` 阶段，使后续失败按实际环节分类，不会被误写成 App ID 错误 | `Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、`Scripts/tests/test_failure_contract_source.py` | 2026-10-18T07:54:31+08:00 |
| 爱思安装的 Seal 无法自签、无法识别现有证书 | 读取不到嵌入描述文件时仍保留 Mach-O CMS 实际签名证书序列号；Seal 的“撤销并继续签名”只显示并预选当前 Seal 实际签名证书，标记为“当前 Seal 证书”，二次确认后撤销并继续签名。自动清理仍不会静默撤销 Seal 证书 | `Seal/Core/Renewal/SelfSigningIdentity.swift`、`Seal/Infrastructure/Renewal/AppBundleSigningIdentityReader.swift`、`Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Features/Apps/CertificateSacrificePickerView.swift`、`Seal/Features/Settings/SettingsViewModel.swift` | 2026-10-18（见下方文件系统精确时间表） |
| 关于页无更新时反复请求 | 关于页不再每次打开自动请求；首次状态显示“已是最新版”，启动自动检查成功后 12 小时内不重复，失败后 5 分钟再自动试；用户手动点击仍立即检查。Release API 404 作为当前没有正式 Release 处理为“已是最新版” | `Seal/App/RootTabView.swift`、`Seal/Features/Settings/AboutView.swift`、`Seal/Infrastructure/UpdateChecker.swift`、`SealTests/Update/UpdateCheckerAssetTests.swift` | 2026-10-18（见下方文件系统精确时间表） |
| 待安装 / 已安装字体粗细闪变 | 标签固定为 semibold 字重，滑动仍只驱动颜色和下划线动画 | `Seal/DesignSystem/CaterpillarSegmentedTabs.swift` | 2026-10-18（见下方文件系统精确时间表） |
| 自定义颜色拖动卡顿、主题抽屉未隐藏 | 取色器打开时让主题抽屉内容隐藏；完成关闭两层，取消恢复主题抽屉；拖动预览移除对整个 RootTabView 的销毁重建 | `Seal/Features/Settings/SettingsRootView.swift`、`Seal/Features/Settings/CustomAccentColorEditor.swift`、`Seal/App/RootTabView.swift` | 主题抽屉既有代码；RootTabView 于本轮修改（见下方文件系统精确时间表） |
| 灵动岛图标缺失、状态文案被裁切 | Live Activity 扩展单独打包 Seal 图标资源；状态短文案收紧宽度 | `SealLiveActivity/Assets.xcassets/SealBrandIcon.imageset/`、`SealLiveActivity/PairingLiveActivityWidget.swift`、`project.yml` | 2026-10-18（见下方文件系统精确时间表） |
| 待安装 / 已安装滑动回页失败 | CI #18 发现自定义分页手势无法稳定回到待安装；改用系统原生分页滚动并按实际滚动偏移驱动下划线 | `Seal/Features/Apps/AppsRootView.swift`、`SealUITests/ImportFlowUITests.swift` | `c2dac5c`；待本次 CI 回归确认 |

## 证书事实与自签路径

Apple 官方说明开发证书属于个人；开发者账号并非“一 ID 永远一本证书”，个人开发者账户可有两张 iOS Development 证书。当前自签恢复直接定位 Seal 主程序 Mach-O 的真实 CMS 签名者；Seal 的撤销候选只给这张证书，避免撤销了别的证书却没解决自签问题。用户二次确认后撤销并继续创建本机证书、签名和覆盖安装。Apple 说明撤销证书会使包含该证书的 provisioning profile 失效，因此只保留这次实际撤销所需的确认，不再额外要求用户手动挑选其他证书。参考：[Certificates overview](https://developer.apple.com/help/account/certificates/certificates-overview/)、[Revoke a certificate](https://developer.apple.com/help/account/certificates/revoke-a-certificate/)。

## 实机约束

`Seal-log(23).txt` 显示当前安装包的 `SealLiveActivity.appex` 缺少 `embedded.mobileprovision`。这代表第三方工具没有完整签好扩展；该情况下 iOS 不会加载 Live Activity 扩展。必须使用能为主 App 和 `SealLiveActivity.appex` 都嵌入描述文件并签名的安装方式，源码不能绕过 iOS 的扩展签名验证。

## 验证范围

- 源码差异检查：`git diff --check`
- 单元测试已覆盖：第三方签名包描述文件缺失时保留真实签名者、清理策略仍保护真实 Seal 签名者、Release API 404 显示最新版，以及其他 HTTP 错误分类。
- 本地 49 项源码契约测试通过；Swift 编译与 IPA 内容须由本次最新 GitHub Actions run 验证。
- CI #18 的 `testTwoStageNavigationSupportsHorizontalSwipe` 发现向右滑回待安装页失败；0.1.3 修复后须由下一轮 CI 回归复验。

## 最终文件时间

精确修改时间统一使用工作区文件系统记录的 `Asia/Shanghai` 时区，到秒；删除文件用包含删除的提交时间记录。

| 路径 | 修改时间 |
| --- | --- |
| `Seal/Core/Signing/CertificateRequestFailurePolicy.swift` | 2026-10-18T08:21:36+08:00 |
| `Seal/Features/Apps/AppsRootView.swift` | 2026-10-18T09:36:59+08:00 |
| `SealUITests/ImportFlowUITests.swift` | 2026-10-18T09:36:59+08:00 |
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
| `project.yml`（主 App 与 Live Activity 版本 `0.1.2` → `0.1.3`） | 2026-10-18T09:37:05+08:00 |
| `RELEASE_NOTES.md`（新增 `0.1.3` 更新说明） | 2026-10-18T09:37:05+08:00 |
| `SealTests/Notifications/PairingCodeNotificationRouteTests.swift` (删除) | 2026-10-18T08:02:16+08:00（删除提交） |

CI #19（提交 `22737e9`）在 Swift 构建前由发布守卫失败：守卫用旧的单行函数签名查找证书候选方法，并强制要求排除 Seal 当前签名者，与本轮已确认的显式自签恢复设计冲突。`Scripts/verify-release-safety.py` 已改为识别多行函数定义、验证 Seal 仅针对当前签名证书并保留二次确认；同时明确自动清理仍保护当前 Seal 证书，显式自签恢复可由用户确认后撤销它。下一次 CI 应验证完整守卫和构建。

### 0.1.4 本轮改动文件时间

以下为本轮实际修改文件的 `Asia/Shanghai` 文件系统时间，精确到秒。

| 路径 | 修改时间 |
| --- | --- |
| `RELEASE_NOTES.md` | 2026-10-18T09:46:50+08:00 |
| `Seal/App/RootTabView.swift` | 2026-10-18T09:43:10+08:00 |
| `Seal/Core/Renewal/SelfSigningIdentity.swift` | 2026-10-18T09:42:35+08:00 |
| `Seal/Core/Signing/CertificateCleanupPolicy.swift` | 2026-10-18T09:51:10+08:00 |
| `Seal/Core/Signing/SigningCoordinator.swift` | 2026-10-18T09:50:17+08:00 |
| `Seal/DesignSystem/CaterpillarSegmentedTabs.swift` | 2026-10-18T09:44:25+08:00 |
| `Seal/Features/Apps/AppsViewModel.swift` | 2026-10-18T09:45:28+08:00 |
| `Seal/Features/Apps/CertificateSacrificePickerView.swift` | 2026-10-18T09:52:11+08:00 |
| `Seal/Features/Settings/AboutView.swift` | 2026-10-18T09:43:42+08:00 |
| `Seal/Features/Settings/SettingsViewModel.swift` | 2026-10-18T09:43:10+08:00 |
| `Seal/Infrastructure/Renewal/AppBundleSigningIdentityReader.swift` | 2026-10-18T09:42:35+08:00 |
| `Seal/Infrastructure/Signing/ApplePortalSigningService.swift` | 2026-10-18T09:45:28+08:00 |
| `Seal/Infrastructure/UpdateChecker.swift` | 2026-10-18T09:50:35+08:00 |
| `SealLiveActivity/Assets.xcassets/SealBrandIcon.imageset/Contents.json` | 2026-10-17T18:57:15+08:00 |
| `SealLiveActivity/Assets.xcassets/SealBrandIcon.imageset/icon.png` | 2026-10-17T18:57:15+08:00 |
| `SealLiveActivity/PairingLiveActivityWidget.swift` | 2026-10-18T09:42:35+08:00 |
| `SealTests/Renewal/AppBundleSigningIdentityReaderTests.swift` | 2026-10-18T09:43:42+08:00 |
| `SealTests/Signing/CertificateCleanupPolicyTests.swift` | 2026-10-18T09:51:10+08:00 |
| `SealTests/Update/UpdateCheckerAssetTests.swift` | 2026-10-18T09:52:40+08:00 |
| `project.yml` | 2026-10-18T09:43:55+08:00 |

### 0.1.5 CI 守卫修复时间

| 路径 | 修改时间 |
| --- | --- |
| `Scripts/verify-release-safety.py` | 2026-10-18T09:56:21+08:00 |
| `project.yml`（0.1.4 → 0.1.5） | 2026-10-18T09:56:35+08:00 |
| `RELEASE_NOTES.md`（新增 0.1.5） | 2026-10-18T09:56:35+08:00 |
| `Seal/Core/Renewal/SealRenewalPolicy.swift` | 2026-10-18T09:57:19+08:00 |
| `Seal/Core/Signing/SigningCoordinator.swift`（注释明确显式自签恢复入口） | 2026-10-18T09:57:19+08:00 |
| `Scripts/verify-release-safety.py`（更新自签恢复断言） | 2026-10-18T09:57:19+08:00 |

CI #20 的 Swift 回归编译发现原生分页 `AppPagerOffsetPreferenceKey.defaultValue` 声明为可变静态属性，Swift 并发检查拒绝编译。改为不可变静态常量；版本升至 0.1.6，等待下一轮云端回归和 IPA 构建。

| 路径 | 修改时间 |
| --- | --- |
| `Seal/Features/Apps/AppsRootView.swift` | 2026-10-18T10:09:29+08:00 |
| `project.yml`（0.1.5 → 0.1.6） | 2026-10-18T10:09:29+08:00 |
| `RELEASE_NOTES.md`（新增 0.1.6） | 2026-10-18T10:09:29+08:00 |

追踪文档本身以文件系统的最终写入时间为准；修改完成后读取该文件的 `LastWriteTime`。

CI #22 的 Swift 回归发现证书恢复候选的 `recommendedSerialNumber` getter 在优先返回 Seal 当前证书后，后续排序表达式缺少 `return`。补上显式返回；版本升至 0.1.7，重新运行云端 CI。

| 路径 | 修改时间 |
| --- | --- |
| `Seal/Features/Apps/CertificateSacrificePickerView.swift` | 2026-10-18T10:29:38+08:00 |
| `project.yml`（0.1.6 → 0.1.7） | 2026-10-18T10:29:38+08:00 |
| `RELEASE_NOTES.md`（新增 0.1.7） | 2026-10-18T10:29:38+08:00 |
