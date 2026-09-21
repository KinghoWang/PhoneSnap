# 贡献指南

先阅读 [产品边界](docs/ARCHITECTURE.md) 和 [安全说明](SECURITY.md)。本仓库围绕截图传 Mac，不计划扩成云相册或通用设备远控。

## 本地检查

构建环境：Xcode 26+ / Swift 6.2+、Node.js 22+、Python 3。

```sh
python3 scripts/test-public-layout.py
python3 scripts/test-build-app.py
node --test relay/server.test.mjs
swift test
xcodebuild -project ios/PhoneSnap.xcodeproj -scheme PhoneSnap -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Mac UI 测试需要可用的 macOS 图形会话；网络测试只使用本机环回服务与临时生成的测试材料。测试通过不能代替真机快捷指令、权限与网络验收。

两个操作系统窗口焦点用例默认明确跳过，保留断言而非标为通过。无交互的 SwiftPM / CI 宿主不能可靠取得系统 key window；在具备焦点能力的测试宿主中设置 `PHONESNAP_INTERACTIVE_FOCUS_TESTS=1` 后单独验收。这两项未完成验收时，不宣称全部 UI 用例通过。普通回车键处理、剪贴板目标选择等断言仍在默认测试中执行。

修复请带最小回归测试。Swift 共用传输代码只改 `Sources/NearbyTransport`，iOS 工程直接引用这些文件。不要修改原协议而不给出兼容路径，也不要用回执不确定后的跨路径重发掩盖错误。

## 提交范围

- 一个 PR 解决一个明确问题，说明复现、改动、测试与未验证项。
- 诊断计时标明设备和阶段，不能跨设备单调时钟相减。
- 只用合成或无隐私图片，不提交配对、账号、证书、签名 Team ID、私人域名、设备标识或真实日志。
- 保留上游及第三方 MIT 许可；新依赖必须说明必要性与许可。
- 不清用户权限、钥匙串或配对来绕过问题；安装／生产部署应独立确认并可回退。

本仓库不接收私人容器中的无关功能、规避系统权限的代码或未经许可的素材。
