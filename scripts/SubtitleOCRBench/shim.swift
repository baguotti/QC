// The app's CancellationState is internal to VideoQCLib; the bench compiles the reader standalone.
import Foundation
final class CancellationState: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    var isCancelled: Bool { lock.withLock { flag } }
    func cancel() { lock.withLock { flag = true } }
}
