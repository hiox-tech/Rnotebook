# R Basics

Run these examples inside a complete executable R chunk. Follow them in order within one document: later examples use objects created earlier. R is case-sensitive: `values` and `Values` differ. Text after `#` is a comment.

## Objects, vectors and calculations

```r
values <- c(12, 18, 24)       # Assign a vector
values * 2                   # Element-wise: 24 36 48
mean(values)                 # Mean: 18
length(values)               # Number of elements: 3
sum(values)                  # Total: 54
labels <- c("A", "B", "C")   # Character vector
values > 15                  # FALSE TRUE TRUE
```

Call a function as `name(arguments)`. Arguments can be named, as in `mean(values, na.rm = TRUE)`. Common types include numeric, character and logical. `TRUE` and `FALSE` are logical values; `NA` represents a missing value.

## Indexing and missing values

```r
values[1]                    # Indexing starts at 1: 12
values[c(1, 3)]              # Elements 1 and 3: 12 24
values[values > 15]          # Select by condition: 18 24
with_missing <- c(12, NA, 24)
is.na(with_missing)          # FALSE TRUE FALSE
mean(with_missing)           # NA
mean(with_missing, na.rm = TRUE)  # 18
```

Use `is.na(x)` rather than `x == NA`. `==` compares values, while `<-` assigns them. `&` and `|` are element-wise AND and OR; `!` negates a condition.

## Data frames and inspection

```r
dat <- data.frame(
  group = c("A", "A", "B"),
  score = c(12, 18, 24)
)
head(dat)                    # First rows
str(dat)                     # Structure and column types
nrow(dat)                    # Rows: 3
names(dat)                   # Column names
dat$score                    # Column as a vector
dat[dat$score >= 18, ]        # Matching rows, all columns
dat$double <- dat$score * 2   # Add a column
summary(dat$score)            # Summary statistics
```

`dat[rows, columns]` separates dimensions with a comma; leaving a dimension empty selects all of it. Inspect table contents using the read-only variable preview, and change data through R code.

## Read and write CSV

Suppose `data/measurements.csv`, relative to the notebook, contains a `score` column:

```r
dat <- read.csv("data/measurements.csv", check.names = FALSE)
str(dat)
mean(dat$score, na.rm = TRUE)
write.csv(dat, "measurements-clean.csv", row.names = FALSE)
getwd()                      # Actual working directory
file.exists("data/measurements.csv")
```

A new session starts in the saved document’s directory; check the actual directory in the inspector. `write.csv()` writes to the named path, so choose the output name deliberately before rerunning. If delimiters, encoding or inferred column types are wrong, inspect the file and `str(dat)` before calculating.

## Plots, functions and random numbers

```r
plot(values, type = "b", xlab = "Index", ylab = "Value")
center <- function(x) {
  x - mean(x, na.rm = TRUE)
}
center(values)               # -6 0 6
set.seed(42)                 # Set the random starting point
sample(1:10, 3)              # Repeating from set.seed(42) reproduces it
```

Base plots appear in chunk results. Record a seed for random sampling or simulation, and record the data and package versions used by a report.

## Packages and help

```r
# After installing a package, load it in each new session
library(ggplot2)
# Or call a function by namespace
ggplot2::ggplot(dat, ggplot2::aes(group, score)) +
  ggplot2::geom_point()
```

Installation and loading are separate. Use Packages → Install in the inspector to choose CRAN or a local file. Installation is usually done once; document code uses `library()` or `package::function()`. Search function documentation in the inspector, or use `help("mean")` in an external R environment.

## Read common errors

| Message or symptom | What to check |
| --- | --- |
| object 'x' not found | Spelling and case; run the chunk creating x; include that code when rendering |
| could not find function | Function spelling, package installation/loading, or use package::function |
| cannot open file | Use getwd() and file.exists() to check directory and relative path |
| unexpected symbol / end of input | Quotes, commas, parentheses and closing fences |
| Mean returns NA | Check missing values; use na.rm = TRUE when appropriate |

For a structured language introduction, see [An Introduction to R](https://cran.r-project.org/doc/manuals/r-release/R-intro.html).
