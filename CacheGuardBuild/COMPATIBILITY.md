# iOS 27.0.1 兼容性与开发路线（2026-10-29）

## 当前结论

**目标：第三方 App 缓存 + 系统数据，iOS 27.0.1，允许侧载/电脑辅助/特殊签名。**

**AirLift 是新发现且值得验证的途径：** AirCard-iOS 和 AirBeep 已公开 iOS 27.0–27.0.1 相关的配对与文件访问实现。现成 FFI 没有通用目录枚举/精准删除 API，因此仍没有可以直接复用的“一键清理所有 App 缓存”后端。

| 路线 | 公布范围 | 对 27.0.1 的判断 |
| --- | --- | --- |
| 3105 | iOS 26.0–26.6.1、iOS 27 beta 1–4 指定构建 | 未列入支持 |
| Erosion / bad_query | iOS 26.0–26.6.2、iOS 27 beta 1–4 指定构建 | 未列入支持 |
| AirLift + RPPairing + LocalDevVPN | 公共项目报告 iOS 27.0–27.0.1 可用 | 已开始集成配对与容器查询；不等同于通用清理 |
| PureKFD / SparseRestore、KFD、MDC | iOS 14–18 时代的部分版本 | 不适用 |
| TrollStore | iOS 14–17.0 中的指定版本 | 不适用 |
| 常规 IPA 侧载 | 安装 App，但仍处于苹果沙盒内 | 不提供跨 App 删除权限 |
| 用户授权的 Files 目录 | 可在许可范围内读写 | 已作为 0.1 版能力实现 |

资料（项目原始文档）：

- https://github.com/YangJiiii/3105
- https://github.com/LinkPass888/AirBeep
- https://github.com/Mak5er/AirCard-iOS
- https://github.com/jailbreakdotparty/Erosion
- https://github.com/Lrdsnow/PureKFD
- https://github.com/opa334/TrollStore
- https://developer.apple.com/documentation/uikit/providing-access-to-directories
- https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox

## 产品路线

### 阶段 A — 已开始（0.1）

SwiftUI 中文界面、权限诊断、本应用沙盒缓存、用户授权的文件夹、扫描预览、白名单候选、删除前确认、失败报告、测试与 IPA 构建脚本。

### 阶段 B — 必须先在设备验证

1. 记录 iOS 27.0.1 的完整 build 号与设备型号。
2. 在离线测试设备上验证文件选择器、签名、File Provider 读写权限。
3. **0.2 已接入** AirLift 本机配对、导入凭据、VPN 目标地址及指定 Bundle ID 容器查询，等待实机测试。
4. 先核验 `al_find_app_container` 的实际成功情况，再开发远程目录枚举能力。
5. 当前 FFI 有文件读取/写入但**不直接具备删除 API**；必须证明精确删除语义和可靠读回验证，才能启用清理。
6. 若不能稳定重现枚举和删除，保持跨 App 模块禁用。

### 阶段 C — 有权限之后的深度版

将新的权限实现封装在 PrivilegedCleanerBridge 下。必须满足：

- 按 App 分离且仅列出已证实可再生的缓存文件；
- 排除聊天数据库、账号令牌、离线下载、关键系统配置和加密容器；
- 允许逐项预览、备份、可恢复性判断和确认；
- 每个版本与设备单独验证；无权限时返回不可用，绝不静默降级为误导性的结果。

## 风险说明

AirBeep 在更新日志中提示，部分 iOS 27.x 上写入操作可能反馈成功但读回并未确认真实修改。因此**配对成功、拿到容器路径和写入返回成功是三个不同层面的状态**，不能等同于缓存真正被清理。

无论签名方式如何，普通应用不等于能读取别的 App 的私有数据。所谓“系统数据”也不是单一可删除文件夹，包含多个服务的缓存、索引、日志和受保护内容。错误删除可能造成应用崩溃、数据丢失或系统需要恢复。

本阶段不建议通过修改备份并整机恢复的方式清理数据：这种方式侵入性高、失败成本大，也不保证降低系统数据占用。
