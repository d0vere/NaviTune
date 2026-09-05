import Foundation
import UIKit
import BackgroundTasks

@MainActor
final class BackgroundSyncCoordinator {
    static let shared = BackgroundSyncCoordinator()

    private let identifier = "com.d0vere.NavidromeMusicSync.continued-sync"
    private var registered = false
    private var progressObserver: ((String, Double) -> Void)?
    private var completionObserver: ((Result<FullLibrarySyncResult, Error>) -> Void)?

    private init() {}

    func registerIfSupported() {
        guard #available(iOS 26.0, *), !registered else { return }
        registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] rawTask in
            guard let self, let task = rawTask as? BGContinuedProcessingTask else {
                rawTask.setTaskCompleted(success: false)
                return
            }
            self.handle(task)
        }
    }

    @available(iOS 26.0, *)
    func startUserInitiatedSync(
        progress: @escaping (String, Double) -> Void,
        completion: @escaping (Result<FullLibrarySyncResult, Error>) -> Void
    ) throws {
        registerIfSupported()
        progressObserver = progress
        completionObserver = completion

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "NaviTune Sync",
            subtitle: "Preparing Music library…"
        )
        request.strategy = .fail
        try BGTaskScheduler.shared.submit(request)
    }

    @available(iOS 26.0, *)
    private func handle(_ task: BGContinuedProcessingTask) {
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = 0

        let work = Task {
            do {
                let result = try await FullLibrarySyncService().syncUsingSavedConfiguration { [weak self, weak task] text, value in
                    guard let task else { return }
                    task.progress.completedUnitCount = Int64((value * 1000).rounded())
                    task.updateTitle("NaviTune Sync", subtitle: text)
                    await MainActor.run {
                        self?.progressObserver?(text, value)
                    }
                }
                task.progress.completedUnitCount = 1000
                task.updateTitle("NaviTune Sync", subtitle: "Complete")
                task.setTaskCompleted(success: true)
                await MainActor.run {
                    self.completionObserver?(.success(result))
                    self.progressObserver = nil
                    self.completionObserver = nil
                }
            } catch {
                task.setTaskCompleted(success: false)
                await MainActor.run {
                    self.completionObserver?(.failure(error))
                    self.progressObserver = nil
                    self.completionObserver = nil
                }
            }
        }

        task.expirationHandler = {
            work.cancel()
        }
    }
}

@MainActor
final class BackgroundExecutionLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private let keepsScreenAwake: Bool

    init(name: String, keepsScreenAwake: Bool = true) {
        self.keepsScreenAwake = keepsScreenAwake
        if keepsScreenAwake {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        if identifier != .invalid {
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
        if keepsScreenAwake {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    deinit {
        if identifier != .invalid {
            UIApplication.shared.endBackgroundTask(identifier)
        }
    }
}
