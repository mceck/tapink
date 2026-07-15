import CoreGraphics

/// A point in the external API's coordinate space — top-left origin, pixels, matching a
/// `GET /screenshot` image — as opposed to `CGPoint`s elsewhere in the app, which are always
/// AppKit's bottom-left-origin points. See `APICoordinates`.
struct PointDTO: Codable {
    var x: Double
    var y: Double

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

struct StrokeRequestDTO: Codable {
    var display: ScreenID
    var points: [PointDTO]
    var color: String
    var width: Double
}

struct ShapeRequestDTO: Codable {
    var display: ScreenID
    var start: PointDTO
    var end: PointDTO
    var color: String
    var width: Double
    var fill: String?
}

struct TextRequestDTO: Codable {
    var display: ScreenID
    var origin: PointDTO
    var string: String
    var color: String
    var fontSize: Double
}

struct DisplayInfoDTO: Codable {
    var id: ScreenID
    var width: Int
    var height: Int
    var isMain: Bool
}

struct ErrorResponseDTO: Codable {
    var error: String
}

struct OKResponseDTO: Codable {
    var ok: Bool
}

struct IDResponseDTO: Codable {
    var id: String
}

struct DrawModeStateDTO: Codable {
    var active: Bool
}
