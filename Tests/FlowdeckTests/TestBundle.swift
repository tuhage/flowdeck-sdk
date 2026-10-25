#if !SWIFT_PACKAGE
import Foundation
private final class TestBundleLocator: NSObject {}
extension Bundle {
    static var module: Bundle { Bundle(for: TestBundleLocator.self) }
}
#endif
