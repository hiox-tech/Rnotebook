import AppKit
import ImageIO

// MARK: - Image Rendering
//
// `![alt](path)` renders the referenced image inline when the cursor is outside
// the token, and shows the raw, editable markdown when the cursor is inside it
// (the `.image` branch of `styleBlock`). A loaded image is drawn by a
// `FragmentOverlay` anchored on the leading `!` — the same mechanism math and
// list markers use — with the rest of the markdown hidden and the line height
// reserved for the picture. An image that can't be shown (outside the token)
// gets the same overlay treatment, but with a small icon + reason in place of
// the picture, so the user knows *why* — not just that nothing rendered.
//
// Resolution: absolute paths, `~`-paths, and `file:` URLs load directly;
// relative paths resolve against the document's directory. A remote `https`
// image loads only when `allowRemoteImages` is on (mirrors Read mode's
// `allowRemoteImages`/`blockExternalImages`), and asynchronously — loading it
// synchronously on the styling path would block the main thread. `http` never
// loads: App Transport Security refuses the insecure connection outright,
// regardless of the setting (same reasoning as Read mode's DocumentHTML).

// Downloaded/data images are retained by URL/digest so recomposition does not
// re-fetch remote badges. Local previews use the bounded cache below. A dictionary,
// not NSCache: NSCache is free to evict entries at any time for its own
// heuristics, not just under memory pressure, which broke this cache's "never
// re-fetch" promise — a remote badge that had already loaded would silently
// drop out, flash back to its pending/placeholder state on the next restyle,
// and get re-fetched, tripping rate limits on frequently-hit hosts (shields.io
// badges). Mutated only on the main actor, same as `inFlightRemoteImages`/
// `undecodableRemoteImages` below.
nonisolated(unsafe) private var imageCache: [String: NSImage] = [:]

// Local previews may be re-read after eviction, unlike downloaded badges.
// One current resolution per file, bounded by decoded bitmap cost and count.
@MainActor private enum LocalImagePreviews {
    struct Signature: Equatable {
        let bytes: UInt64
        let modified: Date?
        let inode: UInt64
        init(_ attributes: [FileAttributeKey: Any]) {
            bytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            modified = attributes[.modificationDate] as? Date
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        }
    }
    struct Entry {
        let signature: Signature
        let image: NSImage
        let pixels: Int
        let originalPixels: Int
        let cost: Int
        var access: UInt64
    }
    static var entries: [Data: Entry] = [:]
    static var cost = 0
    static var clock: UInt64 = 0
    static let limit = 64 * 1024 * 1024
    static func remove(_ key: Data) {
        if let old = entries.removeValue(forKey: key) { cost -= old.cost }
    }
    static func insert(_ entry: Entry, for key: Data) {
        remove(key)
        guard entry.cost <= limit else { return }
        while cost + entry.cost > limit || entries.count >= 64 {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access }) else { break }
            remove(oldest.key)
        }
        entries[key] = entry; cost += entry.cost
    }
}

// Remote URLs currently being fetched, so a burst of re-styles (scrolling,
// cursor moves near the image) doesn't kick off duplicate downloads. Mutated
// only on the main actor: inserted synchronously from `loadRemoteImage`
// (called while styling, always on the main thread) and removed inside the
// fetch completion's `@MainActor` hop.
nonisolated(unsafe) private var inFlightRemoteImages = Set<String>()

// Remote URLs that were fetched and turned out not to decode as an image, so
// repeated re-styles show "Not an image" instead of re-fetching forever.
nonisolated(unsafe) private var undecodableRemoteImages = Set<String>()

/// Why an `![alt](destination)` couldn't be shown — the short label a
/// blocked-image placeholder draws next to its icon. Shared by Edit mode
/// (this file) and Read mode/export (`DocumentHTML`) so the two report the
/// same reason, in the same words, for the same failure.
enum ImageLoadFailure: Equatable {
    case httpUnsupported
    case blockedBySetting
    case notAnImage
    case notFound
    /// Sandboxed: the file's folder isn't granted yet (`FolderAccess`).
    case needsFolderAccess
    /// A `![[file]]` embed of a type Obsidian supports (audio/video/pdf/note)
    /// but Edmund can't render.
    case embedTypeUnsupported
    /// A `![[file]]` embed of a type Obsidian itself doesn't support either.
    case embedTypeGenerallyUnsupported

