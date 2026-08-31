// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Wallpaper",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Wallpaper", targets: ["Wallpaper"])],
    targets: [.executableTarget(name: "Wallpaper")]
)
