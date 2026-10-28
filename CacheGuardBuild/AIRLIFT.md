# CacheGuard 0.2：AirLift / AirBeep 配对指南

本工程以 **iOS 27.0.1 真机**为目标。参考 [AirBeep](https://github.com/LinkPass888/AirBeep) 的配对顺序，独立实现了本机 RPPairing 宿主；调用的原生 API 来自 MIT 许可的 [AirCard-iOS/AirliftFFI](https://github.com/Mak5er/AirCard-iOS)。AirBeep 主项目是 GPL-3.0，本工程没有复制其 Swift 文件。

## 准备

- iOS 27.0.1，开启开发者模式；若用电脑生成配对记录可选择导入。
- LocalDevVPN 或等效回环 VPN。默认设备地址为 `10.7.0.1`，通常还需要 Wi-Fi；要确保 VPN 的实际路由能连到手机内的设备服务。
- macOS + Xcode 27+、XcodeGen，用个人签名、SideStore/AltStore 等可用的方式安装项目构建的 IPA。

## 配对步骤

1. 打开清存首页，进入“AirLift 配对与诊断”。
2. 点“启动本机配对”，允许“本地网络”权限。
3. **不要结束清存**；打开系统设置 → 隐私与安全性 → 开发者模式 → **与 CacheGuard 配对**。
4. 系统设置请求 PIN 时，输入清存 App 显示的数字。回到清存，等待“本机配对成功”。
5. 开启 LocalDevVPN，核对隧道和 IP（默认 `10.7.0.1`）。
6. 输入目标 App 的 Bundle ID，例如 `com.tencent.xin`，点击“验证 App 容器查询”。该调用使用 `al_find_app_container`，不会删除任何文件。

**首次配对后无需每次重做**：v0.4 检查本地配对记录，有记录就自动跳过第一步，并尝试通过同一配对身份连接。更新 App 时应保持相同 Bundle ID 和签名团队；钥匙串提供仅本设备的本地恢复副本，但不能保证在改签名团队/改变 Bundle ID 时跨安装恢复。Developer Mode 中的配对状态与 App 保存的信任记录是两部分；iOS 本身可能撤销信任。

若设置中没有配对入口，可以导入 SideStore、LiveContainer、电脑工具等生成的 `.plist`、`.mobiledevicepairing` 或 `.mobilepair` 文件。系统选择器使用“复制”模式，导入后保存在 App 私有 Application Support 目录，禁止 iCloud 备份并开启文件保护，App 不会打印或上传配对文件内容。**切勿把配对文件发给任何人。**

原生 `al_pairing_run_host` 在配对完成之前是阻塞调用且没有安全取消 API。切到设置时 App 仅在主动配对期间尝试无声音频后台保活；如果长时间卡住，请退出 App 并重试。

## 0.3 安全读取通道诊断

在成功查询微信等 App 容器之后，可继续点击「测试 AirLift 单文件读取」。此操作只测试 **CacheGuard 自己创建的临时标记文件**：创建随机文件、通过 FFI 读取、逐字节核对、删除标记。它可以验证读取通道，但不能证明可以读取或删除微信缓存。未经额外授权，不应为了测试而打开其他 App 可能包含账号凭据的偏好文件。

## 0.4 参考 3105 的权限探测

参考 3105 源码 `LimitedCleanerService`，缓存清理限定两个相对目录：`Library/Caches` 与 `tmp`。3105 使用 `openat` / `readdir` / `unlinkat` 直接遍历、删除；它的前提是进程已获得目标容器的访问权限。AirLift 当前配对后能通过 InstallationProxy 查到容器路径，但并不自动解除本 App 的沙盒限制。v0.4 增加只读 `open`/`fdopendir` 探测，显示顶层条目数量或错误码，明确两条路径是否可以直接访问。没有可验证权限时，删除仍然关闭。

AirCard 的 Rust 依赖还包含 AFC / HouseArrest 的 `ReadDir`、`RemovePath` 接口，但这只是服务 API 存在，尚未验证该设备服务允许访问微信完整容器。不能把导出接口等同于已获得任意 App 删除权限。

## 现在具备的 FFI 能力

| 接口 | 功能 | 0.2 状态 |
| --- | --- | --- |
| `al_pairing_run_host` | RPPairing 配对、PIN 回调 | 已接入，待真机验证 |
| `al_set_target_host` | 本地设备 IP 配置 | 已接入 |
| `al_find_app_container` | 按 Bundle ID 只读查询容器路径 | 已接入，待真机验证 |
| `al_exploit_read_file` | 读取给定绝对路径的文件 | 只用于本 App 临时标记文件，待真机验证 |
| `al_exploit_write_dir` | 向给定目录写入/覆盖内容 | 当前未调用 |
| `al_exploit_inject_folder` | 注入目录树 | 当前未调用 |

**现有 FFI 没有远程目录枚举 API，也没有精确的文件删除 API。** 因此本版本不会把“查询到容器路径”误当成“一键清理所有 App 缓存”的充分条件，也不会把“注入空目录”当成可靠删除。

后续需要在用户的 27.0.1 真机上依次验证：配对、VPN、单 App 查询、受控目录枚举、单文件删除的精确语义及确认/回滚。只允许列出已证实可重新生成的缓存，拒绝聊天数据库、登录凭据、离线下载与系统关键数据。AirBeep 自身也记录了某些系统版本存在写入反馈与读回不一致的问题。

## 构建与许可证

`Vendor/AirCard/AirliftFFI.xcframework` 包含 `ios-arm64` 和 `ios-arm64-simulator`，是一份静态库。已在 `project.yml` 链接，并为 App 声明本地网络 Bonjour 服务、后台音频模式（仅用于配对阶段）。

```bash
brew install xcodegen
xcodegen generate
```

然后在 Xcode 中选择签名 Team，按 README 运行或导出 IPA。本执行环境缺少 Xcode，**本次不能编译或验证 IPA**。

资料：

- [LinkPass888/AirBeep](https://github.com/LinkPass888/AirBeep)（GNU GPL-3.0）
- [Mak5er/AirCard-iOS](https://github.com/Mak5er/AirCard-iOS)（MIT，包含 AirLift FFI）
- [0xjohnny/airlift](https://github.com/0xj0hnny/airlift)（原始漏洞研究）
