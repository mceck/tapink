import XCTest
@testable import TapInkKit

final class HTTPMessageTests: XCTestCase {
    func testParsesSimpleGET() {
        let raw = "GET /draw-mode HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer abc123\r\n\r\n"
        let request = HTTPRequest.parse(Data(raw.utf8))
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.path, "/draw-mode")
        XCTAssertEqual(request?.headers["authorization"], "Bearer abc123")
        XCTAssertEqual(request?.body, Data())
    }

    func testParsesQueryString() {
        let raw = "GET /screenshot?display=69732800&rect=10,20,30,40 HTTP/1.1\r\n\r\n"
        let request = HTTPRequest.parse(Data(raw.utf8))
        XCTAssertEqual(request?.path, "/screenshot")
        XCTAssertEqual(request?.queryItems["display"], "69732800")
        XCTAssertEqual(request?.queryItems["rect"], "10,20,30,40")
    }

    func testParsesBodyByContentLength() {
        let body = "{\"foo\":1}"
        let raw = "POST /tools/pen HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let request = HTTPRequest.parse(Data(raw.utf8))
        XCTAssertEqual(request?.body, Data(body.utf8))
    }

    /// The body hasn't fully arrived yet (declared Content-Length exceeds what's buffered) —
    /// this is exactly the "keep receiving more" signal `APIServer`'s read loop relies on.
    func testReturnsNilWhenBodyIncomplete() {
        let raw = "POST /tools/pen HTTP/1.1\r\nContent-Length: 20\r\n\r\n{\"foo\":1}"
        XCTAssertNil(HTTPRequest.parse(Data(raw.utf8)))
    }

    /// Headers haven't fully arrived yet (no blank-line terminator) — also "keep receiving".
    func testReturnsNilWhenHeadersIncomplete() {
        let raw = "GET /draw-mode HTTP/1.1\r\nHost: localhost"
        XCTAssertNil(HTTPRequest.parse(Data(raw.utf8)))
    }

    func testMalformedRequestLineReturnsNil() {
        let raw = "NOTAREQUESTLINE\r\n\r\n"
        XCTAssertNil(HTTPRequest.parse(Data(raw.utf8)))
    }

    func testResponseSerialization() {
        let response = HTTPResponse.json(["ok": true])
        let serialized = String(data: response.serialized(), encoding: .utf8)!
        XCTAssertTrue(serialized.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(serialized.contains("Content-Type: application/json"))
    }
}
