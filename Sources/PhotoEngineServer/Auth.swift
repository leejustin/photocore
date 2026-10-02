import Foundation
import HTTPTypes
import Hummingbird
import PhotoEngineApple

struct APIMiddleware<Context: RequestContext>: RouterMiddleware {
    let security: WorkerSecurity

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let path = request.uri.path
        if request.method == .options {
            guard let origin = request.headers[.origin], security.allowedOrigins.contains(origin) else {
                throw APIError.forbidden("Origin is not allowed.")
            }
            return Response(status: .noContent, headers: corsHeaders(origin))
        }
        // Shared books and invite links are public by link; book edits check the
        // owner's own token, invite uploads check each person's own token, and
        // both have their own size and count limits.
        if path != "/healthz" && !path.hasPrefix("/b/") && !path.hasPrefix("/j/") {
            let authorization = request.headers[.authorization]
            guard security.acceptsAuthorization(authorization) else {
                throw APIError.unauthorized()
            }
        }
        do {
            var response = try await next(request, context)
            if let origin = request.headers[.origin], security.allowedOrigins.contains(origin) {
                response.headers.append(contentsOf: corsHeaders(origin))
            }
            return response
        } catch let error as APIError {
            throw error
        } catch let error as HTTPError {
            let code: String
            switch error.status {
            case .notFound: code = "not_found"
            case .unauthorized: code = "unauthorized"
            case .forbidden: code = "forbidden"
            case .badRequest: code = "invalid_request"
            case .conflict: code = "conflict"
            case .preconditionFailed: code = "precondition_failed"
            default: code = "internal"
            }
            throw APIError(status: error.status, code: code, message: error.body ?? error.status.reasonPhrase)
        } catch {
            context.logger.error("Request failed", metadata: ["error": "\(error)", "path": "\(path)"])
            throw APIError.internalError("Something went wrong.")
        }
    }

    private func corsHeaders(_ origin: String) -> HTTPFields {
        var headers = HTTPFields()
        headers[.accessControlAllowOrigin] = origin
        headers[.accessControlAllowHeaders] = "Authorization, Content-Type, If-Match, If-None-Match"
        headers[.accessControlAllowMethods] = "GET, POST, PUT, PATCH, DELETE, OPTIONS"
        headers[.vary] = "Origin"
        return headers
    }
}
