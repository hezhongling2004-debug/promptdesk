import Foundation

enum ImportStatus {
    static let tools=["Codex","DeepSeek Harness","豆包工作"]
    static func root(_ tool: String)->URL { SkillInstaller.root(tool == "豆包工作" ? "Codex" : tool) }
    static func status(_ p: Prompt, tool:String, localRoot:URL? = nil)->String {
        let folder=(localRoot ?? root(tool)).appendingPathComponent(SkillInstaller.name(p))
        guard let data=try? Data(contentsOf:folder.appendingPathComponent(".promptdesk-owner.json")), let receipt=try? JSONDecoder().decode(SkillInstaller.Receipt.self,from:data), receipt.id==p.id,
              let skill=try? Data(contentsOf:folder.appendingPathComponent("SKILL.md")), let ui=try? Data(contentsOf:folder.appendingPathComponent("agents/openai.yaml")) else { return "未导入" }
        guard SkillInstaller.hash(skill)==receipt.skillHash && SkillInstaller.hash(ui)==receipt.uiHash else { return "外部已修改" }
        let expected=SkillInstaller.payload(p,originalName:tool != "DeepSeek Harness")
        return skill==expected.0 && ui==expected.1 ? "已导入" : "需要更新"
    }
}
