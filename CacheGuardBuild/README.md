# 清存 CacheGuard — iOS 缓存清理器

当前版本：**0.2.0（AirLift 配对开发版 / 未编译 SwiftUI 源码）**

面向 iOS 27.0.1 的第二阶段开发项目。本版本引入 AirLift 原生库和配对诊断，最低部署目标提升至 iOS 18.0。

## 能做什么

- 扫描并清理 **本应用自己的** Caches 和 tmp 文件。
- 通过 iOS 系统文件选择器手动授权一个文件夹，寻找其中明显的缓存目录（Caches / Cache / tmp / thumbnails 等）。
- 在真正删除前预览候选文件数、估算大小，手动勾选清理范围，并进行第二次确认。
- 拒绝路径越界、跳过符号链接和数据库等类型；删除前再次核对文件大小和修改时间。扫描不完整时禁用该范围的批量清理。
- 显示权限诊断、跳过项与失败项。扫描大小不等于实际释放的空间。
- **AirLift 真配对**：通过 Bonjour 广播本机 RPPairing 服务，在 iOS 27 设置的开发者模式页面完成 PIN 配对；支持导入已有配对文件。
- **设备服务诊断**：配置 LocalDevVPN 地址，并通过 AirLift 原生库只读查询指定 Bundle ID 对应的 App 数据容器。

## 目前不能做什么

- **尚不能自动清理微信、抖音、Telegram 等其他 App 的私有缓存目录。** 但已开始接入 AirLift 配对与容器查询。
- **不能清理 iOS 系统数据中的任意目录。**
- 不能仅凭侧载、企业证书、开发者模式或配对成功推断获得越权删除权限。AirLift 的实际能力要在真机验证。
- 不能承诺零风险清理用户手动选择的文件夹（离线内容可能存于缓存目录）。

这些限制会在 UI 中直观显示，软件不会伪造“深度清理成功”结果。

## 在 Mac 上生成 IPA

要求：macOS、**Xcode 27 或更高版本**、XcodeGen、可用于设备安装的签名身份，且本源码已携带 AirLift FFI XCFramework。

1. 安装 XcodeGen：`brew install xcodegen`
2. 在本项目根目录运行：`xcodegen generate`
3. 用 Xcode 打开 `CacheGuard.xcodeproj`，在 Signing & Capabilities 选择你自己的 Team，修改 `com.example.cacheguard` 为自己的唯一 Bundle ID。
4. 连接 iPhone，先运行 Debug 构建并测试扫描和确认弹窗。
5. 需要 IPA 时，在 Xcode 中 Product → Archive → Distribute App 导出，或使用 `scripts/build-ipa.sh`（需设置 `DEVELOPMENT_TEAM`）。

直接使用脚本：

```bash
export DEVELOPMENT_TEAM=你的TeamID
bash scripts/build-ipa.sh
```

部分签名类型可能不支持通过 `development` 导出 IPA，需根据证书和 Xcode 版本调整 `scripts/ExportOptions.plist`。安装方式由你自己的签名决定。

## 测试

Mac 生成工程后，在 Xcode 中运行 `CacheGuardTests`，或：

```bash
xcodebuild -project CacheGuard.xcodeproj -scheme CacheGuard -destination 'platform=iOS Simulator,name=iPhone 17' test
```

如本机模拟器名称不同，替换 `name`。测试覆盖基础路径边界、目录匹配与数据库排除；还需要在真实 iOS 27.0.1 设备验证 File Provider 授权、文件协调和删除反馈。

## 将来的跨 App 后端

`PrivilegedCleanerBridge` 是明确关闭的接口。只有在**同一 iOS 构建号、机型和实际签名模式**上验证可读写权限后，才考虑独立启用：

1. 只读能力探测（不改动目标文件）。
2. 每个第三方 App 单独列出候选项和可恢复性说明。
3. 备份、白名单、预览、确认、文件变化复核、失败回滚。
4. 明确禁止聊天数据库、账号信息、系统关键配置等高风险路径。

本项目未复制 3105/Erosion 或 AirBeep 主项目（GPLv3）的 Swift 源码；使用 MIT 许可的 AirLift 原生库，许可证已随附。详细配对流程和兼容性见 [AIRLIFT.md](AIRLIFT.md)。

## 源码结构

- `CacheGuard/ContentView.swift`：中文界面。
- `CacheGuard/CleanerViewModel.swift`：扫描与清理的 UI 状态。
- `CacheGuard/CachePolicy.swift`：候选文件与路径安全策略。
- `CacheGuard/LocalCleaner.swift`：公开 API 的实际扫描与删除实现。
- `CacheGuard/PrivilegedCleanerBridge.swift`：未启用的高级权限接口。
- `CacheGuard/AirLift/`：本机配对、信任文件私有存储、VPN 配置与只读容器查询。
- `Vendor/AirCard/AirliftFFI.xcframework`：AirLift FFI 原生库（MIT 许可）。
- `CacheGuardTests/CachePolicyTests.swift`：路径与数据安全测试。
- `project.yml`：XcodeGen 工程配置。

**注意：本环境没有 macOS/Xcode，因此本次没有生成经过编译、签名或真机验证的 IPA。**
