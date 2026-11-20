# Rnotebook 原生编辑器依赖

当前 EdmundCore 为固定上游加既有v14交互补丁及Rnotebook专用裁剪。上游来源、提交和归档摘要见 EdmundCore/UPSTREAM.json；Apache-2.0许可证及各依赖/字体许可证保留。

## 当前范围

- 保留原生 NSTextView/TextKit 2 的 Code/Visual、Markdown解析、行号、高亮、原生表格/剪贴板、图片/列表、主题、查找、公式及Mermaid。
- 公式使用随库提供的SwiftMath；Mermaid使用App已打包且经SHA-256核对的JavaScriptCore/CoreSVG链路，无下载入口。
- 删除WebView阅读、Read模式、内置HTML/RTF/纯文档/PDF导出与打印、Quick Look、未使用的RaTeX引擎/扩展面板注册/下载/更新、状态栏偏好、版本历史和MetricKit上报工具。
- QMD的HTML/Word/PDF导出属于App独立Quarto链路，不使用Edmund的旧导出器。
- 保留语法和主题资源，因为QMD支持多种围栏语言，原生编辑器仍会使用这些数据；不裁剪实际使用的swift-markdown/cmark/SwiftMath依赖。

## 核对与恢复

原始148份来源清单SOURCE-HASHES.json和既有LOCAL-PATCHES.json均保持历史内容。RNOTEBOOK-PRUNING.json记录26份删除与6份交叉引用调整，独立差异在patches/Rnotebook-Pruning.patch。当前保留122份源码/资源；旧README历史记录保存在docs/provenance/EdmundCore-README-before-pruning.md。

运行`python3 scripts/verify-edmund-source.py`同时核对上游、v14及裁剪三层；正常build.sh和test.sh已接入该检查。未记录修改或已删除功能重新出现会失败。

完整删除前归档及SHA-256在.local/maintenance/edmund-prune-2026-11-06/；应用构建不扫描、不打包该目录。详见docs/validation/EdmundCore-Pruning-2026-11-06.md。
