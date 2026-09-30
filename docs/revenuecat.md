# RevenueCat and Blitz Pro

Blitz uses RevenueCat 5.91.0 through Swift Package Manager. The app's single
entitlement is `blitz_pro`; it controls train formations, server live delays,
and Live Activities.

## 1. Add the package

The project already contains the package reference:

`https://github.com/RevenueCat/purchases-ios-spm.git`

The app target links both products:

- `RevenueCat`
- `RevenueCatUI`

If the package is added to a new checkout, use **File > Add Package
Dependencies**, enter the URL, choose an up-to-next-major rule beginning at
5.90.0, and add both products to the **blitz** app target.

## 2. Configure RevenueCat

`RevenueCatManager` is configured once from `BlitzAppDelegate` at launch. The
Debug build uses the RevenueCat Test Store key supplied for this project:

```swift
Purchases.configure(withAPIKey: "test_sqTnjVbVWbaxzsjWfQSfgutSTBf")
```

The app does not use the Test Store key in a release build. Set
`REVENUECAT_API_KEY` to the public iOS key from the RevenueCat dashboard in the
Release build environment. Do not commit a production key to source control.

RevenueCat's SDK key is a client-side public key, but the Test Store key should
only be used for local or Test Store builds.

## 3. Configure products and the entitlement

In the RevenueCat dashboard:

1. Create the Apple products with these exact product IDs:
   - Lifetime: `lifetime`
   - Yearly: `yearly`
   - Monthly: `monthly`
2. Create the entitlement `blitz_pro`.
3. Attach all three products to `blitz_pro`.
4. Create an offering named `default`, mark it as **Current**, and add lifetime,
   annual, and monthly packages pointing at those products. RevenueCat's
   standard package identifiers (`$rc_lifetime`, `$rc_annual`, and
   `$rc_monthly`) are fine; the underlying Store product IDs remain the three
   IDs above.
5. Build the paywall in RevenueCat's Paywall Editor and publish it on the
   current offering.

The products must also exist in App Store Connect with matching IDs, pricing,
availability, and the app's In-App Purchase capability. Test Store products
can be used while developing without App Store Connect products.

## 4. Customer info and entitlement checks

`RevenueCatManager` listens to `Purchases.shared.customerInfoStream`, refreshes
offerings and customer info at launch, and persists only a small cached
`blitz_pro` boolean so non-UI services can make a synchronous gate decision.

The authoritative check in SwiftUI is:

```swift
let isPro = customerInfo?.entitlements["blitz_pro"]?.isActive == true
```

The cache is empty for a new install, so premium work is blocked until an
active entitlement is confirmed. A returning subscriber keeps the last-known
active state while RevenueCat refreshes its local CustomerInfo cache; this
avoids interrupting an already entitled user during a temporary network outage.

## 5. Purchases, restore, and errors

The manager exposes async purchase and restore methods:

```swift
if let package = RevenueCatManager.shared.availablePackages.first {
    let info = await RevenueCatManager.shared.purchase(package: package)
    let unlocked = info?.entitlements["blitz_pro"]?.isActive == true
}

let restored = await RevenueCatManager.shared.restorePurchases()
```

The RevenueCatUI paywall handles the normal purchase flow. Purchase and restore
failures are surfaced in the Blitz Pro alert. A cancelled purchase is treated
as a normal unsuccessful result and does not unlock the entitlement.

## 6. Present the paywall

`BlitzProPaywallView` embeds RevenueCat's current offering paywall:

```swift
import RevenueCatUI

struct PaywallHost: View {
    @State private var showingPaywall = false

    var body: some View {
        Button("Unlock Blitz Pro") { showingPaywall = true }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(displayCloseButton: true)
            }
    }
}
```

Blitz presents this view from the formation upsell and Settings. The paywall
reads the current RevenueCat offering, so prices and localized copy stay in the
dashboard rather than in the app binary.

## 7. Customer Center

Settings includes Customer Center for active subscribers:

```swift
.sheet(isPresented: $showingCustomerCenter) {
    CustomerCenterView()
}
```

Enable/configure Customer Center in the RevenueCat dashboard and verify that
the RevenueCat plan used by the app includes it. It provides subscription
management, restore, and support actions without requiring a custom billing
screen.

## 8. Feature gates in Blitz

- **Train formation:** the formation endpoint is not requested for a free user;
  the detail card shows the Blitz Pro upsell.
- **Server live delay:** the local `sbb-rt` proxy is polled only while the
  cached entitlement is active.
- **Live Activity:** automatic and manual activity starts are blocked without
  `blitz_pro`; an activity is ended if a later customer-info update revokes the
  entitlement.

After a purchase or restore, the entitlement notification immediately refreshes
delays and reschedules eligible Live Activities. If access is revoked, the same
path stops the premium work.

## Testing checklist

1. Use a Debug build with the Test Store key.
2. Confirm the offering has a current `default` offering and all three packages.
3. Purchase each package and verify the Settings status changes to **Active**.
4. Close and reopen the app to verify CustomerInfo restores the entitlement.
5. Restore purchases on a fresh install.
6. Turn off/revoke the entitlement in the Test Store and verify server delay
   polling and Live Activities stop.
7. Configure the production iOS key only in the Release environment before
   shipping.
