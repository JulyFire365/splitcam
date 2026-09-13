# SplitCam 全新 App Store 截图策划

日期：2026-09-13。整组重新设计，不沿用旧 ASC 截图的版式、标题或顺序。此目录提供中英文方案、原生界面截图、示例影像和可再生成的视觉稿；未修改线上 ASC。发布前须以最终发布版本做真机复核。

## 定位与第一印象

核心主张：**拍下眼前，也拍下自己。 / Your view. And you.**

优先服务旅行记录、日常 vlog、反应视频与合拍创作者。前三张依次回答：它做什么、拍出来有什么不同、还能怎样创作。低画质与图标是后半段的实用理由，不占据首屏。

视觉主题为「双视角生活手记」：墨黑、暖白交替，大标题、真实操作界面和一条细分割线构成统一语言。人物与环境覆盖旅行、咖啡、宠物和海边，不反复使用同一服装与表情。禁止堆叠小卖点、虚构评分、排行榜、限时折扣或未支持的功能。

## 八张顺序与双语文案

| 顺序 | 中文标题 / 副标题 | English headline / supporting copy | 画面与验证点 |
| --- | --- | --- | --- |
| 01 核心价值 | 拍下眼前，\n也拍下自己。 / 前后双摄，同步记录照片与视频。 | Your view.\nAnd you. / Capture photos and videos with both cameras. | 正面展示左右分屏相机，左侧湖景、右侧自拍。用户首先看到双视角作品与拍摄入口。 |
| 02 画中画 | 精彩现场，\n还有你的表情。 / 自由调整小窗口，让故事更完整。 | The moment.\nYour reaction. / Move and resize your picture-in-picture view. | 完整湖景与人物小窗：紫色外套、短卷发、惊喜神态，与首张橙衣微笑区分。明确标记「画中画视频需 Pro / PiP video requires Pro」。 |
| 03 合拍 | 灵感有了，\n拍下你的回应。 / 导入照片或视频，开始你的合拍。 | Add your side\nto the story. / Import a photo or video. Create alongside it. | 咖啡拉花照片 + 米白针织衫人物的轻松回应。使用真实合拍视图，标记「视频合拍需 Pro / Video duet requires Pro」。示例为静态导入照片，不伪装成正在播放的视频。 |
| 04 布局 | 换个布局，\n换种表达。 / 左右、上下、画中画，随心构图。 | A layout for\nevery story. / Side by side. Stacked. Picture in picture. | 草坪金毛与穿鼠尾草绿 T 恤、开怀大笑的男性，上下分屏。不制作不存在的界面按钮。 |
| 05 清爽预览 | 让画面，\n多一点空间。 / 9:16 一键收起画幅与画质控制条。 | More room\nfor the moment. / Hide frame and quality controls in 9:16. | 海岸与蓝白条纹衫人物，平静自然的神态。使用真实 9:16 收起状态截图；不声称全部控件消失，也不暗示无边界全屏录像。 |
| 06 小体积 | 精彩照录，\n文件更轻。 / 新增节省空间画质，分享更轻松。 | Big moments.\nSmaller files. / Choose Space Saver for lighter videos. | 设置内真实三档画质页，以节省空间为选中项。估算大小保留“约”和实际内容影响说明，不承诺固定压缩比例。此功能对所有用户开放。 |
| 07 记忆设置 | 熟悉的设置，\n打开就接着拍。 / 记住拍摄模式、画幅、布局与镜像。 | Pick up where\nyou left off. / Keep your capture preferences ready to go. | 设置内记忆布局开关，展示真实偏好页。文案不包含未实现的镜头缩放记忆。 |
| 08 个性图标 | 镜头之外，\n也有你的风格。 / 多款 App 图标，换上你的最爱。 | Your camera.\nYour signature. / Find an app icon that feels like you. | 重点展示四款新 Pro 图标，辅以真实图标列表。标记「部分图标需 Pro / Selected icons require Pro」。 |

## 版式与输出

- 当前上传成图每张 **1284 × 2778**，对应用户 ASC 的 **iPhone 6.5 英寸**栏，sRGB、不带透明通道；中文与英文分别输出。初版 1320 × 2868 对应 6.9 英寸，不能直接放入截图所示的 6.5 英寸栏。本次已替换同名成图，旧版可从 Git 历史恢复。
- 顶部只保留品牌名，不展示 1/8、01/08 等页码。排序编号仅保留在文件名中，方便上传。每张只保留一个主张、一句副标题。
- 主体使用真实模拟器截图，控制名称、位置和状态均来自当前 SwiftUI 实现。第 6、7 张放大原生页面的相关区域，提升画质选项与偏好设置的可读性；第 8 张集中展示四款新图标。照片为专门生成的演示素材，不宣称是真机拍摄样张。
- 黑色和暖白画布交替；图标页可使用新图标素材组成视觉焦点。原始 UI 截图保持 1320 × 2868，通过等比缩放排入 1284 × 2778 成图，不把人脸、图标或字体拉伸。界面保持清晰，避免过度透视或大幅倾斜。
- 方案图不显示价格。涉及 Pro 的能力就近标记，不把免费功能包装成 Pro 权益。

## ASO 上线与实验计划

先用「双摄照片与视频」作为主组，第二轮只更换首张标题/场景：旅行主题 vs. 反应合拍主题。保留其余七张，才能判断首屏方向影响。英语与简体中文单独评估产品页转化，记录展示量、访问量、下载转化与 Pro 购买数据；不预设效果提升比例。

上传前逐项核对：当前发布二进制与图中功能一致、画中画和视频合拍 Pro 标识准确、三档画质实际录制可用、真机镜像与布局一致、所有输出无透明通道、中文没有截断。原 ASC 截图在后台替换前可保留一份可恢复备份；此次仅制作新组，未执行后台删除/上传。

## 官方规格与来源

- [Apple 截图规格](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)：支持 1–10 张，此方案使用 8 张；6.5 英寸竖图接受 1284 × 2778 或 1242 × 2688，图片不能包含透明通道。以用户当前选中的上传栏为准。
- [Apple 上传截图说明](https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots/)：最终替换应在对应语言和版本中执行。
- `source/demo-front.png`、`source/demo-back.png`：首张保留的旅行照片，提示词见 `source/prompts.md`。
- `source/scenes/`：内置 imagegen 新生成的不同服装、表情及配对环境，提示词见 `source/scene-prompts.md`。各场景先放入真实 App 再截图，不在截图上覆盖绘制人物。
- `raw/`：专用 iPhone 模拟器的原生页面截图。测试路线只在 Debug 模拟器构建中存在，发布版不会显示演示照片。

复现命令与验证结果见 `../../Design/QA/verification.md`。先用 `bash Tools/CaptureASO.sh <专用模拟器 UUID>` 截取前五个场景，再用 `swift Tools/RenderASO.swift` 排版，最后运行 `swift Tools/ValidateASO.swift` 检查所有上传图。

**上传时仅选择 `en/` 或 `zh-Hans/` 目录内的 8 张 PNG。`overview-*.png` 是审核联系表，尺寸不同，不可作为商店截图上传；`raw/`、`source/` 也不是上传目录。**
