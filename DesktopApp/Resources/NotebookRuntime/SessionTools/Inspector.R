# Session metadata and explicit management actions. Never parse user input as R.
inspector_install_library <- function() {
  paths <- .libPaths()
  writable <- paths[file.access(paths, 2L) == 0L]
  if (length(writable)) return(writable[[1L]])
  personal <- strsplit(Sys.getenv("R_LIBS_USER"), .Platform$path.sep, fixed = TRUE)[[1L]]
  if (!length(personal) || !nzchar(personal[[1L]])) stop("没有可写入的 R 包目录")
  path.expand(personal[[1L]])
}

inspector_repositories <- function() {
  repos <- getOption("repos")
  repos <- repos[!is.na(repos) & nzchar(repos)]
  repos[repos == "@CRAN@"] <- "https://cloud.r-project.org"
  if (!length(repos)) repos <- "https://cloud.r-project.org"
  unname(utils::head(repos, 16L))
}

# Metadata only: no values or user methods are retained in the browsing cache.
inspector_variable_cache <- new.env(parent = emptyenv())
inspector_variable_cache$id <- 0L
inspector_variable_rows <- function(shared) {
  names <- sort(ls(shared, all.names = TRUE))
  selected <- names[nchar(names, type = "bytes") <= 512L]
  safe <- requireNamespace("rlang", quietly = TRUE)
  lazy <- if (safe) rlang::env_binding_are_lazy(shared, selected) else rep(TRUE, length(selected))
  clip <- function(x) substr(enc2utf8(paste(x, collapse = "/")), 1L, 60L)
  variables <- lapply(seq_along(selected), function(i) {
    name <- selected[[i]]
    row <- function(type, detail, kind = "other") list(name = name, type = type, detail = detail, kind = kind)
    if (bindingIsActive(name, shared)) return(row("active binding", "未触发读取"))
    if (lazy[[i]]) return(row(if (safe) "promise" else "未读取", if (safe) "延迟求值" else "详细信息需要 rlang"))
    tryCatch({
      value <- get(name, envir = shared, inherits = FALSE)
      type <- typeof(value)
      if (type %in% c("closure", "builtin", "special")) return(NULL)
      classes <- attr(value, "class", exact = TRUE)
      label <- if (length(classes)) clip(classes) else type
      if (isS4(value)) return(row(label, "S4 对象"))
      if (type == "environment") return(row(label, "环境"))
      if (type == "externalptr") return(row(label, "外部对象"))
      if (type == "list" && "data.frame" %in% classes) {
        return(row(label, paste0(.row_names_info(value, 2L), " 行 × ", length(unclass(value)), " 列"), "table"))
      }
      dims <- attr(value, "dim", exact = TRUE)
      if (is.numeric(dims) && length(dims)) return(row(label, paste(dims, collapse = " × "), "matrix"))
      kind <- if (type %in% c("double", "integer", "complex")) "numeric" else if (type == "character") "character" else if (type == "list") "list" else "other"
      # Removing the class prevents user length/format/dim methods from running.
      count <- if (type %in% c("list", "logical", "integer", "double", "complex", "character", "raw", "expression")) length(unclass(value)) else NULL
      row(label, if (is.null(count)) "对象" else paste0(count, if (type == "list") " 个成员" else " 个元素"), kind)
    }, error = function(e) row("未读取", "无法安全读取"))
  })
  Filter(Negate(is.null), variables)
}

inspector_variable_page <- function(shared, request = NULL) {
  query <- if (is.null(request$query)) "" else request$query
  offset <- if (is.null(request$offset)) 0L else request$offset
  token <- request$snapshotID
  if (!scalar_string(query) || nchar(query, type = "bytes") > 4096L ||
      !is.numeric(offset) || length(offset) != 1L || is.na(offset) || !is.finite(offset) ||
      offset < 0 || offset > .Machine$integer.max || offset != floor(offset)) stop("Invalid variable page")
  cache <- inspector_variable_cache
  cached <- !is.null(token) && identical(as.integer(token), cache$id) && identical(cache$shared, shared) && !is.null(cache$rows)
  if (!cached) {
    cache$rows <- inspector_variable_rows(shared)
    cache$search <- tolower(vapply(cache$rows, function(row) paste(row$name, row$type, row$detail), character(1L)))
    cache$shared <- shared
    cache$id <- if (cache$id == .Machine$integer.max) 1L else cache$id + 1L
    offset <- 0L
  }
  indices <- if (nzchar(query)) which(grepl(tolower(query), cache$search, fixed = TRUE)) else seq_along(cache$rows)
  if (offset > length(indices)) stop("Invalid variable page offset")
  offset <- as.integer(offset)
  count <- min(500L, length(indices) - offset)
  selected <- if (count) indices[seq.int(offset + 1L, length.out = count)] else integer()
  list(variables = unname(cache$rows[selected]), variableTotal = length(cache$rows),
       variablePage = list(query = query, offset = offset, total = length(indices), snapshotID = cache$id))
}

