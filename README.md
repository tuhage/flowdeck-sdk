# Flowdeck SDK

Swift 6 / iOS 16+ SDK for published Flowdeck paywall and onboarding HTML. It loads
verified local files in WKWebView and owns StoreKit 2 purchases and restoration.
macOS 13+ supports building and testing the core only. No A/B assignment is included.

## Install and configure

Add `.package(url: "https://github.com/tuhage/flowdeck-sdk.git", branch: "main")`
and the `Flowdeck` product to your app. ZIPFoundation 0.9.20 is the sole runtime
dependency, used for bounded ZIP extraction.

Create one SDK instance on the main actor and keep it alive for the app lifetime:

```swift
import Flowdeck

@MainActor
func makeFlowdeck() throws -> Flowdeck {
    try Flowdeck(configuration: .init(
        apiKey: "YOUR_APP_SDK_KEY",
        baseURL: URL(string: "https://flowdeck.example.com")!
        // appAccountToken: AppMetricKit.appAccountToken  // optional attribution
    )) { event in
        switch event {
        case .onboardingCompleted(let placementID):
            // Persist YOUR completion flag here, only after explicit completion.
            print("Completed", placementID)
        case .entitlementsChanged(let entitlements):
            // Map your known product IDs to your application's premium features.
            print(entitlements)
        case .bridge(let placementID, let response):
            print(placementID, response.method, response.result as Any, response.error as Any)
        case .failed(let placementID, let message):
            print(placementID, message)
        default: break
        }
    }
}
```

`baseURL` is an HTTPS origin, without `/v1` or a path prefix. HTTP is accepted only
for loopback development. Requests use `Authorization: Bearer <apiKey>`; redirects
are rejected. The key is never injected into HTML. Do not put an admin token here.

## Present from SwiftUI or UIKit

```swift
// In your SwiftUI View; sdk is the app's retained Flowdeck instance:
.sheet(isPresented: $showPaywall) {
    FlowdeckView(flowdeck: sdk, placementID: "paywall")
}

// UIKit, on the main actor:
Task { @MainActor in
    do {
        try await sdk.present(placementID: "onboarding", from: viewController)
    } catch {
        // Show a retry action; there is no usable cached/bundled package.
    }
}

// For custom UIKit presentation:
let controller = try await sdk.makeViewController(placementID: "paywall")
controller.modalPresentationStyle = .fullScreen
viewController.present(controller, animated: true)

// Optional prefetch / entitlement query:
let placements = try await sdk.refreshPlacements()
let content = try await sdk.prepare(placementID: "paywall")
let entitlements = await sdk.currentEntitlements()
```

SwiftUI supplies loading, failure and retry states. Local WebView load failures
also have native Retry and Close buttons. `close()` dismisses a UIKit modal or a
SwiftUI sheet/fullScreenCover. It never marks onboarding complete. The SDK does
not persist onboarding state, unlock features, schedule trial reminders, or bypass
your app's launch/configuration gate. Keep the app's required Remote Config fetch
and retry gate before deciding whether to present onboarding or home.

`onEvent` runs on the main actor: `loaded`, `bridge`, authored `event`,
`onboardingCompleted`, `closed`, `entitlementsChanged`, and `failed`. A successful
`prepare` only resolves files; `loaded` means WKWebView finished loading them.
StoreKit `Transaction.updates` is observed while the SDK lives; verified updates
are finished and active entitlements are delivered, including delayed approvals
and revocations. Keep only one Flowdeck instance per app StoreKit lifecycle.

## ETag, cache, bundled fallback

The contract is `flowdeck-server/docs/API.md`: `GET /v1/sdk/placements` returns
`app_id` and placements with `id`, `kind`, `version`, `hash`, `size`, relative `url`,
`product_ids`, `published_at`, and `parameters` (a string/number/boolean map).
Missing `parameters` is treated as an empty map for older servers and disk caches.
Subsequent requests send the persisted ETag in
`If-None-Match`; a 304 reuses the manifest. Simultaneous manifest requests share
one in-flight refresh. `refreshPlacements()` surfaces network errors explicitly;
`prepare()` applies the fallback policy below.

1. Fetch/revalidate the manifest; reuse a matching disk ZIP or download the new ZIP.
2. On network/package failure use the last verified usable package for that placement.
3. If there is no usable disk package, use the configured bundled ZIP.
4. If none works, throw. An explicit placement removal in the last known manifest
   is authoritative, including offline; it does not revive a retired screen.

`FlowdeckContent.source` is `network`, `cache`, or `bundled`; `fallbackReason`
explains a failed refresh/download. Cache namespaces include both origin and a
hash of the SDK key; rotating the key starts a fresh namespace. OS cache eviction
is recoverable via network or bundle. The SDK doesn't implement a cache quota or
expiration; immutable package ZIPs remain until the OS/app removes the cache.

