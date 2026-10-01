import Foundation
import PhotoEngineApple
import PhotoEngineCore

/// `photo-engine eval <folder>` — run culling and write human-reviewable efficacy artifacts.
///
/// This does not score subjective taste without labels. It reports reduction, bucket mix,
/// reason breakdown, and contact sheets so you can spot catastrophic misses by eye.
enum CullEval {
    static func run(arguments: [String]) throws {
        guard let folderPath = arguments.first else {
            throw PhotoEngineError.invalidArgument("eval requires a folder path")
        }
        let sourceFolder = URL(fileURLWithPath: folderPath, isDirectory: true).standardizedFileURL
        let rawMode = option(arguments, name: "--profile") ?? "everyday"
        guard let mode = CurationMode(rawValue: rawMode) else {
            throw PhotoEngineError.invalidArgument("Unknown profile '\(rawMode)'.")
        }
        var profile = ScoringProfile.default(for: mode)
        if let rawTarget = option(arguments, name: "--target"), let target = Int(rawTarget), target > 0 {
            profile.sizingMode = .count
            profile.targetCount = target
        } else if let rawKeep = option(arguments, name: "--keep-percent"), let keep = Double(rawKeep) {
            guard (5...90).contains(keep) else {
                throw PhotoEngineError.invalidArgument("Keep percentage must be between 5 and 90.")
            }
            profile.sizingMode = .percentage
            profile.keepPercentage = keep
        }
        if let rawCull = option(arguments, name: "--cull") {
            guard let cull = CullingAggressiveness(rawValue: rawCull) else {
                throw PhotoEngineError.invalidArgument("Unknown cull preset. Use gentle, balanced, or highlights.")
            }
            profile.apply(aggressiveness: cull)
        }
        let limit = option(arguments, name: "--limit").flatMap(Int.init)
        let folder = try prepareFolder(sourceFolder, limit: limit)
        defer {
            if folder != sourceFolder {
                try? FileManager.default.removeItem(at: folder)
            }
        }

        let outputPath = option(arguments, name: "--output")
            ?? "./exports/\(sourceFolder.lastPathComponent)-eval"
        let output = URL(fileURLWithPath: outputPath, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        print("Evaluating \(folder.path)")
        print("Profile \(mode.rawValue), cull \(profile.aggressiveness.rawValue), sizing \(profile.sizingMode.rawValue)/\(profile.targetCount)")

        let result = try PhotoPipelineRunner().run(
            folder: folder,
            outputDirectory: output,
            profile: profile,
            exportSpecification: ExportSpecification(preset: .compact)
        ) { progress in
            let suffix = progress.total > 0 ? " (\(progress.completed)/\(progress.total))" : ""
            print("[\(progress.stage.rawValue)] \(progress.message)\(suffix)")
        }

        let report = Metrics.build(from: result, shootName: sourceFolder.lastPathComponent, profile: profile)
        let reportURL = output.appendingPathComponent("cull-eval.md")
        try report.markdown.write(to: reportURL, atomically: true, encoding: .utf8)
        let jsonURL = output.appendingPathComponent("cull-eval.json")
        try report.writeJSON(to: jsonURL)

        let sheetKept = output.appendingPathComponent("eval-kept.jpg")
        let sheetHidden = output.appendingPathComponent("eval-hidden-sample.jpg")
        let sheetReview = output.appendingPathComponent("eval-review.jpg")
        try writeSheet(decisions: report.keptSample, analyzed: result.analyzed, titlePrefix: "KEEP", to: sheetKept)
        try writeSheet(decisions: report.hiddenSample, analyzed: result.analyzed, titlePrefix: "HIDE", to: sheetHidden)
        try writeSheet(decisions: report.reviewSample, analyzed: result.analyzed, titlePrefix: "REVIEW", to: sheetReview)

        print("")
        print(report.summary)
        print("Report: \(reportURL.path)")
        print("Kept sheet:   \(sheetKept.path)")
        print("Hidden sheet: \(sheetHidden.path)")
        print("Review sheet: \(sheetReview.path)")
        print("")
        print("Eye-check: open the three sheets. Fail the run if a must-keep moment only appears on the hidden sheet.")
    }

    private static func prepareFolder(_ folder: URL, limit: Int?) throws -> URL {
        guard let limit, limit > 0 else { return folder }
        let imported = try PhotoFolderImporter().importFolder(folder)
        let sorted = imported.sorted { $0.asset.relativePath < $1.asset.relativePath }
        guard sorted.count > limit else { return folder }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("photocore-eval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        for item in sorted.prefix(limit) {
            let dest = temp.appendingPathComponent(item.asset.url.lastPathComponent)
            try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: item.asset.url)
        }
        print("Limited to first \(limit) of \(sorted.count) photos (by filename)")
        return temp
    }