inspector_package_cache <- new.env(parent = emptyenv())
inspector_snapshot <- function(shared, refresh_packages = TRUE, variable_request = NULL) {
  page <- inspector_variable_page(shared, variable_request)
  signature <- paste(.libPaths(), collapse = "\n")
  if (refresh_packages || !identical(inspector_package_cache$signature, signature) || is.null(inspector_package_cache$installed)) {
    inspector_package_cache$installed <- utils::installed.packages(fields = c("Title", "Description", "Repository"), noCache = TRUE)
    inspector_package_cache$signature <- signature
  }
  installed <- inspector_package_cache$installed
  installed <- installed[!duplicated(installed[, "Package"]), , drop = FALSE]
  installed <- installed[order(tolower(installed[, "Package"])), , drop = FALSE]
  total <- nrow(installed)
  installed <- utils::head(installed, 2000L)
  attached <- sub("^package:", "", grep("^package:", search(), value = TRUE))
  namespaces <- loadedNamespaces()
  field <- function(i, key, limit) {
    value <- installed[i, key]
    if (is.na(value)) return("")
    substr(gsub("[[:space:]]+", " ", enc2utf8(value)), 1L, limit)
  }
  packages <- lapply(seq_len(nrow(installed)), function(i) list(
    name = unname(installed[i, "Package"]), version = unname(installed[i, "Version"]),
    library = unname(installed[i, "LibPath"]), loaded = installed[i, "Package"] %in% attached,
    namespaceLoaded = installed[i, "Package"] %in% namespaces,
    protected = !is.na(installed[i, "Priority"]) && installed[i, "Priority"] == "base",
    description = { title <- field(i, "Title", 120L); if (nzchar(title)) title else field(i, "Description", 120L) },
    repository = field(i, "Repository", 120L)))
  result <- list(variables = page$variables, variablePage = page$variablePage, packages = unname(packages),
    variableTotal = page$variableTotal, packageTotal = total,
    installLibrary = inspector_install_library(), repositories = as.list(inspector_repositories()),
    workingDirectory = getwd(), libraryPaths = unname(as.list(.libPaths())))
  if (nchar(jsonlite::toJSON(result, auto_unbox = TRUE), type = "bytes") > 786432L) stop("变量或包信息超过显示上限")
  result
}

inspect_notebook <- function(query, shared, emit) {
  operation <- query$operation
  if (identical(operation, "completion")) return(list(completions = inspector_completion(query$name, shared)))
  name <- query$name
  help_url <- NULL
  if (identical(operation, "previewObject")) return(list(objectPreview = inspector_preview(name, query$preview, shared)))
  if (identical(operation, "clearObjects")) {
    objects <- ls(shared, all.names = TRUE)
    locked <- vapply(objects, bindingIsLocked, logical(1L), env = shared)
    rm(list = objects[!locked], envir = shared)
    if (any(locked)) emit("warning", list(text = paste0("已清除未锁定对象；保留 ", sum(locked), " 个锁定对象：", paste(utils::head(objects[locked], 8L), collapse = "、"))))
  } else if (identical(operation, "saveWorkspace")) {
    base::save(list = ls(shared, all.names = TRUE), file = name, envir = shared, version = 3L, eval.promises = FALSE)
  } else if (identical(operation, "setWorkingDirectory")) {
    setwd(name)
  } else if (identical(operation, "removeObject")) {
    if (!exists(name, envir = shared, inherits = FALSE)) stop("变量已不存在")
    if (bindingIsLocked(name, shared)) stop("变量已锁定，未删除")
    rm(list = name, envir = shared)
  } else if (identical(operation, "loadPackage")) {
    library(name, character.only = TRUE, quietly = TRUE, warn.conflicts = FALSE)
  } else if (identical(operation, "unloadPackage")) {
    installed <- utils::installed.packages()
    if (name %in% installed[, "Package"] && any(installed[installed[, "Package"] == name, "Priority"] == "base", na.rm = TRUE))
      stop("R 基础包不能从面板卸载")
    target <- paste0("package:", name)
    if (target %in% search()) detach(target, character.only = TRUE, unload = FALSE)
  } else if (identical(operation, "installPackage")) {
    inspector_install(query, emit)
  } else if (identical(operation, "help")) {
    parts <- strsplit(trimws(name), "::", fixed = TRUE)[[1L]]
    if (length(parts) > 2L || any(!nzchar(parts))) stop("请输入帮助主题，或 包名::主题")
    package <- if (length(parts) == 2L) parts[[1L]] else NULL
    topic <- utils::tail(parts, 1L)
    old <- options(browser = function(url, ...) { help_url <<- url; invisible(NULL) }, help_type = "html")
    on.exit(options(old), add = TRUE)
    found <- utils::help((topic), package = (package), try.all.packages = TRUE, help_type = "html")
    if (length(found)) get("print.help_files_with_topic", asNamespace("utils"))(found)
    else {
      found <- utils::help.search(topic, package = package, agrep = TRUE)
      if (!nrow(found$matches)) stop("未找到相应帮助，请尝试函数名或 包名::主题")
      get("printhsearchInternal", asNamespace("utils"))(found)
    }
    if (!scalar_string(help_url) || !grepl("^http://127[.]0[.]0[.]1:[0-9]+/", help_url)) stop("本地 HTML 帮助不可用")
  }
  list(inspector = inspector_snapshot(shared, refresh_packages = !identical(query$refreshPackages, FALSE), variable_request = query$variablePage), helpURL = help_url)
}

