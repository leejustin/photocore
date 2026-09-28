import Foundation
import Hummingbird

func queryValue(_ request: Request, _ name: String) -> String? {
    guard let query = request.uri.query else { return nil }
    for pair in query.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.first == name else { continue }
        return parts.count > 1 ? parts[1].removingPercentEncoding ?? parts[1] : ""
    }
    return nil
}

func queryInt(_ request: Request, _ name: String, default defaultValue: Int) -> Int {
    guard let raw = queryValue(request, name), let value = Int(raw) else { return defaultValue }
    return value
}
