# IOSurface 访问检测 App（非漏洞触发器）

这是一个可供 Xcode 编译的原生 iPhone App 项目。v1.3 在先前已真机验证的服务可见性／服务打开检查之上，增加**本 App 实际签名权限**和**连接归属的只读元数据**诊断。**不会**调用外部方法、构造竞态、执行内核读写、修改签名或者安装 IPA。

## 如何在 iPhone 16 Pro / iOS 27.0.1 上运行

1. 在 Mac 上安装能识别你设备系统版本的 Xcode，打开 IOSurfaceReachabilityProbe.xcodeproj。
2. 选中 IOSurfaceReachabilityProbe target，在 Signing & Capabilities 选择你自己的开发团队。必要时修改 Bundle Identifier，保持 Xcode 默认普通签名，**不要添加特殊 entitlement**。
3. 用数据线连接 iPhone 16 Pro；如提示则在手机上启用开发者模式。选中设备后点 Run。
4. 打开 App，点击“检测服务”，再点击“复制结果”，把全文发回本对话。

## 测了什么

- 使用 IOKit.framework 的标准匹配函数分别探测 IOSurfaceRoot 和 IOCoreSurfaceRoot 两种标识，并区分 class matching / service-name matching。
- 对找到的服务尝试标准的 IOServiceOpen(type=0)；无论成功与否都立即释放查询对象，成功时再关闭连接。
- 记录系统版本、服务是否可见及完整内核返回码（例如 0x00000000）。
- 1.1 版还通过只读接口 IOObjectGetClass、IORegistryEntryGetRegistryEntryID 查询服务实际类名和注册表对象 ID，以判断不同匹配方式是否命中同一服务。
- 1.3 版通过 Security 的 SecTask 查询**当前 App 自身**是否带有四项 IOSurface/GPU 相关 entitlement，特别是影响普通／受限方法表选择的 `com.apple.private.gpu-restricted` 和 `com.apple.developer.gpu-restricted`。
- 1.3 版对已经成功打开的连接进一步读取 IOObjectGetClass；若运行时可用，使用 IOConnectGetService 只读回查该连接对应的服务类名及 Registry ID，并与原始服务 ID 比较。对应 API 不可用或被系统禁止时明确输出，不自行猜测。
- 没有外部方法调用、竞态压力测试或异常参数。

## 怎么解释

- Service visible + OPEN ALLOWED：这个具体开发者签名的 App 能打开某个匹配到的服务（**完成普通 App 可打开性的动态确认**）。但需要进一步识别服务是否对应内核静态分析的具体 UserClient。
- Service not visible：服务可能不存在、名字不匹配或被沙箱隐藏；**不能反推出 App 权限一定不足**。
- 服务打开返回错误：需要结合返回码和设备日志进一步分析，不代表所有 IOSurface 公共 API 都不可用。
- 服务能打开 ≠ 能调用任意外部 selector ≠ 漏洞可触发 ≠ 能做内核读写 ≠ 永久签名。
- 自身两个 GPU-restricted 权限都不存在时，按照现有两版静态内核代码，符合走**普通表**的条件；实际的 selector 17 是否能正常调用仍需另行验证。本 App 不尝试调用该 selector。

## 现实限制

当前研究环境没有连接你的 iPhone，因此无论 GitHub Actions 构建成功与否，**都不能代替真机运行结果**。完成正常开发者签名并在设备运行后，才可以得到动态访问诊断结论。

### Windows 用户可选：GitHub Actions 构建

此项目已接入 [GitHub Actions](https://github.com/iloveyouwife/IOSurfaceProbe/actions/workflows/build-unsigned.yml)，过去 v1.2 版本曾构建成功。推送代码到 `main` 会触发云端 macOS runner 编译；可在运行页面下载 `IOSurfaceReachabilityProbe-unsigned` 构建产物。**当前 v1.3 的构建结果以 Actions 实际运行状态为准。**你仍须通过正规的开发者证书、有效 provisioning profile 和常规安装工具完成签名安装。未签名 IPA 不能直接安装，正常开发者签名也不是永久签名。

注意：IOKit 接口和动态符号访问可能受 App Store 审核和系统沙箱限制。这份代码供个人授权研究及开发者签名测试，不以 App Store 上架为目标。
