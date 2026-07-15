import AppKit
import Foundation

/// Translates parsed HTTP requests into calls on `DrawSessionCoordinator`. `@MainActor` because
/// everything it touches (the coordinator, `NSScreen`, AppKit) must run on the main thread — see
/// the `Task { @MainActor in }` gotcha documented on `DrawSessionCoordinator` for why this matters.
@MainActor
final class APIRouter {
    private let coordinator: DrawSessionCoordinator

    init(coordinator: DrawSessionCoordinator) {
        self.coordinator = coordinator
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard isAuthorized(request) else {
            return .error("Unauthorized", status: 401)
        }

        switch (request.method, request.path) {
        case ("GET", "/draw-mode"):
            return drawModeState()
        case ("POST", "/draw-mode/enable"):
            coordinator.enableDrawMode()
            return drawModeState()
        case ("POST", "/draw-mode/disable"):
            coordinator.disableDrawMode()
            return drawModeState()
        case ("POST", "/draw-mode/toggle"):
            coordinator.toggleDrawMode()
            return drawModeState()
        case ("POST", "/tools/pen"):
            return handleStroke(request, isHighlighter: false)
        case ("POST", "/tools/highlighter"):
            return handleStroke(request, isHighlighter: true)
        case ("POST", "/tools/rectangle"):
            return handleShape(request, kind: .rectangle)
        case ("POST", "/tools/ellipse"):
            return handleShape(request, kind: .ellipse)
        case ("POST", "/tools/line"):
            return handleShape(request, kind: .line)
        case ("POST", "/tools/arrow"):
            return handleShape(request, kind: .arrow)
        case ("POST", "/tools/text"):
            return handleText(request)
        case ("GET", "/displays"):
            return handleDisplays()
        case ("GET", "/screenshot"):
            return await handleScreenshot(request)
        case ("POST", "/undo"):
            coordinator.document.undo()
            return .json(OKResponseDTO(ok: true))
        case ("POST", "/redo"):
            coordinator.document.redo()
            return .json(OKResponseDTO(ok: true))
        case ("POST", "/clear"):
            coordinator.clearCanvas()
            return .json(OKResponseDTO(ok: true))
        default:
            return .error("Not found", status: 404)
        }
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard let header = request.headers["authorization"], header.hasPrefix("Bearer ") else { return false }
        let token = String(header.dropFirst("Bearer ".count))
        return !token.isEmpty && token == AppSettings.shared.apiToken
    }

    private func drawModeState() -> HTTPResponse {
        .json(DrawModeStateDTO(active: coordinator.isDrawModeActive))
    }

    private func screen(forDisplayID id: ScreenID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == id }
    }

    /// Drawing while draw mode is off wouldn't be visible at all (the overlay windows are
    /// hidden), so every drawing endpoint enables it first rather than erroring — one fewer
    /// round trip for a caller that just wants to annotate the screen.
    private func ensureDrawModeActive() {
        if !coordinator.isDrawModeActive {
            coordinator.enableDrawMode()
        }
    }

    private func handleStroke(_ request: HTTPRequest, isHighlighter: Bool) -> HTTPResponse {
        guard let dto = try? JSONDecoder().decode(StrokeRequestDTO.self, from: request.body),
              let screen = screen(forDisplayID: dto.display),
              let color = NSColor(hex: dto.color) else {
            return .error("Invalid request body", status: 400)
        }
        let scale = screen.backingScaleFactor
        let heightInPoints = screen.frame.height
        let points = dto.points.map {
            APICoordinates.point(fromPixel: $0.cgPoint, screenHeightInPoints: heightInPoints, scale: scale)
        }
        ensureDrawModeActive()
        let stroke = StrokeObject(screen: dto.display, points: points, color: color, width: CGFloat(dto.width), isHighlighter: isHighlighter)
        coordinator.document.add(.stroke(stroke))
        return .json(IDResponseDTO(id: stroke.id.uuidString))
    }

    private func handleShape(_ request: HTTPRequest, kind: ShapeKind) -> HTTPResponse {
        guard let dto = try? JSONDecoder().decode(ShapeRequestDTO.self, from: request.body),
              let screen = screen(forDisplayID: dto.display),
              let color = NSColor(hex: dto.color) else {
            return .error("Invalid request body", status: 400)
        }
        let scale = screen.backingScaleFactor
        let heightInPoints = screen.frame.height
        let start = APICoordinates.point(fromPixel: dto.start.cgPoint, screenHeightInPoints: heightInPoints, scale: scale)
        let end = APICoordinates.point(fromPixel: dto.end.cgPoint, screenHeightInPoints: heightInPoints, scale: scale)
        let fillColor = dto.fill.flatMap { NSColor(hex: $0) } ?? .clear
        ensureDrawModeActive()
        let shape = ShapeObject(screen: dto.display, kind: kind, startPoint: start, endPoint: end, color: color, width: CGFloat(dto.width), fillColor: fillColor)
        coordinator.document.add(.shape(shape))
        return .json(IDResponseDTO(id: shape.id.uuidString))
    }

    private func handleText(_ request: HTTPRequest) -> HTTPResponse {
        guard let dto = try? JSONDecoder().decode(TextRequestDTO.self, from: request.body),
              let screen = screen(forDisplayID: dto.display),
              let color = NSColor(hex: dto.color) else {
            return .error("Invalid request body", status: 400)
        }
        let origin = APICoordinates.point(fromPixel: dto.origin.cgPoint, screenHeightInPoints: screen.frame.height, scale: screen.backingScaleFactor)
        ensureDrawModeActive()
        let text = TextObject(screen: dto.display, origin: origin, string: dto.string, color: color, fontSize: CGFloat(dto.fontSize))
        coordinator.document.add(.text(text))
        return .json(IDResponseDTO(id: text.id.uuidString))
    }

    private func handleDisplays() -> HTTPResponse {
        let mainID = NSScreen.main?.displayID
        let displays: [DisplayInfoDTO] = NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            let scale = screen.backingScaleFactor
            return DisplayInfoDTO(
                id: id,
                width: Int(screen.frame.width * scale),
                height: Int(screen.frame.height * scale),
                isMain: id == mainID
            )
        }
        return .json(displays)
    }

    private func handleScreenshot(_ request: HTTPRequest) async -> HTTPResponse {
        guard let displayString = request.queryItems["display"],
              let displayID = ScreenID(displayString),
              screen(forDisplayID: displayID) != nil else {
            return .error("Missing or invalid 'display' query parameter", status: 400)
        }
        let excludedWindowNumbers = coordinator.excludedCaptureWindowNumbers
        let image: NSImage?
        if let rectString = request.queryItems["rect"] {
            guard let pixelRect = APIRouter.parseRect(rectString) else {
                return .error("Invalid 'rect' query parameter, expected 'x,y,w,h'", status: 400)
            }
            image = await ScreenshotService.shared.captureRegionImage(displayID: displayID, pixelRect: pixelRect, excludingWindowNumbers: excludedWindowNumbers)
        } else {
            image = await ScreenshotService.shared.captureImage(displayID: displayID, excludingWindowNumbers: excludedWindowNumbers)
        }
        guard let image, let data = ScreenshotService.shared.pngData(from: image) else {
            return .error("Screenshot capture failed", status: 500)
        }
        return .png(data)
    }

    private static func parseRect(_ raw: String) -> CGRect? {
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }
}
