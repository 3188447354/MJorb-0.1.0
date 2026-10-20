import SwiftUI

@MainActor
final class UpdatePresentationCoordinator: ObservableObject {
    enum Status: Equatable {
        case unchecked
        case checking
        case latest
        case available(String)
        case unavailable(UpdateCheckFailure)
    }

    @Published private(set) var status: Status = .unchecked
    @Published private(set) var isChecking = false
    @Published var presentedNotice: UpdateNotice?

    private var isSceneActive = false
    private var completedAutomaticCheck = false
    private var needsAutomaticRetry = false
    private var retryDelaySeconds: Int64 = 30
    private var retryTask: Task<Void, Never>?

    func sceneDidChange(isActive: Bool) {
        isSceneActive = isActive
        guard isActive else {
            retryTask?.cancel()
            retryTask = nil
            return
        }

        guard completedAutomaticCheck == false, presentedNotice == nil else { return }
        let force = needsAutomaticRetry
        Task { await checkAutomatically(force: force) }
    }

    func checkAutomatically(force: Bool = false) async {
        guard isSceneActive,
              completedAutomaticCheck == false,
              presentedNotice == nil,
              isChecking == false else { return }
        _ = await performCheck(force: force, isManual: false)
    }

    func checkManually() async -> UpdateCheckResult? {
        guard isChecking == false else { return nil }
        retryTask?.cancel()
        retryTask = nil
        return await performCheck(force: true, isManual: true)
    }

    func markNoticePresented(version: String) {
        guard presentedNotice?.version == version else { return }
        UpdateChecker.shared.markNotified(version: version)
    }

    func dismissNotice() {
        presentedNotice = nil
        completedAutomaticCheck = true
    }

    private func performCheck(force: Bool, isManual: Bool) async -> UpdateCheckResult {
        isChecking = true
        status = .checking
        let result = await UpdateChecker.shared.check(force: force)
        isChecking = false

        switch result {
        case .available(let notice):
            status = .available(notice.version)
            if isManual || UpdateChecker.shared.wasNotified(version: notice.version) == false {
                presentedNotice = notice
            }
            completeAutomaticCheck()
        case .latest:
            status = .latest
            completeAutomaticCheck()
        case .unavailable(let failure):
            status = .unavailable(failure)
            needsAutomaticRetry = true
            scheduleRetryIfNeeded()
        }

        return result
    }

    private func completeAutomaticCheck() {
        completedAutomaticCheck = true
        needsAutomaticRetry = false
        retryDelaySeconds = 30
        retryTask?.cancel()
        retryTask = nil
    }

    private func scheduleRetryIfNeeded() {
        guard isSceneActive else { return }
        retryTask?.cancel()
        let delay = retryDelaySeconds
        retryDelaySeconds = min(retryDelaySeconds * 2, 300)
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, self.isSceneActive else { return }
            await self.checkAutomatically(force: true)
        }
    }
}
