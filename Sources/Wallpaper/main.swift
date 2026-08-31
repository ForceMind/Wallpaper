import AppKit
import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers

// MARK: - Domain

enum WallpaperSource: String, CaseIterable, Codable {
    case bing, unsplash, wikimedia, picsum, builtin

    func title(for language: AppLanguage) -> String {
        switch self {
        case .bing: return language == .english ? "Bing Daily" : "Bing 每日"
        case .unsplash: return language == .english ? "Unsplash Picks" : "Unsplash 精选"
        case .wikimedia: return language == .english ? "Wikimedia Commons" : "维基共享资源"
        case .picsum: return language == .english ? "Picsum Random" : "Picsum 随机"
        case .builtin: return language == .english ? "Built-in 120 Wallpapers" : "内置 120 张"
        }
    }
}

enum UpdateStrategy: String, CaseIterable, Codable {
    case manual, interval, daily, onLaunch, networkChange, randomWindow

    func title(for language: AppLanguage) -> String {
        switch self {
        case .manual: return language == .english ? "Manual only" : "仅手动"
        case .interval: return language == .english ? "Fixed interval" : "固定间隔"
        case .daily: return language == .english ? "Daily schedule" : "每日定时"
        case .onLaunch: return language == .english ? "On launch" : "启动时"
        case .networkChange: return language == .english ? "When network recovers" : "网络恢复"
        case .randomWindow: return language == .english ? "Random window" : "随机时间窗"
        }
    }
}

enum AppLanguage: String, Codable, CaseIterable {
    case chinese, english
}

struct AppSettings: Codable {
    var source: WallpaperSource = .bing
    var strategy: UpdateStrategy = .daily
    var language: AppLanguage = .chinese
    var intervalMinutes: Int = 60
    var dailyHour: Int = 9
    var dailyMinute: Int = 0
    var randomStartHour: Int = 8
    var randomEndHour: Int = 22
    var pauseUpdates = false
    var keepFiles = 20

    private enum CodingKeys: String, CodingKey { case source, strategy, language, intervalMinutes, dailyHour, dailyMinute, randomStartHour, randomEndHour, pauseUpdates, keepFiles }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(WallpaperSource.self, forKey: .source) ?? .bing
        strategy = try c.decodeIfPresent(UpdateStrategy.self, forKey: .strategy) ?? .daily
        language = try c.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .chinese
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 60
        dailyHour = try c.decodeIfPresent(Int.self, forKey: .dailyHour) ?? 9
        dailyMinute = try c.decodeIfPresent(Int.self, forKey: .dailyMinute) ?? 0
        randomStartHour = try c.decodeIfPresent(Int.self, forKey: .randomStartHour) ?? 8
        randomEndHour = try c.decodeIfPresent(Int.self, forKey: .randomEndHour) ?? 22
        pauseUpdates = try c.decodeIfPresent(Bool.self, forKey: .pauseUpdates) ?? false
        keepFiles = try c.decodeIfPresent(Int.self, forKey: .keepFiles) ?? 20
    }
}

struct WallpaperImage: Codable {
    let id: String
    let url: URL
    let title: String
    let source: WallpaperSource
}

// MARK: - Sources

protocol WallpaperProvider {
    var source: WallpaperSource { get }
    func fetch() async throws -> WallpaperImage
}

enum ProviderError: LocalizedError { case badResponse, emptyFeed, noData
    var errorDescription: String? { switch self { case .badResponse: return "服务响应无效"; case .emptyFeed: return "没有可用壁纸"; case .noData: return "图片数据为空" } }
}

struct BingProvider: WallpaperProvider {
    let source: WallpaperSource = .bing
    func fetch() async throws -> WallpaperImage {
        let items = try await fetchMany(limit: 1)
        guard let first = items.first else { throw ProviderError.emptyFeed }
        return first
    }

