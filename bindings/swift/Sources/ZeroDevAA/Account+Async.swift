import Foundation

/// Async wrappers for Account methods.
///
/// The underlying C FFI blocks the calling thread — these extensions
/// dispatch to a background queue so callers can `await` safely from
/// any actor/thread context.
extension Account {
    /// Send a UserOperation asynchronously.
    public func sendUserOp(calls: [Call]) async throws -> Hash {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try self.sendUserOp(calls: calls)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Wait for a UserOp receipt asynchronously.
    public func waitForUserOperationReceipt(
        useropHash: Hash,
        timeoutMs: UInt32 = 0,
        pollIntervalMs: UInt32 = 0
    ) async throws -> UserOperationReceipt {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try self.waitForUserOperationReceipt(
                        useropHash: useropHash, timeoutMs: timeoutMs, pollIntervalMs: pollIntervalMs
                    ))
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Build a UserOperation asynchronously.
    public func buildUserOp(calls: [Call]) async throws -> UserOp {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try self.buildUserOp(calls: calls)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Get address asynchronously.
    public func getAddressAsync() async throws -> Address {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try self.getAddress()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }
}
