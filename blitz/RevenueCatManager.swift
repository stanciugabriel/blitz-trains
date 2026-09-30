import Foundation
import Combine
import RevenueCat

/// The single subscription boundary used by the app and its premium services.
/// RevenueCat's public SDK key is safe to ship in the client. Keep the Test
/// Store key in Debug builds only; supply the production Apple key through the
/// release build environment before shipping.
@MainActor
final class RevenueCatManager: ObservableObject {
    static let shared = RevenueCatManager()

    static let entitlementID = "blitz_pro"
    static let lifetimeProductID = "lifetime"
    static let yearlyProductID = "yearly"
    static let monthlyProductID = "monthly"
    static let productIDs = [lifetimeProductID, yearlyProductID, monthlyProductID]

    private static let cachedEntitlementKey = "blitz.revenuecat.blitzProActive"

    @Published private(set) var customerInfo: CustomerInfo?
    @Published private(set) var offerings: Offerings?
    @Published private(set) var isConfigured = false
    @Published private(set) var lastError: String?
    @Published var lastErrorForPresentation: String? = nil

    private var customerInfoTask: Task<Void, Never>?

    private init() {}

    /// Services that are not SwiftUI views can use this synchronous cached
    /// value without crossing the MainActor. It is updated after every
    /// CustomerInfo refresh or purchase.
    nonisolated static var cachedIsPro: Bool {
        UserDefaults.standard.bool(forKey: cachedEntitlementKey)
    }

    var isPro: Bool {
        customerInfo?.entitlements[Self.entitlementID]?.isActive == true
    }

    var activeProductIdentifier: String? {
        customerInfo?.entitlements[Self.entitlementID]?.productIdentifier
    }

    var availablePackages: [Package] {
        offerings?.current?.availablePackages ?? []
    }

    func configure() {
        guard !isConfigured else { return }
        guard let apiKey = Self.apiKey, !apiKey.isEmpty else {
            lastError = "RevenueCat is not configured for this build."
            return
        }

#if DEBUG
        Purchases.logLevel = .debug
#else
        Purchases.logLevel = .warn
#endif
        Purchases.configure(withAPIKey: apiKey)
        isConfigured = true

        customerInfoTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()
            for await info in Purchases.shared.customerInfoStream {
                self.apply(info)
            }
        }
    }

    func refresh() async {
        guard isConfigured else { return }
        do {
            async let info = Purchases.shared.customerInfo()
            async let currentOfferings = Purchases.shared.offerings()
            let (customerInfo, offerings) = try await (info, currentOfferings)
            apply(customerInfo)
            self.offerings = offerings
            lastError = nil
        } catch {
            lastError = userFacingMessage(for: error)
        }
    }

    func refreshCustomerInfo() async {
        guard isConfigured else { return }
        do {
            apply(try await Purchases.shared.customerInfo())
            lastError = nil
        } catch {
            lastError = userFacingMessage(for: error)
        }
    }

    @discardableResult
    func purchase(package: Package) async -> CustomerInfo? {
        do {
            let result = try await Purchases.shared.purchase(package: package)
            apply(result.customerInfo)
            lastError = nil
            return result.customerInfo
        } catch {
            lastError = userFacingMessage(for: error)
            return nil
        }
    }

    @discardableResult
    func purchase(productIdentifier: String) async -> CustomerInfo? {
        guard let package = availablePackages.first(where: {
            $0.storeProduct.productIdentifier == productIdentifier
        }) else {
            lastError = "This subscription is not available right now."
            return nil
        }
        return await purchase(package: package)
    }

    @discardableResult
    func restorePurchases() async -> CustomerInfo? {
        do {
            let info = try await Purchases.shared.restorePurchases()
            apply(info)
            lastError = nil
            return info
        } catch {
            lastError = userFacingMessage(for: error)
            return nil
        }
    }

    func clearError() {
        lastError = nil
    }

    private func apply(_ info: CustomerInfo) {
        customerInfo = info
        let active = info.entitlements[Self.entitlementID]?.isActive == true
        UserDefaults.standard.set(active, forKey: Self.cachedEntitlementKey)
        NotificationCenter.default.post(
            name: .revenueCatEntitlementChanged,
            object: active
        )
    }

    private static var apiKey: String? {
#if DEBUG
        // RevenueCat Test Store key supplied for local development.
        return "test_sqTnjVbVWbaxzsjWfQSfgutSTBf"
#else
        // Set REVENUECAT_API_KEY in the Release Info.plist or build settings.
        guard let value = Bundle.main.object(forInfoDictionaryKey: "REVENUECAT_API_KEY") as? String,
              !value.isEmpty,
              !value.hasPrefix("$(") else {
            return nil
        }
        return value
#endif
    }

    private func userFacingMessage(for error: Error) -> String {
        if let purchasesError = error as? RevenueCat.ErrorCode {
            return purchasesError.localizedDescription
        }
        return error.localizedDescription
    }
}

extension Notification.Name {
    static let revenueCatEntitlementChanged = Notification.Name("revenueCatEntitlementChanged")
}
