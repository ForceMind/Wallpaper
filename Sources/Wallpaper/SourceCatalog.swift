import Foundation

/// Metadata used by the UI to explain what selecting a source means.
/// A source is a preference for the next automatic fetch; it is not a
/// separate replacement schedule.
struct WallpaperSourceDescriptor {
    let source: WallpaperSource
    let isOnline: Bool
    let refreshDescriptionChinese: String
    let refreshDescriptionEnglish: String

    func refreshDescription(for language: AppLanguage) -> String {
        language == .english ? refreshDescriptionEnglish : refreshDescriptionChinese
    }
}

extension WallpaperSource {
    var isOnlineSource: Bool { self != .builtin }

    /// A concise explanation suitable for a source picker subtitle or tooltip.
    func selectionDescription(for language: AppLanguage) -> String {
        "\(title(for: language)) · \(descriptor.refreshDescription(for: language))"
    }

    var descriptor: WallpaperSourceDescriptor {
        switch self {
        case .bing:
            return WallpaperSourceDescriptor(source: self, isOnline: true,
                refreshDescriptionChinese: "每天一张，自动跟随 Bing 当日内容",
                refreshDescriptionEnglish: "One image per day, following Bing's daily content")
        case .unsplash:
            return WallpaperSourceDescriptor(source: self, isOnline: true,
                refreshDescriptionChinese: "自动从精选候选中去重选择",
                refreshDescriptionEnglish: "Selects and de-duplicates from featured candidates")
        case .wikimedia:
            return WallpaperSourceDescriptor(source: self, isOnline: true,
                refreshDescriptionChinese: "自动获取精选公共许可图片",
                refreshDescriptionEnglish: "Fetches featured openly licensed images automatically")
        case .picsum:
            return WallpaperSourceDescriptor(source: self, isOnline: true,
                refreshDescriptionChinese: "按日期生成稳定的随机图片",
                refreshDescriptionEnglish: "Stable date-seeded random images")
        case .builtin:
            return WallpaperSourceDescriptor(source: self, isOnline: false,
                refreshDescriptionChinese: "离线可用，内置 120 套壁纸兜底",
                refreshDescriptionEnglish: "Always available offline, with 120 built-in fallbacks")
        }
    }
}

/// A full-resolution image plus a deliberately smaller URL used by the
/// preview grid. Keeping these URLs separate avoids downloading eight 4K
/// images merely to paint a 220px thumbnail.
struct WallpaperCandidate {
    let image: WallpaperImage
    let previewURL: URL

    var source: WallpaperSource { image.source }
    var title: String { image.title }
}

/// Fetches candidate images for the control panel. Requests are sequential and
/// bounded so a failed source cannot cause a burst of downloads or high memory.
enum WallpaperSourceCatalog {
    static let builtInCount = 120
    static let fallbackOrder: [WallpaperSource] = [.bing, .unsplash, .wikimedia, .picsum, .builtin]

    static func orderedSources(preferred: WallpaperSource) -> [WallpaperSource] {
        [preferred] + fallbackOrder.filter { $0 != preferred }
    }

    static func candidates(preferred: WallpaperSource, language: AppLanguage, limit: Int = 9) async -> [WallpaperCandidate] {
        let wanted = max(1, min(limit, 9))
        var collected: [WallpaperCandidate] = []
        var seenIDs = Set<String>()
        for source in orderedSources(preferred: preferred) {
            do {
                let values = try await fetch(source: source, language: language, limit: wanted)
                for value in values where seenIDs.insert(value.image.id).inserted {
                    collected.append(value)
                    if collected.count == wanted { return collected }
                }
            } catch {
                // Candidate previews are best effort. The next source is the
                // documented fallback, with built-in always last.
            }
        }
        return collected
    }

    static func builtInCandidates(language: AppLanguage, start: Int = 0, limit: Int = 9) -> [WallpaperCandidate] {
        let provider = BuiltInProvider(language: language)
        let count = max(1, min(limit, 9))
        return (0..<count).compactMap { offset in
            let index = (start + offset).positiveModulo(builtInCount)
            guard let url = try? provider.fileURL(index: index) else { return nil }
            let title = language == .english ? "Built-in wallpaper #\(index + 1)" : "内置壁纸 #\(index + 1)"
            let image = WallpaperImage(id: "builtin-\(index + 1)", url: url, title: title, source: .builtin)
            return WallpaperCandidate(image: image, previewURL: url)
        }
    }

    private static func fetch(source: WallpaperSource, language: AppLanguage, limit: Int) async throws -> [WallpaperCandidate] {
        switch source {
        case .bing: return try await bing(limit: limit)
        case .unsplash: return unsplash(limit: limit)
        case .wikimedia: return try await wikimedia(limit: limit)
        case .picsum: return picsum(limit: limit)
        case .builtin: return builtInCandidates(language: language, start: 0, limit: limit)
        }
    }

