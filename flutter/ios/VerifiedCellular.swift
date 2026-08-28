import Foundation
import Network

// VerifiedCellular, v2, 2026-08. The whole thing: copy this file as one block.
// It stands alone — the types it answers with are declared here too.
//
// A hop is one GET and its reply, on a connection of its own. How many a call
// takes isn't known up front — each redirect adds one — so `chain` keeps making
// hops until a reply isn't a redirect, or until the cap.
//
// `URLSession` cannot require an interface, so every hop is an `NWConnection`
// pinned with `requiredInterfaceType = .cellular` (see `connect`), and HTTP/1.1
// is hand-rolled: each request sends `Connection: close`, and the reply is
// whatever arrives before the socket does.

enum VerifiedCellular {
    /// The IP this device shows over cellular, not the one the default route
    /// shows. Read over cellular, so it holds even while WiFi is winning.
    static func getDeviceIp(timeout: TimeInterval = 3) async throws -> String {
        struct DeviceIp: Decodable { let deviceIp: String }
        let deviceIpEndpoint = URL(string: "https://core-api.verified.inc/v2/1-click/verifications/device-ip")!
        let answer = try await chain(url: deviceIpEndpoint, timeout: timeout)
        guard (200...299).contains(answer.status) else { throw answer.unreadable }
        return try answer.decode(DeviceIp.self).deviceIp
    }

    /// GETs `url` over cellular and follows wherever it leads. The chain ends
    /// back at core-service with the verification record, so a 2xx is the
    /// entity; any other status is the API's refusal, which is an answer too —
    /// its body is the reason. A throw means no answer at all. Every hop is a
    /// bare GET carrying only cookies picked up along the way.
    static func followRedirects(
        url: URL, timeout: TimeInterval = 10
    ) async throws -> Result<OneClickVerificationEntity, ApiError> {
        let answer = try await chain(url: url, timeout: timeout)
        return (200...299).contains(answer.status)
            ? .success(try answer.decode(OneClickVerificationEntity.self))
            : .failure(try answer.decode(ApiError.self))
    }

    // MARK: What the chain answers with

    /// A 1-Click verification, as core-service returns it — the API calls this
    /// entity `1ClickVerificationEntity`, which Swift can't spell. Everything past
    /// `uuid` is optional: one shape covers create, this chain's last hop, and
    /// verify — the same record at different points in its life.
    struct OneClickVerificationEntity: Decodable {
        let uuid: String
        let channel: String?
        let status: String?
        let phone: String?
        let verified: Bool?
        let createdAt: Int?
        let expiresAt: Int?
        let verifiedAt: Int?
        let deliveredAt: Int?
        let attemptsRemaining: Int?

        /// `verified` is derived from `verifiedAt` server-side, so either one
        /// being set is the same answer.
        var isVerified: Bool { verified == true || verifiedAt != nil }
    }

    /// An API refusal. `data.errorCode` carries the product code — OCV008 is
    /// "autofill failed" — and the outer fields are the envelope core-service
    /// wraps every error in. Only `message` is required, so some unrelated JSON
    /// object can't decode as an error by accident.
    struct ApiError: Decodable, Error {
        struct Payload: Decodable {
            let errorCode: String?
        }

        let message: String
        let name: String?
        let code: Int?
        let className: String?
        let data: Payload?

        var errorCode: String? { data?.errorCode }

        var describedMessage: String {
            guard let prefix = errorCode ?? name, !prefix.isEmpty else { return message }
            return "\(prefix): \(message)"
        }
    }

    // MARK: The chain

    private struct Answer {
        let status: Int
        let body: Data
        /// The end of the chain, not what was asked for.
        let url: URL

        var unreadable: CellularError { .unreadableBody(statusCode: status, body: body, url: url) }

