# Quarto语法

**常用写法速查 · 复制到 Code 后按需修改**

## 正文与数学

| 用途 | 写法 |
| --- | --- |
| 标题与段落 | `# 一级`、`## 二级`；段落间空一行 |
| 文字 | `**加粗**`、`*斜体*`、`~~删除~~`、`` `代码` `` |
| 列表与任务 | `- 项目`、`1. 步骤`、`- [ ] 待办` |
| 引用 | `> 引用文字` |
| 链接与图片 | `[文字](https://example.com)`、`![说明](images/plot.png)` |
| 公式 | `$x^2$`；独立公式用上下两行 `$$` 包围 |
| 脚注 | `说明[^1]` 与文末 `[^1]: 脚注内容` |

## 报告骨架

````markdown
---
title: "分析报告"
lang: zh-CN
format:
  html:
    toc: true
    number-sections: true
execute:
  echo: true
---

## 结果 {#sec-results}

```{r}
#| label: fig-trend
#| fig-cap: "测量趋势"
#| echo: false
plot(1:5)
```

见 @fig-trend 和 @sec-results。
````

## R 块选项

在块内每项前加 `#|`，例如 `#| echo: false`。

| 选项 | 作用 |
| --- | --- |
| `echo: false` | 报告隐藏代码，保留结果 |
| `eval: false` | 批量运行／渲染跳过计算；手动运行仍可执行 |
| `include: false` | 渲染时计算但不展示代码与结果 |
| `warning: false` | 渲染报告隐藏警告；`message: false` 控制消息 |
| `fig-width: 6` | 图宽（英寸）；`fig-height: 4` 控制图高 |
| `label: tbl-summary` | 表标签配合 `tbl-cap`，正文用 `@tbl-summary` 引用 |

## 表格、提示与图示

Markdown 表格用 `| 列名 | 数值 |`、下一行 `| --- | ---: |`，再写数据行。围栏语言 `{r}` 表示可执行 R；普通 `r` 只展示代码。`mermaid` 围栏可写流程图，如 `flowchart TD` 下一行 `A --> B`。

提示框用 `::: {.callout-note}` 开始、独立 `:::` 结束。YAML 与 `#|` 选项用空格缩进；引用标签必须唯一。`.Rmd` 常将选项写在块头，如 `{r, echo=FALSE}`；上例 YAML 与 `#|` 用于 Quarto `.qmd`。
