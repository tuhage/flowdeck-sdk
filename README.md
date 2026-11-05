# Flowdeck SDK

Swift 6 / iOS 16+ SDK for published Flowdeck paywall and onboarding HTML. It loads
the placement’s live HTTPS page in WKWebView and owns StoreKit 2 purchases and restoration.
macOS 13+ supports building and testing the core only. No A/B assignment is included.

## Install and configure

Add `.package(url: "https://github.com/tuhage/flowdeck-sdk.git", branch: "main")`
and the `Flowdeck` product to your app. ZIPFoundation 0.9.20 is the sole runtime
dependency, retained only for the existing opt-in bundled fallback.

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
for loopback development. Native API requests use `Authorization: Bearer <apiKey>`; redirects
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
        // Show a retry action; preparation failed and no usable bundled fallback was available.
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

SwiftUI supplies loading, failure and retry states. WebView load failures
also have native Retry and Close buttons. `close()` dismisses a UIKit modal or a
SwiftUI sheet/fullScreenCover. It never marks onboarding complete. The SDK does
not persist onboarding state, unlock features, schedule trial reminders, or bypass
your app's launch/configuration gate. Keep the app's required Remote Config fetch
and retry gate before deciding whether to present onboarding or home.

`onEvent` runs on the main actor: `loaded`, `bridge`, authored `event`,
`onboardingCompleted`, `closed`, `entitlementsChanged`, and `failed`. A successful
`prepare` resolves metadata and the live URL; `loaded` means WKWebView finished loading the page.
StoreKit `Transaction.updates` is observed while the SDK lives; verified updates
are finished and active entitlements are delivered, including delayed approvals
and revocations. Keep only one Flowdeck instance per app StoreKit lifecycle.

## Live pages and migration

The authenticated manifest supplies app ID, placement metadata, product IDs and
parameters. The SDK then opens `baseURL/live/{app_id}/{placement}/` directly in
WKWebView, without an Authorization header. A custom domain can be used as
`baseURL` if it serves the app's SDK API and live routes. Publish and rollback
take effect on the next page load. Manifest ETags persist; HTML and remote ZIPs
are no longer downloaded, extracted or cached by the SDK.

Update the SDK dependency and ship a new app build. Existing presentation and
JavaScript APIs remain unchanged. `FlowdeckContent.indexURL` is now an HTTPS URL
for network content, not a local file; `prepare()` does not prefetch a page.
Old ZIP cache files are ignored. Apps must handle preparation failures and retain
their native retry/fallback flow.

Only the exact placement entry path on the configured origin receives the bridge.
Other paths, origins, subframe navigations and HTTP redirects are blocked. Use
relative assets and bridge `openURL()` for external links. Native message handling
also checks the main frame's URL. The API key never enters the page or WebView.
The server's sandbox CSP intentionally gives the page an opaque JavaScript origin;
trust is based on the validated document URL, not a relaxed wildcard origin check.

### Fallback live origins

`fallbackOrigins` is an optional, explicit list of extra origins that serve the
same SDK API and live routes (for example a regional proxy as `baseURL` and the
main Flowdeck host as a fallback). Each entry follows the `baseURL` rules; wildcards,
paths and duplicates are rejected. Without it, behavior is unchanged.

```swift
let sdk = try Flowdeck(configuration: .init(
    apiKey: "YOUR_APP_SDK_KEY",
    baseURL: URL(string: "https://flowdeck.regional-proxy.example")!,
    fallbackOrigins: [URL(string: "https://api.useflowdeck.com")!]
))
```

The manifest is requested from `baseURL`, then from each fallback origin in order,
after a connection error, timeout or HTTP error; these origins receive the API key.
The live page starts on the origin that served the manifest. If its main frame
fails (connection error, timeout or HTTP error), the same `/live/{app_id}/{placement}/`
path is opened on the next fallback origin. Failure order:
primary origin → fallback origins in order → bundled page → Retry/Close.
Placement kind, product IDs and parameters always come from the manifest.
Each attempt uses a fresh WebView; the bridge runs only in the main frame of the
exact entry path on the origin currently loaded. Redirects, including between
configured origins, are blocked and show Retry/Close without trying another origin.
`fallbackReason` records the previous load error.

### Offline and load-error fallback

