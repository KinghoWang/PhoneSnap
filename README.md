# PhoneSnap

<img src="docs/assets/logo.png" width="88" alt="PhoneSnap neutral icon">

**iPhone 截图，一键送到 Mac。附近直传优先，跨网络时用自建加密中转兜底。**

Screenshot on iPhone. Use it on your Mac. Local-first, with an optional self-hosted encrypted relay.

[English](README.en.md) · [安装与配对](docs/SETUP.md) · [自建中转](relay/README.md) · [架构](docs/ARCHITECTURE.md) · [安全边界](SECURITY.md)

> **开发者预览版，源码分发。** 当前没有 App Store / TestFlight 版本，也没有已公证的通用 Mac 安装包。独立 iOS App 从私人使用的截图模块抽出；它的构建验证与原容器内的实机验收是两回事，不能混为一谈。
>
> 本项目是基于 [Aqu1bp/PhoneSnap](https://github.com/Aqu1bp/PhoneSnap) 的衍生版本，不是该项目的官方发行版。Mac 编辑模块部分代码来自 [recursivecodes/grabbit](https://github.com/recursivecodes/grabbit)。保留原作者 MIT 许可与署名，详见 [来源与改动](THIRD_PARTY_NOTICES.md)。

## 它解决什么问题

手机上看到一段内容，想立刻在 Mac 上引用、标注或对照，不想在聊天软件里“发给自己”、下载，再找文件。

PhoneSnap 把这个流程缩成：**触发截图快捷指令 → Mac 收图 → 复制、标注或钉在屏幕上。**

它不是云相册、聊天软件或设备远控工具。没有内置账号系统，不提供开发者的公共中转服务。

## 主要能力

| 能力 | 当前实现 |
| --- | --- |
| 一次触发 | iOS 快捷指令“截屏”接“发送图片到 Mac（自动选路）”；可自行绑定操作按钮或轻点背面 |
| 附近优先 | Bonjour 发现已配对 Mac，建立 TLS-PSK 加密直连；约 3 秒未建连才考虑中转 |
| 公网兜底 | 可选自建 HTTPS 中转；图片在手机加密，Mac 解密，服务器不持有图片密钥 |
| 不盲目重发 | 直传已开始就不跨通路重发；回执不确定时明确报错，而不是假装送达 |
| 少传一点 | 公网可选原图 / 快速；快速模式先本机压缩再加密，使用二进制密文传输 |
| 收图可核对 | 最近截图展示来源、保存大小、传输包大小和可获得的接收计时；未知信息不猜填 |
| Mac 本地截图 | 区域、窗口、全屏；悬停选窗与手动框选并存 |
| Mac 后处理 | 标注、裁剪、遮挡、OCR、回车复制、原位 1:1 钉图 |

**正常路径：**

```text
iPhone 快捷指令 / 选图
        │
        ├─ 已配对附近连接可用 ── 加密直传原图 ──────────┐
        │                                           │
        └─ 建连前不可用 + 已配置中转                    ▼
             本机压缩（可选）→ 加密 → 自建中转 → Mac 解密保存
                                                   │
                               手机核验保存回执 ◀───┘
```

## 不会替你做的事

- **不会拦截 iPhone 的系统截图按键。** 一键流程依赖你配置的快捷指令，普通截图键不会自动变成无线发送。
- **插数据线不等于快捷指令走 USB。** 旧 USB 相册导入是独立能力，不参与自动选路。
- 不承诺零延迟、关闭 Mac App 后收图、休眠唤醒或所有网络条件下后台可靠运行。
- 不会自动切换 Wi-Fi、热点或 VPN；网络接口信息不足时，不把它猜成 USB / 热点。
- 不会隐藏 iOS 的系统执行提示或灵动岛动画；中性图标只减少视觉干扰。
- 不提供滚动长截图、浏览器网页收图或在线存储。

## 先跑附近直传，不需要服务器

1. 构建并启动 Mac App，在菜单中开启“设置 iPhone 附近传输”。
2. 用 Xcode 构建独立 iOS App，使用自己的签名身份安装。
3. Mac 导出 `.phonesnappair`，通过可信渠道交给自己的手机，核对来源后导入。
4. 先从 App 选择一张**不含隐私的测试图片**，确认 Mac 收到且手机显示保存成功。
5. 在快捷指令中串联“截屏”和 PhoneSnap 的“发送图片到 Mac（自动选路）”。

完整步骤、版本要求与签名注意事项见 [SETUP](docs/SETUP.md)。跨网络需求再看 [自建中转](relay/README.md)，不是必选项。

## 开发

- Mac：macOS 13+ 目标，**构建需要 Xcode 26+ / Swift 6.2+**；旧系统尚未逐一实机验证。
- 独立 iOS：iOS 26+，Xcode 26+，不含导航、健康数据或私人账号配置。
- 中转与跨语言测试：Node.js 22+，无第三方 npm 运行依赖。

```sh
swift test
node --test relay/server.test.mjs
python3 scripts/test-public-layout.py
PHONESNAP_ALLOW_ADHOC=1 PHONESNAP_APP_PATH=dist/PhoneSnap.app bash scripts/build-app.sh
xcodebuild -project ios/PhoneSnap.xcodeproj -scheme PhoneSnap -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

临时签名仅适合本机开发，不等于可直接分发；固定安装路径和稳定签名身份有助于保持权限连续性，但不保证系统永不询问。构建脚本不会覆盖现有输出或清除系统权限。

本次开源快照的通过、跳过和未实测项分别列在 [验证记录](docs/VALIDATION.md)，不把构建成功包装成完整真机验收。

## 安全与隐私

- 附近配对文件和手机中转配对文件**含秘密**。不要提交 Git、贴 Issue、上传服务器或放进公开下载链接。
- 服务器配置只含通道访问凭据，不含图片解密密钥；它仍然是私密文件。
- 端到端加密不隐藏流量大小、时间、设备 IP 等网络元数据，也不防御端点已被控制的情况。
- 保留的旧 HTTP 无线接口不是加密直传，默认对新安装关闭；不要暴露公网。
- 此实现没有经过独立密码学安全审计。详见 [SECURITY](SECURITY.md)。

## 仓库结构

```text
Sources/PhoneSnap/        Mac 菜单栏 App、截图与编辑
Sources/NearbyTransport/  两端共用的发现、传输、加密、诊断代码
ios/                     独立 iPhone App 与 Xcode 工程
relay/                   可自建的密文中转与测试
Tests/                   Mac 与传输协议回归测试
docs/                    使用与架构说明
```

发布不包含私人项目历史、截图、日志、配对、证书、服务器地址或现用 App 安装包。

## 贡献与许可

欢迎修复可复现问题、改进安装文档和补充不同设备／网络场景的测试。提交前阅读 [CONTRIBUTING](CONTRIBUTING.md)。

MIT；原有版权声明保持不变，第三方代码见 [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES.md)。
