# Only the user's evaluated source lives in .GlobalEnv. Infrastructure stays private.
local({
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) != 4L) stop("Expected FIFO, session ID, resources and working directory")
  script_arg <- grep("^--file=", commandArgs(), value = TRUE)[1L]
  root <- dirname(dirname(normalizePath(sub("^--file=", "", script_arg), mustWork = TRUE)))
  sys.source(file.path(root, "ProtocolSerialization", "Framing.R"), envir = environment())
  sys.source(file.path(root, "Evaluator", "NotebookEvaluator.R"), envir = environment())
  sys.source(file.path(root, "SessionTools", "Inspector.R"), envir = environment())
  if (!requireNamespace("jsonlite", quietly = TRUE) || !requireNamespace("evaluate", quietly = TRUE))
    stop("Notebook needs the evaluate and jsonlite R packages. Select an R installation with these packages installed.")
  capture_backend <- if (requireNamespace("ragg", quietly = TRUE) &&
    exists("agg_record", envir = asNamespace("ragg"), inherits = FALSE)) "ragg::agg_record" else "grDevices::pdf"
  session_id <- args[[2L]]
  if (!valid_uuid(session_id)) stop("Invalid session ID")
  resource_dir <- normalizePath(args[[3L]], mustWork = TRUE)
  setwd(normalizePath(args[[4L]], mustWork = TRUE))
  shared_env <- globalenv()
  options(rlang_trace_top_env = shared_env)
  # Notebook is an HTML display target; user-specified kable formats still win.
  if (is.null(getOption("knitr.table.format"))) options(knitr.table.format = "html")
  response <- fifo(args[[1L]], open = "wb", blocking = TRUE)
  on.exit(close(response), add = TRUE)
  # Blocking readLines prevents R's local HTTP help server from servicing the
  # browser. Nonblocking reads plus Sys.sleep keep R's event loop responsive.
  input <- file("stdin", open = "r", blocking = FALSE)
  on.exit(close(input), add = TRUE)
  parent_pid <- suppressWarnings(as.integer(Sys.getenv("KAIL_PARENT_PID")))
  idle_ticks <- 0L
  seen <- character(); ready <- FALSE
  repeat {
    line <- readLines(input, n = 1L, warn = FALSE)
    if (!length(line)) {
      idle_ticks <- idle_ticks + 1L
      if (idle_ticks %% 20L == 0L && (is.na(parent_pid) || !tools::pskill(parent_pid, signal = 0L))) break
      # Burst requests should not each pay the idle 50ms timer. Back off once
      # the session is idle, retaining R's help/event-loop servicing.
      Sys.sleep(if (idle_ticks < 50L) 0.001 else if (idle_ticks < 100L) 0.01 else 0.05)
      next
    }
    idle_ticks <- 0L
    if (nchar(line, type = "bytes") > max_frame_bytes) stop("Command line exceeds limit")
    command <- jsonlite::fromJSON(line, simplifyVector = FALSE)
    validate_command(command, session_id)
    if (command$requestID %in% seen || command$taskID %in% seen) stop("Duplicate request/task ID")
    seen <- c(seen, command$requestID, command$taskID)
    if (length(seen) > 20000L) stop("Session request limit; explicit restart required")
    sequence <- 0L
    emit <- function(kind, payload = list(status = NULL)) {
      force(payload)
      sequence <<- sequence + 1L
      write_frame(response, list(protocolVersion = protocol_version, sessionID = session_id,
        requestID = command$requestID, taskID = command$taskID, sequence = sequence,
        cellID = command$cellID, sourceHash = command$sourceHash, kind = kind, payload = payload))
    }
    if (identical(command$kind, "hello")) {
      if (ready) stop("Handshake already completed")
      ready <- TRUE
      emit("ready", list(pid = Sys.getpid(), rVersion = as.character(getRversion()),
        evaluateVersion = as.character(utils::packageVersion("evaluate")), captureBackend = capture_backend,
        rHome = R.home(), workingDirectory = getwd(), libraryPaths = unname(as.list(.libPaths()))))
      next
    }
    if (!ready) stop("Handshake required before tasks")
    if (identical(command$kind, "shutdown")) { emit("stopped"); break }
    emit("started")
    if (identical(command$kind, "inspector")) {
      status <- tryCatch(withCallingHandlers({
        result <- inspect_notebook(command$inspector, shared_env, emit)
        emit("inspector_result", result)
        list(status = "completed", uncertain = FALSE)
      }, message = function(m) { emit("message", list(text = conditionMessage(m))); invokeRestart("muffleMessage") },
         warning = function(w) { emit("warning", list(text = conditionMessage(w))); invokeRestart("muffleWarning") }),
        interrupt = function(e) list(status = "interrupted", uncertain = TRUE),
        error = function(e) { emit("error", list(text = conditionMessage(e))); list(status = "failed", uncertain = FALSE) })
      emit("finished", status)
      if (isTRUE(status$uncertain)) break
      next
    }
    status <- tryCatch(evaluate_notebook(command, emit, resource_dir, shared_env),
      interrupt = function(e) list(status = "interrupted", uncertain = TRUE),
      error = function(e) {
        emit("error", list(text = conditionMessage(e)))
        list(status = "failed", uncertain = TRUE)
      })
    emit("finished", status)
    if (isTRUE(status$uncertain)) break
  }
}, envir = new.env(parent = baseenv()))
