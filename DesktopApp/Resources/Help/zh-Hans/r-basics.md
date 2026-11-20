# R 基础

把以下代码放进完整的 R 代码块运行。在同一文稿中按顺序运行示例，后面的计算会使用前面创建的对象。R 区分大小写，`values` 与 `Values` 是两个名字；`#` 后面是注释。

## 对象、向量与运算

```r
values <- c(12, 18, 24)       # <- 赋值；c() 组合成向量
values * 2                   # 每个元素乘 2：24 36 48
mean(values)                 # 平均值：18
length(values)               # 元素数：3
sum(values)                  # 总和：54
labels <- c("A", "B", "C")   # 字符向量
values > 15                  # FALSE TRUE TRUE
```

函数用 `函数名(参数)` 调用，命名参数如 `mean(values, na.rm = TRUE)`。常见类型包括数值、字符和逻辑；`TRUE`、`FALSE` 表示逻辑值，`NA` 表示缺失值。

## 索引与缺失值

```r
values[1]                    # R 索引从 1 开始：12
values[c(1, 3)]              # 第 1、3 个：12 24
values[values > 15]          # 按条件选取：18 24
with_missing <- c(12, NA, 24)
is.na(with_missing)          # FALSE TRUE FALSE
mean(with_missing)           # NA
mean(with_missing, na.rm = TRUE)  # 18
```

检测缺失值用 `is.na(x)`，不要写 `x == NA`。`==` 是相等比较，`<-` 是赋值；`&` 和 `|` 分别是逐元素的且、或，`!` 取反。

## 数据框与常用检查

```r
dat <- data.frame(
  group = c("A", "A", "B"),
  score = c(12, 18, 24)
)
head(dat)                    # 前几行
str(dat)                     # 各列类型与结构
nrow(dat)                    # 行数：3
names(dat)                   # 列名
dat$score                    # 按列名取向量
dat[dat$score >= 18, ]        # 满足条件的行，所有列
dat$double <- dat$score * 2   # 新增列
summary(dat$score)            # 汇总统计
```

`dat[行, 列]` 用逗号区分两个维度，留空表示全部。变量检查器的表预览适合检查内容；修改数据请写 R 代码。

## 读取和写出 CSV

假设笔记旁有 `data/measurements.csv`，其中包含 `score` 列：

```r
dat <- read.csv("data/measurements.csv", check.names = FALSE)
str(dat)
mean(dat$score, na.rm = TRUE)
write.csv(dat, "measurements-clean.csv", row.names = FALSE)
getwd()                      # 当前实际工作目录
file.exists("data/measurements.csv")
```

新会话默认以已保存文稿所在目录为工作目录；可在检查器查看实际目录。`write.csv()` 会写入指定路径，重跑前确认输出名。CSV 分隔符、编码和列类型不符时，先检查原文件与 `str(dat)`；不要直接对字符列计算均值。

## 绘图、函数与随机数

```r
plot(values, type = "b", xlab = "Index", ylab = "Value")
center <- function(x) {
  x - mean(x, na.rm = TRUE)
}
center(values)               # -6 0 6
set.seed(42)                 # 固定随机数起点
sample(1:10, 3)              # 再从 set.seed(42) 开始可重现
```

基础绘图可直接在块结果中显示。使用随机抽样或模拟时，在文稿中写明种子；报告还应记录所用数据和包版本。

## 包与帮助

```r
# 包已安装后，在每次新会话中加载
library(ggplot2)
# 不加载整个包也可以按名称调用
ggplot2::ggplot(dat, ggplot2::aes(group, score)) +
  ggplot2::geom_point()
```

安装和加载是两件事。在右侧“R 包 → 安装”选择 CRAN 或本地文件；安装通常只需做一次，文稿用 `library()` 或 `包名::函数名()` 调用。查看函数说明可用检查器帮助搜索，或在外部 R 环境使用 `help("mean")`。

## 常见报错如何处理

| 提示/现象 | 检查方法 |
| --- | --- |
| object 'x' not found | 检查大小写，先运行创建 x 的块；导出时也要有创建代码 |
| could not find function | 检查函数拼写、包是否安装并加载，必要时用包名::函数名 |
| cannot open file | 用 getwd() 和 file.exists() 检查实际目录与相对路径 |
| unexpected symbol / end of input | 检查引号、逗号、括号和代码块闭合 |
| 均值返回 NA | 检查缺失值，按需要使用 na.rm = TRUE |

更系统的语言学习见 [R 官方入门手册](https://cran.r-project.org/doc/manuals/r-release/R-intro.html)。
