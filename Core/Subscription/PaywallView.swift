import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = SubscriptionManager.shared

    /// 触发付费墙的功能（可选，用于高亮显示）
    var triggeredBy: ProFeature?

    @State private var selectedProduct: Product?
    @State private var isPurchasing = false
    @State private var showSuccess = false

    var body: some View {
        ZStack {
            // 背景渐变
            LinearGradient(
                colors: [Color.black, Color(red: 0.1, green: 0.05, blue: 0.2)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    // 关闭按钮
                    closeButton

                    // 标题
                    headerSection

                    // 功能列表
                    featuresSection

                    // 价格选择
                    pricingSection

                    // 购买按钮
                    purchaseButton

                    // 恢复购买 + 条款
                    footerSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
        .task {
            if manager.products.isEmpty {
                await manager.loadProducts()
            }
            // 默认选中年订阅（性价比最高）
            if selectedProduct == nil {
                selectedProduct = manager.products.first { $0.id == ProProduct.yearly.rawValue }
                    ?? manager.products.first
            }
        }
        .alert("purchase.success.title".localized, isPresented: $showSuccess) {
            Button("ok".localized) { dismiss() }
        } message: {
            Text("purchase.success.message".localized)
        }
    }

    // MARK: - Close Button

    private var closeButton: some View {
        HStack {
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            // App Logo
            Image("AppIconImage")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .purple.opacity(0.5), radius: 20)

            Text("paywall.title".localized)
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.white)

            Text("paywall.subtitle".localized)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
        }
    }

    // MARK: - Features

    private var featuresSection: some View {
        VStack(spacing: 0) {
            ForEach(ProFeature.allCases, id: \.self) { feature in
                featureRow(feature)
                if feature != ProFeature.allCases.last {
                    Divider()
                        .background(Color.white.opacity(0.1))
                }
            }
        }
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func featureRow(_ feature: ProFeature) -> some View {
        HStack(spacing: 14) {
            Image(systemName: feature.icon)
                .font(.system(size: 18))
                .foregroundColor(.orange)
                .frame(width: 32)

            Text(feature.displayName)
                .font(.subheadline)
                .foregroundColor(.white)

            Spacer()

            if feature == triggeredBy {
                Text("paywall.new".localized)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange)
                    .clipShape(Capsule())
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.green)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Pricing

    private var pricingSection: some View {
        VStack(spacing: 10) {
            if manager.products.isEmpty && manager.isLoading {
                ProgressView()
                    .tint(.white)
                    .padding()
            } else {
                ForEach(manager.products, id: \.id) { product in
                    pricingCard(product)
                }
            }
        }
    }

    private func pricingCard(_ product: Product) -> some View {
        let isSelected = selectedProduct?.id == product.id
        let isYearly = product.id == ProProduct.yearly.rawValue
        let isLifetime = product.id == ProProduct.lifetime.rawValue

        return Button {
            withAnimation(.spring(response: 0.3)) {
                selectedProduct = product
            }
        } label: {
            HStack(spacing: 14) {
                // 选中指示器
                ZStack {
                    Circle()
                        .stroke(isSelected ? Color.orange : Color.white.opacity(0.3), lineWidth: 2)
                        .frame(width: 22, height: 22)
                    if isSelected {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 14, height: 14)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(planTitle(for: product))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)

                        if isYearly {
                            Text("paywall.save61".localized)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange)
                                .clipShape(Capsule())
                        }
                    }

                    if let trial = product.freeTrialDays, trial > 0 {
                        Text("paywall.trialDays".localized("\(trial)"))
                            .font(.system(size: 12))
                            .foregroundColor(.orange.opacity(0.9))
                    } else if isLifetime {
                        Text("paywall.lifetimeDesc".localized)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(product.displayPrice)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)

                    if let period = product.periodDescription {
                        Text("/ \(period)")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.orange.opacity(0.15) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.orange : Color.clear, lineWidth: 1.5)
            )
        }
    }

    private func planTitle(for product: Product) -> String {
        switch product.id {
        case ProProduct.monthly.rawValue:  return "plan.monthly".localized
        case ProProduct.yearly.rawValue:   return "plan.yearly".localized
        case ProProduct.lifetime.rawValue: return "plan.lifetime".localized
        default: return product.displayName
        }
    }

    // MARK: - Purchase Button

    private var purchaseButton: some View {
        Button {
            guard let product = selectedProduct else { return }
            Task {
                isPurchasing = true
                let success = await manager.purchase(product)
                isPurchasing = false
                if success { showSuccess = true }
            }
        } label: {
            Group {
                if isPurchasing || manager.isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(purchaseButtonText)
                        .font(.system(size: 17, weight: .bold))
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                LinearGradient(
                    colors: [.orange, .pink],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .orange.opacity(0.4), radius: 10, y: 4)
        }
        .disabled(selectedProduct == nil || isPurchasing)
    }

    private var purchaseButtonText: String {
        guard let product = selectedProduct else { return "paywall.selectPlan".localized }
        if let trial = product.freeTrialDays, trial > 0 {
            return "paywall.startTrial".localized("\(trial)")
        }
        if product.id == ProProduct.lifetime.rawValue {
            return "paywall.buyNow".localized(product.displayPrice)
        }
        return "paywall.subscribeNow".localized(product.displayPrice)
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: 12) {
            Button {
                Task { await manager.restorePurchases() }
            } label: {
                Text("paywall.restore".localized)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.5))
            }

            Text("paywall.terms".localized)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.3))
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Link("paywall.termsOfUse".localized, destination: URL(string: "https://splitcam-legal.vercel.app/terms-of-use.html")!)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                Link("paywall.privacyPolicy".localized, destination: URL(string: "https://splitcam-legal.vercel.app/privacy-policy.html")!)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }
}

// MARK: - ProFeature CaseIterable

extension ProFeature: CaseIterable {
    static var allCases: [ProFeature] = [
        .unlimitedRecording,
        .pipMode,
        .duetMode,
        .telephotoZoom,
        .allAspectRatios,
        .layoutSwitchWhileRecording
    ]
}

#Preview {
    PaywallView(triggeredBy: .pipMode)
}
