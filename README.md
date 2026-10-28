# IOSurface 访问检测 App（非漏洞触发器）

这是一个可供 Xcode 编译的原生 iPhone App 项目。它只测试普通开发者签名的 App 能否发现并打开 IOSurface 相关 IOKit 服务。**不会**调用外部方法、构造竞态、执行内核读写、修改签名或者安装 IPA。

## 如何在 iPhone 16 Pro / iOS 27.0.1 上运行

1. 在 Mac 上安装能识别你设备系统版本的 Xcode，打开 IOSurfaceReachabilityProbe.xcodeproj。
2. 选中 IOSurfaceReachabilityProbe target，在 Signing & Capabilities 选择你自己的开发团队。必要时修改 Bundle Identifier，保持 Xcode 默认普通签名，**不要添加特殊 entitlement**。
3. 用数据线连接 iPhone 16 Pro；如提示则在手机上启用开发者模式。选中设备后点 Run。
4. 打开 App，点击“检测服务”，再点击“复制结果”，把全文发回本对话。

## 测了什么

- 使用 IOKit.framework 的标准匹配函数分别探测 IOSurfaceRoot 和 IOCoreSurfaceRoot 两种标识，并区分 class matching / service-name matching。
- 对找到的服务尝试标准的 IOServiceOpen(type=0)；无论成功与否都立即释放查询对象，成功时再关闭连接。
- 记录系统版本、服务是否可见及完整内核返回码（例如 0x00000000）。
- 没有外部方法调用、竞态压力测试或异常参数。

## 怎么解释

- Service visible + OPEN ALLOWED：这个具体开发者签名的 App 能打开某个匹配到的服务（**完成普通 App 可打开性的动态确认**）。但需要进一步识别服务是否对应内核静态分析的具体 UserClient。
- Service not visible：服务可能不存在、名字不匹配或被沙箱隐藏；**不能反推出 App 权限一定不足**。
- 服务打开返回错误：需要结合返回码和设备日志进一步分析，不代表所有 IOSurface 公共 API 都不可用。
- 服务能打开 ≠ 能调用任意外部 selector ≠ 漏洞可触发 ≠ 能做内核读写 ≠ 永久签名。

## 现实限制

当前研究环境不是 Mac，没有 Xcode/iOS SDK，也没有连接你的 iPhone。因此这是**源码与可打开的 Xcode 项目**，不是已编译并验证的 IPA。还必须由你或受信任的 Mac 编译、用正常开发者证书签名并在设备运行，才有实测结论。

### Windows 用户可选：GitHub Actions 构建

项目自带 .github/workflows/build-unsigned.yml。把项目文件放在你自己的 GitHub 仓库**根目录**，打开 Actions，手动运行 Build unsigned iPhone diagnostic；运行完成后下载 IOSurfaceReachabilityProbe-unsigned 构建产物。云端 macOS runner 会尝试构建一个未签名 IPA（其可编译性尚未经实际 CI 运行验证）。你仍须通过正规的开发者证书、有效 provisioning profile 和常规安装工具完成签名安装。未签名 IPA 不能直接安装，正常开发者签名也不是永久签名。

注意：IOKit 接口和动态符号访问可能受 App Store 审核和系统沙箱限制。这份代码供个人授权研究及开发者签名测试，不以 App Store 上架为目标。
