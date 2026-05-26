//
//  TunnelSocket.swift
//  bluesteal
//
//  Base WebSocket channel for the caBLE tunnel transport, over
//  URLSessionWebSocketTask. URLSession delivers complete binary messages (no
//  fragment reassembly needed), so the C# manual receive loop collapses to a
//  single async `receive()`.
//

import Foundation

enum TunnelError: Error, CustomStringConvertible {
    case noResponse
    case subprotocolNotNegotiated(String)
    case missingRoutingId
    case unexpectedTextFrame
    case raceFailed
    case notOpen
    case handshakeFailed
    case decryptFailed
    case crypterLimitExceeded

    var description: String {
        switch self {
        case .noResponse:                  return "no HTTP response on WS upgrade"
        case .subprotocolNotNegotiated(let g): return "fido.cable subprotocol not negotiated (got '\(g)')"
        case .missingRoutingId:            return "response missing/malformed X-caBLE-Routing-ID"
        case .unexpectedTextFrame:         return "unexpected non-binary WebSocket frame"
        case .raceFailed:                  return "all peer race candidates failed"
        case .notOpen:                     return "socket not open"
        case .handshakeFailed:             return "Noise handshake failed"
        case .decryptFailed:               return "Noise decrypt failed"
        case .crypterLimitExceeded:        return "Crypter sequence limit exceeded"
        }
    }
}

class TunnelSocket: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let tracer: RelayTracer
    private var session: URLSession?
    private(set) var task: URLSessionWebSocketTask?

    private let lock = NSLock()
    private var openContinuation: CheckedContinuation<HTTPURLResponse?, Error>?
    private var openResolved = false

    nonisolated init(tracer: RelayTracer) {
        self.tracer = tracer
        super.init()
    }

    /// Opens the WebSocket and resolves once the upgrade completes, returning
    /// the HTTP 101 response (so callers can read the routing-id header).
    /// Cancellation cancels the underlying task so the await never hangs.
    func connect(url: URL, origin: String?) async throws -> HTTPURLResponse? {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session

        var req = URLRequest(url: url)
        req.setValue("fido.cable", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        if let origin { req.setValue(origin, forHTTPHeaderField: "Origin") }
        req.timeoutInterval = 15

        let task = session.webSocketTask(with: req)
        self.task = task

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HTTPURLResponse?, Error>) in
                lock.lock()
                openContinuation = cont
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.close()
        }
    }

    func send(_ data: [UInt8]) async throws {
        guard let task else { throw TunnelError.notOpen }
        try await task.send(.data(Data(data)))
    }

    /// Returns the next complete binary message. Throws on close/error.
    func receive() async throws -> [UInt8] {
        guard let task else { throw TunnelError.notOpen }
        let message = try await task.receive()
        switch message {
        case .data(let d): return [UInt8](d)
        case .string:      throw TunnelError.unexpectedTextFrame
        @unknown default:  throw TunnelError.unexpectedTextFrame
        }
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol proto: String?) {
        resolveOpen(.success(webSocketTask.response as? HTTPURLResponse))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { resolveOpen(.failure(error)) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        resolveOpen(.failure(TunnelError.noResponse))
    }

    private func resolveOpen(_ result: Result<HTTPURLResponse?, Error>) {
        lock.lock()
        guard !openResolved, let cont = openContinuation else { lock.unlock(); return }
        openResolved = true
        openContinuation = nil
        lock.unlock()
        cont.resume(with: result)
    }
}