# Only built-in storage is inspected. No user [, [[, format, print or str methods.
inspector_preview <- function(name, request, shared) {
  if (!exists(name, envir = shared, inherits = FALSE)) stop("变量已不存在，请刷新变量列表")
  if (bindingIsActive(name, shared)) stop("活动绑定未读取，以免触发用户代码")
  if (!requireNamespace("rlang", quietly = TRUE)) stop("只读预览需要 rlang 以安全判断延迟绑定")
  if (rlang::env_binding_are_lazy(shared, name)[[1L]]) stop("延迟对象未求值，以免改变会话")
  if (is.null(request)) request <- list()
  path <- if (is.null(request$path)) integer() else as.integer(unlist(request$path))
  row_offset <- if (is.null(request$rowOffset)) 0L else as.integer(request$rowOffset)
  column_offset <- if (is.null(request$columnOffset)) 0L else as.integer(request$columnOffset)
  value <- get(name, envir = shared, inherits = FALSE)
  for (index in path) {
    if (isS4(value) || typeof(value) != "list") stop("该对象不能展开")
    plain <- unclass(value)
    if (index < 0L || index >= length(plain)) stop("对象结构已改变，请重新打开预览")
    value <- plain[[index + 1L]]
  }
  clip <- function(x, n = 60L) {
    text <- enc2utf8(x)
    ifelse(nchar(text) > n, paste0(substr(text, 1L, n - 1L), "…"), text)
  }
  label <- function(x) {
    classes <- attr(x, "class", exact = TRUE)
    clip(if (length(classes)) paste(classes, collapse = "/") else typeof(x))
  }
  summary <- function(x) {
    if (isS4(x)) return(paste(label(x), "S4 对象"))
    kind <- typeof(x)
    if (kind %in% c("environment", "externalptr", "closure", "builtin", "special", "weakref", "language", "symbol", "promise")) return(label(x))
    paste0(label(x), " · ", length(unclass(x)), " 个元素")
  }
  cell <- function(x) {
    if (isS4(x)) return("<S4>")
    kind <- typeof(x)
    if (!kind %in% c("logical", "integer", "double", "complex", "character", "raw")) return(clip(summary(x)))
    classes <- attr(x, "class", exact = TRUE)
    levels <- attr(x, "levels", exact = TRUE)
    plain <- unclass(x)
    if (!length(plain)) return("<空>")
    plain <- plain[1L]
    if (is.na(plain)) return(if (kind == "double" && is.nan(plain)) "NaN" else "NA")
    if ("factor" %in% classes && is.character(levels) && plain > 0L && plain <= length(levels)) return(clip(levels[[plain]]))
    if ("Date" %in% classes && is.numeric(plain)) return(as.character(structure(plain, class = "Date")))
    if (any(c("POSIXct", "POSIXlt") %in% classes) && is.numeric(plain)) return(clip(format(structure(plain, class = c("POSIXct", "POSIXt")), tz = "UTC")))
    clip(as.character(plain))
  }
  indices <- function(offset, total, count) {
    if (offset > total) stop("对象大小已改变，请返回第一页")
    if (offset == total) return(integer())
    seq.int(offset + 1, min(total, offset + count))
  }
  type <- label(value); kind <- "summary"; columns <- c("属性", "内容")
  rows <- list(); expandable <- logical(); total_rows <- 0; total_columns <- 2L
  row_names <- NULL; scalar_text <- NULL
  storage <- typeof(value)
  classes <- attr(value, "class", exact = TRUE)
  dims <- attr(value, "dim", exact = TRUE)
  tabular <- !isS4(value) && ((storage == "list" && "data.frame" %in% classes) ||
    (storage %in% c("logical", "integer", "double", "complex", "character", "raw") && length(dims) == 2L))
  if (tabular && !(isTRUE(request$structure) && storage == "list")) {
    kind <- "table"; plain <- unclass(value)
    frame <- storage == "list"
    total_rows <- if (frame) .row_names_info(value, 2L) else dims[[1L]]
    total_columns <- if (frame) length(plain) else dims[[2L]]
    ri <- indices(row_offset, total_rows, 100L); ci <- indices(column_offset, total_columns, 30L)
    column_names <- if (frame) names(plain) else { dn <- attr(value, "dimnames", exact = TRUE); if (length(dn) >= 2L) dn[[2L]] else NULL }
    rn <- if (frame) attr(value, "row.names", exact = TRUE) else { dn <- attr(value, "dimnames", exact = TRUE); if (length(dn)) dn[[1L]] else NULL }
    row_names <- vapply(ri, function(i) clip(if (is.character(rn) && length(rn) >= i) rn[[i]] else as.character(i), 120L), character(1L))
    columns <- vapply(ci, function(j) clip(if (length(column_names) >= j && !is.na(column_names[[j]]) && nzchar(column_names[[j]])) column_names[[j]] else paste0("V", j), 120L), character(1L))
    # Each cell is capped to 60 Unicode characters; a page stays below 1MiB.
    rows <- lapply(ri, function(i) unname(as.list(vapply(ci, function(j) {
      if (!frame) return(cell(plain[i + (j - 1) * total_rows]))
      column <- plain[[j]]
      if (isS4(column)) return("<S4>")
      column_plain <- unclass(column)
      if (i > length(column_plain)) return("<无值>")
      if (typeof(column_plain) == "list") return(clip(summary(column_plain[[i]])))
      # Preserve only known built-in labels, without dispatching user methods.
      item <- column_plain[i]
      if (any(c("factor", "Date", "POSIXct") %in% attr(column, "class", exact = TRUE))) {
        attr(item, "class") <- attr(column, "class", exact = TRUE)
        attr(item, "levels") <- attr(column, "levels", exact = TRUE)
      }
      cell(item)
    }, character(1L)))))
    expandable <- rep(FALSE, length(rows))
  } else if (!isS4(value) && storage == "list") {
    kind <- "list"; plain <- unclass(value); total_rows <- length(plain); columns <- c("成员", "类型", "摘要"); total_columns <- 3L
    ri <- indices(row_offset, total_rows, 100L)
    rows <- lapply(ri, function(i) {
      item <- plain[[i]]; nms <- names(plain)
      member <- if (length(nms) >= i && !is.na(nms[[i]]) && nzchar(nms[[i]])) nms[[i]] else paste0("[[", i, "]]")
      item_type <- typeof(item)
      atomic <- !isS4(item) && item_type %in% c("logical", "integer", "double", "complex", "character", "raw")
      count <- if (!isS4(item) && (atomic || item_type == "list")) length(unclass(item)) else 0L
      description <- if (is.null(item)) "NULL" else if (atomic && count) {
        v <- unclass(item)
        paste(vapply(seq_len(min(count, 5L)), function(j) {
          piece <- v[j]
          if (any(c("factor", "Date", "POSIXct") %in% attr(item, "class", exact = TRUE))) {
            attr(piece, "class") <- attr(item, "class", exact = TRUE); attr(piece, "levels") <- attr(item, "levels", exact = TRUE)
          }
          text <- cell(piece)
          if (item_type == "character" && !is.na(v[j])) paste0('"', text, '"') else text
        }, character(1L)), collapse = ", ")
      } else if (!isS4(item) && item_type == "list" && "data.frame" %in% attr(item, "class", exact = TRUE)) {
        paste0(.row_names_info(item, 2L), " 行 × ", count, " 列")
      } else if (item_type == "list" && !isS4(item)) paste0(count, " 个成员") else summary(item)
      if (atomic && count > 5L) description <- paste0(description, ", …")
      list(clip(member), if (atomic) paste0(label(item), " [", count, "]") else label(item), clip(description))
    })
    expandable <- vapply(ri, function(i) {
      item <- plain[[i]]
      !isS4(item) && typeof(item) %in% c("list", "logical", "integer", "double", "complex", "character", "raw") &&
        (length(unclass(item)) > (if (typeof(item) == "list") 0L else 1L) || length(attr(item, "dim", exact = TRUE)) > 0L ||
         (typeof(item) == "character" && length(unclass(item)) == 1L && !is.na(unclass(item)[[1L]]) &&
          (nchar(unclass(item)[[1L]]) > 60L || grepl("[\r\n]", unclass(item)[[1L]]))))
    }, logical(1L))
  } else if (!isS4(value) && storage %in% c("logical", "integer", "double", "complex", "character", "raw")) {
    kind <- "vector"; plain <- unclass(value); total_rows <- length(plain); columns <- c("索引", "值"); total_columns <- 2L
    rows <- lapply(indices(row_offset, total_rows, 100L), function(i) {
      item <- plain[i]
      if (any(c("factor", "Date", "POSIXct") %in% classes)) { attr(item, "class") <- classes; attr(item, "levels") <- attr(value, "levels", exact = TRUE) }
      nms <- attr(value, "names", exact = TRUE)
      index <- if (is.character(nms) && length(nms) >= i && !is.na(nms[[i]]) && nzchar(nms[[i]])) clip(nms[[i]]) else as.character(i)
      list(index, cell(item))
    })
    expandable <- rep(FALSE, length(rows))
    if (storage == "character" && length(plain) == 1L && !is.na(plain[[1L]])) scalar_text <- clip(plain[[1L]], 16000L)
  } else {
    total_rows <- 1L
    if (row_offset > 0L) stop("该对象仅提供摘要")
    rows <- list(list("类型", summary(value))); expandable <- FALSE
  }
  description <- if (kind == "list") paste0(type, " · ", total_rows, " 个成员") else if (kind == "vector") {
    if (length(dims)) paste0(type, " · ", paste(dims, collapse = " × ")) else paste0(type, " · ", total_rows, " 个元素")
  } else if (kind == "table") paste0(type, " · ", total_rows, " 行 × ", total_columns, " 列") else summary(value)
  if ("factor" %in% classes) description <- paste0(description, " · ", length(attr(value, "levels", exact = TRUE)), " levels")
  result <- list(name = name, type = type, kind = kind, summary = description,
    totalRows = total_rows, totalColumns = total_columns, columns = unname(as.list(columns)), rows = unname(rows),
    expandable = unname(as.list(expandable)), rowNames = if (is.null(row_names)) NULL else unname(as.list(row_names)), scalarText = scalar_text,
    request = list(path = unname(as.list(path)), rowOffset = row_offset, columnOffset = column_offset, structure = isTRUE(request$structure)))
  if (nchar(jsonlite::toJSON(result, auto_unbox = TRUE), type = "bytes") > 900000L) stop("预览页超过响应上限")
  result
}

