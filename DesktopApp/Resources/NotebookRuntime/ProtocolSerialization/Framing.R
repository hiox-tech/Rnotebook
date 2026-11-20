protocol_version <- "1.4"
max_frame_bytes <- 1048576L
write_frame <- function(connection, envelope) {
  json <- jsonlite::toJSON(envelope, auto_unbox = TRUE, null = "null", na = "null", digits = 17L)
  bytes <- charToRaw(enc2utf8(json))
  if (length(bytes) < 1L || length(bytes) > max_frame_bytes) stop("Response frame exceeds limit")
  writeBin(as.integer(length(bytes)), connection, size = 4L, endian = "big")
  writeBin(bytes, connection)
  flush(connection)
  invisible(NULL)
}
valid_uuid <- function(x) is.character(x) && length(x) == 1L && !is.na(x) &&
  grepl("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$", x)
scalar_string <- function(x) is.character(x) && length(x) == 1L && !is.na(x)
validate_command <- function(command, session_id) {
  if (!identical(command$protocolVersion, protocol_version) || !identical(command$sessionID, session_id) ||
      !valid_uuid(command$requestID) || !valid_uuid(command$taskID) ||
      !scalar_string(command$kind) || !command$kind %in% c("hello", "evaluate", "inspector", "shutdown")) stop("Invalid command envelope")
  if (!is.null(command$adapter) || !is.null(command$inspection) || !is.null(command$table) || !is.null(command$graphics)) stop("Only Notebook execution is available")
  if (!is.null(command$continueOnError) && (!identical(command$kind, "evaluate") ||
      !is.logical(command$continueOnError) || length(command$continueOnError) != 1L || is.na(command$continueOnError))) stop("Invalid error continuation option")
  if (identical(command$kind, "inspector")) {
    query <- command$inspector
    if (!is.list(query) || !scalar_string(query$operation) ||
        !query$operation %in% c("completion", "snapshot", "clearObjects", "previewObject", "removeObject", "loadPackage", "unloadPackage", "installPackage", "help", "setWorkingDirectory", "saveWorkspace")) stop("Invalid inspector operation")
    if (!is.null(query$refreshPackages) && (!is.logical(query$refreshPackages) || length(query$refreshPackages) != 1L)) stop("Invalid refresh option")
    install <- identical(query$operation, "installPackage") && !is.null(query$installation)
    if (identical(query$operation, "completion")) {
      if (!scalar_string(query$name) || nchar(query$name, type = "bytes") > 512L) stop("Invalid completion context")
    } else if (query$operation %in% c("snapshot", "clearObjects") || install) {
      if (!is.null(query$name)) stop("Unexpected inspector name")
    } else if (!scalar_string(query$name) || !nzchar(query$name) ||
               nchar(query$name, type = "bytes") > if (identical(query$operation, "saveWorkspace")) 4096L else 512L) stop("Invalid inspector name")
    if (identical(query$operation, "saveWorkspace") && !startsWith(query$name, "/")) stop("Invalid workspace destination")
    package_name <- function(x) scalar_string(x) && nchar(x, type = "bytes") <= 128L && grepl("^[A-Za-z][A-Za-z0-9.]*$", x)
    if (query$operation %in% c("loadPackage", "unloadPackage", "installPackage") && !install && !package_name(query$name)) stop("Invalid package name")
    if (identical(query$operation, "previewObject") && !is.null(query$preview)) {
      p <- query$preview
      index <- function(x) is.numeric(x) && length(x) == 1L && is.finite(x) && x >= 0 && x < 2147483647 && x == floor(x)
      if (!is.list(p) || length(p$path) > 12L || !all(vapply(p$path, index, logical(1L))) ||
          (!is.null(p$rowOffset) && !index(p$rowOffset)) || (!is.null(p$columnOffset) && !index(p$columnOffset))) stop("Invalid preview page")
      if (!is.null(p$structure) && (!is.logical(p$structure) || length(p$structure) != 1L || is.na(p$structure))) stop("Invalid preview structure")
    } else if (!is.null(query$preview)) stop("Unexpected preview options")
    if (install) {
      x <- query$installation
      if (!is.list(x) || !scalar_string(x$source) || !x$source %in% c("repository", "local") ||
          !scalar_string(x$library) || !startsWith(x$library, "/") || nchar(x$library, type = "bytes") > 4096L ||
          !is.logical(x$includeSuggested) || length(x$includeSuggested) != 1L) stop("Invalid installation options")
      if (x$source == "repository") {
        if (length(x$files) || length(x$packages) < 1L || length(x$packages) > 20L ||
            !all(vapply(x$packages, package_name, logical(1L))) || anyDuplicated(unlist(x$packages)) ||
            !scalar_string(x$repository) || nchar(x$repository, type = "bytes") > 4096L || !grepl("^(https?://[^/@]+|file:///)", x$repository)) stop("Invalid repository installation")
      } else {
        if (length(x$packages) || length(x$files) < 1L || length(x$files) > 20L ||
            !all(vapply(x$files, function(f) scalar_string(f) && startsWith(f, "/") && nchar(f, type = "bytes") <= 4096L && grepl("[.](tar[.]gz|tgz)$", f), logical(1L)))) stop("Invalid local package files")
      }
    } else if (!is.null(query$installation)) stop("Unexpected installation options")
  }
  if (identical(command$kind, "evaluate") &&
      (!scalar_string(command$source) || !scalar_string(command$cellID) ||
       !scalar_string(command$sourceHash) || !grepl("^[0-9a-f]{64}$", command$sourceHash) ||
       !identical(command$mode, "notebookCell"))) stop("Invalid Notebook command")
  if (!is.null(command$plot)) {
    p <- command$plot
    number <- function(x, lo, hi) is.numeric(x) && length(x) == 1L && is.finite(x) && x >= lo && x <= hi
    if (!is.list(p) || !number(p$width, 72, 1800) || p$width != floor(p$width) ||
        !number(p$height, 72, 1800) || p$height != floor(p$height) ||
        !number(p$pointSize, 8, 36) || !number(p$scale, 1, 3) || p$scale != floor(p$scale))
      stop("Invalid plot display options")
    if (!is.null(p$background) && (!scalar_string(p$background) || !grepl("^(transparent|#[0-9A-Fa-f]{6})$",p$background))) stop("Invalid graphics background")
  }

  invisible(command)
}
