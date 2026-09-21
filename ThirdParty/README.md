# Grabbit 编辑模块来源

来源：recursivecodes/grabbit，GitHub main 源码包，2026-09-08 下载。
许可证：MIT，完整条款见 Grabbit-LICENSE；构建时随 App 分发。

复用：AnnotationOverlay.swift、GrabbitDocument.swift、EditorWindowController+Rendering.swift、CropOverlayView.swift、EditorPreferences.swift，以及 EditorViews.swift 中的 CGPoint 边界限制方法。

适配：偏好键改为 phonesnap.editor 命名空间；移除未使用的 Grabbit 历史库标注反序列化入口；新增独立的 PhoneSnap 中文编辑窗口；本机隐私识别和 Mac 系统截图调用由本项目实现。没有移植 Grabbit 的菜单栏、历史图库、全局快捷键管理器或捕获覆盖层。

OCR：复用 AnnotationOverlay 的区域选择回调，参考上游 EditorWindowController 中的 performOCR、showOCRResult 交互与坐标换算；PhoneSnap 使用合并后的当前编辑画面而非原始文档图片，新增整图识别、可编辑结果、可撤销合并换行、UTF-8 TXT 导出及过期结果丢弃。

原始版权声明仅位于随附许可证中；源码保留上游注释。此目录不含任何用户配对凭据。

马赛克：沿用 Grabbit 的 BlurRegion、CIPixellate 滤镜、强度参数与画布交互；PhoneSnap 新增纯色／马赛克选择、完全不透明颜色设置，以及保留区域 ID、位置和层级的样式转换与撤销。没有引入另一套截图工具。