    private static func writeSheet(
        decisions: [SelectionDecision],
        analyzed: [AnalyzedPhoto],
        titlePrefix: String,
        to url: URL
    ) throws {
        let byID = Dictionary(uniqueKeysWithValues: analyzed.map { ($0.id, $0) })
        let cells: [ContactSheet.Cell] = decisions.compactMap { decision in
            guard let photo = byID[decision.photoID] else { return nil }
            let why = decision.reasons.prefix(1).first ?? decision.bucket.rawValue
            let score = String(format: "%.2f", decision.score)
            return .init(
                url: photo.asset.url,
                label: "\(titlePrefix) \(score) \(photo.asset.url.lastPathComponent) — \(why)"
            )
        }
        guard !cells.isEmpty else {
            // Still write a tiny placeholder-free note via empty grid skip.
            try "# empty\n".write(to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
            return
        }
        try ContactSheet.write(cells, columns: 4, cellSize: 280, to: url)
    }

    private static func option(_ arguments: [String], name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    struct Metrics {
        var shootName: String
        var profile: String
        var cull: String
        var sourceCount: Int
        var keptCount: Int
        var alternateCount: Int
        var reviewCount: Int
        var hiddenCount: Int
        var exactDuplicateHidden: Int
        var nearDuplicateOrSameMoment: Int
        var technicalHidden: Int
        var belowCutHidden: Int
        var groupCount: Int
        var exactGroupCount: Int
        var burstGroupCount: Int
        var reductionPercent: Double
        var reviewPerHundred: Double
        var analysisSeconds: Double
        var totalSeconds: Double
        var summary: String
        var markdown: String
        var keptSample: [SelectionDecision]
        var hiddenSample: [SelectionDecision]
        var reviewSample: [SelectionDecision]

        private struct JSONPayload: Encodable {
            var shootName: String
            var profile: String
            var cull: String
            var sourceCount: Int
            var keptCount: Int
            var alternateCount: Int
            var reviewCount: Int
            var hiddenCount: Int
            var exactDuplicateHidden: Int
            var nearDuplicateOrSameMoment: Int
            var technicalHidden: Int
            var belowCutHidden: Int
            var groupCount: Int
            var exactGroupCount: Int
            var burstGroupCount: Int
            var reductionPercent: Double
            var reviewPerHundred: Double
            var analysisSeconds: Double
            var totalSeconds: Double
            var summary: String
        }

        func writeJSON(to url: URL) throws {
            let payload = JSONPayload(
                shootName: shootName,
                profile: profile,
                cull: cull,
                sourceCount: sourceCount,
                keptCount: keptCount,
                alternateCount: alternateCount,
                reviewCount: reviewCount,
                hiddenCount: hiddenCount,
                exactDuplicateHidden: exactDuplicateHidden,
                nearDuplicateOrSameMoment: nearDuplicateOrSameMoment,
                technicalHidden: technicalHidden,
                belowCutHidden: belowCutHidden,
                groupCount: groupCount,
                exactGroupCount: exactGroupCount,
                burstGroupCount: burstGroupCount,
                reductionPercent: reductionPercent,
                reviewPerHundred: reviewPerHundred,
                analysisSeconds: analysisSeconds,
                totalSeconds: totalSeconds,
                summary: summary
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(payload).write(to: url, options: .atomic)
        }

        static func build(from result: PipelineResult, shootName: String, profile: ScoringProfile) -> Metrics {
            let decisions = result.shortlist.decisions
            let kept = decisions.filter { $0.bucket == .selected || $0.bucket == .protected }
            let alternates = decisions.filter { $0.bucket == .alternate }
            let review = decisions.filter { $0.bucket == .review }
            let hidden = decisions.filter { $0.bucket == .hidden }

            func hasReason(_ decision: SelectionDecision, _ needle: String) -> Bool {
                decision.reasons.contains { $0.localizedCaseInsensitiveContains(needle) }
            }

            let exactDup = decisions.filter { hasReason($0, "exact duplicate") }.count
            let nearDup = decisions.filter { hasReason($0, "near-duplicate") }.count
            let sameMoment = decisions.filter { hasReason($0, "same moment") }.count
            let belowCut = decisions.filter {
                hasReason($0, "weaker than") || hasReason($0, "just below")
            }.count
            let technicalHidden = hidden.filter { decision in
                !hasReason(decision, "exact duplicate")
                    && !hasReason(decision, "near-duplicate")
                    && !hasReason(decision, "same moment")
                    && !hasReason(decision, "weaker than")
                    && !hasReason(decision, "just below")
            }.count
            let exactGroups = result.grouping.groups.filter { $0.kind == .exactDuplicate }.count
            let burstGroups = result.grouping.groups.count - exactGroups
            let source = max(result.imported.count, 1)
            let reduction = (1.0 - Double(kept.count) / Double(source)) * 100
            let reviewRate = Double(review.count) * 100.0 / Double(source)

            let summary = String(
                format: "%@: %d → %d kept (%.0f%% culled), %d review, %d alternates, %d hidden · reasons: %d technical / %d exact dup / %d near-dup / %d same-moment / %d below cut · %.1fs",
                shootName,
                result.imported.count,
                kept.count,
                reduction,
                review.count,
                alternates.count,
                hidden.count,
                technicalHidden,
                exactDup,
                nearDup,
                sameMoment,
                belowCut,
                result.metrics.totalSeconds
            )

            var lines = [
                "# Cull eval — \(shootName)",
                "",
                summary,
                "",
                "## Settings",
                "",
                "- Profile: \(profile.mode.rawValue)",
                "- Cull: \(profile.aggressiveness.rawValue)",
                "- Target count: \(profile.targetCount)",
                "",
                "## Efficacy proxies",
                "",
                "| Metric | Value |",
                "| --- | --- |",
                "| Source photos | \(result.imported.count) |",
                "| Kept (selected+protected) | \(kept.count) |",
                "| Reduction | \(String(format: "%.1f", reduction))% |",
                "| Confirm / review queue | \(review.count) (\(String(format: "%.1f", reviewRate))/100) |",
                "| Alternates | \(alternates.count) |",
                "| Hidden | \(hidden.count) |",
                "| Hidden — technical | \(technicalHidden) |",
                "| Exact duplicate (any bucket) | \(exactDup) |",
                "| Near-duplicate alternate | \(nearDup) |",
                "| Same-moment alternate | \(sameMoment) |",
                "| Below cut | \(belowCut) |",
                "| Moment groups | \(burstGroups) |",
                "| Exact-copy groups | \(exactGroups) |",
                "| Analysis time | \(String(format: "%.1f", result.metrics.analysisSeconds))s |",
                "| Total time | \(String(format: "%.1f", result.metrics.totalSeconds))s |",
                "",
                "## How to judge",
                "",
                "1. Open `eval-kept.jpg` — are these the frames you'd deliver?",
                "2. Open `eval-hidden-sample.jpg` — any irreplaceable moment only here? That is a fail.",
                "3. Open `eval-review.jpg` — should be genuine close calls, not obvious trash or obvious keeps.",
                "4. Prefer zero catastrophic misses over a tighter shortlist.",
                "",
                "## Top kept",
                ""
            ]
            for decision in kept.sorted(by: { ($0.rank ?? 999) < ($1.rank ?? 999) }).prefix(25) {
                if let photo = result.analyzed.first(where: { $0.id == decision.photoID }) {
                    lines.append("- \(photo.asset.url.lastPathComponent) score=\(String(format: "%.3f", decision.score)) — \(decision.reasons.prefix(2).joined(separator: "; "))")
                }
            }
            lines.append("")
            lines.append("## Hidden sample (highest score among hidden)")
            lines.append("")
            for decision in hidden.sorted(by: { $0.score > $1.score }).prefix(25) {
                if let photo = result.analyzed.first(where: { $0.id == decision.photoID }) {
                    lines.append("- \(photo.asset.url.lastPathComponent) score=\(String(format: "%.3f", decision.score)) — \(decision.reasons.prefix(2).joined(separator: "; "))")
                }
            }
            lines.append("")

            return Metrics(
                shootName: shootName,
                profile: profile.mode.rawValue,
                cull: profile.aggressiveness.rawValue,
                sourceCount: result.imported.count,
                keptCount: kept.count,
                alternateCount: alternates.count,
                reviewCount: review.count,
                hiddenCount: hidden.count,
                exactDuplicateHidden: exactDup,
                nearDuplicateOrSameMoment: nearDup + sameMoment,
                technicalHidden: technicalHidden,
                belowCutHidden: belowCut,
                groupCount: result.grouping.groups.count,
                exactGroupCount: exactGroups,
                burstGroupCount: burstGroups,
                reductionPercent: reduction,
                reviewPerHundred: reviewRate,
                analysisSeconds: result.metrics.analysisSeconds,
                totalSeconds: result.metrics.totalSeconds,
                summary: summary,
                markdown: lines.joined(separator: "\n"),
                keptSample: Array(kept.sorted(by: { ($0.rank ?? 999) < ($1.rank ?? 999) }).prefix(24)),
                hiddenSample: Array(hidden.sorted(by: { $0.score > $1.score }).prefix(24)),
                reviewSample: Array(review.sorted(by: { $0.score > $1.score }).prefix(24))
            )
        }
    }
}
