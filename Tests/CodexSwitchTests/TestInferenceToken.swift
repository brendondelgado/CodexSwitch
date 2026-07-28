import Foundation

func testInferenceToken(expiresAt: Date) -> String {
    let payload = try! JSONSerialization.data(
        withJSONObject: ["exp": Int(expiresAt.timeIntervalSince1970)]
    )
    let encoded = payload
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "e30.\(encoded).signature"
}
