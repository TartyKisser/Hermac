import AppKit
@preconcurrency import ApplicationServices
import ScreenCaptureKit
@preconcurrency import Vision
import ImageIO
import UniformTypeIdentifiers
import OSLog

enum RecentContextCaptureService {
    private static let diagnostics = Logger(subsystem: "dev.hermac.app", category: "RecentContext")
    struct Result {
        let text: String
        let imageURL: URL?
        let notice: String
    }

    struct WindowCandidate {
        let id: CGWindowID
        let title: String
        let frame: NSRect
    }

    struct OCRLine: Sendable {
        let text: String
        let box: CGRect
    }

    struct TextAnchor: Sendable {
        let text: String
        let box: CGRect
        let isSelection: Bool

        init(text: String, box: CGRect, isSelection: Bool = true) {
            self.text = text
            self.box = box
            self.isSelection = isSelection
        }
    }

    enum CaptureError: LocalizedError {
        case sourceChanged, windowUnavailable
        var errorDescription: String? {
            switch self {
            case .sourceChanged: "读取期间来源窗口发生变化，请重新选中文字后再试。"
            case .windowUnavailable: "无法确定选中文字所在的窗口，请重新选择后再试。"
            }
        }
    }

    /// Read the selected document's current and at most two preceding screens.
    /// No application database or off-screen window is used.
    @MainActor
    static func capture(application: NSRunningApplication, windowTitle: String,
                        windowFrame: NSRect?, scrollRect: NSRect?, anchorRect: NSRect?,
                        selectedText: String = "",
                        maxPages: Int = 3) async throws -> Result {
        guard ScreenCaptureService.hasPermission || ScreenCaptureService.requestPermission() else {
            throw ScreenCaptureService.CaptureError.permissionRequired
        }
        let pid = application.processIdentifier
        guard isFrontmost(pid) else { throw CaptureError.sourceChanged }
        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let windows = shareable.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.isOnScreen
        }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let candidates = windows.map {
            WindowCandidate(id: $0.windowID, title: $0.title ?? "", frame: appKitRect($0.frame, top: top))
        }
        guard let id = matchingWindowID(candidates, title: windowTitle, frame: windowFrame, anchor: anchorRect),
              let window = windows.first(where: { $0.windowID == id }) else {
            throw CaptureError.windowUnavailable
        }
        let actualFrame = appKitRect(window.frame, top: top)
        let point = anchorRect.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        let viewport = scrollRect.flatMap { rect -> NSRect? in
            let clipped = rect.intersection(actualFrame)
            return clipped.isEmpty || clipped.isNull ? nil : clipped
        }
        let crop = viewport ?? actualFrame
        let tracking = trackingRect(window: crop, anchor: point, hasViewport: viewport != nil)
        let scrollPoint = viewport.map { NSPoint(x: $0.midX, y: $0.midY) }
            ?? NSPoint(x: min(max(point.x, actualFrame.minX + 12), actualFrame.maxX - 12),
                       y: min(max(point.y, actualFrame.minY + 12), actualFrame.maxY - 12))
        let source = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(source, 0.15)
        let initialWindow = element(source, attribute: kAXFocusedWindowAttribute)
        let scrollbar = scrollSnapshot(source: source, point: scrollPoint, top: top)
        let activity = Activity()
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]) { event in
            MainActor.assumeIsolated {
                // Esc cancels the Hermac operation; it does not represent a
                // user's new scrolling position that restoration must preserve.
                if event.type == .keyDown, event.keyCode == 53 { return }
                if event.cgEvent?.getIntegerValueField(.eventSourceUserData) != scrollMarker {
                    activity.interrupted = true
                }
            }
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let size = ScreenCaptureService.outputSize(width: Int(actualFrame.width * 2), height: Int(actualFrame.height * 2))
        let configuration = SCScreenshotConfiguration()
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.showsCursor = false
        configuration.ignoreShadows = true
        configuration.includeChildWindows = false
        configuration.dynamicRange = .sdr

        func stillSource() -> Bool {
            guard isFrontmost(pid), !activity.interrupted else { return false }
            if let initialWindow {
                guard let current = element(source, attribute: kAXFocusedWindowAttribute) else { return false }
                return CFEqual(initialWindow, current)
            }
            return true
        }

        func screenshot() async throws -> CGImage {
            guard stillSource() else { throw CaptureError.sourceChanged }
            let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration)
            guard stillSource() else { throw CaptureError.sourceChanged }
            guard let image = output.sdrImage else { throw ScreenCaptureService.CaptureError.imageUnavailable }
            return image
        }

        let first = try await screenshot()
        var previous = cropped(first, to: crop, in: actualFrame)
        var previousLines = try await recognize(previous)
        guard stillSource() else { throw CaptureError.sourceChanged }
        let initialCrop = previous
        let initialTrackingPixels = pixelRect(tracking, in: crop, imageWidth: previous.width, imageHeight: previous.height)
        let textAnchor = restorationAnchor(in: previousLines, selectedText: selectedText,
                                          point: CGPoint(x: (point.x - crop.minX) / crop.width,
                                                         y: (point.y - crop.minY) / crop.height))
        var pages = [previousLines]
        var forwardSteps: [CGFloat] = []
        var restored = true
        var stopReason = "completed"
        let distance = max(80, min(650, tracking.height * 0.62)).rounded()
        diagnostics.notice("Capture requestedDistance=\(distance), hasScrollbar=\(scrollbar != nil), hasTextAnchor=\(textAnchor != nil), maxPages=\(min(3, max(1, maxPages)))")

        func restore() async {
            guard stillSource() else { restored = false; return }
            guard !forwardSteps.isEmpty else { restored = true; return }
            let restoredByAX: Bool
            if let scrollbar,
               AXUIElementSetAttributeValue(scrollbar.element, kAXValueAttribute as CFString,
                                            NSNumber(value: scrollbar.value)) == .success {
                diagnostics.notice("Restore route=AX")
                restoredByAX = true
                await settleDuringRestore()
            } else { restoredByAX = false }
            // Replay each inverse step with the same spacing. Registration on
            // chat bubbles can underestimate movement and is not a pixel ruler.
            if !restoredByAX {
                if Task.isCancelled { await settleDuringRestore() }
                for step in restorationSteps(from: forwardSteps) {
                    guard stillSource() else { restored = false; return }
                    diagnostics.notice("Restore route=WindowServer, step=\(step)")
                    postScroll(step, at: scrollPoint, pid: pid, top: top)
                    await settleDuringRestore()
                }
            }
            restored = false
            for attempt in 0...2 {
                guard stillSource(), let full = try? await screenshot() else { return }
                let current = cropped(full, to: crop, in: actualFrame)
                let lines = (try? await recognize(current)) ?? []
                guard stillSource() else { return }
                let drift = textAnchor.flatMap { anchorDisplacement($0, in: lines) }
                let difference = imageDifference(initialCrop.cropping(to: initialTrackingPixels) ?? initialCrop,
                                                 current.cropping(to: initialTrackingPixels) ?? current)
                restored = restorationVerified(anchor: textAnchor, drift: drift, viewport: crop.size,
                                                imageDifference: difference)
                diagnostics.notice("Restore check attempt=\(attempt), anchorFound=\(drift != nil), driftYPoints=\(drift.map { $0.y * crop.height } ?? -9999), imageDifference=\(difference), verified=\(restored)")
                if restored { return }
                guard attempt < 2, textAnchor?.isSelection == true, let drift,
                      let correction = correctionDistance(normalizedDrift: drift.y, viewportHeight: crop.height) else { return }
                postScroll(correction, at: scrollPoint, pid: pid, top: top)
                await settleDuringRestore()
            }
        }

        do {
            for _ in 1..<min(3, max(1, maxPages)) {
                try Task.checkCancellation()
                guard stillSource() else { throw CaptureError.sourceChanged }
                let beforeValue = scrollbar.flatMap { number($0.element, attribute: kAXValueAttribute) }
                restored = false
                forwardSteps.append(distance)
                postScroll(distance, at: scrollPoint, pid: pid, top: top)
                try await Task.sleep(for: .milliseconds(500))
                let full = try await screenshot()
                let current = cropped(full, to: crop, in: actualFrame)
                let lines = try await recognize(current)
                guard stillSource() else { throw CaptureError.sourceChanged }
                let afterValue = scrollbar.flatMap { number($0.element, attribute: kAXValueAttribute) }
                if let beforeValue, let afterValue, abs(beforeValue - afterValue) < 0.00001 {
                    forwardSteps.removeLast()
                    stopReason = "axBoundary"
                    break
                }
                let trackingPixels = pixelRect(tracking, in: crop, imageWidth: previous.width, imageHeight: previous.height)
                let ocrMotion = textTranslation(from: previousLines, to: lines,
                                                region: normalizedRect(tracking, in: crop))
                    .map { abs($0) * crop.height }
                let imageMotion = try? await translation(from: previous, to: current, region: trackingPixels)
                let imagePoints = imageMotion.map {
                    scrollDistance(translationPixels: $0, imageHeight: previous.height, viewportHeight: crop.height)
                }
                let movement = resolvedMovement(ocrMotion: ocrMotion, imageMotion: imagePoints)
                diagnostics.notice("Page requestedDistance=\(distance), ocrMotion=\(ocrMotion ?? -1), imageMotion=\(imagePoints ?? -1), resolvedMotion=\(movement ?? -1), hasScrollbar=\(scrollbar != nil)")
                if let movement, movement < 2 {
                    let previousRegion = previous.cropping(to: trackingPixels) ?? previous
                    let currentRegion = current.cropping(to: trackingPixels) ?? current
                    let unchanged = imageDifference(previousRegion, currentRegion) < 0.0005
                    if unchanged { forwardSteps.removeLast() }
                    stopReason = unchanged ? "confirmedNoMovement" : "unconfirmedNoMovement"
                    break
                }
                pages.append(lines)
                if movement == nil {
                    // Do not keep paging when the app has not exposed an exact
                    // scrollbar and registration cannot establish its movement.
                    if scrollbar == nil { stopReason = "unmeasuredMovement"; break }
                }
                previous = current
                previousLines = lines
            }
            await restore()
        } catch {
            diagnostics.notice("Capture stopped reason=interrupted, pageCount=\(pages.count), frontmost=\(isFrontmost(pid)), userInput=\(activity.interrupted)")
            await restore()
            throw error
        }
        try Task.checkCancellation()
        guard stillSource() else { throw CaptureError.sourceChanged }
        let text = combinedText(pages)
        // A single current-window image is enough for a model to disambiguate
        // sparse OCR. Later screens remain text-only and are never uploaded.
        let imageURL = text.filter { !$0.isWhitespace }.count < 120 ? try save(first) : nil
        let notice = restored
            ? "已读取当前窗口最近 \(pages.count) 屏的可见内容，并恢复原滚动位置。"
            : "已读取当前窗口最近 \(pages.count) 屏的可见内容，并尝试恢复滚动位置；未能确认完全恢复，请检查原窗口。"
        diagnostics.notice("Capture stopReason=\(stopReason, privacy: .public), pageCount=\(pages.count), restoreVerified=\(restored)")
        return Result(text: text, imageURL: imageURL, notice: notice)
    }

    // MARK: Window geometry and context helpers

    static func matchingWindowID(_ windows: [WindowCandidate], title: String, frame: NSRect?, anchor: NSRect?) -> CGWindowID? {
        if let frame, !frame.isEmpty {
            let matches = windows.filter {
                abs($0.frame.minX - frame.minX) < 12 && abs($0.frame.minY - frame.minY) < 12
                    && abs($0.frame.width - frame.width) < 16 && abs($0.frame.height - frame.height) < 16
            }
            let titled = matches.filter { !title.isEmpty && $0.title == title }
            if titled.count == 1 { return titled[0].id }
            return matches.count == 1 ? matches[0].id : nil
        }
        let titled = windows.filter { !title.isEmpty && $0.title == title }
        if titled.count == 1 { return titled[0].id }
        if let anchor {
            let pointed = windows.filter { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
            if pointed.count == 1 { return pointed[0].id }
        }
        return windows.count == 1 ? windows[0].id : nil
    }

    static func trackingRect(window: NSRect, anchor: NSPoint, hasViewport: Bool) -> NSRect {
        if hasViewport { return window.insetBy(dx: 8, dy: min(20, window.height * 0.05)) }
        let inset = window.insetBy(dx: 10, dy: min(65, window.height * 0.12))
        let width = min(inset.width, max(140, window.width * 0.58))
        let x = min(max(anchor.x - width / 2, inset.minX), inset.maxX - width)
        return NSRect(x: x, y: inset.minY, width: width, height: inset.height)
    }

    static func pixelRect(_ rect: NSRect, in window: NSRect, imageWidth: Int, imageHeight: Int) -> CGRect {
        CGRect(x: (rect.minX - window.minX) / window.width * CGFloat(imageWidth),
               y: (window.maxY - rect.maxY) / window.height * CGFloat(imageHeight),
               width: rect.width / window.width * CGFloat(imageWidth),
               height: rect.height / window.height * CGFloat(imageHeight)).integral
    }

    private static func normalizedRect(_ rect: NSRect, in window: NSRect) -> CGRect {
        CGRect(x: (rect.minX - window.minX) / window.width, y: (rect.minY - window.minY) / window.height,
               width: rect.width / window.width, height: rect.height / window.height)
    }

    static func combinedText(_ pages: [[OCRLine]], limit: Int = 12_000) -> String {
        var seen = Set<String>()
        var parts: [String] = []
        var count = 0
        for index in pages.indices {
            let lines = pages[index].map(\.text).filter { seen.insert($0).inserted && !$0.isEmpty }
            guard !lines.isEmpty else { continue }
            let header = index == 0 ? "[当前选区所在屏幕]" : "[上方第 \(index) 屏]"
            let page = header + "\n" + lines.joined(separator: "\n")
            let separator = parts.isEmpty ? 0 : 2
            let clipped = String(page.prefix(max(0, limit - count - separator)))
            if !clipped.isEmpty { parts.append(clipped); count += clipped.count + separator }
            if count >= limit { break }
        }
        return parts.reversed().joined(separator: "\n\n")
    }

    /// Repeated UI labels are ignored; matching unique text gives a robust
    /// scroll displacement without letting a static toolbar dominate alignment.
    static func textTranslation(from old: [OCRLine], to new: [OCRLine], region: CGRect) -> CGFloat? {
        let oldGroups = Dictionary(grouping: old.filter { region.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }, by: \.text)
        let newGroups = Dictionary(grouping: new.filter { region.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }, by: \.text)
        var shifts: [CGFloat] = []
        var stationary = 0
        for (text, lines) in oldGroups where text.count > 3 && lines.count == 1 {
            guard let next = newGroups[text], next.count == 1,
                  abs(next[0].box.midX - lines[0].box.midX) < 0.04 else { continue }
            let shift = next[0].box.midY - lines[0].box.midY
            if abs(shift) > 0.004 { shifts.append(shift) }
            else { stationary += 1 }
        }
        guard shifts.count >= 2 else { return stationary >= 4 ? 0 : nil }
        shifts.sort()
        let median = shifts[shifts.count / 2]
        let agreeing = shifts.filter { abs($0 - median) < 0.015 }
        return agreeing.count >= 2 && agreeing.count * 2 >= shifts.count ? median : nil
    }

    static func scrollDistance(translationPixels: CGFloat, imageHeight: Int, viewportHeight: CGFloat) -> CGFloat {
        abs(translationPixels) * viewportHeight / CGFloat(imageHeight)
    }

    /// Static text can belong to a sidebar rather than the scrolling document.
    /// It is only evidence of a boundary when image registration agrees.
    static func resolvedMovement(ocrMotion: CGFloat?, imageMotion: CGFloat?) -> CGFloat? {
        if let ocrMotion, ocrMotion >= 2 { return ocrMotion }
        if let imageMotion { return imageMotion }
        return nil
    }

    static func restorationSteps(from forward: [CGFloat]) -> [CGFloat] {
        forward.reversed().map { -$0 }
    }

    static func restorationAnchor(in lines: [OCRLine], selectedText: String, point: CGPoint) -> TextAnchor? {
        let groups = Dictionary(grouping: lines, by: { normalizedText($0.text) })
        let unique = groups.filter { $0.key.count >= 3 && $0.value.count == 1 }
            .map { TextAnchor(text: $0.key, box: $0.value[0].box, isSelection: false) }
        let selected = normalizedText(selectedText)
        let selectedLines = unique.filter {
            !selected.isEmpty && ($0.text.contains(selected) || selected.contains($0.text))
        }
        func distance(_ line: TextAnchor) -> CGFloat {
            let dx = max(line.box.minX - point.x, 0, point.x - line.box.maxX)
            let dy = max(line.box.minY - point.y, 0, point.y - line.box.maxY)
            return hypot(dx, dy)
        }
        if let match = selectedLines.min(by: { distance($0) < distance($1) }) {
            return TextAnchor(text: match.text, box: match.box)
        }
        guard CGRect(x: 0, y: 0, width: 1, height: 1).contains(point),
              let nearby = unique.min(by: { distance($0) < distance($1) }), distance(nearby) < 0.18 else { return nil }
        return nearby
    }

    static func anchorDisplacement(_ anchor: TextAnchor, in lines: [OCRLine]) -> CGPoint? {
        let matching = lines.filter { normalizedText($0.text) == anchor.text }
        guard matching.count == 1 else { return nil }
        return CGPoint(x: matching[0].box.midX - anchor.box.midX, y: matching[0].box.midY - anchor.box.midY)
    }

    static func restorationVerified(anchor: TextAnchor?, drift: CGPoint?, viewport: CGSize,
                                    imageDifference: Double) -> Bool {
        if let anchor {
            guard let drift else { return false }
            let positionMatches = abs(drift.x * viewport.width) <= 10 && abs(drift.y * viewport.height) <= 6
            return positionMatches && (anchor.isSelection || imageDifference < 0.0015)
        }
        return imageDifference < 0.0015
    }

    static func correctionDistance(normalizedDrift: CGFloat, viewportHeight: CGFloat) -> CGFloat? {
        let distance = (normalizedDrift * viewportHeight).rounded()
        let bound = min(140, viewportHeight * 0.25)
        return abs(distance) > 3 ? min(max(distance, -bound), bound) : nil
    }

    private static func normalizedText(_ text: String) -> String {
        String(text.lowercased().filter { !$0.isWhitespace })
    }

    // MARK: Capture, recognition and restoration

    @MainActor private final class Activity { var interrupted = false }
    private static let scrollMarker: Int64 = 0x484D524543454E54

    private static func settleDuringRestore() async {
        // Parent-task cancellation must not collapse the spacing between the
        // inverse events needed to put the source document back.
        await Task.detached { try? await Task.sleep(for: .milliseconds(500)) }.value
    }

    @MainActor private static func isFrontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private static func appKitRect(_ rect: CGRect, top: CGFloat) -> NSRect {
        NSRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }

    @MainActor private static func postScroll(_ distance: CGFloat, at point: NSPoint, pid: pid_t, top: CGFloat) {
        guard isFrontmost(pid), let event = makeScrollEvent(distance, at: point, top: top) else { return }
        // WindowServer routes the event at its screen location to the actual
        // scrollable view. Direct per-process posting bypasses this hit testing
        // in custom clients such as WeChat.
        event.post(tap: .cghidEventTap)
    }

    static func makeScrollEvent(_ distance: CGFloat, at point: NSPoint, top: CGFloat) -> CGEvent? {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: Int32(distance.rounded()), wheel2: 0, wheel3: 0) else { return nil }
        event.location = CGPoint(x: point.x, y: top - point.y)
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: scrollMarker)
        return event
    }

    private static func cropped(_ image: CGImage, to rect: NSRect, in window: NSRect) -> CGImage {
        image.cropping(to: pixelRect(rect, in: window, imageWidth: image.width, imageHeight: image.height)) ?? image
    }

    private static func recognize(_ image: CGImage) async throws -> [OCRLine] {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { observation in
                observation.topCandidates(1).first.map { OCRLine(text: $0.string, box: observation.boundingBox) }
            }.sorted {
                abs($0.box.midY - $1.box.midY) > 0.012 ? $0.box.midY > $1.box.midY : $0.box.minX < $1.box.minX
            }
        }.value
    }

    static func translation(from old: CGImage, to new: CGImage, region: CGRect) async throws -> CGFloat? {
        try await Task.detached(priority: .userInitiated) {
            let reference = old.cropping(to: region) ?? old
            let current = new.cropping(to: region) ?? new
            let request = VNTranslationalImageRegistrationRequest(targetedCGImage: current)
            try VNImageRequestHandler(cgImage: reference).perform([request])
            guard let observation = request.results?.first, observation.confidence > 0.1,
                  abs(observation.alignmentTransform.tx) < CGFloat(reference.width) * 0.08,
                  abs(observation.alignmentTransform.ty) < CGFloat(reference.height) * 0.9 else { return nil }
            if abs(observation.alignmentTransform.ty) < 2,
               imageDifference(reference, current) > 0.003 { return nil }
            return observation.alignmentTransform.ty
        }.value
    }

    private static func imageDifference(_ first: CGImage, _ second: CGImage) -> Double {
        func samples(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 64 * 64)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: 64, height: 64,
                                        bitsPerComponent: 8, bytesPerRow: 64,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            }
            return bytes
        }
        let left = samples(first), right = samples(second)
        return zip(left, right).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / (64 * 64 * 255)
    }

    private struct ScrollSnapshot { let element: AXUIElement; let value: Double }

    @MainActor private static func scrollSnapshot(source: AXUIElement, point: NSPoint, top: CGFloat) -> ScrollSnapshot? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(source, Float(point.x), Float(top - point.y), &hit) == .success else { return nil }
        var current = hit
        for _ in 0..<16 {
            guard let node = current else { break }
            if let bar = element(node, attribute: kAXVerticalScrollBarAttribute),
               let value = number(bar, attribute: kAXValueAttribute) {
                var settable = DarwinBoolean(false)
                if AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
                    return ScrollSnapshot(element: bar, value: value)
                }
            }
            current = element(node, attribute: kAXParentAttribute)
        }
        return nil
    }

    @MainActor private static func element(_ source: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(source, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    @MainActor private static func number(_ source: AXUIElement, attribute: String) -> Double? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(source, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.doubleValue
    }

    private static func save(_ image: CGImage) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Hermac-Reminder-Context", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ScreenCaptureService.CaptureError.imageUnavailable
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw ScreenCaptureService.CaptureError.imageUnavailable
        }
        return url
    }
}
