import Foundation
import Network

struct HTTPRequest {
    var method: String
    var path: String
    /// Keys are lowercased.
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ status: Int, _ object: Any, pretty: Bool = false) -> HTTPResponse {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        let body = (try? JSONSerialization.data(withJSONObject: object, options: options)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: body)
    }
}

/// A minimal HTTP/1.1 server bound to the loopback interface.
final class HTTPServer {
    typealias Handler = (HTTPRequest) -> HTTPResponse

    private let listener: NWListener
    private let queue = DispatchQueue(label: "vision-mcp.http")
    private let handler: Handler

    init(port: UInt16, handler: @escaping Handler) throws {
        guard let port = NWEndpoint.Port(rawValue: port) else { throw POSIXError(.EINVAL) }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    func start(onReady: @escaping () -> Void, onFailure: @escaping (Error) -> Void) {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: onReady()
            case .failed(let error), .waiting(let error): onFailure(error)
            default: break
            }
        }
        listener.newConnectionHandler = { [handler, queue] connection in
            HTTPConnection(connection, handler: handler).start(on: queue)
        }
        listener.start(queue: queue)
    }
}

private final class HTTPConnection {
    private enum Parsed {
        case request(HTTPRequest)
        case incomplete(expectsContinue: Bool)
        case invalid(Int)
    }

    private static let headerLimit = 16 * 1024
    private static let bodyLimit = 1024 * 1024
    private static let terminator = Data("\r\n\r\n".utf8)

    private let connection: NWConnection
    private let handler: HTTPServer.Handler
    private var buffer = Data()
    private var sentContinue = false

    init(_ connection: NWConnection, handler: @escaping HTTPServer.Handler) {
        self.connection = connection
        self.handler = handler
    }

    func start(on queue: DispatchQueue) {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if error != nil {
                connection.cancel()
                return
            }
            process(ended: isComplete)
        }
    }

    private func process(ended: Bool) {
        switch parse() {
        case .request(let request):
            sentContinue = false
            let close = ended || request.headers["connection"]?.lowercased() == "close"
            send(handler(request), close: close)
        case .invalid(let status):
            send(HTTPResponse(status: status), close: true)
        case .incomplete(let expectsContinue):
            if ended {
                connection.cancel()
                return
            }
            if expectsContinue, !sentContinue {
                sentContinue = true
                connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
            }
            receive()
        }
    }

    private func parse() -> Parsed {
        guard let headerEnd = buffer.range(of: Self.terminator) else {
            return buffer.count > Self.headerLimit ? .invalid(431) : .incomplete(expectsContinue: false)
        }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3 else { return .invalid(400) }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(400) }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .invalid(411) }
        var length = 0
        if let declared = headers["content-length"] {
            guard let value = Int(declared), value >= 0 else { return .invalid(400) }
            length = value
        }
        guard length <= Self.bodyLimit else { return .invalid(413) }

        let bodyStart = headerEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else {
            return .incomplete(expectsContinue: headers["expect"]?.lowercased() == "100-continue")
        }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        buffer = Data(buffer[(bodyStart + length)...])
        return .request(HTTPRequest(
            method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body))
    }

    private func send(_ response: HTTPResponse, close: Bool) {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = close ? "close" : "keep-alive"
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { [self] error in
            if close || error != nil {
                connection.cancel()
            } else if buffer.isEmpty {
                receive()
            } else {
                process(ended: false)
            }
        })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 431: "Request Header Fields Too Large"
        default: "Error"
        }
    }
}
