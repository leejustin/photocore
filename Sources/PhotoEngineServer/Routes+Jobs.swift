import Foundation
import HTTPTypes
import Hummingbird

func registerJobRoutes(_ router: Router<BasicRequestContext>, env: ServerEnvironment) {
    router.get("healthz") { _, _ in
        try APIJSON.response(HealthBody(ok: true))
    }

    router.get("v2/readyz") { _, _ in
        var checks: [String: Bool] = ["catalog": false, "disk": false, "vision": true]
        do {
            _ = try env.catalog.listSessions(limit: 1)
            checks["catalog"] = true
        } catch {
            checks["catalog"] = false
        }
        let root = env.configuration.security.outputRoot
        if let values = try? FileManager.default.attributesOfFileSystem(forPath: root.path),
           let free = values[.systemFreeSize] as? Int64 {
            checks["disk"] = free > 2_000_000_000
        }
        let ok = checks.values.allSatisfy { $0 }
        return try APIJSON.response(ReadyBody(ok: ok, checks: checks), status: ok ? .ok : .serviceUnavailable)
    }

    router.get("v2/jobs") { request, _ in
        let limit = min(200, max(1, queryInt(request, "limit", default: 50)))
        let state = queryValue(request, "state")
        let records = try await env.jobs.jobs(limit: limit, state: state)
        return try APIJSON.response(records.map(JobDTO.init))
    }

    router.get("v2/jobs/{jid}") { _, context in
        let jid = try context.parameters.require("jid")
        guard let record = try await env.jobs.job(id: jid) else { throw APIError.notFound("No job \(jid)") }
        return try APIJSON.response(JobDTO(record))
    }

    router.post("v2/jobs/{jid}/cancel") { _, context in
        let jid = try context.parameters.require("jid")
        guard let record = try await env.jobs.cancel(id: jid) else { throw APIError.notFound("No job \(jid)") }
        return try APIJSON.response(JobDTO(record), status: .accepted)
    }

    router.get("v2/jobs/{jid}/events") { _, context in
        let jid = try context.parameters.require("jid")
        guard try await env.jobs.job(id: jid) != nil else { throw APIError.notFound("No job \(jid)") }
        let stream = await env.jobs.subscribe(id: jid)
        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache"
        let body = ResponseBody { writer in
            var buffer = ByteBuffer()
            buffer.writeString(": keepalive\n\n")
            try await writer.write(buffer)
            for await record in stream {
                let event = record.state == "running" ? "progress" : "state"
                let data = try APIJSON.data(JobDTO(record))
                var chunk = ByteBuffer()
                chunk.writeString("event: \(event)\ndata: ")
                chunk.writeBytes(data)
                chunk.writeString("\n\n")
                try await writer.write(chunk)
            }
            try await writer.finish(nil)
        }
        return Response(status: .ok, headers: headers, body: body)
    }
}
