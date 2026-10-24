import Testing
@testable import Flowdeck

@Test func versionIsSet() {
    #expect(!Flowdeck.version.isEmpty)
}
