# App Clip 签名支持核查

## 当前状态

Seal 尚不支持保留并重签 App Clip。签名工作区检测到非空 AppClips 时会停止；不能仅移除这道检查，否则 App Clip 无独立描述文件、Bundle ID 和权限匹配，可能生成无法安装或关联错误的包。

用户提供的微信、彩云天气、飓风相机三个 IPA 均未发现 AppClips 下的文件。已用 Apple 官方 Fruta 工程构建未签名设备 IPA，确认真实结构为主 app 内的 AppClips/Fruta iOS Clip.app；该样本不包含有效描述文件，不能替代真实签名或设备测试。

## 实现前提

1. 识别主应用下 AppClips 中的 app 及其子组件，与普通扩展区分。
2. 为主应用及 App Clip 分别处理 Bundle ID、签名权限和匹配的描述文件；更新双方关联标识并核验授权，不得复用不匹配的描述文件。
3. 确保 CodeSignKit 按子组件到父组件的顺序签名，签后逐目标核对 ID、描述文件及权限。
4. 根据账户实际可用能力处理 Apple 门户拒绝，失败时保留原始包，不得伪装为成功或删除 App Clip。
5. 在有权限的真实样本和设备上验证签名、安装、续签与 App Clip 唤起。扫码等线上入口还依赖网站关联和 Apple 的配置，换签后原站点不一定授权新的团队和标识。可通过 Apple 支持的本地体验进行开发测试。

## 参考

- https://developer.apple.com/documentation/xcode/changing-the-bundle-identifier
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.associated-appclip-app-identifiers
- https://developer.apple.com/documentation/appclip/associating-your-app-clip-with-your-website
- https://developer.apple.com/documentation/appclip/testing-the-launch-experience-of-your-app-clip