    var label: String {
        switch self {
        case .httpUnsupported: return "HTTP connection not supported"
        case .blockedBySetting: return "External images blocked"
        case .notAnImage: return "Not an image"
        case .notFound: return "Image not found"
        case .needsFolderAccess: return "Folder access needed"
        case .embedTypeUnsupported: return "Embedded file not an image"
        case .embedTypeGenerallyUnsupported: return "Embed file type generally unsupported"
        }
    }

    /// Classifies a non-image `![[file]]` embed by its extension. Obsidian
    /// supports audio/video/pdf/note embeds but Edmund can't render them
    /// (`.embedTypeUnsupported`); anything else Obsidian wouldn't embed either
    /// (`.embedTypeGenerallyUnsupported`). Shared by Edit and Read so the two
    /// report the same reason. No extension ⇒ a note embed (`.md` implied).
    static func forEmbed(destination: String) -> ImageLoadFailure {
        let ext = (destination as NSString).pathExtension.lowercased()
        let obsidianSupported: Set<String> = [
            "mp3", "wav", "m4a", "ogg", "3gp", "flac",   // audio
            "mp4", "webm", "ogv", "mov", "mkv",          // video
            "pdf", "md",                                 // pdf + embedded note
        ]
        return ext.isEmpty || obsidianSupported.contains(ext)
            ? .embedTypeUnsupported : .embedTypeGenerallyUnsupported
    }
}

extension EditorTextView {

    /// What `styleBlock` should show for an image token when the cursor is
    /// outside it.
    enum ImageDisplay {
        /// The image loaded; draw it.
        case image(NSImage)
        /// It can't be shown; draw an icon + `failure.label` in its place.
        case blocked(ImageLoadFailure)
        /// A remote fetch is in flight — transient, not an error; the caller
        /// falls back to plain alt text until a recompose picks up the result.
        case pending
    }

