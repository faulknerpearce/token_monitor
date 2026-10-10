import Foundation

extension URL {
    /// A URL from a compile-time string literal.
    ///
    /// A malformed literal is a programming error: it trips an assertion in
    /// debug builds and tests, and in release yields `file:///dev/null`, so
    /// the request fails as a normal network error instead of crashing.
    init(staticString string: StaticString) {
        if let url = URL(string: "\(string)") {
            self = url
        } else {
            assertionFailure("Malformed static URL: \(string)")
            self = URL(fileURLWithPath: "/dev/null")
        }
    }
}
