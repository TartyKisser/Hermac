import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

enum ScreenCaptureService {
    enum CaptureError: LocalizedError {
        case permissionRequired, displayUnavailable, windowUnavailable, imageUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionRequired:
                "请在系统设置的“隐私与安全性 → 屏幕与系统音频录制”中允许 Hermac 访问屏幕，然后重试。"
            case .displayUnavailable: "输入框所在的屏幕已不可用，请重新呼出快捷会话。"
            case .windowUnavailable: "无法排除快捷会话窗口，请重新呼出后再试。"
            case .imageUnavailable: "无法保存屏幕截图，请重试。"
            }
        }
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Capture only the panel's display, leaving the panel itself out of the image.
    @MainActor
    static func capture(displayID: CGDirectDisplayID, excludingWindowID: CGWindowID) async throws -> URL {
        guard hasPermission || requestPermission() else { throw CaptureError.permissionRequired }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayUnavailable
        }
        guard let panel = content.windows.first(where: { $0.windowID == excludingWindowID }) else {
            throw CaptureError.windowUnavailable
        }
        let filter = SCContentFilter(display: display, excludingWindows: [panel])
        let size = outputSize(width: CGDisplayPixelsWide(displayID), height: CGDisplayPixelsHigh(displayID))
        let configuration = SCScreenshotConfiguration()
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr
        let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration)
        guard let image = output.sdrImage else { throw CaptureError.imageUnavailable }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Hermac-Screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CaptureError.imageUnavailable
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.imageUnavailable }
        return url
    }

    // Bound image uploads while retaining enough resolution for on-screen text.
    static func outputSize(width: Int, height: Int) -> CGSize {
        let scale = min(1, 2048 / Double(max(width, height)))
        return CGSize(width: max(1, (Double(width) * scale).rounded()),
                      height: max(1, (Double(height) * scale).rounded()))
    }
}
