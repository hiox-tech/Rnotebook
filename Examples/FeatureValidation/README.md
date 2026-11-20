# 全功能验证笔记

这些文件是独立的普通QMD/RMD与本地资源，不是项目或历史结果。用户可复制整个目录体验，App只管理笔记本身。

| 文件 | 用途 | 预期 |
|---|---|---|
| 01-全功能体验.qmd | 丰富排版、公式、Mermaid、本地图片、CSV、统计、图形、富表格、变量树、格式化、运行与导出 | FEATURE_VALIDATION_OK；eval:false块跳过 |
| 02-执行与错误边界.qmd | 静态跳过、error:true继续、默认首错停止、手动运行 | 成功3、跳过1、失败2、未运行1；错误为刻意设计 |
| 03-语法与容器.qmd | 字面围栏、普通r示例、HTML注释／原始区、Div及引用中的字面示例 | 仅3个真实R块执行，CONTAINER_VALIDATION_OK |
| 04-长文档与查找.qmd | 长文档、Unicode、重复标题、折叠、查找替换与滚动 | 默认全部跳过，不启动R；末尾LONG_DOCUMENT_END |
| 05-RMD兼容.Rmd | RMD块头、命名、布尔选项、保存与预览 | 成功2、跳过1，RMD_COMPATIBILITY_OK |
| 06-结构拒绝边界.qmd | 当前不支持的引用容器与未闭合围栏 | 批量／不完整块格式化拒绝；前部独立正常块可手动运行 |

从01开始，按“运行全部”；可选ggplot2／flextable未安装时会显示明确标记，不自动安装。基础执行需要应用既有的evaluate／jsonlite／rlang／knitr依赖。导出HTML／DOCX／Typst PDF／LaTeX PDF需对应本机Quarto和可用引擎；缺少外部依赖的情况须单独记录，不算通过。

数据为固定种子生成的模拟值。02中的错误、04的跳过均为预期。撤销、替换、外部修改和安装等破坏性场景应在副本中操作。自动与实窗验收以本轮docs/validation记录为准，文件存在不等于功能通过。

本机本轮结果：HTML／Word／Typst PDF真实导出通过；中文LaTeX缺少`xeCJK.sty`，须先准备相应环境。Visual表格边框可用01中的feature-summary、feature-model、feature-bootstrap复试：拖动检查器／窗口宽度，滚离再滚回，切Code/Visual及浅深色，检查右侧竖线完整。
