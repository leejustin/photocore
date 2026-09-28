import Foundation
import Hummingbird

func registerPhotoRoutes(_ router: Router<BasicRequestContext>, env: ServerEnvironment) {
    router.get("v2/sessions/{sid}/photos") { request, context in
        let sid = try context.parameters.require("sid")
        guard let session = try await env.registry.session(id: sid) else { throw APIError.notFound("No session \(sid)") }
        let set = queryValue(request, "set") ?? "all"
        let limit = min(200, max(1, queryInt(request, "limit", default: 50)))
        let offset = Int(queryValue(request, "cursor") ?? "") ?? 0
        let rows = PhotoMapping.filtered(session, set: set)
        let slice = rows.dropFirst(offset).prefix(limit)
        let items = slice.compactMap { PhotoMapping.photo($0, session: session, sid: sid) }
        let next = offset + limit < rows.count ? String(offset + limit) : nil
        return try APIJSON.response(Page(items: items, nextCursor: next))
    }

    router.patch("v2/sessions/{sid}/photos/{pid}") { request, context in
        let sid = try context.parameters.require("sid")
        let pid = try context.parameters.require("pid")
        let patch = try await request.decode(as: PhotoPatch.self, context: context)
        let match = request.headers[.ifMatch]
        let photo = try await env.registry.applyPatch(patch, sessionID: sid, photoID: pid, ifMatch: match)
        var headers = HTTPFields()
        headers[.eTag] = photo.etag
        return try APIJSON.response(photo, headers: headers)
    }
}
