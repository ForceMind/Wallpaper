import AppKit
import Foundation

// MARK: - Domain

enum WallpaperSource: String, CaseIterable, Codable {
    case bing, unsplash, picsum

    var title: String {
        switch self { case .bing: return "Bing 每日"; case .unsplash: return "Unsplash Source"; case .picsum: return "Picsum 兜底" }
    }
}

enum UpdateStrategy: String, CaseIterable, Codable {
    case manual, interval, daily, onLaunch, networkChange, randomWindow

    var title: String {
        switch self {
        case .manual: return "仅手动"
        case .interval: return "固定间隔"
        case .daily: return "每日定时"
        case .onLaunch: return "启动时"
        case .networkChange: return "网络变化"
        case .randomWindow: return "随机时间窗"
        }
    }
}

struct AppSettings: Codable {
    var source: WallpaperSource = .bing
    var strategy: UpdateStrategy = .daily
    var intervalMinutes: Int = 60
    var dailyHour: Int = 9
    var dailyMinute: Int = 0
    var randomStartHour: Int = 8
    var randomEndHour: Int = 22
    var pauseUpdates = false
    var keepFiles = 20
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
        var components = URLComponents(string: "https://www.bing.com/HPImageArchive.aspx")!
        components.queryItems = [URLQueryItem(name: "format", value: "js"), URLQueryItem(name: "idx", value: "0"), URLQueryItem(name: "n", value: "1"), URLQueryItem(name: "mkt", value: "zh-CN")]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProviderError.badResponse }
        struct Feed: Decodable { struct Item: Decodable { let url: String; let hsh: String?; let copyright: String? }; let images: [Item] }
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        guard let item = feed.images.first else { throw ProviderError.emptyFeed }
        let imageURL: URL
        if let absolute = URL(string: item.url), absolute.scheme != nil {
            imageURL = absolute
        } else {
            imageURL = URL(string: "https://www.bing.com" + (item.url.hasPrefix("/") ? item.url : "/" + item.url))!
        }
        return WallpaperImage(id: item.hsh ?? imageURL.absoluteString, url: imageURL, title: item.copyright ?? "Bing 每日壁纸", source: source)
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
        let providers: [WallpaperProvider] = [provider(for: preferred), provider(for: .bing), provider(for: .unsplash), provider(for: .picsum)]
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

    private func provider(for source: WallpaperSource) -> WallpaperProvider { switch source { case .bing: return BingProvider(); case .unsplash: return UnsplashProvider(); case .picsum: return PicsumProvider() } }

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

// MARK: - Scheduler

final class Scheduler {
    private var timer: Timer?
    private var lastDailyTrigger: String?
    private var lastRandomDay: Int?
    private weak var delegate: AppDelegate?
    init(delegate: AppDelegate) { self.delegate = delegate }
    func reschedule() {
        timer?.invalidate(); timer = nil
        let settings = delegate?.store.settings ?? AppSettings()
        guard !settings.pauseUpdates else { return }
        switch settings.strategy {
        case .manual: break
        case .onLaunch: Task { await delegate?.performUpdate() }
        case .interval:
            timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(5, settings.intervalMinutes) * 60), repeats: true) { [weak self] _ in Task { await self?.delegate?.performUpdate() } }
        case .daily, .randomWindow:
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.checkTimeWindow() }
        case .networkChange:
            timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in Task { await self?.delegate?.performUpdate() } }
        }
    }
    private func checkTimeWindow() {
        guard let delegate else { return }; let s = delegate.store.settings; let now = Calendar.current.dateComponents([.hour, .minute], from: Date()); let hour = now.hour ?? 0
        if s.strategy == .daily, hour == s.dailyHour, (now.minute ?? -1) == s.dailyMinute {
            let key = "\(Calendar.current.component(.year, from: Date()))-\(Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0)"
            guard lastDailyTrigger != key else { return }
            lastDailyTrigger = key
            Task { await delegate.performUpdate() }
        }
        if s.strategy == .randomWindow, hour >= s.randomStartHour, hour < s.randomEndHour,
           lastRandomDay != (Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0), Bool.random() {
            lastRandomDay = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 0
            Task { await delegate.performUpdate() }
        }
    }
}

