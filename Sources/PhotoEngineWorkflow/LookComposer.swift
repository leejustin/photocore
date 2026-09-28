import Foundation
import PhotoEngineApple
import PhotoEngineCore

public struct LookSettings: Codable, Sendable, Equatable {
    public var lookID: String
    public var temperature: Double
    public var autoStraighten: Bool
    public var renderBase: RenderBase

    public init(lookID: String, temperature: Double, autoStraighten: Bool, renderBase: RenderBase) {
        self.lookID = lookID
        self.temperature = temperature
        self.autoStraighten = autoStraighten
        self.renderBase = renderBase
    }
}

public enum LookComposer {
    public static func effective(look: AlbumLook, settings: LookSettings) -> AlbumLook {
        var look = look
        look.temperature += settings.temperature
        look.autoStraighten = settings.autoStraighten
        return look
    }

    public static func recipe(for photo: AnalyzedPhoto, look: AlbumLook, settings: LookSettings, horizon: Double?) -> EditRecipe {
        let adjusted = effective(look: look, settings: settings)
        var recipe = adjusted.recipe(for: photo, horizonDegrees: settings.autoStraighten ? horizon : nil)
        recipe.base = settings.renderBase
        return recipe
    }
}
