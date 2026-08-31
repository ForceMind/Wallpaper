# Wallpaper

轻量 macOS 菜单栏壁纸应用，使用 Swift + AppKit + SwiftPM 构建，不依赖第三方运行时。应用不显示 Dock 图标，常驻状态栏照片按钮。

## 功能

- 壁纸源：Bing 每日壁纸、Unsplash 精选、Picsum（自动回退）。
- 额外在线源：Wikimedia Commons 精选风景图。
- 离线源：内置 120 套程序化壁纸，首次使用时按需生成，不占用大量安装包空间。
- 界面语言：默认中文，可在菜单栏切换 English；设置会持久化。
- 更新策略：仅手动、固定间隔、每日定时、启动时、网络变化（轮询兜底）、随机时间窗。
- 缓存：写入 `~/Library/Application Support/Wallpaper/Cache`，默认最多保留 20 张并按修改时间淘汰。
- 菜单栏操作：立即更新、暂停/恢复自动更新、切换来源与策略、选择 15/30/60/180 分钟间隔、打开缓存目录、退出。
- 低内存设计：无图片列表 UI，下载完成后直接写盘并交给系统桌面服务；只保留轻量元数据。

## 更新策略

这里有两个不同概念：

- **来源刷新**：程序自动处理。Bing 按每日内容更新，其他在线源按请求结果、重定向和缓存自动适配，用户不需要设置。
- **更换时机**：用户唯一需要调整的部分，决定本机桌面什么时候换成下一张图。菜单中的“更换时机”和“更换间隔”只控制这一层。

| 策略 | 行为 | 适用场景 |
| --- | --- | --- |
| 仅手动 | 不创建定时器，只响应“立即更新” | 流量敏感或完全自定义 |
| 固定间隔 | 按设置的 15/30/60/180 分钟执行 | 高频更换 |
| 每日定时 | 默认每天 09:00 执行一次 | 每日一图 |
| 启动时 | 应用启动后立即执行一次 | 登录后刷新 |
| 网络变化 | 每 5 分钟检查一次并更新 | 网络恢复后的兜底同步 |
| 随机时间窗 | 默认 08:00–22:00，每天随机触发一次 | 不规律更换 |

网络请求失败会自动按“首选来源 → Bing → Unsplash → Wikimedia → Picsum → 内置壁纸”顺序回退。完全离线时仍可从内置 120 套壁纸继续更新。图片下载采用文件流接口，避免把整张 4K 图片保存在 Swift `Data` 中；缓存达到上限后按文件修改时间淘汰最旧文件。

## 图标

应用图标位于 `Assets/AppIcon.png`，由日出、山脉和湖泊构成的圆角玻璃图标。打包脚本会自动把它复制到 App Bundle 的 Resources 并写入 `Info.plist`。

## 构建与运行

需要 macOS 13+ 和 Swift 5.9+。推荐使用与 macOS SDK 匹配的完整 Xcode：

```bash
swift build -c release
.build/release/Wallpaper
```

生成可双击的 `.app`：

```bash
./scripts/build-app.sh
open dist/Wallpaper.app
```

安装到当前用户的 Applications 目录：

```bash
mkdir -p "$HOME/Applications"
ditto dist/Wallpaper.app "$HOME/Applications/Wallpaper.app"
open "$HOME/Applications/Wallpaper.app"
```

首次运行若 macOS 提示来源未验证，可在“系统设置 → 隐私与安全性”中允许打开。应用只需要网络访问和更改桌面图片的系统权限，不上传用户文件。

启动后会显示一次简短控制面板，同时在菜单栏放置“壁纸”图标。关闭控制面板后，点击菜单栏图标即可重新打开；如果菜单栏很拥挤，图标可能收进右侧的“控制中心”区域，也可以直接从 Applications 双击应用重新打开控制面板。

### 故障排查

- **看不到窗口**：确认运行的是 `Wallpaper.app`，而不是只打开了源码目录；重新双击 Applications 中的应用即可。
- **看不到菜单栏图标**：检查菜单栏最右侧或控制中心的隐藏项目；应用使用 `LSUIElement`，不会出现在 Dock 中。
- **没有网络**：选择“内置 120 张”来源，或等待自动回退；内置壁纸会在 `~/Library/Application Support/Wallpaper/BuiltIn` 按需生成。
- **壁纸没有立即变化**：点击控制面板的“立即更新”；启动时会自动尝试一次，失败会静默回退到内置壁纸。

## 发布 Release

维护者可使用以下命令创建版本（示例为 `v1.0.0`）：

```bash
./scripts/build-app.sh
ditto -c -k --sequesterRsrc --keepParent dist/Wallpaper.app dist/Wallpaper-v1.0.0.zip
gh release create v1.0.0 dist/Wallpaper-v1.0.0.zip --title "Wallpaper v1.0.0" --generate-notes
```

首次运行后点击菜单栏照片图标即可操作。网络不可用时会按 Bing → Unsplash → Picsum 顺序回退；所有设置保存在 `UserDefaults`。

## 后续扩展

可在 `WallpaperProvider` 协议上增加本地文件夹、RSS/JSON API、NASA APOD 等来源；内置壁纸目录可扩展到更多程序化主题；调度器可替换为 `NSWorkspace` 登录/解锁通知和 `NWPathMonitor` 以获得更即时的系统事件。
