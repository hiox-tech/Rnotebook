# 认识 Rnotebook

Rnotebook 是 macOS 上面向 R 分析与报告写作的笔记工具。用一份 `.qmd` 或 `.rmd` 文件保存说明文字、计算代码和报告配置，在文中运行 R 查看结果，再通过 Quarto 生成可分享的 HTML、Word 或 PDF。

![Visual 编辑界面：正文与 R 代码位于左侧，文档的 R 状态、变量和包位于右侧。](images/workspace-visual-zh.png)

## 适合怎样的工作

- 分析笔记：记录数据来源、清洗步骤、计算和结论，减少代码与解释分散的问题。
- 课程与研究：把公式、表格、绘图和推导写在一起，边运行边检查。
- 重复报告：将读取数据、分析和绘图写成代码，数据更新后重新渲染。
- 轻量写作：只编辑 Markdown、插入图片和公式时，无须启动 R。

## 主要功能

| 任务 | 使用方式 |
| --- | --- |
| 编写笔记 | Code 精确编辑源码，Visual 查看排版并使用格式工具 |
| 执行计算 | 运行当前块、选区、全部、以上或以下 R 块；支持中断 |
| 检查数据 | 变量筛选、继续载入、只读对象预览；包搜索与安装 |
| 整理长文档 | Code 折叠、minimap、Visual 标题导航、查找与替换 |
| 生成报告 | 选择 YAML 或自定义参数，导出 HTML、Word、LaTeX PDF、Typst PDF |
| 管理文稿 | 原生打开、保存、自动保存、外部修改对比和未保存草稿恢复 |

## 文稿、会话和报告分别保存什么

**文稿**保存 Markdown 原文、R 代码和 YAML 配置。**R 会话**保存本窗口当前运行产生的对象和交互结果。**报告**是 Quarto 根据文稿生成的另一份文件。保存文稿不会把 R 内存或交互输出写入正文；重新打开笔记后，需要执行代码来重新获得结果。

图片、CSV 和参考文献保持普通文件。例如 `报告.qmd` 引用 `data/测量.csv`，分享时应保留相应目录关系。软件采用编辑器与右侧检查器两栏；每份文稿使用独立窗口和 R 会话。

## 阅读路线

第一次使用先看[组件与环境](rnotebook-help://article/components)，对照[界面导览](rnotebook-help://article/interface)，再按[快速开始](rnotebook-help://article/quick-start)完成一份报告。查写法时可直接搜索，或打开[Quarto语法](rnotebook-help://article/syntax)、[R 基础](rnotebook-help://article/r-basics)和[Quarto 与 QMD 基础](rnotebook-help://article/quarto-basics)。