    private static func bing(limit: Int) async throws -> [WallpaperCandidate] {
        var components = URLComponents(string: "https://www.bing.com/HPImageArchive.aspx")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "js"),
            URLQueryItem(name: "idx", value: "0"),
            URLQueryItem(name: "n", value: "\(max(1, min(limit, 8)))"),
            URLQueryItem(name: "mkt", value: "zh-CN")
        ]
        let request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 12)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProviderError.badResponse }
        struct Feed: Decodable {
            struct Item: Decodable { let url: String; let hsh: String?; let copyright: String? }
            let images: [Item]
        }
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        let values = feed.images.compactMap { item -> WallpaperCandidate? in
            let full: URL
            if let absolute = URL(string: item.url), absolute.scheme != nil { full = absolute }
            else { full = URL(string: "https://www.bing.com" + (item.url.hasPrefix("/") ? item.url : "/" + item.url))! }
            var preview = URLComponents(url: full, resolvingAgainstBaseURL: false)!
            var query = preview.queryItems ?? []
            query.append(URLQueryItem(name: "w", value: "640"))
            preview.queryItems = query
            let title = item.copyright ?? "Bing 每日壁纸"
            let image = WallpaperImage(id: item.hsh ?? full.absoluteString, url: full, title: title, source: .bing)
            return WallpaperCandidate(image: image, previewURL: preview.url ?? full)
        }
        guard !values.isEmpty else { throw ProviderError.emptyFeed }
        return values
    }

    private static func unsplash(limit: Int) -> [WallpaperCandidate] {
        let photos: [(String, String)] = [
            ("1500534623283-312aade485b7", "山谷"), ("1497250681960-ef046c08a56e", "森林"),
            ("1501785888041-af3ef285b470", "湖畔"), ("1470770841072-f978cf4d019e", "山路"),
            ("1469474968028-56623f02e42e", "海岸"), ("1500530855697-b586d89ba3ee", "雾林"),
            ("1441974231531-c6227db76b6e", "树林"), ("1511497584788-876760111969", "沙漠"),
            ("1500534314209-a25ddb2bd429", "云海"), ("1501854140801-50d01698950b", "雪山"),
            ("1464822759023-fed622ff2c3b", "群山"), ("1433086966358-54859d0ed716", "瀑布")
        ]
        return photos.prefix(max(1, min(limit, photos.count))).map { id, label in
            var full = URLComponents(string: "https://images.unsplash.com/photo-\(id)")!
            full.queryItems = [URLQueryItem(name: "auto", value: "format"), URLQueryItem(name: "fit", value: "crop"), URLQueryItem(name: "w", value: "2560"), URLQueryItem(name: "q", value: "85")]
            var preview = full; preview.queryItems = [URLQueryItem(name: "auto", value: "format"), URLQueryItem(name: "fit", value: "crop"), URLQueryItem(name: "w", value: "640"), URLQueryItem(name: "q", value: "50")]
            let image = WallpaperImage(id: "unsplash-\(id)", url: full.url!, title: "Unsplash \(label)", source: .unsplash)
            return WallpaperCandidate(image: image, previewURL: preview.url!)
        }
    }

    private static func picsum(limit: Int) -> [WallpaperCandidate] {
        let ids = [10, 28, 35, 42, 55, 67, 82, 96, 103]
        return ids.prefix(max(1, min(limit, ids.count))).map { id in
            let full = URL(string: "https://picsum.photos/id/\(id)/3840/2160")!
            let preview = URL(string: "https://picsum.photos/id/\(id)/640/360")!
            let image = WallpaperImage(id: "picsum-\(id)", url: full, title: "Picsum #\(id)", source: .picsum)
            return WallpaperCandidate(image: image, previewURL: preview)
        }
    }

    private static func wikimedia(limit: Int) async throws -> [WallpaperCandidate] {
        var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: "featured landscape"), URLQueryItem(name: "gsrnamespace", value: "6"),
            URLQueryItem(name: "gsrlimit", value: "\(max(1, min(limit, 9)))"), URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url"), URLQueryItem(name: "iiurlwidth", value: "640"), URLQueryItem(name: "format", value: "json")
        ]
        let request = URLRequest(url: components.url!, timeoutInterval: 12)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProviderError.badResponse }
        struct Feed: Decodable {
            struct Query: Decodable {
                struct Page: Decodable { struct Info: Decodable { let thumburl: String?; let url: String }; let title: String; let imageinfo: [Info] }
                let pages: [String: Page]
            }
            let query: Query?
        }
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        guard let pages = feed.query?.pages.values else { throw ProviderError.emptyFeed }
        let values = pages.compactMap { page -> WallpaperCandidate? in
            guard let info = page.imageinfo.first, let full = URL(string: info.url) else { return nil }
            let preview = URL(string: info.thumburl ?? info.url) ?? full
            let image = WallpaperImage(id: "wikimedia-\(page.title)", url: full, title: "维基：\(page.title)", source: .wikimedia)
            return WallpaperCandidate(image: image, previewURL: preview)
        }
        guard !values.isEmpty else { throw ProviderError.emptyFeed }
        return Array(values.prefix(limit))
    }
}

private extension Int {
    func positiveModulo(_ divisor: Int) -> Int {
        let value = self % divisor
        return value >= 0 ? value : value + divisor
    }
}
