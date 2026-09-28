import CryptoKit
import Foundation
import PhotoEngineApple
import PhotoEngineCore
import PhotoEnginePersistence
import PhotoEngineWorkflow

struct Page<Item: Encodable>: Encodable {
    var items: [Item]
    var nextCursor: String?
}

struct HealthBody: Encodable {
    var ok: Bool
}

struct ReadyBody: Encodable {
    var ok: Bool
    var checks: [String: Bool]
}

struct CreateSessionBody: Codable {
    var sourcePath: String
    var occasion: String?
    var cull: String?
    var target: Int?
    var keepPercent: Double?
    var renderBase: String?
}

struct DeliverBody: Codable {
    var exportPreset: String?
    var writeSidecarsBesideOriginals: Bool?
}

struct ResolveBody: Decodable {
    var action: String
    var photoID: String?
}

struct CountsBody: Encodable {
    var total: Int
    var album: Int
    var alternates: Int
    var needsLook: Int
    var hidden: Int
    var unusable: Int
}

struct SessionSettingsBody: Encodable {
    var occasion: String
    var cull: String
    var target: Int?
    var keepPercent: Double?
    var renderBase: String
}

struct MetricsBody: Encodable {
    var totalSeconds: Double
    var analysisSeconds: Double
    var discoverySeconds: Double
    var groupingSeconds: Double
    var selectionSeconds: Double
    var exportSeconds: Double
}

struct SessionSummaryDTO: Encodable {
    var id: String
    var sourceName: String
    var status: String
    var createdAt: Date
    var completedAt: Date?
    var counts: CountsBody
    var pendingConfirmations: Int
    var coverThumbURL: String?
}

struct SessionDetailDTO: Encodable {
    var id: String
    var sourceName: String
    var status: String
    var createdAt: Date
    var completedAt: Date?
    var counts: CountsBody
    var pendingConfirmations: Int
    var coverThumbURL: String?
    var settings: SessionSettingsBody
    var look: LookSettings
    var metrics: MetricsBody
}

struct FaceBoxDTO: Encodable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct MarkDTO: Encodable {
    var flag: String
    var stars: Int
    var color: String
}

struct PhotoDTO: Encodable {
    var id: String
    var fileName: String
    var capturedAt: Date?
    var width: Int
    var height: Int
    var bucket: String
    var inAlbum: Bool
    var rank: Int?
    var score: Double
    var reasons: [String]
    var unusableReason: String?
    var groupID: String?
    var mark: MarkDTO
    var hasCustomRecipe: Bool
    var faces: [FaceBoxDTO]
    var etag: String
    var thumbURL: String
    var previewURL: String
}

struct PhotoPatch: Decodable {
    var flag: String?
    var stars: Int?
    var color: String?
    var bucket: String?
    var recipe: EditRecipe?
    var clearRecipe: Bool = false

    private enum CodingKeys: String, CodingKey {
        case flag, stars, color, bucket, recipe
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        flag = try container.decodeIfPresent(String.self, forKey: .flag)
        stars = try container.decodeIfPresent(Int.self, forKey: .stars)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        bucket = try container.decodeIfPresent(String.self, forKey: .bucket)
        if container.contains(.recipe) {
            if try container.decodeNil(forKey: .recipe) {
                clearRecipe = true
            } else {
                recipe = try container.decode(EditRecipe.self, forKey: .recipe)
            }
        }
    }
}

struct GroupDTO: Encodable {
    var id: String
    var kind: String
    var memberIDs: [String]
    var keeperID: String
}

struct ConfirmationDTO: Encodable {
    var id: String
    var kind: String
    var suggestedID: String
    var candidateIDs: [String]
    var hiddenRunnerUpIDs: [String]
    var explanation: String
}

struct ConfirmationsBody: Encodable {
    var moments: [ConfirmationDTO]
    var beyondCap: Int
}

struct JobErrorDTO: Encodable {
    var code: String
    var message: String
}

struct JobDTO: Encodable {
    var id: String
    var kind: String
    var sessionID: String?
    var state: String
    var stage: String?
    var completed: Int?
    var total: Int?
    var message: String?
    var error: JobErrorDTO?
    var result: JSONValue?
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?

