import Foundation
import CZeroDevAA

/// URLSession-based HTTP transport for iOS/macOS.
///
/// Bridges the C HTTP callback to URLSession, bypassing Zig's built-in
/// TLS client which doesn't work on iOS (missing CA cert paths).
///
/// The callback runs synchronously (blocks the calling thread via semaphore)
/// because the Zig C FFI is synchronous. This is safe — the calling thread
/// is always a background thread, never the main thread.

private func urlSessionHttpCallback(
    ctx: UnsafeMutableRawPointer?,
    url: UnsafePointer<CChar>?,
    body: UnsafePointer<CChar>?,
    bodyLen: Int,
    responseOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    responseLenOut: UnsafeMutablePointer<Int>?
) -> Int32 {
    guard let url = url, let body = body, let responseOut = responseOut, let responseLenOut = responseLenOut else {
        return 1
    }

    let urlString = String(cString: url)
    guard let urlObj = URL(string: urlString) else { return 1 }

    var request = URLRequest(url: urlObj)
    request.httpMethod = "POST"
    request.httpBody = Data(bytes: body, count: bodyLen)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    var responseData: Data?
    var responseError: Error?
    let semaphore = DispatchSemaphore(value: 0)

    let task = URLSession.shared.dataTask(with: request) { data, _, error in
        responseData = data
        responseError = error
        semaphore.signal()
    }
    task.resume()
    semaphore.wait()

    guard responseError == nil, let data = responseData else { return 1 }

    // Allocate response with C malloc so the Zig side can free with std.c.free
    let ptr = malloc(data.count)!.assumingMemoryBound(to: CChar.self)
    data.withUnsafeBytes { bytes in
        memcpy(ptr, bytes.baseAddress!, data.count)
    }
    responseOut.pointee = ptr
    responseLenOut.pointee = data.count

    return 0 // AA_OK
}

extension Context {
    /// Use URLSession for all HTTP requests instead of Zig's built-in client.
    ///
    /// **Required on iOS** where Zig's TLS client can't initialize.
    /// Optional on macOS (Zig's client works, but URLSession may be preferred).
    ///
    /// Call this immediately after creating the context:
    /// ```swift
    /// let ctx = try Context(projectID: "...", chainID: 11155111, gasMiddleware: .zeroDev)
    /// ctx.useURLSessionTransport()
    /// ```
    public func useURLSessionTransport() {
        aa_context_set_http_transport(ptr, urlSessionHttpCallback, nil)
    }
}
