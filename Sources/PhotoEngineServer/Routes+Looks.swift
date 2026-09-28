import Foundation
import Hummingbird
import PhotoEngineApple

func registerLookRoutes(_ router: Router<BasicRequestContext>, env: ServerEnvironment) {
    router.get("v2/looks") { _, _ in
        let looks = AlbumLookLibrary.shared.allLooks().map { LookDTO(id: $0.id, name: $0.name, kind: $0.kind.rawValue) }
        return try APIJSON.response(looks)
    }

    router.post("v2/looks") { request, _ in
        var request = request
        let body = try await request.collectBody(upTo: 20_000_000)
        let bytes = Data(body.readableBytesView)
        let type = request.headers[.contentType] ?? ""
        guard let boundary = type.split(separator: "boundary=").last.map({ String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }) else {
            throw APIError.invalid("Upload a .cube or .xmp file as multipart form data.")
        }
        guard let file = multipartFile(bytes, boundary: boundary) else {
            throw APIError.invalid("The upload did not include a file.")
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
        try file.data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let look: AlbumLook
        if file.name.lowercased().hasSuffix(".cube") {
            look = try AlbumLookLibrary.shared.importCubeLUT(from: temp)
        } else if file.name.lowercased().hasSuffix(".xmp") {
            look = try AlbumLookLibrary.shared.importXMPPreset(from: temp)
        } else {
            throw APIError.invalid("Looks must be .cube or .xmp files.")
        }
        return try APIJSON.response(LookDTO(id: look.id, name: look.name, kind: look.kind.rawValue), status: .created)
    }
}

private func multipartFile(_ data: Data, boundary: String) -> (name: String, data: Data)? {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    let marker = "--\(boundary)"
    guard let headerRange = text.range(of: "filename=\"") else { return nil }
    let nameStart = headerRange.upperBound
    guard let nameEnd = text[nameStart...].firstIndex(of: "\"") else { return nil }
    let name = String(text[nameStart..<nameEnd])
    guard let headerEnd = text.range(of: "\r\n\r\n") else { return nil }
    let bodyStart = headerEnd.upperBound
    guard let end = text[bodyStart...].range(of: "\r\n\(marker)") else { return nil }
    let payload = Data(text[bodyStart..<end.lowerBound].utf8)
    return (name, payload)
}