    init(_ record: JobRecord) {
        id = record.id
        kind = record.kind
        sessionID = record.sessionID
        state = record.state
        stage = record.stage
        completed = record.completed
        total = record.total
        message = record.message
        if let code = record.errorCode, let message = record.errorMessage {
            error = JobErrorDTO(code: code, message: message)
        }
        if let data = record.result, let object = try? JSONDecoder().decode(JSONValue.self, from: data) {
            result = object
        }
        createdAt = record.createdAt
        startedAt = record.startedAt
        finishedAt = record.finishedAt
    }
}

struct LookDTO: Encodable {
    var id: String
    var name: String
    var kind: String
}

struct DeliveredFileDTO: Encodable {
    var fileName: String
    var url: String
}

enum JSONValue: Codable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

enum PhotoMapping {
    static func counts(session: CurationSession) -> CountsBody {
        CountsBody(
            total: session.rows.count,
            album: filtered(session, set: "album").count,
            alternates: filtered(session, set: "alternates").count,
            needsLook: filtered(session, set: "needsLook").count,
            hidden: filtered(session, set: "hidden").count,
            unusable: filtered(session, set: "unusable").count
        )
    }

    static func filtered(_ session: CurationSession, set: String) -> [CuratedRow] {
        session.rows.filter { row in
            let mark = session.mark(for: row.id)
            let inAlbum = AlbumMembership.contains(row, mark: mark)
            switch set {
            case "album": return inAlbum
            case "alternates": return row.bucket == .alternate && !inAlbum
            case "needsLook": return row.bucket == .review && !inAlbum
            case "hidden": return !inAlbum && (row.bucket == .hidden || mark.flag == .reject)
            case "unusable": return row.reasons.contains(where: PhotoTechnicalReject.isTechnicalRejectReason)
            default: return true
            }
        }
    }

    static func photo(_ row: CuratedRow, session: CurationSession, sid: String) -> PhotoDTO? {
        guard let analyzed = session.result.analyzed.first(where: { $0.id == row.id }) else { return nil }
        let mark = session.mark(for: row.id)
        let recipe = session.customRecipes[row.id]
        return PhotoDTO(
            id: row.id.description,
            fileName: row.sourceURL.lastPathComponent,
            capturedAt: analyzed.asset.metadata.captureDate,
            width: analyzed.asset.metadata.pixelWidth,
            height: analyzed.asset.metadata.pixelHeight,
            bucket: row.bucket.rawValue,
            inAlbum: AlbumMembership.contains(row, mark: mark),
            rank: row.rank,
            score: row.score,
            reasons: row.reasons,
            unusableReason: row.reasons.first { PhotoTechnicalReject.isTechnicalRejectReason($0) },
            groupID: session.groupsByPhoto[row.id]?.id.uuidString,
            mark: MarkDTO(flag: mark.flag.rawValue, stars: mark.stars, color: mark.color.rawValue),
            hasCustomRecipe: recipe != nil,
            faces: analyzed.signals.faces.map {
                FaceBoxDTO(x: $0.boundingBox.x, y: $0.boundingBox.y, width: $0.boundingBox.width, height: $0.boundingBox.height)
            },
            etag: etag(row: row, mark: mark, recipe: recipe),
            thumbURL: "/v2/media/\(sid)/\(row.id.description)/thumb",
            previewURL: "/v2/media/\(sid)/\(row.id.description)/preview"
        )
    }

    static func etag(row: CuratedRow, mark: PhotoReviewMark, recipe: EditRecipe?) -> String {
        let recipeData = (try? APIJSON.data(recipe)) ?? Data()
        var hasher = SHA256()
        hasher.update(data: Data(row.id.description.utf8))
        hasher.update(data: Data(row.bucket.rawValue.utf8))
        hasher.update(data: Data(mark.flag.rawValue.utf8))
        hasher.update(data: Data("\(mark.stars)".utf8))
        hasher.update(data: Data(mark.color.rawValue.utf8))
        hasher.update(data: recipeData)
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "\"\(digest)\""
    }

    static func pending(_ session: CurationSession) -> (moments: [ConfirmationMoment], beyondCap: Int) {
        let built = session.confirmations
        let moments = built.moments.filter { moment in
            !session.skippedConfirmationIDs.contains(moment.id)
                && !moment.candidateIDs.contains { session.mark(for: $0).flag != .unflagged }
        }
        return (moments, built.beyondCap)
    }
}
