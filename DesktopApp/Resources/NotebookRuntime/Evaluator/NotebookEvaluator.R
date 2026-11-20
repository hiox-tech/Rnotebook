evaluate_notebook <- function(command, emit, resource_dir, shared_env) {
  display <- command$plot
  if (is.null(display)) display <- list(width = 480L, height = 320L, pointSize = 14, scale = 2L)
  pixel_width <- as.integer(display$width * display$scale)
  pixel_height <- as.integer(display$height * display$scale)
  dpi <- as.integer(72L * display$scale)
  background <- if (is.null(display$background)) "white" else display$background
  previous_device <- grDevices::dev.cur()
  if (requireNamespace("ragg", quietly = TRUE) && exists("agg_record", asNamespace("ragg"), inherits = FALSE)) {
    ragg::agg_record(width = pixel_width, height = pixel_height, res = dpi, pointsize = display$pointSize, background = background)
  } else {
    grDevices::pdf(file = NULL, width = display$width / 72, height = display$height / 72, pointsize = display$pointSize, bg = background)
  }
  recording_device <- grDevices::dev.cur()
  grDevices::dev.control(displaylist = "enable")
  on.exit({
    if (recording_device %in% grDevices::dev.list()) grDevices::dev.off(recording_device)
    if (previous_device != 1L && previous_device %in% grDevices::dev.list()) grDevices::dev.set(previous_device)
  }, add = TRUE)
  failed <- FALSE
  plot_ids <- character()
  output_bytes <- 0L
  output_count <- 0L
  plot_bytes <- 0
  fatal_limit <- function(text) stop(structure(list(message = text, call = NULL), class = c("notebook_resource_limit", "error", "condition")))
  send_text <- function(kind, text) {
    text <- enc2utf8(text)
    output_bytes <<- output_bytes + nchar(text, type = "bytes")
    output_count <<- output_count + 1L
    if (output_bytes > 2097152L || output_count > 2048L) {
      stop(structure(list(message = "Notebook output limit exceeded", call = NULL), class = c("kail_output_limit", "error", "condition")))
    }
    # Bound individual frames without cutting through a UTF-8 code point.
    chars <- nchar(text, type = "chars")
    for (start in seq.int(1L, max(1L, chars), by = 8192L)) {
      emit(kind, list(text = substr(text, start, start + 8191L)))
    }
    invisible(NULL)
  }
  display_value <- function(value, visible) {
    if (!visible) return(invisible(NULL))
    if (!requireNamespace("knitr", quietly = TRUE)) {
      print(value)
      return(invisible(NULL))
    }
    # Dispatch the package's native Notebook printer on the already evaluated
    # value. Ordinary objects print here too; never print them a second time.
    rendered <- knitr::knit_print(value)
    if (!inherits(rendered, "knit_asis")) return(invisible(NULL))
    text <- enc2utf8(paste(as.character(rendered), collapse = "\n"))
    html <- grepl("<(table|div|span|html)([ >])", text, ignore.case = TRUE)
    if (html) {
      text <- sub("^\\s*```\\{=html\\}\\s*\n", "", text, perl = TRUE)
      text <- sub("\n```\\s*$", "", text, perl = TRUE)
    }
    styles <- character()
    for (dependency in attr(rendered, "knit_meta")) {
      if (!inherits(dependency, "html_dependency") || is.null(dependency$src$file)) next
      for (stylesheet in dependency$stylesheet) {
        file <- file.path(dependency$src$file, stylesheet)
        if (file.exists(file) && file.info(file)$size <= 262144) {
          styles <- c(styles, paste(readLines(file, warn = FALSE, encoding = "UTF-8"), collapse = "\n"))
        }
      }
    }
    payload <- list(title = if (inherits(value, "flextable")) "flextable" else if (inherits(value, "knitr_kable")) "kable" else "富文本",
      representations = list(list(mime = if (html) "text/html" else "text/markdown", text = text)),
      styles = unname(as.list(styles)))
    encoded_bytes <- nchar(jsonlite::toJSON(payload, auto_unbox = TRUE), type = "bytes")
    output_bytes <<- output_bytes + encoded_bytes
    output_count <<- output_count + 1L
    if (encoded_bytes > 1046528 || output_bytes > 2097152 || output_count > 2048L) fatal_limit("Notebook rich output limit exceeded")
    emit("display_rich", payload)
    invisible(NULL)
  }
  handler <- evaluate::new_output_handler(
    source = function(x) invisible(NULL),
    value = display_value,
    text = function(x) send_text("stdout", x),
    message = function(x) send_text("message", conditionMessage(x)),
    warning = function(x) send_text("warning", conditionMessage(x)),
    error = function(x) {
      if (inherits(x, "kail_output_limit") || inherits(x, "notebook_resource_limit")) stop(x)
      failed <<- TRUE; send_text("error", conditionMessage(x))
    },
    graphics = function(plot) {
      output_count <<- output_count + 1L
      if (length(plot_ids) >= 64L) fatal_limit("Plot count limit exceeded")
      resource_id <- paste0(command$taskID, "-", sprintf("%06d", length(plot_ids) + 1L))
      path <- file.path(resource_dir, paste0(resource_id, ".png"))
      previous <- grDevices::dev.cur()
      grDevices::png(path, width = pixel_width, height = pixel_height, res = dpi, pointsize = display$pointSize, type = "cairo", bg = background)
      tryCatch(grDevices::replayPlot(plot), finally = {
        grDevices::dev.off()
        if (previous != 1L && previous %in% grDevices::dev.list()) grDevices::dev.set(previous)
      })
      size <- unname(file.info(path)$size)
      if (size > 16777216 || plot_bytes + size > 33554432) {
        unlink(path)
        fatal_limit("Plot resource limit exceeded")
      }
      plot_bytes <<- plot_bytes + size
      plot_ids <<- c(plot_ids, resource_id)
      emit("display_image", list(resourceID = resource_id, mime = "image/png", sizeBytes = size))
      invisible(NULL)
    }
  )
  # Visible values use native print/knit_print exactly once, without re-evaluation.
  result <- evaluate::evaluate(command$source, envir = shared_env,
    stop_on_error = if (isTRUE(command$continueOnError)) 0L else 1L, output_handler = handler, new_device = FALSE)
  final <- evaluate::trim_intermediate_plots(result)
  all_plots <- Filter(evaluate::is.recordedplot, result)
  kept <- vapply(all_plots, function(plot) any(vapply(Filter(evaluate::is.recordedplot, final), identical, logical(1), y = plot)), logical(1))
  emit("plots_finalized", list(resourceIDs = unname(as.list(plot_ids[kept]))))
  list(status = if (failed) "failed" else "completed", uncertain = FALSE)
}
