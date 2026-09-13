# SplitCam 商店资料

当前准备版本：**1.8（Build 9）**。这些是本地发布资料，修改文件不会自动同步 App Store Connect。

## 直接用于 1.8 的文件

| ASC 字段 | English (US) | 简体中文 |
| --- | --- | --- |
| 此版本的新功能 / What’s New | `whats_new_en.txt` | `whats_new_zh-Hans.txt` |
| 推广文本 / Promotional Text | `promotional_text_en.txt` | `promotional_text_zh-Hans.txt` |
| 截图 | `ASO/2026-09/en/01…08.png` | `ASO/2026-09/zh-Hans/01…08.png` |

截图现为 **iPhone 6.5 英寸 / 1284 × 2778**，上传各语言目录内按文件名排序的 8 张单图；图内已去掉页码。**不要上传 overview、raw、source 或 Design/QA**，它们的尺寸和用途不同。正式替换前确认最终二进制与截图一致。新的推广文本提到 1.8 的功能，应随 1.8 可用时再展示，避免用户仍只能下载 1.7 时看到未上线功能。

## 需要确认的 ASO 建议

完整评估见 [1.8 ASO 审核](ASO/1.8-audit.md)。`ASO/1.8-proposed/` 内是可复制的名称、副标题、关键词与描述建议稿；没有自动替换线上字段。

建议优先采用功能/收费说明准确的新描述。名称与关键词涉及搜索定位，先对照 ASC 原值和实际表现，再决定是否使用候选组合。`en` 文件对应本次 English (US) 方案，不代表已覆盖所有英语地区。

## 发版核对

查看 [1.8 发布清单](Releases/1.8.md)。执行：

```sh
swift Tools/ValidateReleaseMetadata.swift 1.8 9
```

可在命令末尾追加编译后 App 的 `Info.plist` 绝对路径，检查最终版本与 Build。更新说明不包含其他 App 推广；内部发布记录可以列出完整工程变更。
