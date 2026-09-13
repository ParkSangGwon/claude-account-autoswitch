import Foundation

/// Comparing release tags, which are dotted numbers and nothing cleverer.
public enum ReleaseVersion {
    /// Whether `candidate` is a later release than `current`, per component so 0.1.10 lands after
    /// 0.1.9. A component that is not a number at all answers no rather than guessing.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        guard !a.isEmpty, !b.isEmpty else { return false }
        for i in 0..<max(a.count, b.count) {
            guard let left = i < a.count ? a[i] : 0, let right = i < b.count ? b[i] : 0 else { return false }
            if left != right { return left > right }
        }
        return false
    }

    /// `v1.2.3` and `1.2.3-beta` both read as 1, 2, 3; a segment with no leading digits is nil.
    private static func components(_ text: String) -> [Int?] {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        return trimmed.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) }
    }
}