    /// Resolves and (for local files) loads the image referenced by
    /// `destination`, classifying why it can't be shown when it can't.
    func imageDisplay(destination: String, width: Int? = nil, height: Int? = nil) -> ImageDisplay {
        let dest = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dest.isEmpty else { return .blocked(.notFound) }

        if let scheme = URL(string: dest)?.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            guard scheme == "https" else { return .blocked(.httpUnsupported) }
            guard allowRemoteImages else { return .blocked(.blockedBySetting) }
            return loadRemoteImage(dest)
        }
        // Already-inlined `data:` URIs (the self-contained markdown export
        // emits these): decode locally, no I/O. Anything else with a scheme
        // (`file:` handled below; other schemes) resolves to nil → notFound.
        if dest.lowercased().hasPrefix("data:") {
            return loadDataURI(dest)
        }
        guard let url = resolveImageURL(dest) else { return .blocked(.notFound) }
        // Check access even for cache hits; a prior grant may have changed.
        guard FolderAccess.covers(url) else { return .blocked(.needsFolderAccess) }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return .blocked(.notFound)
        }
        let signature = LocalImagePreviews.Signature(attributes)
        // Data preserves distinct UTF8 file names, including NFC/NFD spellings.
        let key = Data(url.path.utf8)
        LocalImagePreviews.clock &+= 1
        func requestedPixels(_ natural: NSSize, original: Int) -> Int {
            let display = imageDisplaySize(natural: natural, width: width, height: height)
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            let desired = max(display.width, display.height) * scale
            guard desired.isFinite, desired > 0 else { return 1 }
            // Small resize changes reuse a pixel bucket; never upscale the file.
            return Int(min(CGFloat(original), max(1, ceil(desired / 64) * 64)))
        }
        if var cached = LocalImagePreviews.entries[key], cached.signature == signature {
            let needed = requestedPixels(cached.image.size, original: cached.originalPixels)
            if cached.pixels == 0 || (cached.pixels >= needed && cached.pixels <= max(64, needed * 2)) {
                cached.access = LocalImagePreviews.clock; LocalImagePreviews.entries[key] = cached
                return .image(cached.image)
            }
        }
        LocalImagePreviews.remove(key)
        // NSImage supplies the existing logical size (including DPI) and the
        // vector/animated fallback. Static raster pixels are decoded separately
        // by ImageIO at their display resolution, never by full-size drawing.
        guard let original = NSImage(contentsOf: url), original.size.width > 0, original.size.height > 0,
              original.size.width.isFinite, original.size.height.isFinite else { return .blocked(.notAnImage) }
        var image = original
        var pixels = 0, originalPixels = 0, cost = 0
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(source) == 1,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let h = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, w > 0, h > 0 {
            originalPixels = max(w, h)
            pixels = requestedPixels(original.size, original: originalPixels)
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceShouldCacheImmediately: true]
            guard let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return .blocked(.notAnImage)
            }
            image = NSImage(cgImage: bitmap, size: original.size)
            image.cacheMode = .never
            cost = bitmap.bytesPerRow * bitmap.height
        } else {
            // Preserve SVG/PDF and animated representations. The count bound
            // still applies; estimate their bitmap cost without rasterizing.
            let estimate = original.size.width * original.size.height * 4
            cost = Int(min(CGFloat(LocalImagePreviews.limit), max(1, estimate)))
        }
        LocalImagePreviews.insert(.init(signature: signature, image: image, pixels: pixels,
            originalPixels: originalPixels, cost: cost, access: LocalImagePreviews.clock), for: key)
        return .image(image)
    }

    /// Decodes an already-inlined `data:` URI, caching by a digest of the
    /// (potentially megabyte-long) string so the restyled block doesn't hold a
    /// second copy of the payload as a dictionary key and doesn't re-decode on
    /// every recompose. Non-base64 or undecodable payloads are "Not an image".
    private func loadDataURI(_ dest: String) -> ImageDisplay {
        let key = Self.dataURIKey(dest)
        if let cached = imageCache[key] { return .image(cached) }
        guard let data = Self.decodeBase64DataURI(dest), let image = NSImage(data: data) else {
            return .blocked(.notAnImage)
        }
        imageCache[key] = image
        return .image(image)
    }

    /// A short, stable cache key for a `data:` URI: byte count + FNV-1a hash.
    /// Full string as key would keep a second copy of a multi-megabyte payload.
    static func dataURIKey(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return "data:\(s.utf8.count):\(String(hash, radix: 16))"
    }

    /// The raw bytes of a `data:...;base64,<payload>` URI. Only base64 is
    /// supported — that is what every inliner here (export, clipboard) writes;
    /// percent-encoded non-base64 data URIs stay "Not an image".
    static func decodeBase64DataURI(_ dest: String) -> Data? {
        guard dest.lowercased().hasPrefix("data:") else { return nil }
        guard let comma = dest.firstIndex(of: ",") else { return nil }
        let header = dest[dest.index(after: dest.startIndex)..<comma]
        guard header.lowercased().hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(dest[dest.index(after: comma)...]))
    }

    /// Returns the cached/decoded outcome for a remote `urlString`; otherwise
    /// starts an async fetch (once per URL, while one is already in flight)
    /// and returns `.pending`. The completion caches the image (or remembers a
    /// decode failure) and re-styles the document so the result appears —
    /// without blocking the main thread on network I/O.
    private func loadRemoteImage(_ urlString: String) -> ImageDisplay {
        if let cached = imageCache[urlString] { return .image(cached) }
        if undecodableRemoteImages.contains(urlString) { return .blocked(.notAnImage) }
        guard !inFlightRemoteImages.contains(urlString), let url = URL(string: urlString) else { return .pending }
        inFlightRemoteImages.insert(urlString)

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let image = data.flatMap { NSImage(data: $0) }
            Task { @MainActor in
                inFlightRemoteImages.remove(urlString)
                if let image {
                    imageCache[urlString] = image
                } else {
                    undecodableRemoteImages.insert(urlString)
                }
                self?.recomposeAllDirty()
            }
        }.resume()
        return .pending
    }

    /// Resolves a destination string to a local file URL. Returns nil for a
    /// remote URL (handled separately, before this is reached) or when a
    /// relative path can't be anchored.
    private func resolveImageURL(_ destination: String) -> URL? {
        let dest = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dest.isEmpty else { return nil }

        if let url = URL(string: dest), let scheme = url.scheme {
            return scheme == "file" ? url : nil
        }
        // A markdown destination may be percent-encoded (`%20`, or a non-ASCII
        // assets-folder name written by `imageDestination(for:)`) — decode
        // before treating it as a path, mirroring LocalImageInlining.resolve.
        let decoded = dest.removingPercentEncoding ?? dest
        if decoded.hasPrefix("/") { return URL(fileURLWithPath: decoded) }
        if decoded.hasPrefix("~") {
            return URL(fileURLWithPath: (decoded as NSString).expandingTildeInPath)
        }
        // Relative to the document's directory.
        if let docDir = document?.fileURL?.deletingLastPathComponent() {
            return docDir.appendingPathComponent(decoded)
        }
        return nil
    }

    /// Whether `destination` is a local file the sandbox can't read yet. No I/O.
    func imageNeedsFolderAccess(destination: String) -> Bool {
        guard FolderAccess.isSandboxed, let url = resolveImageURL(destination) else { return false }
        return !FolderAccess.covers(url)
    }

    /// A `FragmentOverlay` for `destination`'s image or placeholder, or nil
    /// while a remote fetch is pending (the caller then shows plain alt text).
    /// `width`/`height` are declared pixel dimensions from an HTML `<img>` tag.
    /// `fontSize` sizes a placeholder to the surrounding text (a heading's);
    /// nil means the body size.
    func imageOverlay(destination: String, width: Int? = nil, height: Int? = nil,
                      fontSize: CGFloat? = nil) -> FragmentOverlay? {
        switch imageDisplay(destination: destination, width: width, height: height) {
        case .image(let image):
            return scaledOverlay(image: image, width: width, height: height)
        case .blocked(let failure):
            return placeholderOverlay(failure: failure, fontSize: fontSize)
        case .pending:
            return nil
        }
    }

    /// Scales `image` down to fit the text width while keeping its aspect
    /// ratio. `bounds.minY == 0` sits the image bottom on the text baseline
    /// (the reserved line height makes room above it). Declared `width`/
    /// `height` override the natural size first (one alone scales the other
    /// proportionally); the max-width clamp still applies after.
    private func scaledOverlay(image: NSImage, width: Int? = nil, height: Int? = nil) -> FragmentOverlay? {
        let size = imageDisplaySize(natural: image.size, width: width, height: height)
        guard size.width > 0, size.height > 0 else { return nil }
        return FragmentOverlay(image: image, bounds: CGRect(origin: .zero, size: size))
    }

    private func imageDisplaySize(natural: NSSize, width: Int?, height: Int?) -> NSSize {
        var size = natural
        guard size.width > 0, size.height > 0 else { return .zero }
        switch (width, height) {
        case let (w?, h?): size = NSSize(width: CGFloat(w), height: CGFloat(h))
        case let (w?, nil): size = NSSize(width: CGFloat(w), height: size.height * CGFloat(w) / size.width)
        case let (nil, h?): size = NSSize(width: size.width * CGFloat(h) / size.height, height: CGFloat(h))
        case (nil, nil): break
        }
        let maxWidth = availableContentWidth
        if maxWidth > 0, size.width > maxWidth {
            size = NSSize(width: maxWidth, height: size.height * (maxWidth / size.width))
        }
        return size
    }

    /// Draws "icon  reason" into one image (same technique as the callout
    /// header: `LucideIcons.image` tinted to match the muted text), so a
    /// blocked/missing/undecodable image reads at a glance instead of just
    /// showing nothing.
    /// A placeholder overlay for a non-image `![[file]]` embed, labelled by the
    /// file's type (uses a `file-x` icon rather than the image `image-off`).
    func embedOverlay(destination: String, fontSize: CGFloat? = nil) -> FragmentOverlay? {
        placeholderOverlay(failure: .forEmbed(destination: destination), icon: "file-x", fontSize: fontSize)
    }

    private func placeholderOverlay(failure: ImageLoadFailure, icon iconName: String = "image-off",
                                    fontSize: CGFloat? = nil) -> FragmentOverlay? {
        let font = fontSize.map { bodyFont.withSize($0) } ?? bodyFont
        let pointSize = font.pointSize
        guard let icon = LucideIcons.image(iconName, color: .secondaryLabelColor, pointSize: pointSize)
        else { return nil }

        let labelAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let label = NSAttributedString(string: failure.label, attributes: labelAttrs)
        let labelSize = label.size()

        let gap = pointSize * 0.3
        let iconW = icon.size.width, iconH = icon.size.height
        let descent = -font.descender
        let textH = font.ascender + descent
        let height = ceil(max(iconH, textH))
        let width = ceil(iconW + gap + labelSize.width)
        // The label's baseline inside the image (y-up). The overlay's minY is
        // set to minus this so the label shares the surrounding text's
        // baseline; a bottom-on-baseline image floated it a descent too high.
        let baselineY = (height - textH) / 2 + descent

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            icon.draw(in: NSRect(x: 0, y: (height - iconH) / 2, width: iconW, height: iconH))
            // No `.usesLineFragmentOrigin`: the rect's origin is the baseline.
            label.draw(with: NSRect(x: iconW + gap, y: baselineY, width: labelSize.width, height: textH),
                       options: [])
            return true
        }
        image.cacheMode = .never   // re-rasterize at the screen's backing scale, like the callout header

        return FragmentOverlay(image: image, bounds: CGRect(x: 0, y: -baselineY, width: width, height: height))
    }
}
