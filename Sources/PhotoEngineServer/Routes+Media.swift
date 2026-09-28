import Foundation
import HTTPTypes
import Hummingbird
import PhotoEngineCore

func registerMediaRoutes(_ router: Router<BasicRequestContext>, env: ServerEnvironment) {
    router.get("v2/media/{sid}/{pid}/thumb") { request, context in
        let sid = try context.parameters.require("sid")
        let pid = try photoID(context.parameters.require("pid"))
        guard let session = try await env.registry.session(id: sid) else { throw APIError.notFound("No session \(sid)") }
        let rendered = try await env.media.thumbnail(session: session, photoID: pid)
        return try await jpeg(request, context: context, data: rendered.data, etag: rendered.etag, immutable: true)
    }

    router.get("v2/media/{sid}/{pid}/preview") { request, context in
        let sid = try context.parameters.require("sid")
        let pid = try photoID(context.parameters.require("pid"))
        let size = min(4096, max(256, queryInt(request, "size", default: 1600)))
        guard let session = try await env.registry.session(id: sid) else { throw APIError.notFound("No session \(sid)") }
        let rendered = try await env.media.preview(session: session, photoID: pid, size: size)
        return try await jpeg(request, context: context, data: rendered.data, etag: rendered.etag, immutable: false)
    }

    router.get("v2/media/{sid}/deliveries/{jid}/{file}") { request, context in
        let sid = try context.parameters.require("sid")
        let jid = try context.parameters.require("jid")
        let file = try context.parameters.require("file")
        guard !file.contains("/") && file != ".." && file != "." else { throw APIError.invalid("Invalid file name.") }
        guard let job = try await env.jobs.job(id: jid), job.sessionID == sid, job.kind == "deliver",
              let data = job.result, let result = try? APIJSON.decoder.decode(DeliveryFolder.self, from: data) else {
            throw APIError.notFound("No delivered file.")
        }
        let url = URL(fileURLWithPath: result.folder, isDirectory: true).appendingPathComponent(file)
        guard url.lastPathComponent == file, FileManager.default.fileExists(atPath: url.path) else {
            throw APIError.notFound("No delivered file.")
        }
        let bytes = try Data(contentsOf: url)
        if let range = request.headers[.range], let slice = byteRange(range, length: bytes.count) {
            var headers = HTTPFields()
            headers[.contentType] = "image/jpeg"
            headers[.acceptRanges] = "bytes"
            headers[HTTPField.Name("Content-Range")!] = "bytes \(slice.start)-\(slice.end)/\(bytes.count)"
            return APIJSON.bytes(Data(bytes[slice.start...slice.end]), status: .partialContent, headers: headers)
        }
        var headers = HTTPFields()
        headers[.contentType] = "image/jpeg"
        headers[.acceptRanges] = "bytes"
        return APIJSON.bytes(bytes, headers: headers)
    }

    router.get("v2/openapi.yaml") { _, _ in
        guard let url = Bundle.module.url(forResource: "openapi", withExtension: "yaml"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw APIError.internalError("The API contract is missing.")
        }
        var headers = HTTPFields()
        headers[.contentType] = "application/yaml; charset=utf-8"
        var buffer = ByteBuffer()
        buffer.writeString(text)
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: buffer))
    }
}

private struct DeliveryFolder: Decodable {
    var folder: String
}

private func photoID(_ string: String) throws -> PhotoID {
    guard let uuid = UUID(uuidString: string) else { throw APIError.notFound("No photo \(string)") }
    return PhotoID(uuid)
}

private func jpeg(_ request: Request, context _: some RequestContext, data: Data, etag: String, immutable: Bool) async throws -> Response {
    var headers = HTTPFields()
    headers[.contentType] = "image/jpeg"
    headers[.eTag] = etag
    if immutable {
        headers[.cacheControl] = "private, max-age=31536000, immutable"
    }
    if etagMatches(request.headers[.ifNoneMatch], etag) {
        return Response(status: .notModified, headers: headers)
    }
    return APIJSON.bytes(data, headers: headers)
}

private func etagMatches(_ header: String?, _ etag: String) -> Bool {
    guard let header, !header.isEmpty else { return false }
    let bare = etag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    return header.split(separator: ",").contains { candidate in
        let value = candidate.trimmingCharacters(in: .whitespaces)
        return value == etag || value.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) == bare
    }
}

private func byteRange(_ header: String, length: Int) -> (start: Int, end: Int)? {
    guard header.hasPrefix("bytes="), length > 0 else { return nil }
    let spec = header.dropFirst("bytes=".count).split(separator: ",").first.map(String.init) ?? ""
    let parts = spec.split(separator: "-", maxSplits: 1).map(String.init)
    guard parts.count == 2, let start = Int(parts[0]) else { return nil }
    let end = Int(parts[1]) ?? (length - 1)
    guard start >= 0, end >= start, start < length else { return nil }
    return (start, min(end, length - 1))
}
