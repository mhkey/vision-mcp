import Foundation

/// Relays newline-delimited JSON-RPC between stdin/stdout and the running app, for clients that only speak stdio.
enum StdioBridge {
    static func run(port: UInt16) -> Never {
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = Data(line.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")

            let done = DispatchSemaphore(value: 0)
            var reply: Data?
            URLSession.shared.dataTask(with: request) { data, _, error in
                reply = error == nil ? (data ?? Data()) : nil
                done.signal()
            }.resume()
            done.wait()

            if let reply {
                if !reply.isEmpty { write(reply) }
            } else if let id = requestID(line) {
                let failure: [String: Any] = [
                    "jsonrpc": "2.0", "id": id,
                    "error": ["code": -32000, "message": "Vision MCP is not running. Start the VisionMCP app, then retry."] as [String: Any],
                ]
                if let data = try? JSONSerialization.data(withJSONObject: failure) { write(data) }
            }
        }
        exit(0)
    }

    private static func requestID(_ line: String) -> Any? {
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = message["id"], !(id is NSNull)
        else { return nil }
        return id
    }

    private static func write(_ data: Data) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
