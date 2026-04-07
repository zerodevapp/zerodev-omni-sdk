import Foundation

/// Async signer protocol for iOS-compatible wallet providers (Privy, WalletConnect, etc.).
///
/// Unlike `SignerProtocol` (which is synchronous), this protocol uses Swift async/await.
/// The SDK handles bridging to the synchronous C FFI layer internally using a dedicated
/// dispatch queue — no semaphore deadlocks on iOS's cooperative executor.
///
/// ## Usage
/// ```swift
/// class PrivySigner: AsyncSignerProtocol {
///     func signHash(_ hash: [UInt8]) async throws -> [UInt8] {
///         try await wallet.provider.request(.eth_sign(hash))
///     }
///     func signMessage(_ msg: [UInt8]) async throws -> [UInt8] {
///         try await wallet.provider.request(.personal_sign(msg))
///     }
///     func signTypedDataHash(_ hash: [UInt8]) async throws -> [UInt8] {
///         try await wallet.provider.request(.eth_sign(hash))
///     }
///     func getAddress() -> [UInt8] { addressBytes }
/// }
///
/// let signer = try Signer.async(PrivySigner())
/// ```
public protocol AsyncSignerProtocol: AnyObject, Sendable {
    func signHash(_ hash: [UInt8]) async throws -> [UInt8]
    func signMessage(_ msg: [UInt8]) async throws -> [UInt8]
    func signTypedDataHash(_ hash: [UInt8]) async throws -> [UInt8]
    func getAddress() -> [UInt8]
}

/// Bridges an `AsyncSignerProtocol` to the synchronous `SignerProtocol` required by the C FFI.
/// Uses a dedicated serial dispatch queue to avoid deadlocking iOS's cooperative executor.
final class AsyncSignerBridge: SignerProtocol, @unchecked Sendable {
    private let impl: AsyncSignerProtocol
    private let queue = DispatchQueue(label: "dev.zerodev.signer", qos: .userInitiated)

    init(_ impl: AsyncSignerProtocol) {
        self.impl = impl
    }

    func signHash(_ hash: [UInt8]) throws -> [UInt8] {
        try blockOnQueue { try await self.impl.signHash(hash) }
    }

    func signMessage(_ msg: [UInt8]) throws -> [UInt8] {
        try blockOnQueue { try await self.impl.signMessage(msg) }
    }

    func signTypedDataHash(_ hash: [UInt8]) throws -> [UInt8] {
        try blockOnQueue { try await self.impl.signTypedDataHash(hash) }
    }

    func getAddress() -> [UInt8] {
        impl.getAddress()
    }

    /// Runs an async closure on a dedicated queue, blocking the current (C FFI) thread safely.
    /// The key: we dispatch the Task onto our own serial queue, not the caller's thread,
    /// so the semaphore.wait() never blocks the thread that the Task needs to complete on.
    private func blockOnQueue<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        nonisolated(unsafe) let result = UnsafeMutablePointer<Result<T, Error>>.allocate(capacity: 1)
        let semaphore = DispatchSemaphore(value: 0)

        queue.async {
            Task {
                do {
                    result.pointee = .success(try await work())
                } catch {
                    result.pointee = .failure(error)
                }
                semaphore.signal()
            }
        }

        semaphore.wait()
        defer { result.deallocate() }

        switch result.pointee {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}