// MARK: - Menu bar app

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SettingsStore()
    private var statusItem: NSStatusItem!
    private var scheduler: Scheduler!
    private lazy var manager = WallpaperManager(settingsStore: store)
    private let statusTitle = "正在准备…"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "壁纸")
        scheduler = Scheduler(delegate: self); scheduler.reschedule(); rebuildMenu()
    }

    func performUpdate() async {
        guard !store.settings.pauseUpdates else { return }
        let result = await manager.update()
        await MainActor.run { [weak self] in
            guard let self else { return }; self.rebuildMenu()
            if case .failure = result { self.showError() }
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu(); let state = manager.lastImage?.title ?? statusTitle
        menu.addItem(withTitle: state, action: nil, keyEquivalent: "")
        menu.addItem(.separator()); menu.addItem(withTitle: "立即更新", action: #selector(updateNow), keyEquivalent: "u")
        let pause = menu.addItem(withTitle: store.settings.pauseUpdates ? "恢复自动更新" : "暂停自动更新", action: #selector(togglePause), keyEquivalent: "p"); pause.target = self
        let source = NSMenuItem(title: "壁纸来源：\(store.settings.source.title)", action: nil, keyEquivalent: ""); let sourceMenu = NSMenu(); WallpaperSource.allCases.forEach { item in let child = NSMenuItem(title: item.title, action: #selector(selectSource(_:)), keyEquivalent: ""); child.representedObject = item.rawValue; child.target = self; sourceMenu.addItem(child) }; source.submenu = sourceMenu; menu.addItem(source)
        let strategy = NSMenuItem(title: "更新策略：\(store.settings.strategy.title)", action: nil, keyEquivalent: ""); let strategyMenu = NSMenu(); UpdateStrategy.allCases.forEach { item in let child = NSMenuItem(title: item.title, action: #selector(selectStrategy(_:)), keyEquivalent: ""); child.representedObject = item.rawValue; child.target = self; strategyMenu.addItem(child) }; strategy.submenu = strategyMenu; menu.addItem(strategy)
        let cadence = NSMenuItem(title: "间隔：\(store.settings.intervalMinutes) 分钟", action: nil, keyEquivalent: ""); let cadenceMenu = NSMenu(); [15, 30, 60, 180].forEach { minutes in let child = NSMenuItem(title: "每 \(minutes) 分钟", action: #selector(selectInterval(_:)), keyEquivalent: ""); child.representedObject = minutes; child.target = self; cadenceMenu.addItem(child) }; cadence.submenu = cadenceMenu; menu.addItem(cadence)
        menu.addItem(.separator()); let folder = menu.addItem(withTitle: "打开缓存目录", action: #selector(openCache), keyEquivalent: ""); folder.target = self
        let quit = menu.addItem(withTitle: "退出 Wallpaper", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self
        statusItem.menu = menu
    }

    @objc private func updateNow() { Task { await performUpdate() } }
    @objc private func togglePause() { store.mutate { $0.pauseUpdates.toggle() }; scheduler.reschedule(); rebuildMenu() }
    @objc private func selectSource(_ sender: NSMenuItem) { if let raw = sender.representedObject as? String, let source = WallpaperSource(rawValue: raw) { store.mutate { $0.source = source }; scheduler.reschedule(); rebuildMenu() } }
    @objc private func selectStrategy(_ sender: NSMenuItem) { if let raw = sender.representedObject as? String, let strategy = UpdateStrategy(rawValue: raw) { store.mutate { $0.strategy = strategy }; scheduler.reschedule(); rebuildMenu() } }
    @objc private func selectInterval(_ sender: NSMenuItem) { if let minutes = sender.representedObject as? Int { store.mutate { $0.intervalMinutes = minutes }; scheduler.reschedule(); rebuildMenu() } }
    @objc private func openCache() { NSWorkspace.shared.open(manager.cacheDirectory) }
    @objc private func quitApp() { NSApp.terminate(nil) }
    private func showError() { NSSound.beep() }
}
