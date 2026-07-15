import Foundation

/// A parsed HTTP/1.1 request. `path` never includes the query string — see `queryItems`.
struct HTTPRequest {
    var method: String
    var path: String
    var queryItems: [String: String]
    var headers: [String: String]
    var body: Data

    /// Parses as much of an HTTP/1.1 request as `data` currently holds. Returns `nil` if the
    /// request line/headers haven't fully arrived yet, or if the declared `Content-Length` body
    /// hasn't fully arrived yet — both mean "keep receiving", which is exactly how `APIServer`'s
    /// incremental read loop uses this single function. Deliberately doesn't support chunked
    /// transfer-encoding or pipelined requests: the only clients TapInk talks to (curl today, an
    /// MCP server later) never need them.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEndRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let headerString = String(data: data[..<headerEndRange.lowerBound], encoding: .utf8) else { return nil }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else { return nil }

        let (path, queryItems) = parseTarget(String(requestParts[1]))

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        let bodyStart = headerEndRange.upperBound
        guard data.count - bodyStart >= contentLength else { return nil }
        let body = data[bodyStart..<data.index(bodyStart, offsetBy: contentLength)]

        return HTTPRequest(method: String(requestParts[0]), path: path, queryItems: queryItems, headers: headers, body: Data(body))
    }

    private static func parseTarget(_ raw: String) -> (path: String, queryItems: [String: String]) {
        guard let questionIndex = raw.firstIndex(of: "?") else { return (raw, [:]) }
        let path = String(raw[raw.startIndex..<questionIndex])
        var items: [String: String] = [:]
        for pair in raw[raw.index(after: questionIndex)...].split(separator: "&") {
            let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawKey = keyValue.first else { continue }
            let key = String(rawKey).removingPercentEncoding ?? String(rawKey)
            let rawValue = keyValue.count > 1 ? String(keyValue[1]) : ""
            items[key] = rawValue.removingPercentEncoding ?? rawValue
        }
        return (path, items)
    }
}

/// A serializable HTTP/1.1 response. Always closes the connection after sending (`Connection:
/// close`) — `APIServer` handles one request per connection, so there's nothing to keep alive.
struct HTTPResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data

    func serialized() -> Data {
        var allHeaders = headers
        allHeaders["Content-Length"] = "\(body.count)"
        allHeaders["Connection"] = "close"
        var head = "HTTP/1.1 \(status) \(HTTPResponse.statusText(for: status))\r\n"
        for (key, value) in allHeaders {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    private static func statusText(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: (try? JSONEncoder().encode(value)) ?? Data())
    }

    static func error(_ message: String, status: Int) -> HTTPResponse {
        json(ErrorResponseDTO(error: message), status: status)
    }

    static func png(_ data: Data) -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["Content-Type": "image/png"], body: data)
    }
}