inspector_install <- function(query, emit) {
  spec <- query$installation
  local <- !is.null(spec) && identical(spec$source, "local")
  lib <- if (is.null(spec)) inspector_install_library() else spec$library
  allowed <- unique(c(.libPaths(), inspector_install_library()))
  if (!normalizePath(lib, mustWork = FALSE) %in% normalizePath(allowed, mustWork = FALSE)) stop("请选择当前 R 已配置的安装目录")
  if (!dir.exists(lib) && !dir.create(lib, recursive = TRUE)) stop("无法创建 R 包目录")
  if (file.access(lib, 2L) != 0L) stop("安装目录不可写")
  targets <- if (is.null(spec)) query$name else unlist(if (local) spec$files else spec$packages, use.names = FALSE)
  names <- targets
  if (local) {
    names <- vapply(targets, function(file) {
      if (!file.exists(file)) stop("本地安装包已不存在")
      entries <- utils::untar(file, list = TRUE)
      desc <- grep("^[A-Za-z][A-Za-z0-9.]*/DESCRIPTION$", entries, value = TRUE)
      if (length(desc) != 1L) stop("本地文件不是有效的 R 包归档")
      scratch <- tempfile("rnotebook-package-"); dir.create(scratch); on.exit(unlink(scratch, recursive = TRUE), add = TRUE)
      utils::untar(file, files = desc, exdir = scratch)
      metadata <- read.dcf(file.path(scratch, desc))
      package <- metadata[1L, "Package"]
      if (!grepl("^[A-Za-z][A-Za-z0-9.]*$", package)) stop("本地包名无效")
      package
    }, character(1L))
  }
  if (any(names %in% loadedNamespaces())) stop(paste0("包的名称空间已载入；请先重启 R，再安装：", paste(names[names %in% loadedNamespaces()], collapse = "、")))
  failures <- character(); successes <- character()
  for (i in seq_along(targets)) {
    emit("message", list(text = paste0("正在安装 ", names[[i]], " (", i, "/", length(targets), ")")))
    warnings <- character()
    problem <- tryCatch({
      withCallingHandlers({
        if (local) {
          binary <- endsWith(targets[[i]], ".tgz")
          if (binary && identical(.Platform$pkgType, "source")) stop("当前 R 不支持该 macOS 二进制包，请选择源码 tar.gz")
          utils::install.packages(targets[[i]], lib = lib, repos = NULL, type = if (binary) .Platform$pkgType else "source", quiet = FALSE)
        } else {
          repos <- if (is.null(spec)) inspector_repositories() else spec$repository
          utils::install.packages(targets[[i]], lib = lib, repos = repos, dependencies = if (!is.null(spec) && isTRUE(spec$includeSuggested)) TRUE else NA, quiet = FALSE)
        }
      }, warning = function(w) { warnings <<- c(warnings, conditionMessage(w)); emit("warning", list(text = conditionMessage(w))); invokeRestart("muffleWarning") })
      installed <- utils::installed.packages(lib.loc = lib, noCache = TRUE)
      if (length(warnings)) stop(paste(warnings, collapse = "；"))
      if (!names[[i]] %in% installed[, "Package"]) stop("目标目录中未找到安装的包")
      NULL
    }, error = function(e) conditionMessage(e))
    if (is.null(problem)) { successes <- c(successes, names[[i]]); emit("message", list(text = paste0(names[[i]], " 安装完成"))) }
    else { failures <- c(failures, paste0(names[[i]], "：", problem)); emit("warning", list(text = failures[[length(failures)]])) }
  }
  if (length(failures)) stop(paste0("已安装 ", length(successes), " 个，失败 ", length(failures), " 个。", paste(failures, collapse = "；")))
}

