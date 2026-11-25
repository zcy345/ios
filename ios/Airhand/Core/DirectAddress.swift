import Foundation
import Network

enum DirectAddress {
    static let wireCode = "100000"

    /// A DNS name, IPv4, or IPv6. Brackets distinguish an IPv6 address with a port.
    static func parse(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value.utf8.count <= 300,
              !value.contains(where: { $0.isWhitespace || "/?#@%\\".contains($0) }) else { return nil }
        let host: String
        var port = 4433
        if value.hasPrefix("[") {
            guard let end = value.firstIndex(of: "]"),
                  let ip = IPv6Address(String(value[value.index(after: value.startIndex)..<end])) else { return nil }
            host = "[\(ip.debugDescription)]"
            let tail = value[value.index(after: end)...]
            if !tail.isEmpty {
                guard tail.first == ":", let p = parsePort(tail.dropFirst()) else { return nil }
                port = p
            }
        } else if value.filter({ $0 == ":" }).count > 1 {
            guard let ip = IPv6Address(value) else { return nil }
            host = "[\(ip.debugDescription)]"
        } else {
            let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            if parts.count == 2 {
                guard let p = parsePort(parts[1]) else { return nil }
                port = p
            }
            let labels = name.split(separator: ".", omittingEmptySubsequences: false)
            if name.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) {
                guard labels.count == 4, labels.allSatisfy({
                    !$0.isEmpty && ($0.count == 1 || $0.first != "0") && UInt8($0) != nil
                }) else { return nil }
            } else {
                guard !name.isEmpty, name.utf8.count <= 253, labels.allSatisfy({ label in
                    (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-" &&
                    label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                }) else { return nil }
            }
            host = name
        }
        return "\(host):\(port)"
    }

    private static func parsePort(_ value: Substring) -> Int? {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = UInt16(value), port > 0 else { return nil }
        return Int(port)
    }
}