    func fetchMany(limit: Int) async throws -> [WallpaperImage] {
        var components = URLComponents(string: "https://www.bing.com/HPImageArchive.aspx")!
        components.queryItems = [URLQueryItem(name: "format", value: "js"), URLQueryItem(name: "idx", value: "0"), URLQueryItem(name: "n", value: "\(max(1, min(limit, 8)))"), URLQueryItem(name: "mkt", value: "zh-CN")]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProviderError.badResponse }
        struct Feed: Decodable { struct Item: Decodable { let url: String; let hsh: String?; let copyright: String? }; let images: [Item] }
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        let images = feed.images.map { item -> WallpaperImage in
            let imageURL: URL
            if let absolute = URL(string: item.url), absolute.scheme != nil { imageURL = absolute }
            else { imageURL = URL(string: "https://www.bing.com" + (item.url.hasPrefix("/") ? item.url : "/" + item.url))! }
            return WallpaperImage(id: item.hsh ?? imageURL.absoluteString, url: imageURL, title: item.copyright ?? "Bing 每日壁纸", source: source)
        }
        guard !images.isEmpty else { throw ProviderError.emptyFeed }
        return images
    }
}

struct UnsplashProvider: WallpaperProvider {
    let source: WallpaperSource = .unsplash
    func fetch() async throws -> WallpaperImage {
        let images = [
            ("1500534623283-312aade485b7", "https://images.unsplash.com/photo-1500534623283-312aade485b7?auto=format&fit=crop&w=3840&q=85", "Unsplash 山谷"),
            ("1497250681960-ef046c08a56e", "https://images.unsplash.com/photo-1497250681960-ef046c08a56e?auto=format&fit=crop&w=3840&q=85", "Unsplash 森林"),
            ("1501785888041-af3ef285b470", "https://images.unsplash.com/photo-1501785888041-af3ef285b470?auto=format&fit=crop&w=3840&q=85", "Unsplash 湖畔")
        ]
        let index = (Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0) % images.count
        let selected = images[index]
        return WallpaperImage(id: "unsplash-\(selected.0)", url: URL(string: selected.1)!, title: selected.2, source: source)
    }
}

struct PicsumProvider: WallpaperProvider {
    let source: WallpaperSource = .picsum
    func fetch() async throws -> WallpaperImage {
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
        return WallpaperImage(id: "picsum-\(day)", url: URL(string: "https://picsum.photos/3840/2160?random=\(day)")!, title: "Picsum 随机图片", source: source)
    }
}

struct WikimediaProvider: WallpaperProvider {
    let source: WallpaperSource = .wikimedia
    func fetch() async throws -> WallpaperImage {
        var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: "featured landscape"),
            URLQueryItem(name: "gsrnamespace", value: "6"),
            URLQueryItem(name: "gsrlimit", value: "1"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url"),
            URLQueryItem(name: "iiurlwidth", value: "3840"),
            URLQueryItem(name: "format", value: "json")
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProviderError.badResponse }
        struct Feed: Decodable {
            struct Query: Decodable {
                struct Page: Decodable { struct Info: Decodable { let thumburl: String?; let url: String }; let title: String; let imageinfo: [Info] }
                let pages: [String: Page]
            }
            let query: Query?
        }
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        guard let page = feed.query?.pages.values.first, let info = page.imageinfo.first,
              let imageURL = URL(string: info.thumburl ?? info.url) else { throw ProviderError.emptyFeed }
        return WallpaperImage(id: "wikimedia-\(page.title)", url: imageURL, title: "维基：\(page.title)", source: source)
    }
}

struct BuiltInProvider: WallpaperProvider {
    let source: WallpaperSource = .builtin
    let language: AppLanguage
    private let count = 120

    func fetch() async throws -> WallpaperImage {
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        let index = (day - 1) % count
        let file = try fileURL(index: index)
        let title = language == .english ? "Built-in wallpaper #\(index + 1)" : "内置壁纸 #\(index + 1)"
        return WallpaperImage(id: "builtin-\(index + 1)", url: file, title: title, source: source)
    }