# No parse/eval, user methods, active bindings or promises are executed.
inspector_completion <- function(context, shared) {
  if (!is.character(context) || length(context) != 1L || nchar(context, type="bytes") > 512L) return(list())
  if (nzchar(context) && !grepl("^[[:alnum:]_.$]*$", context)) return(list())
  pieces <- strsplit(paste0(context, "!"), "$", fixed=TRUE)[[1L]]
  pieces[length(pieces)] <- sub("!$", "", pieces[length(pieces)])
  prefix <- pieces[[length(pieces)]]
  if (length(pieces) == 1L) {
    candidates <- ls(shared, all.names=TRUE)
  } else {
    binding <- pieces[[1L]]
    if (!exists(binding, shared, inherits=FALSE) || bindingIsActive(binding, shared) ||
        !requireNamespace("rlang", quietly=TRUE) || rlang::env_binding_are_lazy(shared, binding)[[1L]]) return(list())
    value <- get(binding, shared, inherits=FALSE)
    if (length(pieces) > 2L) for (part in pieces[2L:(length(pieces)-1L)]) {
      if (isS4(value) || typeof(value) != "list") return(list())
      plain <- unclass(value)
      index <- match(part, attr(plain, "names", exact=TRUE))
      if (is.na(index)) return(list())
      value <- plain[[index]]
    }
    if (isS4(value)) return(list())
    candidates <- attr(value, "names", exact=TRUE)
  }
  candidates <- unique(candidates[!is.na(candidates) & startsWith(candidates, prefix)])
  candidates <- utils::head(sort(candidates[nchar(candidates, type="bytes") <= 512L & !grepl("\n", candidates, fixed=TRUE) & !grepl("\r", candidates, fixed=TRUE)]), 200L)
  lapply(candidates, function(name) {
    insertion <- if (identical(make.names(name), name)) name else encodeString(name, quote="`")
    list(label=name, insertion=insertion, detail="R session")
  })
}
