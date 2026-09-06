import Foundation

@MainActor
final class RecordingCountdown {
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let sleep: () async throws -> Void

    init(sleep: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) {
        self.sleep = sleep
    }

    func start(tick: @escaping (Int?) -> Void, completion: @escaping () async -> Void) {
        cancel()
        let run = UUID()
        generation = run
        tick(3)
        task = Task {
            do {
                for next in [2, 1, 0] {
                    guard !Task.isCancelled, generation == run else { return }
                    try await sleep()
                    guard !Task.isCancelled, generation == run else { return }
                    tick(next == 0 ? nil : next)
                }
                task = nil
                await completion()
            } catch {
                if generation == run { tick(nil) }
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
    }
}
