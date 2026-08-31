import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Low-memory thumbnail and preview-cache helpers used by the control panel.
/// The original image is streamed to a temporary file, decoded at a bounded
/// pixel size, and immediately written as a small JPEG. At most one source
/// image is decoded at a time.
enum PreviewSupport {
    static let defaultMaxPixelSize = 220
    static let defaultCacheLimit = 36

    static func image(at url: URL, maxPixelSize: Int = defaultMaxPixelSize) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(32, maxPixelSize)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }

    /// Cache one candidate's preview. `candidate.previewURL` should already be
    /// a low-resolution endpoint where the source supports one.
    static func cache(candidate: WallpaperCandidate, in directory: URL,
                      maxPixelSize: Int = defaultMaxPixelSize) async throws -> URL {
        let previewDirectory = directory.appendingPathComponent("Preview", isDirectory: true)
        try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        let safeID = candidate.image.id
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let destination = previewDirectory.appendingPathComponent("\(candidate.source.rawValue)-\(safeID)-\(maxPixelSize).jpg")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        let sourceURL: URL
        var temporaryURL: URL?
        if candidate.previewURL.isFileURL {
            sourceURL = candidate.previewURL
        } else {
            let (url, response) = try await URLSession.shared.download(from: candidate.previewURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? FileManager.default.removeItem(at: url)
                throw ProviderError.badResponse
            }
            sourceURL = url
            temporaryURL = url
        }
        defer { if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) } }

        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else { throw ProviderError.noData }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(32, maxPixelSize)
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destinationRef = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ProviderError.noData
        }
        CGImageDestinationAddImage(destinationRef, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(destinationRef) else { throw ProviderError.noData }
        return destination
    }

    /// Sequentially materialize thumbnails so nine large source images never
    /// coexist in memory. The returned tuple retains source metadata for UI
    /// labels and selection actions.
    static func cache(candidates: [WallpaperCandidate], in directory: URL,
                      maxPixelSize: Int = defaultMaxPixelSize) async -> [(WallpaperCandidate, URL)] {
        var result: [(WallpaperCandidate, URL)] = []
        result.reserveCapacity(candidates.count)
        for candidate in candidates {
            if let url = try? await cache(candidate: candidate, in: directory, maxPixelSize: maxPixelSize) {
                result.append((candidate, url))
            }
        }
        return result
    }

    /// Keep preview cache bounded independently from full-resolution wallpaper
    /// files. Modification time gives predictable least-recently-written
    /// eviction without retaining image objects.
    static func prunePreviewCache(in directory: URL, keeping limit: Int = defaultCacheLimit) {
        let previewDirectory = directory.appendingPathComponent("Preview", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: previewDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles), files.count > limit else { return }
        let sorted = files.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhs < rhs
        }
        for file in sorted.prefix(files.count - max(0, limit)) { try? FileManager.default.removeItem(at: file) }
    }
}
