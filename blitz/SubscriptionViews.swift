import SwiftUI
import RevenueCatUI

struct BlitzProUpsellCard: View {
    let feature: String

    @ObservedObject private var subscriptions = RevenueCatManager.shared
    @State private var isShowingPaywall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Blitz Pro", systemImage: "crown.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            Text("Unlock \(feature)")
                .font(.title3.weight(.semibold))

            Text("Blitz Pro includes live train information, server delay updates, and Live Activities.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("See Blitz Pro plans") {
                isShowingPaywall = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        }
        .sheet(isPresented: $isShowingPaywall) {
            BlitzProPaywallView()
        }
        .onChange(of: subscriptions.isPro) { _, active in
            if active { isShowingPaywall = false }
        }
    }
}

struct BlitzProPaywallView: View {
    @ObservedObject private var subscriptions = RevenueCatManager.shared

    var body: some View {
        PaywallView(displayCloseButton: true)
            .onPurchaseCompleted { _ in
                Task { await subscriptions.refreshCustomerInfo() }
            }
            .onRestoreCompleted { _ in
                Task { await subscriptions.refreshCustomerInfo() }
            }
            .onPurchaseFailure { error in
                subscriptions.lastErrorForPresentation = error.localizedDescription
            }
            .onRestoreFailure { error in
                subscriptions.lastErrorForPresentation = error.localizedDescription
            }
            .alert("Blitz Pro", isPresented: Binding(
                get: { subscriptions.lastErrorForPresentation != nil },
                set: { if !$0 { subscriptions.lastErrorForPresentation = nil } }
            )) {
                Button("OK", role: .cancel) { subscriptions.lastErrorForPresentation = nil }
            } message: {
                Text(subscriptions.lastErrorForPresentation ?? "")
            }
    }
}

struct SubscriptionSettingsSection: View {
    @ObservedObject private var subscriptions = RevenueCatManager.shared
    @State private var isShowingPaywall = false
    @State private var isShowingCustomerCenter = false

    var body: some View {
        Section {
            HStack {
                Label("Blitz Pro", systemImage: subscriptions.isPro ? "crown.fill" : "lock.fill")
                Spacer()
                Text(subscriptions.isPro ? "Active" : "Not active")
                    .foregroundStyle(subscriptions.isPro ? .green : .secondary)
            }

            if let product = subscriptions.activeProductIdentifier {
                Text("Plan: \(product)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(subscriptions.isPro ? "View Blitz Pro plans" : "Unlock Blitz Pro") {
                isShowingPaywall = true
            }

            Button("Restore Purchases") {
                Task { await subscriptions.restorePurchases() }
            }

            Button("Manage Subscription") {
                isShowingCustomerCenter = true
            }
        } header: {
            Text("Subscription")
        } footer: {
            Text("Blitz Pro unlocks train formation, server live delays, and Live Activities.")
        }
        .sheet(isPresented: $isShowingPaywall) {
            BlitzProPaywallView()
        }
        .sheet(isPresented: $isShowingCustomerCenter) {
            CustomerCenterView()
        }
        .alert("Blitz Pro", isPresented: Binding(
            get: { subscriptions.lastError != nil },
            set: { if !$0 { subscriptions.clearError() } }
        )) {
            Button("OK", role: .cancel) { subscriptions.clearError() }
        } message: {
            Text(subscriptions.lastError ?? "")
        }
    }
}