Configure an app-bundled ZIP for each placement that needs an offline page.
If the manifest cannot be fetched, or the live main frame fails to load because
of connectivity, timeout, or an HTTP error (on every configured origin), the SDK verifies and shows that
placement's bundled page. Without a usable bundle, native Retry/Close remains.
A bundle that itself fails to load shows Retry/Close; fallback never loops.
Blocked navigation and redirects do not trigger fallback.

Add the ZIP to the app target's resources (Copy Bundle Resources). It must contain
`index.html` at its root and relative assets as regular files, without explicit
directory entries. Record its SHA-256 using `shasum -a 256 fallback.zip`:

```swift
let fallback = FlowdeckFallbackPackage(
    placementID: "onboarding",
    kind: .onboarding,
    zipURL: Bundle.main.url(forResource: "fallback", withExtension: "zip")!,
    sha256: "YOUR_64_CHARACTER_LOWERCASE_SHA256",
    productIDs: [] // For paywalls, list the bundle's approved StoreKit product IDs.
)
let sdk = try Flowdeck(configuration: .init(
    apiKey: "YOUR_APP_SDK_KEY",
    baseURL: URL(string: "https://flowdeck.example.com")!,
    fallbackPackages: [fallback]
))
```

ZIPFoundation remains necessary for bundled ZIP verification/extraction.
No previously viewed remote page is saved or used as an offline fallback.
The bundled page retains its local-file bridge boundary and its own kind/product
IDs. After a live load failure, it receives the presentation's parameters.
`FlowdeckViewController.content` and the `loaded` event identify the active
bundled content; `fallbackReason` records the live load error.
Existing manifest-failure behavior (including authoritative placement removal)
is unchanged.

## Placement parameters

Set parameters on each placement in Flowdeck, for example `ask_review` as a boolean
on `onboarding`. Parameters belong to the placement; updates require no new HTML
package or version. The next manifest refresh picks them up, on the next preparation.

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
On a manifest failure, a bundle uses the last manifest’s parameters when available; otherwise its map is empty.

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

`window.flowdeck` is injected at document start, in the trusted placement main frame. Every
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

The host project is generated in TMPDIR. Tests cover live URL construction, origin/path boundaries, manifest errors,
opt-in bundle verification, archive corruption/traversal, bridge parsing/scope,
local WKWebView Promise callbacks and navigation,
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

### Placement statistics

Each presentation automatically records one placement-level `impression` (empty
page) when it appears, and one `close` when dismissed. Reappearing after a system
sheet does not count again. Page changes are explicit:

```js
await window.flowdeck.page('welcome'); // Each call counts a page impression.
await window.flowdeck.page('threadback_ad');
await window.flowdeck.click('app_store'); // Optional explicit click.
```

Alternatively, annotate a clickable element (including dynamically added elements):

```html
<a data-flowdeck-click="app_store" href="#">Get the app</a>
```

Clicks on descendants also count once. Use either the attribute or an explicit
`click()` for the same action to avoid counting twice. Clicks and dismissal use
the last reported page; before `page()` they use the empty placement-level bucket.
Names are case-sensitive, up to 64 ASCII letters, digits, underscores, dots or
hyphens (empty is allowed). Never use URLs, user text or personal identifiers.
Existing `event(name, props)` remains a host callback; its arbitrary properties
are not uploaded to statistics.

The SDK posts batches of up to 100 events to `/v1/sdk/events` every five seconds
while running, with a 30-second delay after failures. Its per-configuration disk
cache holds up to 1,000 pending events across launches; when full, new events are
dropped. Events older than 29 days are discarded to stay inside the server's
30-day ingestion window. Storage/network work runs off the UI actor. The cache
can be purged by the OS; a disk-write failure retains events only in memory.
Delivery resumes when the app runs again; this is not a background delivery
service. Only placement, page, event type, click target and occurrence time are
sent, with the app's API key; no device/user ID, IP field or StoreKit attribution
is included. The server has no deduplication, so retrying after a lost response
can overcount. Totals count events, not unique visitors; page impressions are
additional to the placement-level impression.

### Live-page verification

The migration was also built for iOS Simulator and exercised on iPhone SE (3rd
generation) and iPhone 17 Pro Max using a local HTTP `/live/probe/onboarding/`
fixture with the server's exact `sandbox allow-scripts allow-forms` CSP.
Native parameter, page, click and onboarding Promise calls completed successfully.
This verifies sandbox compatibility; it is not a production deployment check.