    func fileURL(index: Int) throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Wallpaper/BuiltIn", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(String(format: "wallpaper-%03d.png", index + 1))
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        let width = 1600, height = 1000
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ProviderError.noData }
        let hue = Double(index % 24) / 24.0
        let top = NSColor(hue: CGFloat(hue), saturation: 0.60, brightness: 0.22, alpha: 1).cgColor
        let bottom = NSColor(hue: CGFloat((hue + 0.08).truncatingRemainder(dividingBy: 1)), saturation: 0.72, brightness: 0.78, alpha: 1).cgColor
        let gradient = CGGradient(colorsSpace: colorSpace, colors: [top, bottom] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        for layer in 0..<6 {
            let x = CGFloat((index * 97 + layer * 211) % width)
            let y = CGFloat(90 + (index * 53 + layer * 137) % (height - 180))
            let radius = CGFloat(100 + (index * 31 + layer * 47) % 260)
            context.setFillColor(NSColor(white: 1, alpha: 0.035 + CGFloat(layer) * 0.012).cgColor)
            context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        guard let cgImage = context.makeImage(), let destinationRef = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ProviderError.noData }
        CGImageDestinationAddImage(destinationRef, cgImage, nil)
        guard CGImageDestinationFinalize(destinationRef) else { throw ProviderError.noData }
        return destination
    }
}

// MARK: - Cache and desktop integration

final class WallpaperManager {
    private let fileManager = FileManager.default
    private let settingsStore: SettingsStore
    private(set) var lastImage: WallpaperImage?
    private(set) var lastError: String?

    init(settingsStore: SettingsStore) { self.settingsStore = settingsStore }

    var cacheDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Wallpaper/Cache", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func update() async -> Result<WallpaperImage, Error> {
        let preferred = settingsStore.settings.source
        let providers: [WallpaperProvider] = [provider(for: preferred), provider(for: .bing), provider(for: .unsplash), provider(for: .wikimedia), provider(for: .picsum), provider(for: .builtin)]
        var seen = Set<WallpaperSource>()
        for provider in providers where seen.insert(provider.source).inserted {
            do {
                let image = try await provider.fetch()
                let localURL = try await download(image)
                try setDesktop(url: localURL)
                lastImage = image; lastError = nil
                pruneCache(keeping: settingsStore.settings.keepFiles)
                return .success(image)
            } catch { lastError = error.localizedDescription }
        }
        return .failure(ProviderError.noData)
    }

    private func provider(for source: WallpaperSource) -> WallpaperProvider {
        switch source {
        case .bing: return BingProvider()
        case .unsplash: return UnsplashProvider()
        case .wikimedia: return WikimediaProvider()
        case .picsum: return PicsumProvider()
        case .builtin: return BuiltInProvider(language: settingsStore.settings.language)
        }
    }

    private func download(_ image: WallpaperImage) async throws -> URL {
        // URLSession's download API streams to a temporary file, keeping peak memory
        // close to constant even for 4K images.
        let (temporaryURL, response) = try await URLSession.shared.download(from: image.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProviderError.badResponse }
        let ext = ((response as? HTTPURLResponse)?.mimeType == "image/png") ? "png" : "jpg"
        let destination = cacheDirectory.appendingPathComponent("\(image.source.rawValue)-\(image.id).\(ext)")
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } else {
            try? fileManager.removeItem(at: temporaryURL)
        }
        return destination
    }

    private func setDesktop(url: URL) throws {
        for screen in NSScreen.screens { try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:]) }
    }

    func apply(localURL: URL, title: String = "内置壁纸", source: WallpaperSource = .builtin) throws {
        try setDesktop(url: localURL)
        lastImage = WallpaperImage(id: localURL.lastPathComponent, url: localURL, title: title, source: source)
        lastError = nil
    }

    func apply(image: WallpaperImage) async throws {
        let localURL = image.url.isFileURL ? image.url : try await download(image)
        try setDesktop(url: localURL)
        lastImage = image
        lastError = nil
    }

    func cachePreview(_ image: WallpaperImage) async throws -> URL {
        let previewDirectory = cacheDirectory.appendingPathComponent("Preview", isDirectory: true)
        try fileManager.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        let safeID = image.id.replacingOccurrences(of: "/", with: "-")
        let destination = previewDirectory.appendingPathComponent("\(image.source.rawValue)-\(safeID).jpg")
        if fileManager.fileExists(atPath: destination.path) { return destination }
        let (temporaryURL, response) = try await URLSession.shared.download(from: image.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProviderError.badResponse }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func pruneCache(keeping limit: Int) {
        guard let files = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles), files.count > limit else { return }
        let sorted = files.sorted { (a, b) -> Bool in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
        sorted.prefix(max(0, files.count - limit)).forEach { try? fileManager.removeItem(at: $0) }
    }
}