Every use checks SHA-256 against the manifest/bundled descriptor. ZIP extraction
rejects path traversal, symlinks, duplicate/case-colliding names and non-files;
requires root `index.html`; checks CRC; and limits ZIPs to 10 MiB, extracted bytes
to 30 MiB, and entries to 500. Files are staged before use; corrupted extracted
assets are repaired from the verified ZIP. Authenticated package URLs must match
`/v1/sdk/packages/{hash}`. Local read access and navigation stay inside that
package. Subframes cannot invoke the native bridge. Use relative bundled assets;
remote top-level pages never receive a bridge.

To add an app-bundled fallback, add a normalized ZIP as an app resource and record
its SHA-256 (`shasum -a 256 fallback.zip`). The ZIP contains regular files, not
explicit directory entries, with `index.html` at the root:

```swift
let fallback = FlowdeckFallbackPackage(
    placementID: "paywall", kind: .paywall,
    zipURL: Bundle.main.url(forResource: "fallback", withExtension: "zip")!,
    sha256: "YOUR_64_CHARACTER_LOWERCASE_SHA256",
    productIDs: ["your.approved.weekly", "your.approved.weekly.payg"]
)
let configuration = FlowdeckConfiguration(
    apiKey: "YOUR_APP_SDK_KEY",
    baseURL: URL(string: "https://flowdeck.example.com")!,
    fallbackPackages: [fallback]
)
```

## Placement parameters

Set parameters on each placement in Flowdeck, for example `ask_review` as a boolean
on `onboarding`. Parameters belong to the placement; updates require no new HTML
package or version. The next manifest refresh picks them up, even when the ZIP is
already cached. They persist with the manifest and last-ready placement for offline use.

Swift can read typed values from `Placement` returned by `refreshPlacements()` or
from prepared `FlowdeckContent`:

```swift
let content = try await sdk.prepare(placementID: "onboarding")
let shouldAskReview = content.parameters.bool("ask_review", default: false)
let headline = content.parameters.string("headline", default: "Welcome")
let delay = content.parameters.number("review_delay", default: 0) // Double
// Use shouldAskReview to gate your app's review request at the intended step.

// Read placement settings without downloading an HTML package:
let placements = try await sdk.refreshPlacements()
let onboarding = placements.first { $0.id == "onboarding" }
let askReview = onboarding?.parameters.bool("ask_review", default: false) ?? false
```

Accessors use your default for missing keys or mismatched types; values are never
coerced. `false`, `0`, and an empty string remain valid values. A presentation keeps
the parameters selected when its content was prepared; it does not update live.
Package fallback uses the latest known manifest's parameters, even for an older or
bundled ZIP. If the manifest is unavailable, the last-ready descriptor supplies its
saved parameters; a bundle alone has an empty map.

HTML can read the frozen `window.flowdeck.parameters` object synchronously, including
from the first inline script. `getParameters()` returns the same presentation values
through the native Promise bridge and emits the usual `flowdeck:result` event:

```js
const { ask_review = false } = window.flowdeck.parameters;
// At the intended onboarding step; requesting does not guarantee a visible prompt.
if (ask_review === true) {
  try { await window.flowdeck.requestReview(); } catch (error) { /* continue onboarding */ }
}
const parameters = await window.flowdeck.getParameters();
```

## HTML bridge reference

`window.flowdeck` is injected at document start, in the local main frame. Every
method returns a Promise. Await it; catch errors. Native failures reject with an
`Error` carrying `code: "native_error"`. Invalid/untrusted raw messages reject
at the WebKit transport boundary. Purchase cancellation and pending approval
**resolve** with a status; they do not grant access.

| Method | Resolved value / effect |
|---|---|
| `getParameters()` | This presentation's placement parameters as a string/number/boolean object. No network refresh. |
| `getProducts()` | Array of available StoreKit products from this placement's `product_ids`, in manifest order. Unavailable IDs are omitted. |
| `purchase(productId)` | `{status: "purchased" \| "cancelled" \| "pending", transaction?, entitlements: [...]}`. Rejects IDs outside this placement. Verifies and finishes successful transactions. |
| `restore()` | Calls `AppStore.sync()`, then returns active verified entitlements. May show Apple's sign-in UI in a real app; invoke only from the user's Restore button. |
| `getEntitlements()` | Active, verified `Transaction.currentEntitlements`, excluding revoked, expired and upgraded transactions. |
| `requestReview()` | `{requested: true}` after requesting in the presentation's active scene. Apple decides whether to show anything; this is not a rating/submission confirmation. |
| `close()` | `null`; dismisses the presentation, reports `closed`. |
| `openURL(url)` | `{opened: boolean}` via the system, for HTTP/HTTPS URLs without credentials. Other schemes are rejected. |
| `event(name, props = {})` | `null`; delivers an application callback, no analytics network upload. Props are JSON values. |
| `completeOnboarding()` | `null`; signals explicit completion to the app. Accepted only for `kind: "onboarding"`; does not dismiss or persist a flag. |

