import AppKit
import ScreenCaptureKit

public final class ScreenshotService {
    public static let shared = ScreenshotService()

    private let shutterSoundURL = Bundle.main.url(forResource: "CameraShutter", withExtension: "wav")

    private init() {}

    /// Captures exactly one display (the one under the cursor at the moment the
    /// shortcut fired), excluding only the given windows (the toolbar) so the
    /// live annotations baked into the per-screen canvas are still captured.
    /// Returns whether a screenshot was actually taken, so callers (a toast, e.g.) don't
    /// report success when permission was missing or the capture otherwise failed.
    @MainActor
    @discardableResult
    public func capture(displayID: ScreenID, excludingWindowNumbers: [Int], saveToDisk: Bool) async -> Bool {
        guard let cgImage = await captureDisplayImage(displayID: displayID, excludingWindowNumbers: excludingWindowNumbers) else { return false }
        playShutterSound()
        deliver(NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)), saveToDisk: saveToDisk)
        return true
    }

    /// Captures the same way as `capture`, then crops to `regionInPoints` —
    /// given in the screen's own view-local coordinates (origin at its
    /// bottom-left, matching `CanvasView.bounds`) — before delivering it.
    @MainActor
    @discardableResult
    public func captureRegion(
        displayID: ScreenID,
        regionInPoints: CGRect,
        scale: CGFloat,
        excludingWindowNumbers: [Int],
        saveToDisk: Bool
    ) async -> Bool {
        guard let cgImage = await captureDisplayImage(displayID: displayID, excludingWindowNumbers: excludingWindowNumbers) else { return false }

        let pixelRect = ScreenshotService.pixelRect(forRegionInPoints: regionInPoints, imageHeightInPixels: cgImage.height, scale: scale)

        guard let cropped = cgImage.cropping(to: pixelRect) else {
            NSLog("TapInk: failed to crop screenshot to selected region \(pixelRect)")
            return false
        }
        playShutterSound()
        deliver(NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height)), saveToDisk: saveToDisk)
        return true
    }

    /// Same underlying capture as `capture`, but hands back the raw image without playing the
    /// shutter sound or delivering to clipboard/disk — for callers (like freeze-background) that
    /// want the pixels themselves rather than a user-facing "I took a screenshot" action.
    @MainActor
    public func captureImage(displayID: ScreenID, excludingWindowNumbers: [Int]) async -> NSImage? {
        guard let cgImage = await captureDisplayImage(displayID: displayID, excludingWindowNumbers: excludingWindowNumbers) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Same silent capture as `captureImage`, cropped to `pixelRect` — already in the top-left-
    /// origin pixel space `CGImage.cropping(to:)` expects. Unlike `captureRegion`'s
    /// `regionInPoints`, callers here (the external API) already have pixel coordinates, so no
    /// bottom-left/top-left flip is needed.
    @MainActor
    public func captureRegionImage(displayID: ScreenID, pixelRect: CGRect, excludingWindowNumbers: [Int]) async -> NSImage? {
        guard let cgImage = await captureDisplayImage(displayID: displayID, excludingWindowNumbers: excludingWindowNumbers) else { return nil }
        guard let cropped = cgImage.cropping(to: pixelRect.integral) else {
            NSLog("TapInk: failed to crop screenshot to region \(pixelRect)")
            return nil
        }
        return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
    }

    /// Shared PNG conversion used both for disk-saving and for the external API's screenshot response.
    public func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Converts a selection rect from AppKit view-local coordinates (origin at the
    /// bottom-left, y increasing upward — matching `CanvasView.bounds`) into the pixel
    /// crop rect `CGImage.cropping(to:)` expects (origin at the top-left, y increasing
    /// downward), scaled for the display's backing scale factor. Pulled out as a pure,
    /// testable function since the vertical flip is exactly the kind of easy-to-get-wrong
    /// math where a sign error silently produces a vertically-mirrored-in-position crop.
    static func pixelRect(forRegionInPoints regionInPoints: CGRect, imageHeightInPixels: Int, scale: CGFloat) -> CGRect {
        let imageHeightInPoints = CGFloat(imageHeightInPixels) / scale
        return CGRect(
            x: regionInPoints.origin.x * scale,
            y: (imageHeightInPoints - regionInPoints.origin.y - regionInPoints.height) * scale,
            width: regionInPoints.width * scale,
            height: regionInPoints.height * scale
        ).integral
    }

    @MainActor
    private func captureDisplayImage(displayID: ScreenID, excludingWindowNumbers: [Int]) async -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else {
            NSLog("TapInk: Screen Recording permission not granted yet; opening System Settings.")
            PermissionsManager.shared.requestScreenRecording()
            return nil
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                NSLog("TapInk: no SCDisplay matching displayID \(displayID)")
                return nil
            }
            let excludedWindows = content.windows.filter { excludingWindowNumbers.contains(Int($0.windowID)) }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: excludedWindows)

            // SCDisplay.width/height are in points, but SCStreamConfiguration's
            // are in pixels — without scaling by backingScaleFactor, captures on
            // a Retina display would come out at half (or less) native resolution.
            let scale = NSScreen.screens.first(where: { $0.displayID == displayID })?.backingScaleFactor ?? 2
            let config = SCStreamConfiguration()
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = false

            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            NSLog("TapInk: screenshot capture failed: \(error)")
            return nil
        }
    }

    private func deliver(_ image: NSImage, saveToDisk: Bool) {
        if saveToDisk {
            save(image)
        } else {
            copyToClipboard(image)
        }
    }

    private func playShutterSound() {
        guard let shutterSoundURL else { return }
        NSSound(contentsOf: shutterSoundURL, byReference: true)?.play()
    }

    private func copyToClipboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private func save(_ image: NSImage) {
        let folderPath = AppSettings.shared.screenshotSaveFolderPath
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: folderPath) {
            try? fileManager.createDirectory(atPath: folderPath, withIntermediateDirectories: true)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = URL(fileURLWithPath: folderPath)
            .appendingPathComponent("TapInk \(formatter.string(from: Date())).png")

        guard let data = pngData(from: image) else { return }
        try? data.write(to: url)
    }
}
