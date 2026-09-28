import Foundation
import HTTPTypes
import Hummingbird

struct APIError: Error, HTTPResponseError, Sendable {
    var status: HTTPResponse.Status
    var headers: HTTPFields = [:]
    var code: String
    var message: String
    var details: [String: String]

    init(status: HTTPResponse.Status, code: String, message: String, details: [String: String] = [:]) {
        self.status = status
        self.code = code
        self.message = message
        self.details = details
    }

    static func unauthorized(_ message: String = "Missing or invalid bearer token.") -> APIError {
        APIError(status: .unauthorized, code: "unauthorized", message: message)
    }

    static func forbidden(_ message: String) -> APIError {
        APIError(status: .forbidden, code: "forbidden", message: message)
    }

    static func notFound(_ message: String) -> APIError {
        APIError(status: .notFound, code: "not_found", message: message)
    }

    static func invalid(_ message: String) -> APIError {
        APIError(status: .badRequest, code: "invalid_request", message: message)
    }

    static func conflict(_ message: String) -> APIError {
        APIError(status: .conflict, code: "conflict", message: message)
    }

    static func precondition(_ message: String) -> APIError {
        APIError(status: .preconditionFailed, code: "precondition_failed", message: message)
    }

    static func busy(_ message: String) -> APIError {
        APIError(status: .serviceUnavailable, code: "busy", message: message)
    }

    static func internalError(_ message: String) -> APIError {
        APIError(status: .internalServerError, code: "internal", message: message)
    }

    func response(from request: Request, context: some RequestContext) throws -> Response {
        let envelope = ErrorBody(error: ErrorBody.Payload(code: code, message: message, details: details))
        return try APIJSON.response(envelope, status: status, headers: headers)
    }
}

private struct ErrorBody: Encodable {
    struct Payload: Encodable {
        var code: String
        var message: String
        var details: [String: String]
    }

    var error: Payload
}

enum APIJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func data<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    static func response<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok, headers: HTTPFields = [:]) throws -> Response {
        var headers = headers
        if headers[.contentType] == nil {
            headers[.contentType] = "application/json; charset=utf-8"
        }
        var buffer = ByteBuffer()
        buffer.writeBytes(try data(value))
        return Response(status: status, headers: headers, body: .init(byteBuffer: buffer))
    }

    static func bytes(_ data: Data, status: HTTPResponse.Status = .ok, headers: HTTPFields) -> Response {
        var buffer = ByteBuffer()
        buffer.writeBytes(data)
        return Response(status: status, headers: headers, body: .init(byteBuffer: buffer))
    }
}