Product objects contain `id`, `displayName`, `description`, `displayPrice`,
`price` (decimal string), `currencyCode`, StoreKit `type`, optional
`subscriptionPeriod: {value, unit}`, optional `introductoryOffer`, and
`isEligibleForIntroOffer` fetched from StoreKit for this customer. `unit` is `day`,
`week`, `month`, or `year` (future unknown units use `unknown`).

An intro offer contains `displayPrice`, `price`, `paymentMode` (`freeTrial`,
`payAsYouGo`, `payUpFront`, or `unknown`), `period: {value, unit}`, and
`periodCount`. Only display an offer as available when `isEligibleForIntroOffer`
is true. Period count applies to the offer's period, not to a hard-coded week.
Render localized `displayPrice` directly; localize period labels in your HTML.
Selection must drive the purchased product ID, CTA, disclosure and trial reminder
UI. The SDK never invents prices, offers or eligibility.

Entitlements/transaction objects contain `productID`, `transactionID`,
`originalTransactionID` (IDs are strings for JavaScript precision), and optional
`expirationDate` as an ISO 8601 string. Consumables aren't durable entitlements;
apps that sell them must deliver the purchased item using the purchase result.

For every parsed call, `flowdeck:result` is dispatched before its Promise settles:

```js
window.addEventListener('flowdeck:result', ({detail}) => {
  // {id, method, result?} or {id, method, error: {code, message}}
});
window.addEventListener('flowdeck:entitlements', ({detail}) => {
  // Updated entitlement array while the presentation is visible.
});
const products = await window.flowdeck.getProducts();
try {
  const result = await window.flowdeck.purchase(products[0].id);
  if (result.status === 'purchased') await window.flowdeck.close();
} catch (error) { /* show an actionable error */ }
```

The internal message format is `{id: string, method: string, params: object}`,
posted to `window.webkit.messageHandlers.flowdeck.postMessage(...)`. IDs must be
1–128 UTF-8 bytes. Messages are limited to 64 KiB. Methods without arguments use
`params: {}`; purchase uses `{productId}`, openURL uses `{url}`, event uses
`{name, props}`. Event names are 1–128 UTF-8 bytes. Prefer `window.flowdeck` over
raw messages; the wrapper handles native replies and dispatches result events.
Do not forward bridge access to iframes or untrusted scripts. Published HTML is
privileged app content and should be reviewed before publication.

## Examples and verification

- [Paywall HTML](Examples/Paywall/index.html): selectable trial/PAYG products,
  StoreKit prices/terms, cancellation/pending/error UI, restore and external links.
  Publish it with your approved IDs and replace the example legal URLs.
- [Onboarding HTML](Examples/Onboarding/index.html): review request and explicit
  completion before close. Native actions require the SDK; the dashboard preview cannot execute them.
- `Tests/FlowdeckTests/Fixtures/Products.storekit`: one group, six **local test**
  products. Three-day trials: weekly $6.99, monthly $9.99, yearly $39.99. PAYG:
  $0.99 → $9.99/week, $3.99 → $14.99/month, $29.99 → $49.99/year, each intro
  exactly one billing period. This does not provision or alter a live catalog.

```bash
# All build products and logs can stay under your task temporary directory.
export TMPDIR="/your/task/tmp/"
mkdir -p "$TMPDIR"
swift build --scratch-path "$TMPDIR/swift-build"
swift test --scratch-path "$TMPDIR/swift-build" --enable-swift-testing
xcodebuild -scheme Flowdeck -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$TMPDIR/DerivedData" \
  -clonedSourcePackagesDirPath "$TMPDIR/SourcePackages" CODE_SIGNING_ALLOWED=NO build

# Local StoreKit + WKWebView tests require an application host, not the bare
# Swift Package xctest tool. Requires XcodeGen and an existing simulator UDID.
Scripts/test-ios.sh YOUR_SIMULATOR_UDID
```

The host project is generated in TMPDIR. Tests cover ETag reuse/restarts,
offline/cache/bundle selection, failed updates, archive corruption/traversal,
bridge parsing/scope, real local WKWebView Promise callbacks and navigation,
and StoreKitTest purchases, restored entitlements, intro eligibility, pending
approval, cancellation, revocation, expiry and restore failure recovery.
No Apple account, provisioning, signing, upload or submission is required.

### Known local test runtime limitation

On the available iOS 26.5 (23F77) runtime, StoreKitTest fails to save its local
configuration with `SKInternalErrorDomain Code=3` and returns no products. The
purchase/restore integration test deliberately fails in that case; it never
switches to an Apple account or treats the empty catalog as a pass. Apple tracks
this runtime issue in [the developer forum](https://developer.apple.com/forums/thread/826971).
Rerun the full suite on a runtime where StoreKitTest configuration succeeds.
Core tests and WKWebView tests can be checked independently with
`Scripts/test-ios.sh UDID -skip-testing:FlowdeckHarnessTests/StoreKitIntegrationTests`.