        func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
            do { return try JSONDecoder().decode(type, from: body) } catch { throw unreadable }
        }
    }

    private static func chain(url: URL, timeout: TimeInterval) async throws -> Answer {
        let deadline = Date().addingTimeInterval(timeout)
        var url = url
        var cookies: [String: String] = [:]

        let maxRedirects = 10
        for _ in 0...maxRedirects {
            guard deadline.timeIntervalSinceNow > 0 else { throw CellularError.timeout }
            let connection = try await connect(to: url, deadline: deadline)
            defer { connection.cancel() }

            let raw = try await exchange(request(for: url, cookies: cookies), on: connection, deadline: deadline)
            guard let reply = parse(raw) else {
                throw CellularError.unreadableBody(statusCode: 0, body: raw, url: url)
            }
            cookies.merge(reply.cookies) { _, newer in newer }

            guard (300...399).contains(reply.status) else {
                return Answer(status: reply.status, body: reply.body, url: url)
            }
            guard let location = reply.headers["location"],
                  let next = URL(string: location, relativeTo: url)?.absoluteURL else {
                throw CellularError.unusableURL(url)
            }
            guard next.scheme != "http" else { throw CellularError.cleartextRedirectBlocked }
            url = next
        }
        throw CellularError.tooManyRedirects
    }

    // MARK: Connect and exchange

    private static func connect(to url: URL, deadline: Date) async throws -> NWConnection {
        let defaultPort = url.scheme == "http" ? 80 : 443
        guard let host = url.host, let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? defaultPort)) else {
            throw CellularError.unusableURL(url)
        }

        // .tls advertises no ALPN, so the server never picks HTTP/2 — which is
        // what keeps the wire at HTTP/1.1, all `parse` understands.
        let parameters: NWParameters = url.scheme == "http" ? .tcp : .tls
        parameters.requiredInterfaceType = .cellular
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        // Requiring cellular means the connection parks in `.waiting` instead of
        // failing when there is no cellular, so the wait needs its own bound.
        let connectBy = min(deadline, Date().addingTimeInterval(5))

        do {
            try await beforeDeadline(connectBy, cancelling: connection) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    connection.stateUpdateHandler = { state in
                        let outcome: Result<Void, Error>
                        switch state {
                        case .ready: outcome = .success(())
                        case .failed(let error): outcome = .failure(error)
                        case .cancelled: outcome = .failure(CellularError.timeout)
                        default: return // .waiting isn't a failure; the deadline bounds it
                        }
                        connection.stateUpdateHandler = nil // so this resumes exactly once
                        continuation.resume(with: outcome)
                    }
                    connection.start(queue: .global(qos: .utility))
                }
            }
            return connection
        } catch {
            connection.cancel()
            if case CellularError.timeout = error { throw CellularError.noCellularAvailable }
            if case NWError.posix(let code) = error,
               [.ENETUNREACH, .ENETDOWN, .EHOSTUNREACH, .EADDRNOTAVAIL].contains(code) {
                throw CellularError.noCellularAvailable
            }
            throw error
        }
    }

    /// Sends the request and reads the reply. On a stream `receiveMessage` waits
    /// for the close, which `Connection: close` guarantees, so it hands back the
    /// whole response in one go.
    private static func exchange(_ request: Data, on connection: NWConnection, deadline: Date) async throws -> Data {
        try await beforeDeadline(deadline, cancelling: connection) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: request, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
            }
            return try await withCheckedThrowingContinuation { continuation in
                connection.receiveMessage { data, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: data ?? Data()) }
                }
            }
        }
    }

    /// Cancelling the connection is what unblocks a stalled send or receive, so
    /// the deadline does that and reports whatever error follows as `.timeout`.
    private static func beforeDeadline<T>(_ deadline: Date, cancelling connection: NWConnection, _ work: () async throws -> T) async throws -> T {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            connection.cancel()
            throw CellularError.timeout
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + remaining)
        timer.setEventHandler { connection.cancel() }
        timer.activate()
        defer { timer.cancel() }

        do {
            return try await work()
        } catch {
            throw deadline.timeIntervalSinceNow > 0 ? error : CellularError.timeout
        }
    }

    // MARK: HTTP/1.1 by hand

    private static func request(for url: URL, cookies: [String: String]) -> Data {
        // Percent-encoded on purpose: url.path decodes the escapes, which would
        // corrupt a path carrying a %2F or a space.
        var target = url.path(percentEncoded: true)
        if target.isEmpty { target = "/" }
        if let query = url.query(percentEncoded: true), !query.isEmpty { target += "?\(query)" }

        // Host carries the port unless it is the scheme's default.
        var host = url.host ?? ""
        if let port = url.port, port != (url.scheme == "http" ? 80 : 443) { host += ":\(port)" }

        var lines = [
            "GET \(target) HTTP/1.1",
            "Host: \(host)",
            "Connection: close",
            // Some carrier gateways drop requests that don't identify themselves.
            "User-Agent: VerifiedCellular/1",
        ]
        if !cookies.isEmpty {
            lines.append("Cookie: " + cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "))
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// Splits one HTTP/1.1 response into status, headers (lowercased), cookies
    /// (`Set-Cookie` repeats, so keeping it with the rest would drop all but the
    /// last) and body, de-chunked when the headers say so. nil = not a response.
    private static func parse(_ data: Data) -> (status: Int, headers: [String: String], cookies: [String: String], body: Data)? {
        guard let blank = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<blank.lowerBound], encoding: .utf8) else { return nil }

        var lines = head.components(separatedBy: "\r\n")
        guard let status = lines.removeFirst().split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
            return nil
        }

        var headers: [String: String] = [:], cookies: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard name == "set-cookie" else {
                headers[name] = value
                continue
            }
            // Only the leading pair is the cookie; the rest is attributes.
            let pair = value.prefix { $0 != ";" }
            if let equals = pair.firstIndex(of: "="), equals != pair.startIndex {
                cookies[pair[..<equals].trimmingCharacters(in: .whitespaces)] =
                    pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            }
        }

        var body = Data(data[blank.upperBound...])

        // A chunked body is a hex size line, CRLF, that many bytes, CRLF, until
        // a zero. Malformed framing keeps the raw bytes, which at least stay
        // readable in a log.
        if headers["transfer-encoding"]?.lowercased().contains("chunked") ?? false {
            let crlf = Data("\r\n".utf8)
            var joined = Data(), index = body.startIndex
            while index < body.endIndex {
                guard let eol = body.range(of: crlf, in: index..<body.endIndex),
                      let line = String(data: body[index..<eol.lowerBound], encoding: .utf8),
                      let size = Int(line.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces), radix: 16)
                else { joined = body; break }
                if size == 0 { break }
                guard let end = body.index(eol.upperBound, offsetBy: size, limitedBy: body.endIndex),
                      let next = body.index(end, offsetBy: crlf.count, limitedBy: body.endIndex)
                else { joined = body; break }
                joined.append(body[eol.upperBound..<end])
                index = next
            }
            body = joined
        }

        return (status, headers, cookies, body)
    }
}

enum CellularError: Error {
    case noCellularAvailable
    case timeout
    case tooManyRedirects
    case cleartextRedirectBlocked
    /// A URL with no host, or a redirect pointing somewhere unparseable.
    case unusableURL(URL)
    /// The chain answered, but the body was not what was asked for.
    case unreadableBody(statusCode: Int, body: Data, url: URL)
}
