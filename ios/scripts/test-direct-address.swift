import Foundation

@main
struct DirectAddressTests {
    static func main() {
        let valid = [
            " 192.168.1.10 ": "192.168.1.10:4433", "PC.local:5500": "pc.local:5500",
            "localhost": "localhost:4433", "::1": "[::1]:4433",
            "[2001:db8::1]:65535": "[2001:db8::1]:65535",
        ]
        for (input, expected) in valid {
            precondition(DirectAddress.parse(input) == expected, input)
            precondition(DirectAddress.parse(expected) == expected, expected)
        }
        for input in ["", "100000", ":4433", "pc:", "pc:0", "pc:65536", "pc:+12",
                      "192.168.1.256", "192.168.1.02", "[::1", "[::1]4433", "[::1]:", "a::g",
                      "pc/path", "https://pc", "name@pc", "bad..name", "pc wifi", "-host"] {
            precondition(DirectAddress.parse(input) == nil, input)
        }
    }
}
