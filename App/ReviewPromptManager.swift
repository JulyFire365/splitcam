import Combine
import Foundation
import StoreKit
import SwiftUI
import UIKit

/// 统一管理 App Store 评分请求的资格、频控与展示时机。
@MainActor
final class ReviewPromptManager: ObservableObject {
    static let shared = ReviewPromptManager()

    @Published private(set) var pendingRequestID: UUID?

    private enum Key {
        static let firstLaunchDate = "review.firstLaunchDate"
        static let launchCount = "review.launchCount"
        static let successfulCreationCount = "review.successfulCreationCount"
        static let lastPromptDate = "review.lastPromptDate"
        static let lastPromptedVersion = "review.lastPromptedVersion"
        static let promptAttemptDates = "review.promptAttemptDates"
    }

    private let defaults: UserDefaults

    private let minimumLaunches = 3
    private let minimumSuccessfulCreations = 2
    private let minimumAppAge: TimeInterval = 3 * 24 * 60 * 60
    private let minimumPromptInterval: TimeInterval = 120 * 24 * 60 * 60
    private let promptWindow: TimeInterval = 365 * 24 * 60 * 60
    private let maximumPromptAttemptsPerYear = 2

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recordLaunch()
    }

    /// 仅在图片或视频真正保存成功后调用，用于衡量用户是否已获得足够价值。
    func recordSuccessfulCreation() {
        defaults.set(defaults.integer(forKey: Key.successfulCreationCount) + 1,
                     forKey: Key.successfulCreationCount)
    }

    /// 视频已成功写入系统相册后，将评分请求排队至主界面处理。
    func queueAfterSuccessfulVideoSave() {
        guard pendingRequestID == nil else { return }
        pendingRequestID = UUID()
    }

    /// 用户主动前往 App Store 评价后，避免在同一版本再次展示系统评分请求。
    func recordManualReviewIntent(now: Date = Date()) {
        clearPendingRequest()
        defaults.set(now, forKey: Key.lastPromptDate)
        defaults.set(currentAppVersion, forKey: Key.lastPromptedVersion)
    }

    /// 在主界面延迟后调用。符合频控条件时会消费这次请求机会。
    func consumePendingRequestIfEligible(now: Date = Date()) -> Bool {
        guard pendingRequestID != nil else { return false }
        defer { clearPendingRequest() }

        guard isEligibleForPrompt(at: now) else { return false }

        var attempts = promptAttemptDates.filter { now.timeIntervalSince($0) < promptWindow }
        attempts.append(now)
        defaults.set(attempts.map(\.timeIntervalSinceReferenceDate), forKey: Key.promptAttemptDates)
        defaults.set(now, forKey: Key.lastPromptDate)
        defaults.set(currentAppVersion, forKey: Key.lastPromptedVersion)
        return true
    }

    private func recordLaunch() {
        if defaults.object(forKey: Key.firstLaunchDate) == nil {
            defaults.set(Date(), forKey: Key.firstLaunchDate)
        }
        defaults.set(defaults.integer(forKey: Key.launchCount) + 1, forKey: Key.launchCount)
    }

    private func isEligibleForPrompt(at now: Date) -> Bool {
        guard let firstLaunchDate = defaults.object(forKey: Key.firstLaunchDate) as? Date,
              now.timeIntervalSince(firstLaunchDate) >= minimumAppAge,
              defaults.integer(forKey: Key.launchCount) >= minimumLaunches,
              defaults.integer(forKey: Key.successfulCreationCount) >= minimumSuccessfulCreations,
              defaults.string(forKey: Key.lastPromptedVersion) != currentAppVersion else {
            return false
        }

        if let lastPromptDate = defaults.object(forKey: Key.lastPromptDate) as? Date,
           now.timeIntervalSince(lastPromptDate) < minimumPromptInterval {
            return false
        }

        let attempts = promptAttemptDates.filter { now.timeIntervalSince($0) < promptWindow }
        return attempts.count < maximumPromptAttemptsPerYear
    }

    private var promptAttemptDates: [Date] {
        (defaults.array(forKey: Key.promptAttemptDates) as? [Double] ?? [])
            .map(Date.init(timeIntervalSinceReferenceDate:))
    }

    private var currentAppVersion: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(shortVersion) (\(build))"
    }

    private func clearPendingRequest() {
        pendingRequestID = nil
    }
}

/// iOS 18 起使用 StoreKit 的 SwiftUI 评分请求接口。
@available(iOS 18.0, *)
struct ReviewPromptHost: View {
    @ObservedObject var manager: ReviewPromptManager
    let isAtRoot: Bool
    let navigationRevision: Int

    @Environment(\.requestReview) private var requestReview

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: "\(manager.pendingRequestID?.uuidString ?? "none")-\(navigationRevision)") {
                await requestReviewIfAppropriate()
            }
    }

    private func requestReviewIfAppropriate() async {
        guard isAtRoot, manager.pendingRequestID != nil else { return }

        do {
            try await Task.sleep(nanoseconds: 2_000_000_000)
        } catch {
            return
        }

        guard isAtRoot,
              UIApplication.shared.applicationState == .active,
              manager.consumePendingRequestIfEligible() else {
            return
        }

        requestReview()
    }
}

/// iOS 16–17 的兼容实现。
@available(iOS, introduced: 16.0, obsoleted: 18.0)
struct LegacyReviewPromptHost: View {
    @ObservedObject var manager: ReviewPromptManager
    let isAtRoot: Bool
    let navigationRevision: Int

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: "\(manager.pendingRequestID?.uuidString ?? "none")-\(navigationRevision)") {
                await requestReviewIfAppropriate()
            }
    }

    private func requestReviewIfAppropriate() async {
        guard isAtRoot, manager.pendingRequestID != nil else { return }

        do {
            try await Task.sleep(nanoseconds: 2_000_000_000)
        } catch {
            return
        }

        guard isAtRoot,
              UIApplication.shared.applicationState == .active,
              manager.consumePendingRequestIfEligible(),
              let windowScene = UIApplication.shared.connectedScenes
                  .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            return
        }

        SKStoreReviewController.requestReview(in: windowScene)
    }
}
