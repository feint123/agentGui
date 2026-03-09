import Foundation

enum StoryContinuityWarningKind: String {
    case locationConflict
    case chapterRegression
    case resolvedForeshadowReuse
    case worldRuleConflict
}

struct StorySceneDraftInput {
    var chapterNumber: Int
    var sceneIndex: Int
    var title: String
    var summary: String
    var locationName: String
    var povCharacterName: String
    var characterNames: [String]
    var referencedForeshadowTags: [String]
    var text: String
}

struct StorySceneContinuitySnapshot {
    var chapterNumber: Int
    var sceneIndex: Int
    var locationName: String
    var summary: String
}

struct StoryContinuityWarning: Equatable {
    var kind: StoryContinuityWarningKind
    var message: String
}

final class StoryContinuityService {
    func evaluateSceneDraft(
        draft: StorySceneDraftInput,
        previousScene: StorySceneContinuitySnapshot?,
        activeCharacterCards: [StoryCharacterCard],
        worldRules: [StoryWorldRule],
        resolvedForeshadowTags: [String]
    ) -> [StoryContinuityWarning] {
        var warnings: [StoryContinuityWarning] = []

        if let previousScene,
           draft.chapterNumber < previousScene.chapterNumber ||
            (draft.chapterNumber == previousScene.chapterNumber && draft.sceneIndex <= previousScene.sceneIndex) {
            warnings.append(
                StoryContinuityWarning(
                    kind: .chapterRegression,
                    message: "当前场景顺序早于上一场景，可能发生时间回退。"
                )
            )
        }

        let activeNames = Set(draft.characterNames + [draft.povCharacterName]).filter { !$0.isEmpty }
        if !draft.locationName.isEmpty,
           activeCharacterCards.contains(where: {
               activeNames.contains($0.name) &&
               !$0.lastKnownLocation.isEmpty &&
               $0.lastKnownLocation != draft.locationName
           }) {
            warnings.append(
                StoryContinuityWarning(
                    kind: .locationConflict,
                    message: "角色最近位置与当前场景地点不一致，缺少过渡。"
                )
            )
        }

        let resolvedSet = Set(resolvedForeshadowTags)
        if draft.referencedForeshadowTags.contains(where: { resolvedSet.contains($0) }) {
            warnings.append(
                StoryContinuityWarning(
                    kind: .resolvedForeshadowReuse,
                    message: "当前草稿重新使用了已解决的伏笔标签。"
                )
            )
        }

        let draftText = [draft.summary, draft.text, draft.locationName, draft.title].joined(separator: " ")
        if worldRules.contains(where: { rule in
            let detail = rule.detail.lowercased()
            let strict = detail.contains("不得") || detail.contains("不能") || detail.contains("禁止") || detail.contains("forbidden") || detail.contains("must not")
            guard strict else { return false }
            let scopeHit = !rule.scope.isEmpty && draftText.contains(rule.scope)
            let titleHit = draftText.contains(rule.title)
            return scopeHit || titleHit
        }) {
            warnings.append(
                StoryContinuityWarning(
                    kind: .worldRuleConflict,
                    message: "当前草稿可能违反既有世界规则，请检查限制条件。"
                )
            )
        }

        return warnings
    }
}