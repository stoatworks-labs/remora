import Foundation
import RemoraCore

/// One HTTP GET over Remora's TCP streams, for REAPER's web interface. It asks in HTTP/1.0, so the
/// server sends its answer whole, never chunked, and closes: the answer ends at the close, or at
/// its Content-Length if it gives one. Everything runs on the queue it's given.
public enum HTTPGet {
    public struct Answer: Equatable {
        public let status: Int
        public let body: String

        public init(status: Int, body: String) {
            self.status = status
            self.body = body
        }
    }

    public enum Failure: Error, Equatable {
        /// Nothing listening, or the network said no: why.
        case unreachable(String)
        case timedOut
        /// What answered isn't speaking HTTP.
        case badAnswer
        /// Over `maxBytes`.
        case tooBig
    }

    /// The most an answer may be. REAPER's TRACK lines for a few hundred tracks are far under it.
    public static let maxBytes = 4 << 20

    /// The request's bytes. Nothing in it but the path, which the caller has checked.
    public static func request(host: String, port: UInt16, path: String) -> [UInt8] {
        Array("GET \(path) HTTP/1.0\r\nHost: \(host):\(port)\r\nUser-Agent: Remora\r\nAccept: text/plain\r\n\r\n".utf8)
    }

    /// Reads an answer. `ended`: the server has closed, so whatever is there is all of it. Nil
    /// while more is to come.
    public static func parse(_ bytes: [UInt8], ended: Bool) -> Result<Answer, Failure>? {
        guard let headEnd = find([13, 10, 13, 10], in: bytes) else {
            return ended ? .failure(.badAnswer) : nil
        }
        let head = String(decoding: bytes[..<headEnd], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", maxSplits: 2)
        guard first.count >= 2, first[0].hasPrefix("HTTP/"), let status = Int(first[1]) else {
            return .failure(.badAnswer)
        }
        var length: Int?
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                length = Int(kv[1].trimmingCharacters(in: .whitespaces))
            }
        }
        var body = Array(bytes[(headEnd + 4)...])
        if let length {
            if body.count < length { return ended ? .failure(.badAnswer) : nil }
            body = Array(body.prefix(length))
        } else if !ended {
            return nil
        }
        return .success(Answer(status: status, body: String(decoding: body, as: UTF8.self)))
    }

    /// Asks once, on a stream of its own. `done` is called once, on `queue`; call this on `queue`.
    public static func get(_ platform: Platform, host: String, port: UInt16, path: String, queue: DispatchQueue,
                           timeout: TimeInterval = 3, done: @escaping (Result<Answer, Failure>) -> Void) {
        let stream = platform.tcp(host: host, port: port, queue: queue)
        var buffer: [UInt8] = []
        var asked = false
        var over = false
        func finish(_ r: Result<Answer, Failure>) {
            guard !over else { return }
            over = true
            // The stream would dial again by itself: stopped here, once, whatever happened.
            stream.onData = nil
            stream.onState = nil
            stream.stop()
            done(r)
        }
        stream.onData = { bytes in
            buffer += bytes
            if buffer.count > maxBytes {
                finish(.failure(.tooBig))
            } else if let r = parse(buffer, ended: false) {
                finish(r)
            }
        }
        stream.onState = { state in
            switch state {
            case .connected:
                guard !asked else { return }
                asked = true
                stream.send(request(host: host, port: port, path: path))
            case .failed(let why):
                // Closed after the question: that is the end of the answer.
                if asked {
                    finish(parse(buffer, ended: true) ?? .failure(.badAnswer))
                } else {
                    finish(.failure(.unreachable(why)))
                }
            case .stopped, .connecting:
                break
            }
        }
        queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(.timedOut)) }
        stream.start()
    }

    static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] {
            if Array(hay[i..<(i + needle.count)]) == needle { return i }
        }
        return nil
    }
}
