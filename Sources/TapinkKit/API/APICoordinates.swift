import CoreGraphics

/// Converts between the external API's coordinate space (top-left origin, pixels — matching
/// what an agent sees in a `GET /screenshot` image) and AppKit's coordinate space (bottom-left
/// origin, points — what `DrawingObject`/`CanvasView` use internally). Pulled out as a pure,
/// testable function for the same reason as `ScreenshotService.pixelRect`: a flip like this is
/// easy to get backwards, and a sign error would silently place drawings upside down.
enum APICoordinates {
    static func point(fromPixel pixel: CGPoint, screenHeightInPoints: CGFloat, scale: CGFloat) -> CGPoint {
        CGPoint(x: pixel.x / scale, y: screenHeightInPoints - pixel.y / scale)
    }
}
