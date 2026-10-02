import Foundation
import ImageIO
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Writes the diary with Apple's own model: on the device, or Apple's Private
/// Cloud Compute model where the OS offers it. Free to run and nothing leaves
/// Apple's systems. The on-device model has a small context window, so the
/// book is written one chapter at a time.
public struct AppleDiaryWriter: DiaryWriter {
    public var name: String

    public static func makeIfAvailable() -> AppleDiaryWriter? {
        #if canImport(FoundationModels)
        if #available(macOS 27, iOS 27, *), PrivateCloudComputeLanguageModel().isAvailable {
            return AppleDiaryWriter(name: "apple-private-cloud")
        }
        if #available(macOS 26, iOS 26, *) {
            guard case .available = SystemLanguageModel.default.availability else { return nil }
            return AppleDiaryWriter(name: "apple-on-device")
        }
        #endif
        return nil
    }

    public func write(_ request: DiaryRequest, thumbnails: [String: Data]) async throws -> DiaryText {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            return try await AppleDiarySession.write(request, thumbnails: thumbnails, privateCloud: name == "apple-private-cloud")
        }
        #endif
        throw CocoaError(.featureUnsupported)
    }
}

#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
@Generable
struct TripOpeningDraft {
    @Guide(description: "A book title of two to six words, using only names from the facts")
    var title: String
    @Guide(description: "One or two sentences introducing the trip")
    var intro: String
}

@available(macOS 26, iOS 26, *)
@Generable
struct ChapterDraft {
    @Guide(description: "A heading of two to five words, different from the book title")
    var heading: String
    @Guide(description: "One or two sentences in first person plural, using only the facts")
    var diary: String
}

@available(macOS 26, iOS 26, *)
enum AppleDiarySession {
    static func session(privateCloud: Bool) -> LanguageModelSession {
        if #available(macOS 27, iOS 27, *), privateCloud {
            return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: DiaryInstructions.system)
        }
        return LanguageModelSession(instructions: DiaryInstructions.system)
    }

    /// The larger Private Cloud Compute model can look at the photos; the
    /// on-device model gets the facts only.
    static func chapterPrompt(_ text: String, keys: [String], thumbnails: [String: Data], privateCloud: Bool) -> Prompt {
        if #available(macOS 27, iOS 27, *), privateCloud {
            let images: [Attachment<ImageAttachmentContent>] = keys.compactMap { key in
                guard let data = thumbnails[key], let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
                return Attachment(image)
            }
            return Prompt {
                text
                for image in images { image }
            }
        }
        return Prompt(text)
    }

    static func facts(_ request: DiaryRequest, scope: Set<String?>) -> String {
        request.facts
            .filter { scope.contains($0.scope) }
            .map { "- \($0.text)" }
            .joined(separator: "\n")
    }

    static func write(_ request: DiaryRequest, thumbnails: [String: Data], privateCloud: Bool) async throws -> DiaryText {
        let fallback = TemplateDiaryWriter().text(for: request)
        let tripFacts = facts(request, scope: [nil])
        var opening = (title: fallback.title, intro: fallback.intro)
        do {
            let response = try await session(privateCloud: privateCloud).respond(
                to: "Trip facts:\n\(tripFacts)\nPlaces: \(request.places.joined(separator: "; "))\nWrite the title and intro in a \(request.tone.rawValue) tone.",
                generating: TripOpeningDraft.self
            )
            opening = (response.content.title, response.content.intro)
        } catch {
            // Keep the offline title; chapters are still attempted.
        }

        var sections: [DiaryText.Section] = []
        var photos: [DiaryText.Photo] = []
        let safeSections = Dictionary(fallback.sections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let safePhotos = Dictionary(fallback.photos.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for chapter in request.chapters {
            let keys = chapter.photos.map(\.key)
            let scope = Set<String?>([nil, chapter.id] + keys.map { Optional($0) })
            let prompt = """
            Chapter \(chapter.id), \(chapter.day), \(chapter.when).
            Facts:
            \(facts(request, scope: scope))
            What the photos in this chapter show:
            \(chapter.photos.map { ($0.labels.isEmpty ? "" : $0.labels.joined(separator: ", ")) + ($0.people > 0 ? " (\($0.people) people)" : "") }.filter { !$0.isEmpty }.joined(separator: "; "))
            Write the chapter heading and a short diary entry built only from these facts, in a \(request.tone.rawValue) tone.
            """
            do {
                let draft = try await session(privateCloud: privateCloud).respond(
                    to: chapterPrompt(prompt, keys: keys, thumbnails: thumbnails, privateCloud: privateCloud),
                    generating: ChapterDraft.self
                ).content
                sections.append(DiaryText.Section(id: chapter.id, heading: draft.heading, diary: draft.diary))
                // The small on-device model writes poor captions (it repeats labels
                // and fragments of signs), so captions come from the facts.
                photos.append(contentsOf: keys.compactMap { safePhotos[$0] })
            } catch {
                if let safe = safeSections[chapter.id] { sections.append(safe) }
                photos.append(contentsOf: keys.compactMap { safePhotos[$0] })
            }
        }
        return DiaryText(title: opening.title, intro: opening.intro, sections: sections, photos: photos)
    }
}
#endif
