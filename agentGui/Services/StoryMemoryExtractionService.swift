import Foundation

final class StoryMemoryExtractionService {
    func makeTimelineExtractionPrompt(scene: StorySceneRecord) -> String {
        """
        从以下场景中提取可写入剧情时间线的事件。返回时优先关注：章节号、场景号、事件标题、参与角色、地点、时间标记、伏笔标签。

        场景标题：\(scene.title)
        场景摘要：\(scene.summary)
        场景正文：\(scene.content)
        """
    }

    func makeCharacterStateExtractionPrompt(scene: StorySceneRecord) -> String {
        """
        从以下场景中提取角色状态更新。返回时优先关注：角色名、目标变化、关系变化、弧线阶段、最近出现章节、最近地点、说话风格变化。

        POV 角色：\(scene.povCharacterName)
        场景地点：\(scene.locationName)
        场景摘要：\(scene.summary)
        场景正文：\(scene.content)
        """
    }
}