import Foundation

public enum ServerAddress {
    /// "https://varlatch.example.com" from what a person typed: no spaces,
    /// https:// when no scheme is given, no trailing slash. Nil when it
    /// cannot be a server's address.
    public static func normalize(_ text: String) -> String? {
        var s = text.filter { !$0.isWhitespace }
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return nil }
        if s.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) == nil {
            s = "https://" + s
        }
        guard s.range(of: #"^https?://[^/?#]+(/[^?#]*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        return s
    }
}
