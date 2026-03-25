import StoreKit
import SwiftUI

// MARK: - Product Identifiers

enum ProProduct: String, CaseIterable {
    case monthly  = "com.splitcam.pro.monthly"
    case yearly   = "com.splitcam.pro.yearly"
    case lifetime = "com.splitcam.pro.lifetime"

    var isSubscription: Bool {
        self != .lifetime
    }
}

// MARK: - Pro Feature

/// 需要 Pro 才能使用的功能
enum ProFeature: String {
    case unlimitedRecording  = "无限录制时长"
    case pipMode             = "画中画模式"
    case duetMode            = "合拍模式"
    case telephotoZoom       = "3x 长焦"
    case allAspectRatios     = "全部画面比例"
    case layoutSwitchWhileRecording = "录制中切换布局"

    var icon: String {
        switch self {
        case .unlimitedRecording: return "infinity"
        case .pipMode:            return "pip"
        case .duetMode:           return "person.2.fill"
        case .telephotoZoom:      return "camera.metering.spot"
        case .allAspectRatios:    return "aspectratio"
        case .layoutSwitchWhileRecording: return "rectangle.2.swap"
        }
    }
}

// MARK: - Subscription Manager

@MainActor
final class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    // MARK: - Published State

    @Published private(set) var isPro = false
    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasedProductIDs: Set<String> = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    // MARK: - Free Tier Limits

    /// 免费版最大录制时长（秒）
    static let freeRecordingLimit: TimeInterval = 30

    // MARK: - Private

    private var transactionListener: Task<Void, Error>?
    private let productIDs = Set(ProProduct.allCases.map(\.rawValue))

    // MARK: - Init

    private init() {
        transactionListener = listenForTransactions()
        Task { await loadProducts() }
        Task { await updatePurchasedProducts() }
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Check Pro Feature Access

    /// 检查某个功能是否可用（免费或已订阅）
    func canAccess(_ feature: ProFeature) -> Bool {
        return isPro
    }

    /// 检查是否需要展示付费墙
    func shouldShowPaywall(for feature: ProFeature) -> Bool {
        return !isPro
    }

    // MARK: - Load Products

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let storeProducts = try await Product.products(for: productIDs)
            // 按价格排序: 月 → 年 → 终身
            products = storeProducts.sorted { ($0.price as NSDecimalNumber).doubleValue < ($1.price as NSDecimalNumber).doubleValue }
        } catch {
            errorMessage = "无法加载商品信息: \(error.localizedDescription)"
        }
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async -> Bool {
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await updatePurchasedProducts()
                return true

            case .userCancelled:
                return false

            case .pending:
                errorMessage = "购买正在处理中，请稍候"
                return false

            @unknown default:
                return false
            }
        } catch {
            errorMessage = "购买失败: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Restore Purchases

    func restorePurchases() async {
        isLoading = true
        defer { isLoading = false }

        try? await AppStore.sync()
        await updatePurchasedProducts()
    }

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                do {
                    let transaction = try self?.checkVerified(result)
                    await transaction?.finish()
                    await self?.updatePurchasedProducts()
                } catch {
                    // 验证失败，忽略
                }
            }
        }
    }

    // MARK: - Update Purchased Products

    private func updatePurchasedProducts() async {
        var purchased: Set<String> = []

        // 检查订阅
        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result) {
                if transaction.revocationDate == nil {
                    purchased.insert(transaction.productID)
                }
            }
        }

        purchasedProductIDs = purchased
        isPro = !purchased.isEmpty
    }

    // MARK: - Verification

    nonisolated private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let value):
            return value
        }
    }
}

// MARK: - Product Helpers

extension Product {
    /// 订阅周期描述
    var periodDescription: String? {
        guard let subscription = self.subscription else { return nil }
        switch subscription.subscriptionPeriod.unit {
        case .month: return "月"
        case .year:  return "年"
        case .week:  return "周"
        case .day:   return "天"
        @unknown default: return nil
        }
    }

    /// 是否有免费试用
    var hasFreeTrial: Bool {
        guard let intro = subscription?.introductoryOffer else { return false }
        return intro.paymentMode == .freeTrial
    }

    /// 免费试用天数
    var freeTrialDays: Int? {
        guard let intro = subscription?.introductoryOffer,
              intro.paymentMode == .freeTrial else { return nil }
        let period = intro.period
        switch period.unit {
        case .day:   return period.value
        case .week:  return period.value * 7
        case .month: return period.value * 30
        case .year:  return period.value * 365
        @unknown default: return nil
        }
    }
}
