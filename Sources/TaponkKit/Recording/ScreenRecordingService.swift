import AppKit
import AVFoundation
import ScreenCaptureKit

/// Captures a live screen recording via `SCStream`, feeding sample buffers straight into an
/// `AVAssetWriter` that transcodes them to H.264 — no audio track (`SCStreamConfiguration
/// .capturesAudio` stays at its `false` default; recording audio wasn't requested and would
/// need microphone permission on top of Screen Recording). Unlike `ScreenshotService`, which is
/// a one-shot capture, this is inherently stateful across a start/stop pair: the stream and
/// writer stay alive between calls, so only one recording can be in flight at a time (enforced
/// by `DrawSessionCoordinator.activeRecordingKind`, not here).
public final class ScreenRecordingService: NSObject {
    public static let shared = ScreenRecordingService()

    /// Serial so sample buffers are always appended in delivery order, and so the
    /// `markAsFinished()` call in `stop()` can be scheduled *after* every buffer already
    /// queued ahead of it — without that ordering, a straggling in-flight buffer could be
    /// appended to an input already marked finished, which raises.
    private let sampleQueue = DispatchQueue(label: "com.tapink.screenrecording.samples")

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var sessionStarted = false

    private override init() {}

    @MainActor
    public func startFullScreen(displayID: ScreenID, excludingWindowNumbers: [Int]) async -> Bool {
        let scale = NSScreen.screens.first(where: { $0.displayID == displayID })?.backingScaleFactor ?? 2
        return await start(displayID: displayID, excludingWindowNumbers: excludingWindowNumbers) { display, config in
            config.width = ScreenRecordingService.evenPixelLength(CGFloat(display.width) * scale)
            config.height = ScreenRecordingService.evenPixelLength(CGFloat(display.height) * scale)
        }
    }

    /// `regionInPoints`/`screenHeightInPoints` are in the same bottom-left-origin, view-local
    /// space `CanvasView`'s region selection already produces (matching `ScreenshotService
    /// .captureRegion`'s convention) — `sourceRect(forRegionInPoints:screenHeightInPoints:)`
    /// below does the flip to what `SCStreamConfiguration.sourceRect` expects.
    @MainActor
    public func startRegion(
        displayID: ScreenID,
        regionInPoints: CGRect,
        screenHeightInPoints: CGFloat,
        scale: CGFloat,
        excludingWindowNumbers: [Int]
    ) async -> Bool {
        await start(displayID: displayID, excludingWindowNumbers: excludingWindowNumbers) { _, config in
            config.sourceRect = ScreenRecordingService.sourceRect(forRegionInPoints: regionInPoints, screenHeightInPoints: screenHeightInPoints)
            config.width = ScreenRecordingService.evenPixelLength(regionInPoints.width * scale)
            config.height = ScreenRecordingService.evenPixelLength(regionInPoints.height * scale)
        }
    }

    /// Stops the stream and flushes the asset writer so the file on disk is complete by the
    /// time this returns. Safe to call when nothing is recording (no-op).
    @MainActor
    public func stop() async {
        guard let activeStream = stream, let input = videoInput, let writer = assetWriter else { return }
        stream = nil
        try? await activeStream.stopCapture()
        sampleQueue.sync { input.markAsFinished() }
        await writer.finishWriting()
        assetWriter = nil
        videoInput = nil
        sessionStarted = false
    }

    /// Converts a selection rect from AppKit view-local coordinates (origin at the bottom-left,
    /// y increasing upward) into the top-left-origin rect `SCStreamConfiguration.sourceRect`
    /// expects. Deliberately stays in *points* — unlike `ScreenshotService.pixelRect`, `sourceRect`
    /// isn't pixel-scaled; only `SCStreamConfiguration.width`/`height` are.
    static func sourceRect(forRegionInPoints regionInPoints: CGRect, screenHeightInPoints: CGFloat) -> CGRect {
        CGRect(
            x: regionInPoints.origin.x,
            y: screenHeightInPoints - regionInPoints.origin.y - regionInPoints.height,
            width: regionInPoints.width,
            height: regionInPoints.height
        )
    }

    /// H.264 needs even pixel dimensions (4:2:0 chroma subsampling); a selected region or a
    /// display's own point size scaled by a fractional backing factor can easily land on an
    /// odd number, which some encoders refuse outright.
    static func evenPixelLength(_ value: CGFloat) -> Int {
        let rounded = Int(value.rounded())
        return rounded.isMultiple(of: 2) ? rounded : rounded - 1
    }

