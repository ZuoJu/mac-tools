import AppKit
import ApplicationServices
import CoreKit
import Foundation

/// 系统剪贴板监听器：轮询 changeCount（Maccy 同款低开销方案），变化时抓取内容。
public final class ClipboardMonitor {
    /// 需要忽略的敏感应用（密码管理器等）。
    public static let sensitiveAppBundleIDs: Set<String> = [
        "com.agilebits.onepassword-osx",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.apple.keychainaccess",
    ]

    public var onCaptured: ((ClipboardItem) -> Void)?
    /// 组合根可注入额外的忽略名单（来自设置）。
    public var extraIgnoredBundleIDs: Set<String> = []
    public var ignoreSensitiveApps = true

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    /// 单条文本最大保存长度。
    private static let maxTextLength = 100_000

    public init() {}

    public var isRunning: Bool { timer != nil }

    public func start(interval: TimeInterval = 0.5) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 应用自身回写剪贴板后调用，避免把自己复制的内容再次入历史。
    public func suppressCurrentChange() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        let ignored = ignoreSensitiveApps ? Self.sensitiveAppBundleIDs.union(extraIgnoredBundleIDs) : extraIgnoredBundleIDs
        if let item = Self.captureItem(imagesDirectory: AppPaths.clipboardImages, ignoredBundleIDs: ignored) {
            onCaptured?(item)
        }
    }

    /// 从剪贴板抓取一条内容；优先级：文件 > 文本 > 图片。
    public static func captureItem(
        imagesDirectory: URL,
        ignoredBundleIDs: Set<String>,
        pasteboard: NSPasteboard = .general,
        date: Date = Date()
    ) -> ClipboardItem? {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }
        if let bundleID = front?.bundleIdentifier, ignoredBundleIDs.contains(bundleID) { return nil }

        // 1. 文件（访达复制）
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let paths = urls.map { $0.path }
            let payload = paths.sorted().joined(separator: "|").data(using: .utf8) ?? Data()
            return ClipboardItem(
                kind: .files,
                text: paths.joined(separator: "\n"),
                fileNames: urls.map { $0.lastPathComponent },
                fingerprint: ClipboardItem.fingerprint(kind: .files, payload: payload),
                firstCopiedAt: date,
                lastCopiedAt: date,
                sourceAppBundleID: front?.bundleIdentifier,
                sourceAppName: front?.localizedName
            )
        }

        // 2. 文本（含 URL）
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let capped = String(text.prefix(maxTextLength))
            let payload = capped.data(using: .utf8) ?? Data()
            return ClipboardItem(
                kind: .text,
                text: capped,
                fingerprint: ClipboardItem.fingerprint(kind: .text, payload: payload),
                byteSize: capped.utf8.count,
                firstCopiedAt: date,
                lastCopiedAt: date,
                sourceAppBundleID: front?.bundleIdentifier,
                sourceAppName: front?.localizedName
            )
        }

        // 3. 图片
        if let types = pasteboard.types, types.contains(.tiff) || types.contains(.png),
           let image = NSImage(pasteboard: pasteboard),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let name = UUID().uuidString + ".png"
            do {
                try png.write(to: imagesDirectory.appendingPathComponent(name), options: .atomic)
            } catch {
                return nil
            }
            return ClipboardItem(
                kind: .image,
                imageRelativePath: name,
                imagePixelWidth: Double(rep.pixelsWide),
                imagePixelHeight: Double(rep.pixelsHigh),
                fingerprint: ClipboardItem.fingerprint(kind: .image, payload: png),
                byteSize: png.count,
                firstCopiedAt: date,
                lastCopiedAt: date,
                sourceAppBundleID: front?.bundleIdentifier,
                sourceAppName: front?.localizedName
            )
        }
        return nil
    }
}

/// 可选功能：把选中内容向前台应用模拟 ⌘V 粘贴（需辅助功能权限）。
public enum Paster {
    public static func pasteToActiveApp() {
        guard AXIsProcessTrusted() else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        usleep(20_000)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
