import AppKit

enum BrandIcon {
    // Finder / Dock / app switcher / native dialogs / menu bar / in-app branding
    // share this exact bundle resource. No system-symbol fallback.
    static let image: NSImage = {
        guard let name=Bundle.main.object(forInfoDictionaryKey:"CFBundleIconFile") as? String,
              let url=Bundle.main.url(forResource:name,withExtension:nil),
              let icon=NSImage(contentsOf:url) else { preconditionFailure("AppIcon.icns missing from application bundle") }
        icon.isTemplate=false
        icon.accessibilityDescription="提示词工作台蛛网图标"
        return icon
    }()
    static var menuBar: NSImage {
        let icon=image.copy() as! NSImage
        icon.size=NSSize(width:22,height:22)
        icon.isTemplate=false
        return icon
    }
}
