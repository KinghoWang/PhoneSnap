# 来源、许可与改动

## PhoneSnap 上游

- 项目：<https://github.com/Aqu1bp/PhoneSnap>
- 本衍生版本从已有的本地上游源码快照继续开发；没有可核验的原下载 commit，因此不虚构精确基线 SHA。
- 原作者：Aquib Misbah。
- 许可：MIT，原文和原版权声明保留在根目录 `LICENSE`。
- 保留的能力包括 Mac 菜单栏工具、USB 导入及旧无线接收基础。不要将这些能力标为本衍生版本首创。

## Grabbit

- 项目：<https://github.com/recursivecodes/grabbit>
- 原作者：recursivecodes。
- 许可：MIT，完整原文在 `ThirdParty/Grabbit-LICENSE`，构建时随 Mac App 分发。
- 复用和适配范围见 `ThirdParty/README.md`，主要是标注、文档、裁剪、渲染与编辑偏好。

## 本衍生版本

由 KinghoWang 维护的扩展包括附近配对直传、自建端到端加密中转、自动选路、二进制密文、快速画质、分阶段诊断、截图元数据、原位钉图与权限引导等；具体历史与上游边界以代码和上述来源说明为准。

新增代码随本仓库按 MIT 分发。iOS App 只抽出截图功能，不含私人容器的其他产品代码。iOS / README 中的中性图标由 AI 辅助生成；Mac 原图标随上游代码保留。项目名、图标和署名不表示原作者背书。

本仓库使用 Apple 系统框架和 Node.js 内置模块，不内嵌第三方运行依赖包。构建工具、系统 SDK 和容器基础镜像分别受其自身条款约束。
