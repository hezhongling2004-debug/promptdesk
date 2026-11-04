import Foundation
import CryptoKit

enum SkillInstaller {
    struct Receipt: Codable { var id: UUID; var skillHash: String; var uiHash: String }
    static func hash(_ data: Data) -> String { SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined() }
    static func quoted(_ string: String) -> String { String(data:try! JSONEncoder().encode(string),encoding:.utf8)! }
    static func name(_ p: Prompt) -> String { "promptdesk-" + p.id.uuidString.lowercased() }
    static func root(_ tool: String) -> URL {
        let env = ProcessInfo.processInfo.environment
        let key = tool == "Codex" ? "CODEX_HOME" : "DSH_HOME"
        let base = env[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath:$0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(tool == "Codex" ? ".codex" : ".dsh")
        return base.appendingPathComponent("skills")
    }
    static func payload(_ p: Prompt, originalName: Bool = false) -> (Data, Data) {
        let display=p.title.replacingOccurrences(of:"\n",with:" ")
        let invocation=originalName ? display : name(p)
        let description="用于「\(display)」（\(p.category)）。仅当用户请求这一任务或明确选择本提示词时使用。"
        let skill=Data(("---\nname: \(quoted(invocation))\ndescription: \(quoted(description))\n---\n\n# \(display)\n\n"+p.body+"\n").utf8)
        let ui=Data("interface:\n  display_name: \(quoted(display))\n  short_description: \(quoted(String(description.prefix(64))))\n  default_prompt: \(quoted("请使用 $"+invocation+" 完成任务："+display))\n".utf8)
        return (skill,ui)
    }
    static func install(_ p: Prompt, root: URL, originalName: Bool = false) throws -> Bool {
        let fm=FileManager.default
        let folder=root.resolvingSymlinksInPath().appendingPathComponent(name(p))
        // Never follow a foreign symlink or claim ownership of an existing skill.
        if fm.fileExists(atPath:folder.path) && folder.resolvingSymlinksInPath().standardizedFileURL != folder.standardizedFileURL {
            throw failure("目标文件夹是链接，已跳过")
        }
        let receiptURL=folder.appendingPathComponent(".promptdesk-owner.json")
        let skillURL=folder.appendingPathComponent("SKILL.md")
        let agents=folder.appendingPathComponent("agents")
        let uiURL=agents.appendingPathComponent("openai.yaml")
        let (skill,ui)=payload(p,originalName:originalName)
        if fm.fileExists(atPath:folder.path) {
            for url in [receiptURL,skillURL,agents,uiURL] where url.resolvingSymlinksInPath().standardizedFileURL != url.standardizedFileURL { throw failure("目标文件存在链接，已跳过") }
            guard let data=try? Data(contentsOf:receiptURL), let old=try? JSONDecoder().decode(Receipt.self,from:data), old.id==p.id else { throw failure("同名目录不属于工作台，已保留") }
            let priorSkill=try Data(contentsOf:skillURL); let priorUI=try Data(contentsOf:uiURL)
            guard hash(priorSkill)==old.skillHash && hash(priorUI)==old.uiHash else { throw failure("技能已在外部修改，已保留；请在工作台创建副本后安装") }
            if skill==priorSkill && ui==priorUI { return false }
        }
        try fm.createDirectory(at:folder.deletingLastPathComponent(),withIntermediateDirectories:true)
        let staged=folder.deletingLastPathComponent().appendingPathComponent(".promptdesk-stage-"+UUID().uuidString)
        let parked=folder.deletingLastPathComponent().appendingPathComponent(".promptdesk-previous-"+UUID().uuidString)
        defer { try? fm.removeItem(at:staged) }
        let existing=fm.fileExists(atPath:folder.path)
        if existing {
            try fm.copyItem(at:folder,to:staged)
            let backup=staged.appendingPathComponent(".promptdesk-backups/"+UUID().uuidString)
            try fm.createDirectory(at:backup,withIntermediateDirectories:true)
            try Data(contentsOf:skillURL).write(to:backup.appendingPathComponent("SKILL.md"))
            try Data(contentsOf:uiURL).write(to:backup.appendingPathComponent("openai.yaml"))
        } else { try fm.createDirectory(at:staged,withIntermediateDirectories:true) }
        try fm.createDirectory(at:staged.appendingPathComponent("agents"),withIntermediateDirectories:true)
        try skill.write(to:staged.appendingPathComponent("SKILL.md"),options:.atomic)
        try ui.write(to:staged.appendingPathComponent("agents/openai.yaml"),options:.atomic)
        let receipt=Receipt(id:p.id,skillHash:hash(skill),uiHash:hash(ui))
        try JSONEncoder().encode(receipt).write(to:staged.appendingPathComponent(".promptdesk-owner.json"),options:.atomic)
        if existing { try fm.moveItem(at:folder,to:parked) }
        do { try fm.moveItem(at:staged,to:folder) }
        catch { if existing { try? fm.moveItem(at:parked,to:folder) }; throw error }
        if existing { try? fm.removeItem(at:parked) }
        return true
    }
    struct Removal { let source:URL; let backup:URL }
    static func removalPlan(_ p:Prompt, roots:[URL], backupRoot:URL) throws -> [Removal] {
        let fm=FileManager.default
        var seen=Set<String>(); var plan:[Removal]=[]
        for root in roots {
            let folder=root.resolvingSymlinksInPath().appendingPathComponent(name(p))
            guard seen.insert(folder.path).inserted else { continue }
            guard fm.fileExists(atPath:folder.path) else { continue }
            guard folder.resolvingSymlinksInPath().standardizedFileURL==folder.standardizedFileURL,
                  let data=try? Data(contentsOf:folder.appendingPathComponent(".promptdesk-owner.json")),
                  let receipt=try? JSONDecoder().decode(Receipt.self,from:data), receipt.id==p.id else { throw failure("技能来源无法确认，已保留："+folder.path) }
            // Archive the whole owned folder, including external edits, without following links.
            plan.append(Removal(source:folder,backup:backupRoot.appendingPathComponent(UUID().uuidString).appendingPathComponent(name(p))))
        }
        return plan
    }
    static func detach(_ plan:[Removal]) throws {
        var moved:[Removal]=[]
        do {
            for entry in plan {
                try FileManager.default.createDirectory(at:entry.backup.deletingLastPathComponent(),withIntermediateDirectories:true)
                try FileManager.default.moveItem(at:entry.source,to:entry.backup); moved.append(entry)
            }
        } catch { restore(moved); throw error }
    }
    static func restore(_ plan:[Removal]) {
        for entry in plan.reversed() where FileManager.default.fileExists(atPath:entry.backup.path) && !FileManager.default.fileExists(atPath:entry.source.path) {
            try? FileManager.default.moveItem(at:entry.backup,to:entry.source)
        }
    }
    static func failure(_ message:String)->NSError { NSError(domain:"PromptDesk.Skill",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    static func migrateOwnedTitles(root:URL) throws {
        let fm=FileManager.default
        for folder in (try? fm.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? [] where folder.lastPathComponent.hasPrefix("promptdesk-") {
            let receiptURL=folder.appendingPathComponent(".promptdesk-owner.json")
            let skillURL=folder.appendingPathComponent("SKILL.md")
            let uiURL=folder.appendingPathComponent("agents/openai.yaml")
            guard folder.resolvingSymlinksInPath().standardizedFileURL==folder.standardizedFileURL,
                  let receiptData=try? Data(contentsOf:receiptURL), var receipt=try? JSONDecoder().decode(Receipt.self,from:receiptData),
                  let skill=try? Data(contentsOf:skillURL),let ui=try? Data(contentsOf:uiURL),hash(skill)==receipt.skillHash,hash(ui)==receipt.uiHash,
                  let yaml=String(data:ui,encoding:.utf8),let line=yaml.components(separatedBy:"\n").first(where:{$0.trimmingCharacters(in:.whitespaces).hasPrefix("display_name:")}),let colon=line.firstIndex(of:":"),
                  let title=try? JSONDecoder().decode(String.self,from:Data(line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces).utf8)),
                  var text=String(data:skill,encoding:.utf8) else { continue }
            let lines=text.components(separatedBy:"\n")
            guard let index=lines.prefix(8).firstIndex(where:{$0.hasPrefix("name:")}),lines[index] != "name: "+quoted(title) else { continue }
            var updated=lines; updated[index]="name: "+quoted(title); text=updated.joined(separator:"\n")
            let backup=folder.appendingPathComponent(".promptdesk-backups/"+UUID().uuidString)
            try fm.createDirectory(at:backup,withIntermediateDirectories:true);try skill.write(to:backup.appendingPathComponent("SKILL.md"))
            let data=Data(text.utf8);try data.write(to:skillURL,options:.atomic);receipt.skillHash=hash(data)
            try JSONEncoder().encode(receipt).write(to:receiptURL,options:.atomic)
        }
    }
}
