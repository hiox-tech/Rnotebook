# Quarto语法

这份参考针对 Rnotebook 当前编辑器和导出流程。Code 可保留并编辑完整原文；Visual 提供常用 Markdown 与下列扩展的排版。Quarto 的最终输出还会受到格式、引擎和 YAML 的影响，不一定与 Visual 完全相同。

## 标题、段落与行内样式

| 用途 | 写法 |
| --- | --- |
| 一级至六级标题 | `# 标题` 至 `###### 标题` |
| 段落 | 段落之间留空行 |
| 强制换行 | 行末两个空格，或行末反斜杠 |
| 加粗、斜体、组合 | `**加粗**`、`*斜体*`、`***粗斜体***` |
| 删除线 | `~~删除~~` |
| 高亮 | `==重点==` |
| 行内代码 | `` `mean(x)` `` |
| 下划线 | `<u>文字</u>` |
| 上标、下标 | `<sup>2</sup>`、`<sub>i</sub>` |
| 键帽 | `<kbd>⌘S</kbd>` |
| 转义标记 | `\*` 表示普通星号 |

## 列表、任务、引用与分隔线

```markdown
- 无序项目
  - 嵌套项目

1. 第一步
2. 第二步

- [ ] 待完成
- [x] 已完成

> 引用文字

---
```

分隔线与 YAML 都可能使用 `---`。文档开头成对的 `---` 用于 YAML，正文中的分隔线按 Markdown 上下文识别。

## 链接、图片与尺寸

```markdown
[Quarto](https://quarto.org/)
[另一份笔记](notes.qmd)
[本页标题](#章节)
![图片说明](images/plot.png)
![图片说明|320](images/plot.png)
![图片说明|320x200](images/plot.png)
[[notes]]
[[notes#章节|显示文字]]
![[plot.png|320x200]]
```

图片可通过“插入”菜单导入或链接。文件路径以笔记位置为基准；写 wiki 链接不会自动建立笔记库索引、补扩展名或复制目标文件。wiki 图片嵌入用于受支持的图片，不会把另一份文档内容转引进来。

## 表格与脚注

```markdown
| 指标 | 数值 |
| :--- | ---: |
| 均值 | 18 |
| 样本量 | 3 |

这里有一个脚注[^note]。

[^note]: 脚注说明。
```

普通表格是 Markdown 文本。R 生成的 kable/flextable 等结果是运行结果预览，保存正文不会自动恢复这些历史输出。

## 普通代码块与可执行 R 代码块

普通围栏用来显示代码；Rnotebook 的交互运行入口针对完整的 R 代码块。左侧示例中的语言标记决定用途。

````markdown
```text
这里是展示用文本。
```

```r
x <- 1  # 展示用的 R 代码
```

```{r}
x <- c(12, 18, 24)
mean(x)
```
````

使用代码块选项时可写 Quarto 的 `#|` 行。例如下列 `echo`/`warning` 是 **Quarto 渲染选项**；不要把它们当成交互会话的权限或执行隔离设置。

````markdown
```{r}
#| label: example
#| echo: true
#| warning: false
summary(iris)
```
````

围栏需要闭合。普通文本、其他语言代码和不完整围栏不会因为出现在文档里就自动运行。

支持 RMD 的常见参数块头，如 `{r setup, include=FALSE}`。批量运行遵守静态 `eval: false`，单块／选区手动运行可覆盖；`error: true` 允许普通错误后继续。完整规则见[R 运行与报告导出](rnotebook-help://article/r-export)。

## YAML 文档信息

```yaml
---
title: "分析报告"
author: "作者"
format:
  html:
    toc: true
execute:
  echo: true
---
```

YAML 必须放在文档开头。导出选择“YAML”时读取文档配置；选择“自定义”时使用面板里的对应参数，不会把面板草稿写回笔记。完整可用选项以 Quarto 文档及所选格式为准。

## 行内公式与公式块

```markdown
均值为 $\bar{x}$。

$$
E = mc^2
$$
```

使用 LaTeX 数学表达式。编辑器的显示与 HTML/Word/PDF 的字体、排版或可支持命令可能不同；复杂公式请检查最终输出。

## Mermaid 图形

````markdown
```mermaid
flowchart LR
    A[准备数据] --> B[运行分析]
    B --> C[导出报告]
```
````

内置模板覆盖流程图、时序图、类图、状态图、实体关系图和 XY 图。通过“插入 → Mermaid图形”选择模板。Mermaid 围栏用于图形，不运行 R；最终导出由 Quarto 的 Mermaid 流程处理，具体图形写法和输出格式需要兼容。

## 提示块与折叠提示

```markdown
> [!NOTE] 说明
> 这里是提示正文。

> [!TIP]- 点击展开
> 这里是可折叠正文。

> [!WARNING]+ 默认展开
> 请检查参数。
```

基本类型有 note、tip、important、warning、caution；也支持 info、todo、abstract、success、question、failure、danger、bug、example、quote 等类型及其别名。未知类型保留为普通引用。静态导出会保留折叠正文，不等同于交互折叠界面。

Quarto 原生提示块也可在 Code 中手写，交给 Quarto 渲染；不要据此推断所有 Quarto Div 都会在 Visual 中提供相同布局。

```markdown
::: {.callout-note}
这是 Quarto 原生提示块。
:::
```

## 注释、标签与块锚点

```markdown
<!-- HTML 注释 -->
%%行内注释%%

%%
跨段注释
%%

#研究笔记
段落内容。 ^block-id
```

支持标签和块标记的识别，但不建立全局标签搜索或资源索引。注释影响显示或导出正文；**不会阻止此前已由 R/knitr 执行的代码**。若要控制渲染执行，应使用 Quarto 执行选项。

## 导出兼容与更多 QMD 语法

导出默认开启“兼容 Edmund 语法”，转换高亮、注释、提示/折叠、wiki 链接/图片、尺寸、块锚点和部分简单 HTML 标记。可在渲染面板关闭，用户自有 filter 仍保留。不同格式下颜色、图标和键帽等外观可以有差异。

引文、交叉引用、更多 Div、格式专属参数等 QMD 功能可在 Code 中编辑，由 Quarto 处理；此处不承诺完整的 Visual 语义预览，也不把 RMD 自动转换为其他引擎的专有语义。

继续查看 [QMD 官方语法](https://quarto.org/docs/authoring/markdown-basics.html)、[Quarto 中使用 R](https://quarto.org/docs/computations/r.html)，或返回[快速开始](rnotebook-help://article/quick-start)。