    /// `RecordingQuality.bitsPerPixel` is tuned against HEVC; H.264 needs roughly 40% more bits
    /// to hit the same visual quality, so it gets a flat multiplier rather than a second set of
    /// per-quality constants. The 30fps assumption is just a sizing baseline for the *average*
    /// bitrate cap passed to the encoder — actual output is far lower for the mostly-static
    /// frames a screen recording produces, real motion is what pushes usage toward the cap.
    static func targetBitRate(width: Int, height: Int, quality: RecordingQuality, codec: RecordingCodec) -> Int {
        let codecFactor = codec == .h264 ? 1.4 : 1.0
        let pixelsPerSecond = Double(width * height) * 30
        return Int(pixelsPerSecond * quality.bitsPerPixel * codecFactor)
    }

    @MainActor
    private func start(
        displayID: ScreenID,
        excludingWindowNumbers: [Int],
        configure: (SCDisplay, SCStreamConfiguration) -> Void
    ) async -> Bool {
        guard stream == nil else { return false }
        guard CGPreflightScreenCaptureAccess() else {
            NSLog("TapInk: Screen Recording permission not granted yet; opening System Settings.")
            PermissionsManager.shared.requestScreenRecording()
            return false
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                NSLog("TapInk: no SCDisplay matching displayID \(displayID)")
                return false
            }
            // Always the `excludingApplications:exceptingWindows:` initializer, even with an
            // empty exclude list — the `excludingWindows:`-only variant is known to fail to
            // start the stream with an empty array (same gotcha as `ScreenshotService`).
            let excludedWindows = content.windows.filter { excludingWindowNumbers.contains(Int($0.windowID)) }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: excludedWindows)

            let config = SCStreamConfiguration()
            config.showsCursor = AppSettings.shared.recordCursorInVideos
            configure(display, config)

            let url = ScreenRecordingService.makeOutputURL()
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let codec = AppSettings.shared.recordingCodec
            let quality = AppSettings.shared.recordingQuality
            var compressionProperties: [String: Any] = [
                AVVideoAverageBitRateKey: ScreenRecordingService.targetBitRate(
                    width: config.width, height: config.height, quality: quality, codec: codec
                ),
            ]
            // High profile squeezes noticeably more out of the same bitrate than H.264's
            // Baseline/Main default; HEVC has no equivalent knob worth setting explicitly.
            if codec == .h264 {
                compressionProperties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: codec.avCodecType,
                AVVideoWidthKey: config.width,
                AVVideoHeightKey: config.height,
                AVVideoCompressionPropertiesKey: compressionProperties,
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                NSLog("TapInk: asset writer rejected video input")
                return false
            }
            writer.add(input)
            guard writer.startWriting() else {
                NSLog("TapInk: asset writer failed to start: \(String(describing: writer.error))")
                return false
            }

            let newStream = SCStream(filter: filter, configuration: config, delegate: self)
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await newStream.startCapture()

            stream = newStream
            assetWriter = writer
            videoInput = input
            sessionStarted = false
            return true
        } catch {
            NSLog("TapInk: failed to start screen recording: \(error)")
            return false
        }
    }

    private static func makeOutputURL() -> URL {
        let folderPath = AppSettings.shared.screenshotSaveFolderPath
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: folderPath) {
            try? fileManager.createDirectory(atPath: folderPath, withIntermediateDirectories: true)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return URL(fileURLWithPath: folderPath)
            .appendingPathComponent("TapInk Recording \(formatter.string(from: Date())).mov")
    }
}

extension ScreenRecordingService: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer), let videoInput, let assetWriter else { return }

        // Not every frame `SCStream` delivers carries new pixel data — frames tagged `.idle`,
        // `.suspended`, etc. (nothing changed since the last frame) can have no real image
        // behind them at all. Only `.complete` is guaranteed to be an actual new frame; feeding
        // the others to the asset writer risks appending an empty or stale buffer.
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRawValue = attachmentsArray.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue),
              status == .complete
        else { return }

        if !sessionStarted {
            assetWriter.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }
        guard videoInput.isReadyForMoreMediaData else { return }
        videoInput.append(sampleBuffer)
    }
}

extension ScreenRecordingService: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("TapInk: screen recording stream stopped with error: \(error)")
    }
}
