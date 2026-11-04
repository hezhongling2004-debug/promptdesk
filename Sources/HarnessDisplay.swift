import Foundation

enum HarnessDisplay {
    static func install(root: URL) throws {
        let fm = FileManager.default
        let profile = root.deletingLastPathComponent().appendingPathComponent("profiles/desktop")
        guard fm.fileExists(atPath:profile.appendingPathComponent("package.json").path) else { throw SkillInstaller.failure("未找到 Harness 桌面配置，技能已写入，但中文菜单适配尚未启用") }
        let plugin=profile.appendingPathComponent("node_modules/promptdesk-skill-labels")
        let marker=plugin.appendingPathComponent(".promptdesk-owner")
        if fm.fileExists(atPath:plugin.path) && (try? String(contentsOf:marker,encoding:.utf8)) != "promptdesk-labels-v1" { throw SkillInstaller.failure("中文菜单插件目录冲突，已保留原文件") }
        guard plugin.resolvingSymlinksInPath().standardizedFileURL == plugin.standardizedFileURL else { throw SkillInstaller.failure("中文菜单插件路径为链接，已跳过") }
        var labels:[String:String]=[:]
        for folder in (try? fm.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? [] {
            guard folder.lastPathComponent.hasPrefix("promptdesk-"), fm.fileExists(atPath:folder.appendingPathComponent(".promptdesk-owner.json").path),
                  let yaml=try? String(contentsOf:folder.appendingPathComponent("agents/openai.yaml"),encoding:.utf8),
                  let line=yaml.components(separatedBy:"\n").first(where:{$0.trimmingCharacters(in:.whitespaces).hasPrefix("display_name:")}),
                  let colon=line.firstIndex(of:":"),
                  let title=try? JSONDecoder().decode(String.self,from:Data(line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces).utf8)) else { continue }
            labels[folder.lastPathComponent]=title
        }
        guard let templateURL=Bundle.main.url(forResource:"harness-labels",withExtension:"cjs") else { throw SkillInstaller.failure("中文菜单模板缺失") }
        let template=try String(contentsOf:templateURL,encoding:.utf8)
        let json=String(data:try JSONEncoder().encode(labels),encoding:.utf8)!
        try fm.createDirectory(at:plugin,withIntermediateDirectories:true)
        try "promptdesk-labels-v1".write(to:marker,atomically:true,encoding:.utf8)
        let package:[String:Any] = ["name":"promptdesk-skill-labels","version":"1.0.0","type":"module","main":"index.mjs","exports":[".":"./index.mjs","./client":"./client.cjs","./package.json":"./package.json"],"dsh":["client":["platform":"web","inject":["@deepseek-ai/dsh-client-ui-input-trigger","@deepseek-ai/dsh-client-ui-skill"]]]]
        try JSONSerialization.data(withJSONObject:package,options:.prettyPrinted).write(to:plugin.appendingPathComponent("package.json"),options:.atomic)
        try "export const name='promptdesk-skill-labels'; export function apply() {}".write(to:plugin.appendingPathComponent("index.mjs"),atomically:true,encoding:.utf8)
        try template.replacingOccurrences(of:"__PROMPTDESK_LABELS__",with:json).write(to:plugin.appendingPathComponent("client.cjs"),atomically:true,encoding:.utf8)
        let config=profile.appendingPathComponent("cordis.patch.yml")
        let text=fm.fileExists(atPath:config.path) ? try String(contentsOf:config,encoding:.utf8) : ""
        if !text.contains("promptdesk-skill-labels") {
            let backup=profile.appendingPathComponent(".promptdesk-backups/"+UUID().uuidString+".yml")
            try fm.createDirectory(at:backup.deletingLastPathComponent(),withIntermediateDirectories:true)
            try text.write(to:backup,atomically:true,encoding:.utf8)
            try (text+"\n# PromptDesk: Chinese skill labels; remove this row to disable.\n- insert:\n    - id: promptdesk-skill-labels\n      name: promptdesk-skill-labels\n").write(to:config,atomically:true,encoding:.utf8)
        }
    }
}
