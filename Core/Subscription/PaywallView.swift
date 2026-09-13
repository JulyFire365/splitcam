import SwiftUI
import StoreKit

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var manager = SubscriptionManager.shared
    var triggeredBy: ProFeature?
    @State private var selectedProductID: String?
    @State private var trialEligibility: [String: Bool] = [:]
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var showSuccess = false
    @State private var showRestoreResult = false

    private let paper = Color(red: 0.97, green: 0.965, blue: 0.95)
    private let ink = Color(red: 0.10, green: 0.10, blue: 0.15)
    private let accent = Color(red: 0.37, green: 0.30, blue: 0.88)
    private var selectedProduct: Product? { manager.products.first { $0.id == selectedProductID } }
    private var busy: Bool { isPurchasing || isRestoring || manager.isLoading }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ProHeroView()
                        .frame(height: min(240, max(170, geometry.size.height * 0.28)))
                        .clipShape(HeroCurve())
                    VStack(spacing: 20) {
                        header
                        features
                        pricing
                        Text("paywall.terms".localized)
                            .font(.caption2)
                            .foregroundStyle(ink.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
                    // A large-text dock can fill a small screen by itself.
                    // Keep every plan and disclosure reachable in one scroll.
                    if dynamicTypeSize.isAccessibilitySize { purchaseDock }
                }
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("paywall.content")
            .background(paper.ignoresSafeArea())
            .ignoresSafeArea(.container, edges: .top)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !dynamicTypeSize.isAccessibilitySize { purchaseDock }
            }
            .overlay(alignment: .topTrailing) { closeButton }
        }
        .preferredColorScheme(.light)
        .statusBarHidden(true)
        .task { if manager.products.isEmpty { await manager.loadProducts() } }
        .task(id: manager.products.map(\.id)) {
            selectDefaultProduct()
            for product in manager.products {
                if let subscription = product.subscription {
                    trialEligibility[product.id] = await subscription.isEligibleForIntroOffer
                }
            }
        }
        .onChange(of: manager.isPro) { isPro in
            if isPro && !isPurchasing && !isRestoring { dismiss() }
        }
        .alert("purchase.success.title".localized, isPresented: $showSuccess) {
            Button("ok".localized) { dismiss() }
        } message: { Text("purchase.success.message".localized) }
        .alert("paywall.restore".localized, isPresented: $showRestoreResult) {
            Button("ok".localized) { if manager.isPro { dismiss() } }
        } message: {
            Text(manager.isPro ? "purchase.restore.success".localized : "purchase.restore.empty".localized)
        }
        .alert("error".localized, isPresented: Binding(
            get: { manager.errorMessage != nil },
            set: { if !$0 { manager.errorMessage = nil } }
        )) {
            Button("ok".localized) { manager.errorMessage = nil }
        } message: { Text(manager.errorMessage ?? "") }
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 32, height: 32)
                .background(.white.opacity(0.12), in: Circle())
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("paywall.close".localized)
        .padding(10)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("paywall.headline".localized)
                .font(.system(.largeTitle, design: .serif, weight: .semibold))
                .tracking(-0.8)
                .foregroundStyle(ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("paywall.subtitle".localized)
                .font(.subheadline)
                .foregroundStyle(ink.opacity(0.6))
                .multilineTextAlignment(.center)
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(ProFeature.allCases, id: \.self) { feature in
                HStack(spacing: 12) {
                    Image(systemName: feature.icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(accent).frame(width: 26)
                    Text("paywall.benefit.\(feature.rawValue)".localized)
                        .font(.subheadline.weight(feature == triggeredBy ? .semibold : .regular))
                        .foregroundStyle(ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(accent)
                }
            }
        }
    }

    private var pricing: some View {
        VStack(spacing: 12) {
            if manager.products.isEmpty {
                if manager.isLoading {
                    ProgressView().tint(accent).frame(maxWidth: .infinity).padding(24)
                } else {
                    VStack(spacing: 10) {
                        Text("paywall.unavailable".localized)
                            .font(.subheadline).foregroundStyle(ink.opacity(0.6))
                        Button("paywall.retry".localized) {
                            Task { await manager.loadProducts() }
                        }.foregroundStyle(accent)
                    }.frame(maxWidth: .infinity).padding(16)
                }
            } else {
                let subscriptions = [ProProduct.monthly, .yearly].compactMap { plan in
                    manager.products.first { $0.id == plan.rawValue }
                }
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 10))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
                layout { ForEach(subscriptions) { product in planCard(product) } }
                if let lifetime = manager.products.first(where: { $0.id == ProProduct.lifetime.rawValue }) {
                    lifetimeCard(lifetime)
                }
            }
        }.disabled(busy)
    }

    private func planCard(_ product: Product) -> some View {
        let selected = selectedProductID == product.id
        return Button { selectedProductID = product.id } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text(planTitle(product)).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 2)
                    selectionMark(selected)
                }
                Text(product.displayPrice)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.65)
                Text(product.id == ProProduct.yearly.rawValue ? "paywall.billedYearly".localized : "paywall.billedMonthly".localized)
                    .font(.caption).foregroundStyle(ink.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                if let savings = annualSavings, product.id == ProProduct.yearly.rawValue {
                    Text("paywall.savings".localized("\(savings)"))
                        .font(.caption2.weight(.bold)).foregroundStyle(accent)
                } else {
                    Text("paywall.flexible".localized)
                        .font(.caption2).foregroundStyle(ink.opacity(0.6))
                }
            }
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(selected ? accent.opacity(0.07) : .white.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(selected ? accent : ink.opacity(0.12), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func lifetimeCard(_ product: Product) -> some View {
        let selected = selectedProductID == product.id
        return Button { selectedProductID = product.id } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    selectionMark(selected)
                    Text("plan.lifetime".localized).font(.subheadline.weight(.semibold))
                    if !dynamicTypeSize.isAccessibilitySize {
                        Text("paywall.once".localized).font(.caption).foregroundStyle(ink.opacity(0.6))
                        Spacer(minLength: 0)
                        Text(product.displayPrice).font(.subheadline.weight(.bold))
                    }
                }
                if dynamicTypeSize.isAccessibilitySize {
                    Text(product.displayPrice).font(.title2.weight(.bold))
                    Text("paywall.once".localized).font(.caption).foregroundStyle(ink.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(ink).padding(14)
            .background(selected ? accent.opacity(0.07) : .white.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? accent : ink.opacity(0.12), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func selectionMark(_ selected: Bool) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(selected ? accent : ink.opacity(0.2)).accessibilityHidden(true)
    }

    private var purchaseDock: some View {
        VStack(spacing: 10) {
            Button {
                guard let product = selectedProduct, !busy else { return }
                Task {
                    isPurchasing = true
                    let success = await manager.purchase(product)
                    isPurchasing = false
                    if success { showSuccess = true }
                }
            } label: {
                HStack {
                    Spacer(minLength: 0)
                    if busy { ProgressView().tint(.white) } else {
                        Text(purchaseTitle)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "arrow.right").font(.subheadline.weight(.semibold))
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.white).frame(minHeight: 54).padding(.horizontal, 12)
                .background(LinearGradient(colors: [accent, Color(red: 0.22, green: 0.45, blue: 0.93)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 17))
                .opacity(selectedProduct == nil ? 0.45 : 1)
            }
            .disabled(selectedProduct == nil || busy)
            .accessibilityIdentifier("paywall.purchase")
            if let product = selectedProduct {
                Text(billingSummary(product))
                    .font(.caption).foregroundStyle(ink.opacity(0.65))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("paywall.billingSummary")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { legalLinks }
                VStack(spacing: 8) { legalLinks }
            }
            .font(.caption).foregroundStyle(ink.opacity(0.65))
        }
        .frame(maxWidth: 560).padding(.horizontal, 24)
        .padding(.top, 14).padding(.bottom, 8).frame(maxWidth: .infinity)
        .background {
            paper.ignoresSafeArea(.container, edges: .bottom)
                .overlay(alignment: .top) {
                    // A top-only shadow fades into the scroll area without
                    // darkening the purchase controls or intercepting gestures.
                    LinearGradient(stops: [
                        .init(color: ink.opacity(0), location: 0),
                        .init(color: ink.opacity(0.025), location: 0.4),
                        .init(color: ink.opacity(0.09), location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                    .frame(height: 24)
                    .offset(y: -24)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        }
    }

    @ViewBuilder private var legalLinks: some View {
        Button("paywall.restore".localized) {
            guard !busy else { return }
            Task {
                isRestoring = true
                await manager.restorePurchases()
                isRestoring = false
                if manager.errorMessage == nil { showRestoreResult = true }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .disabled(busy)
        Link("paywall.termsOfUse".localized, destination: URL(string: "https://splitcam-legal.vercel.app/terms-of-use.html")!)
            .fixedSize(horizontal: false, vertical: true)
        Link("paywall.privacyPolicy".localized, destination: URL(string: "https://splitcam-legal.vercel.app/privacy-policy.html")!)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func selectDefaultProduct() {
        guard selectedProduct == nil else { return }
        selectedProductID = manager.products.first { $0.id == ProProduct.yearly.rawValue }?.id ?? manager.products.first?.id
    }

    private func eligibleTrialDays(_ product: Product) -> Int? {
#if DEBUG && targetEnvironment(simulator)
        // Exercise the returning-customer UI without buying a product or
        // changing StoreKit eligibility. This override is absent from Release.
        if ScreenshotSupport.screen == "paywall",
           ProcessInfo.processInfo.arguments.contains("-preview-no-trial") { return nil }
#endif
        guard trialEligibility[product.id] == true else { return nil }
        return product.freeTrialDays
    }

    private var purchaseTitle: String {
        guard let product = selectedProduct else { return "paywall.selectPlan".localized }
        // Name the commitment, not the introductory offer. Trial duration,
        // subsequent price and renewal terms live together in billingSummary.
        switch product.id {
        case ProProduct.yearly.rawValue: return "paywall.subscribeYearly".localized
        case ProProduct.monthly.rawValue: return "paywall.subscribeMonthly".localized
        case ProProduct.lifetime.rawValue: return "paywall.buyLifetime".localized
        default: return "paywall.unlock".localized
        }
    }

    private func billingSummary(_ product: Product) -> String {
        if product.id == ProProduct.lifetime.rawValue { return "paywall.billing.once".localized(product.displayPrice) }
        let period = product.periodDescription ?? ""
        if let days = eligibleTrialDays(product) {
            return "paywall.billing.trial".localized("\(days)", product.displayPrice, period)
        }
        return "paywall.billing.recurring".localized(product.displayPrice, period)
    }

    private func planTitle(_ product: Product) -> String {
        product.id == ProProduct.yearly.rawValue ? "plan.yearly".localized : "plan.monthly".localized
    }

    /// Derived from this storefront's actual prices, never a fixed marketing claim.
    private var annualSavings: Int? {
        guard let monthly = manager.products.first(where: { $0.id == ProProduct.monthly.rawValue }),
              let yearly = manager.products.first(where: { $0.id == ProProduct.yearly.rawValue }),
              monthly.priceFormatStyle.currencyCode == yearly.priceFormatStyle.currencyCode,
              monthly.price > 0 else { return nil }
        let fullYear = NSDecimalNumber(decimal: monthly.price).doubleValue * 12
        let percent = Int(((1 - NSDecimalNumber(decimal: yearly.price).doubleValue / fullYear) * 100).rounded(.down))
        return percent > 0 ? percent : nil
    }
}

private struct HeroCurve: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: rect.maxX, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 24))
        path.addQuadCurve(to: CGPoint(x: 0, y: rect.maxY - 24), control: CGPoint(x: rect.midX, y: rect.maxY + 24))
        path.closeSubpath()
        return path
    }
}

extension ProFeature: CaseIterable {
    static var allCases: [ProFeature] { [.pipMode, .duetMode, .appIcons] }
}

#Preview { PaywallView(triggeredBy: .pipMode) }
