import Foundation

/// Runs all Rust core calls on one dedicated serial queue. rusqlite work is
/// synchronous and must never block the main thread.
final class CoreWorker: @unchecked Sendable {
    enum WorkerError: Error {
        case storeNotOpen
    }

    private let queue = DispatchQueue(label: "com.razlio.rallo.core-worker", qos: .userInitiated)
    // Only touched on `queue`.
    private var store: RalloStore?

    func open(dataDir: String) async throws {
        try await submit { [self] in
            store = try RalloStore.open(dataDir: dataDir)
        }
    }

    func perform<T>(_ work: @escaping (RalloStore) throws -> T) async throws -> T {
        try await submit { [self] in
            guard let store else { throw WorkerError.storeNotOpen }
            return try work(store)
        }
    }

    private func submit<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}