final class SettingsStore {
    private let key = "Wallpaper.AppSettings"
    private(set) var settings: AppSettings { didSet { save() } }
    init() { if let data = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode(AppSettings.self, from: data) { settings = value } else { settings = AppSettings() } }
    private func save() { if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: key) } }
    func mutate(_ change: (inout AppSettings) -> Void) { var copy = settings; change(&copy); settings = copy }
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SettingsStore()
    private var statusItem: NSStatusItem!
    private var scheduler: ChangeScheduler!
    private var welcomeWindow: NSWindow?
    private var previewURLs: [URL] = []
    private var previewCandidates: [WallpaperImage] = []
    private var previewTitles: [String] = []
    private var previewSources: [WallpaperSource] = []
    private var previewButtons: [NSButton] = []
    private var previewLabels: [NSTextField] = []
    private weak var panelStatusLabel: NSTextField?
    private lazy var manager = WallpaperManager(settingsStore: store)
    private let statusTitle = "正在准备…"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "Wallpaper") {
            image.isTemplate = true
            statusItem.button?.image = image
        }
        statusItem.button?.title = store.settings.language == .english ? " Wallpaper" : " 壁纸"
        statusItem.button?.toolTip = store.settings.language == .english ? "Wallpaper" : "壁纸"
        scheduler = ChangeScheduler(settingsProvider: { [weak self] in self?.store.settings ?? AppSettings() }, changeHandler: { [weak self] _ in Task { await self?.performUpdate() } })
        scheduler.start(); rebuildMenu()
        if !UserDefaults.standard.bool(forKey: "Wallpaper.HasShownWelcome") { showWelcome() }
    }

    func performUpdate(manual: Bool = false) async {
        guard manual || !store.settings.pauseUpdates else { return }
        await MainActor.run { [weak self] in self?.panelStatusLabel?.stringValue = self?.store.settings.language == .english ? "Fetching from preferred source…" : "正在从首选来源获取…" }
        let result = await manager.update()
        await MainActor.run { [weak self] in
            guard let self else { return }; self.rebuildMenu()
            switch result {
            case .success(let image): self.panelStatusLabel?.stringValue = (self.store.settings.language == .english ? "Changed: " : "已更换：") + image.source.title(for: self.store.settings.language)
            case .failure: self.panelStatusLabel?.stringValue = self.store.settings.language == .english ? "All sources failed. Current wallpaper was kept." : "所有来源均失败，已保留当前壁纸。"; self.showError()
            }
        }
    }

    private func rebuildMenu() {
        let english = store.settings.language == .english
        let menu = NSMenu(); let state = manager.lastImage?.title ?? (english ? "Preparing…" : statusTitle)
        menu.addItem(withTitle: state, action: nil, keyEquivalent: "")
        menu.addItem(.separator()); menu.addItem(withTitle: english ? "Update now" : "立即更新", action: #selector(updateNow), keyEquivalent: "u")
        let pause = menu.addItem(withTitle: store.settings.pauseUpdates ? (english ? "Resume updates" : "恢复自动更新") : (english ? "Pause updates" : "暂停自动更新"), action: #selector(togglePause), keyEquivalent: "p"); pause.target = self
        let source = NSMenuItem(title: (english ? "Preferred source: " : "首选来源：") + store.settings.source.title(for: store.settings.language), action: nil, keyEquivalent: ""); let sourceMenu = NSMenu(); WallpaperSource.allCases.forEach { item in let child = NSMenuItem(title: item.selectionDescription(for: store.settings.language), action: #selector(selectSource(_:)), keyEquivalent: ""); child.representedObject = item.rawValue; child.target = self; sourceMenu.addItem(child) }; source.submenu = sourceMenu; menu.addItem(source)
        let strategy = NSMenuItem(title: (english ? "Change timing: " : "更换时机：") + store.settings.strategy.title(for: store.settings.language), action: nil, keyEquivalent: ""); let strategyMenu = NSMenu(); UpdateStrategy.allCases.forEach { item in let child = NSMenuItem(title: item.title(for: store.settings.language), action: #selector(selectStrategy(_:)), keyEquivalent: ""); child.representedObject = item.rawValue; child.target = self; strategyMenu.addItem(child) }; strategy.submenu = strategyMenu; menu.addItem(strategy)
        if store.settings.strategy == .interval {
            let cadence = NSMenuItem(title: english ? "Change interval: \(store.settings.intervalMinutes) min" : "更换间隔：\(store.settings.intervalMinutes) 分钟", action: nil, keyEquivalent: ""); let cadenceMenu = NSMenu(); [15, 30, 60, 180].forEach { minutes in let child = NSMenuItem(title: english ? "Every \(minutes) minutes" : "每 \(minutes) 分钟", action: #selector(selectInterval(_:)), keyEquivalent: ""); child.representedObject = minutes; child.target = self; cadenceMenu.addItem(child) }; cadence.submenu = cadenceMenu; menu.addItem(cadence)
        }
        if store.settings.strategy == .daily {
            let schedule = NSMenuItem(title: english ? String(format: "Daily at %02d:%02d", store.settings.dailyHour, store.settings.dailyMinute) : String(format: "每日 %02d:%02d 更换", store.settings.dailyHour, store.settings.dailyMinute), action: nil, keyEquivalent: "")
            let scheduleMenu = NSMenu(); [8, 9, 12, 18, 21].forEach { hour in let child = NSMenuItem(title: english ? String(format: "%02d:00", hour) : String(format: "%02d:00", hour), action: #selector(selectDailyTime(_:)), keyEquivalent: ""); child.representedObject = hour; child.target = self; scheduleMenu.addItem(child) }; schedule.submenu = scheduleMenu; menu.addItem(schedule)
        }
        if store.settings.strategy == .randomWindow {
            let window = NSMenuItem(title: english ? String(format: "Random window %02d:00–%02d:00", store.settings.randomStartHour, store.settings.randomEndHour) : String(format: "随机窗口 %02d:00–%02d:00", store.settings.randomStartHour, store.settings.randomEndHour), action: nil, keyEquivalent: "")
            let windowMenu = NSMenu(); [(8, 18), (8, 22), (18, 23)].forEach { range in let child = NSMenuItem(title: english ? String(format: "%02d:00–%02d:00", range.0, range.1) : String(format: "%02d:00–%02d:00", range.0, range.1), action: #selector(selectRandomWindow(_:)), keyEquivalent: ""); child.representedObject = "\(range.0)-\(range.1)"; child.target = self; windowMenu.addItem(child) }; window.submenu = windowMenu; menu.addItem(window)
        }
        let language = NSMenuItem(title: english ? "Language: English" : "语言：中文", action: nil, keyEquivalent: ""); let languageMenu = NSMenu(); AppLanguage.allCases.forEach { value in let child = NSMenuItem(title: value == .english ? "English" : "中文", action: #selector(selectLanguage(_:)), keyEquivalent: ""); child.representedObject = value.rawValue; child.target = self; languageMenu.addItem(child) }; language.submenu = languageMenu; menu.addItem(language)
        menu.addItem(withTitle: english ? "Open control panel" : "打开控制面板", action: #selector(openWelcome), keyEquivalent: "").target = self
        menu.addItem(.separator()); let folder = menu.addItem(withTitle: english ? "Open cache folder" : "打开缓存目录", action: #selector(openCache), keyEquivalent: ""); folder.target = self
        let quit = menu.addItem(withTitle: english ? "Quit Wallpaper" : "退出 Wallpaper", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self
        statusItem.menu = menu
    }

    @objc private func updateNow() { Task { await performUpdate(manual: true) } }
    @objc private func togglePause() { store.mutate { $0.pauseUpdates.toggle() }; scheduler.reschedule(); rebuildMenu() }
    @objc private func selectSource(_ sender: NSMenuItem) { if let raw = sender.representedObject as? String, let source = WallpaperSource(rawValue: raw) { store.mutate { $0.source = source }; scheduler.reschedule(); rebuildMenu(); reloadVisiblePanel() } }
    @objc private func selectStrategy(_ sender: NSMenuItem) { if let raw = sender.representedObject as? String, let strategy = UpdateStrategy(rawValue: raw) { store.mutate { $0.strategy = strategy }; scheduler.reschedule(); rebuildMenu() } }
    @objc private func selectInterval(_ sender: NSMenuItem) { if let minutes = sender.representedObject as? Int { store.mutate { $0.intervalMinutes = minutes }; scheduler.reschedule(); rebuildMenu() } }
    @objc private func selectDailyTime(_ sender: NSMenuItem) { if let hour = sender.representedObject as? Int { store.mutate { $0.dailyHour = hour; $0.dailyMinute = 0 }; scheduler.reschedule(); rebuildMenu() } }
    @objc private func selectRandomWindow(_ sender: NSMenuItem) { if let raw = sender.representedObject as? String { let parts = raw.split(separator: "-").compactMap { Int($0) }; if parts.count == 2 { store.mutate { $0.randomStartHour = parts[0]; $0.randomEndHour = parts[1] }; scheduler.reschedule(); rebuildMenu() } } }
    @objc private func selectLanguage(_ sender: NSMenuItem) { if let raw = sender.representedObject as? String, let language = AppLanguage(rawValue: raw) { store.mutate { $0.language = language }; scheduler.reschedule(); rebuildMenu(); reloadVisiblePanel() } }
    @objc private func openWelcome() { showWelcome() }
    @objc private func openCache() { NSWorkspace.shared.open(manager.cacheDirectory) }
    @objc private func quitApp() { NSApp.terminate(nil) }
    private func showError() { NSSound.beep() }
    private func reloadVisiblePanel() {
        guard welcomeWindow?.isVisible == true else { return }
        welcomeWindow?.orderOut(nil); welcomeWindow = nil; showWelcome()
    }

    private func showWelcome() {
        if let existing = welcomeWindow, existing.isVisible { existing.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let english = store.settings.language == .english
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Wallpaper"
        window.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: english ? "Choose a wallpaper" : "选择壁纸")
        label.frame = NSRect(x: 32, y: 535, width: 456, height: 28)
        label.alignment = .center
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        let hint = NSTextField(labelWithString: english ? "Low-resolution previews · click one to change your desktop" : "低清缩略图 · 点击即可更换当前桌面")
        hint.frame = NSRect(x: 32, y: 510, width: 456, height: 20); hint.alignment = .center; hint.textColor = .secondaryLabelColor; hint.font = .systemFont(ofSize: 12)
        let sourceInfo = NSTextField(labelWithString: store.settings.source.selectionDescription(for: store.settings.language))
        sourceInfo.frame = NSRect(x: 32, y: 484, width: 456, height: 20); sourceInfo.alignment = .center; sourceInfo.textColor = .secondaryLabelColor; sourceInfo.font = .systemFont(ofSize: 11)
        let grid = NSView(frame: NSRect(x: 30, y: 150, width: 460, height: 320))
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        let initialCandidates = WallpaperSourceCatalog.builtInCandidates(language: store.settings.language, start: day - 1, limit: 9)
        previewURLs = []; previewCandidates = []; previewTitles = []; previewSources = []; previewButtons = []; previewLabels = []
        for offset in 0..<9 {
            let row = offset / 3, column = offset % 3
            let cell = NSView(frame: NSRect(x: CGFloat(column) * 150, y: CGFloat(2 - row) * 104, width: 140, height: 94))
            cell.wantsLayer = true; cell.layer?.cornerRadius = 10; cell.layer?.masksToBounds = true
            let imageView = NSImageView(frame: cell.bounds); imageView.imageScaling = .scaleAxesIndependently; imageView.autoresizingMask = [.width, .height]
            let candidate = initialCandidates[offset]
            imageView.image = PreviewSupport.image(at: candidate.previewURL)
            cell.addSubview(imageView)
            let sourceLabel = NSTextField(labelWithString: candidate.source.title(for: store.settings.language))
            sourceLabel.frame = NSRect(x: 5, y: 5, width: 130, height: 16); sourceLabel.font = .systemFont(ofSize: 10, weight: .medium); sourceLabel.textColor = .white; sourceLabel.drawsBackground = true; sourceLabel.backgroundColor = NSColor.black.withAlphaComponent(0.55); sourceLabel.isBordered = false; sourceLabel.lineBreakMode = .byTruncatingTail; sourceLabel.alignment = .center; cell.addSubview(sourceLabel)
            let button = NSButton(frame: cell.bounds)
            button.isBordered = false; button.title = ""; button.target = self; button.action = #selector(selectPreview(_:)); button.autoresizingMask = [.width, .height]
            button.tag = offset
            previewURLs.append(candidate.image.url); previewCandidates.append(candidate.image)
            previewTitles.append(candidate.title); previewSources.append(candidate.source); previewButtons.append(button); previewLabels.append(sourceLabel)
            cell.addSubview(button); grid.addSubview(cell)
        }
        let status = NSTextField(labelWithString: english ? "Loading candidates…" : "正在加载候选壁纸…")
        status.frame = NSRect(x: 32, y: 112, width: 456, height: 20); status.alignment = .center; status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 11); panelStatusLabel = status
        let update = NSButton(title: english ? "Fetch and change now" : "立即获取并更换", target: self, action: #selector(updateNow)); update.frame = NSRect(x: 78, y: 48, width: 150, height: 34)
        let close = NSButton(title: english ? "Close" : "关闭", target: self, action: #selector(closeWelcome)); close.frame = NSRect(x: 292, y: 48, width: 150, height: 34)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 600))
        window.contentView?.addSubview(label); window.contentView?.addSubview(hint); window.contentView?.addSubview(sourceInfo); window.contentView?.addSubview(grid); window.contentView?.addSubview(status); window.contentView?.addSubview(update); window.contentView?.addSubview(close)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        welcomeWindow = window
        Task { await loadOnlinePreviews() }
    }
    private func thumbnail(for url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 220, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 140, height: 86))
    }
    private func loadOnlinePreviews() async {
        let candidates = await WallpaperSourceCatalog.candidates(preferred: store.settings.source, language: store.settings.language, limit: 9)
        let cached = await PreviewSupport.cache(candidates: candidates, in: manager.cacheDirectory, maxPixelSize: PreviewSupport.defaultMaxPixelSize)
        PreviewSupport.prunePreviewCache(in: manager.cacheDirectory)
        let sourceLabel = store.settings.source.title(for: store.settings.language)
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.panelStatusLabel?.stringValue = cached.isEmpty
                ? (self.store.settings.language == .english ? "Offline fallback: built-in wallpapers" : "在线来源不可用，当前为内置离线壁纸")
                : (self.store.settings.language == .english ? "Previewing candidates · preferred: \(sourceLabel)" : "候选已加载 · 首选来源：\(sourceLabel)")
        }
        for (index, pair) in cached.enumerated() {
            let candidate = pair.0.image
            let localURL = pair.1
            guard let image = PreviewSupport.image(at: localURL) else { continue }
            await MainActor.run { [weak self] in
                guard let self, index < self.previewButtons.count else { return }
                self.previewURLs[index] = candidate.url; self.previewCandidates[index] = candidate; self.previewTitles[index] = candidate.title; self.previewSources[index] = candidate.source
                self.previewButtons[index].image = image; self.previewLabels[index].stringValue = candidate.source.title(for: self.store.settings.language); self.previewButtons[index].toolTip = "\(candidate.source.title(for: self.store.settings.language)) · \(candidate.title)"
            }
        }
    }
    @objc private func selectPreview(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < previewURLs.count else { return }
        let candidate = previewCandidates[sender.tag]
        Task {
            do { try await manager.apply(image: candidate); await MainActor.run { [weak self] in self?.rebuildMenu() } }
            catch { await MainActor.run { [weak self] in self?.showError() } }
        }
    }
    @objc private func closeWelcome() { welcomeWindow?.orderOut(nil); UserDefaults.standard.set(true, forKey: "Wallpaper.HasShownWelcome") }
}

// Explicit AppKit entry point. Keeping the application/delegate wiring here
// avoids a silent background process when the compiler does not synthesize
// NSApplicationMain for an @main delegate class.
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
