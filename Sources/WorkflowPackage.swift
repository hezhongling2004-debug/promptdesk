import Darwin
import Foundation

func workflowError(_ message: String) -> NSError {
    NSError(domain: "PromptDesk.WorkflowPackage", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

func itemType(_ url: URL) throws -> FileAttributeType? {
    do {
        return try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
        return nil
    }
}

struct WorkflowPackage: Identifiable {
    let name: String
    let displayName: String
    let description: String
    let directory: URL
    let userInvocable: Bool
    var id: String { name }

    static func inspect(_ directory: URL) throws -> Self {
        let url = directory.appendingPathComponent("SKILL.md")
        guard try itemType(directory) == .typeDirectory, try itemType(url) == .typeRegular else {
            throw workflowError("请在技能文件夹第一层放置 SKILL.md。\n" + directory.path)
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let fields = try WorkflowFrontmatter.read(source, filename: url.path)
        guard let name = fields["name"], name.count <= 64,
              name.range(of: #"\A[a-z0-9]+(-[a-z0-9]+)*\z"#, options: .regularExpression) != nil else {
            throw workflowError("SKILL.md 的 name 需要使用小写英文、数字和单个短横线，最多 64 个字符。\n" + url.path)
        }
        guard let description = fields["description"],
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw workflowError("请在 SKILL.md 开头填写 description。\n" + url.path)
        }
        var userInvocable = true
        for key in ["user-invocable", "disable-model-invocation"] {
            guard let flag = fields[key]?.lowercased() else { continue }
            let enabled: Bool
            switch flag {
            case "true", "yes", "on", "1": enabled = true
            case "false", "no", "off", "0": enabled = false
            default: throw workflowError(key + " 需要填写布尔值（如 true 或 false）。\n" + url.path)
            }
            if key == "user-invocable" { userInvocable = enabled }
        }
        return Self(name: name, displayName: WorkflowNaming.title(in: directory) ?? name,
                    description: description, directory: directory, userInvocable: userInvocable)
    }

    static func validateTree(_ directory: URL) throws {
        guard try itemType(directory) == .typeDirectory else { throw workflowError("请选取普通文件夹。\n" + directory.path) }
        var directories = [directory]
        while let parent = directories.popLast() {
            for child in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
                switch try itemType(child) {
                case .typeDirectory: directories.append(child)
                case .typeRegular: break
                default: throw workflowError("技能包包含链接或特殊文件，请用实际文件替换后再导入。\n" + child.path)
                }
            }
        }
    }
}

/// Extract the scalar fields used by the catalog. Original YAML, including optional
/// tool-specific mappings and comments, stays in the file that is copied to each host.
private enum WorkflowFrontmatter {
    private static let keys: Set<String> = ["name", "description", "user-invocable", "disable-model-invocation"]

    static func read(_ source: String, filename: String) throws -> [String: String] {
        var text = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.first == "\u{feff}" { text.removeFirst() }
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" && lines[$0].first == "-" }) else {
            throw workflowError("SKILL.md 开头需要用两行 --- 包住 name 和 description。\n" + filename)
        }
        var result: [String: String] = [:]
        var index = 1
        while index < end {
            let line = lines[index]
            index += 1
            guard line.first?.isWhitespace == false, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard keys.contains(key) else { continue }
            guard result[key] == nil else { throw workflowError("SKILL.md 中重复定义了 " + key + "。\n" + filename) }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            var continuation: [String] = []
            while index < end && (lines[index].isEmpty || lines[index].first?.isWhitespace == true) {
                continuation.append(lines[index])
                index += 1
            }
            do { result[key] = try scalar(value, continuation: continuation) }
            catch { throw workflowError("无法读取 SKILL.md 的 " + key + "。请使用纯文本、引号文本或分行文本。\n" + filename) }
        }
        return result
    }

    private static func scalar(_ value: String, continuation: [String]) throws -> String {
        if value.first == "|" || value.first == ">" {
            let marker = value.prefix { !$0.isWhitespace }
            guard marker.range(of: #"^[|>][+-]?[1-9]?[+-]?$"#, options: .regularExpression) != nil else {
                throw workflowError("分行文本的格式无效")
            }
            let lines = continuation.map { $0.trimmingCharacters(in: .whitespaces) }
            return lines.joined(separator: value.first == ">" ? " " : "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let components = [value] + continuation.map { $0.trimmingCharacters(in: .whitespaces) }
        var joined = components.filter { !$0.isEmpty && !$0.hasPrefix("#") }.joined(separator: " ")
        if let quote = joined.first, quote == "\"" || quote == "'" {
            // Trailing YAML comments are accepted only after a closed quoted scalar.
            if let range = joined.range(of: #"(?<=["'])\s+#.*$"#, options: [.regularExpression, .backwards]) {
                let prefix = String(joined[..<range.lowerBound])
                if prefix.last == quote {
                    if quote == "\"", let decoded = try? JSONDecoder().decode(String.self, from: Data(prefix.utf8)) { return decoded }
                    if quote == "'", let single = singleQuoted(prefix) { return single }
                }
            }
            if quote == "\"" { return try JSONDecoder().decode(String.self, from: Data(joined.utf8)) }
            if let single = singleQuoted(joined) { return single }
            throw workflowError("引号不匹配")
        }
        if let comment = joined.range(of: #"\s+#.*$"#, options: .regularExpression) { joined.removeSubrange(comment) }
        let trimmed = joined.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, "[{!&*".contains(first) { throw workflowError("需要文本字段") }
        return trimmed
    }

    private static func singleQuoted(_ source: String) -> String? {
        guard source.count >= 2, source.first == "'", source.last == "'" else { return nil }
        let inner = source.dropFirst().dropLast()
        var output = ""
        var iterator = inner.makeIterator()
        while let character = iterator.next() {
            if character == "'", iterator.next() != "'" { return nil }
            output.append(character)
        }
        return output
    }
}

struct WorkflowPackageLibrary {
    let root: URL
    private var fm: FileManager { .default }

    /// Keyed by the imported manifest name, so importing a revised original
    /// package retains the user's name and resolves to the existing library item.
    private struct NameOverride: Codable {
        let name: String
        let displayName: String
    }
    private var namesURL: URL { root.appendingPathComponent(".workflow-names.json") }

    private func overrides() throws -> [String: NameOverride] {
        guard let kind = try itemType(namesURL) else { return [:] }
        guard kind == .typeRegular else { throw workflowError("技能名称索引无效。") }
        let records = try JSONDecoder().decode([String: NameOverride].self, from: Data(contentsOf: namesURL))
        var seen: Set<String> = []
        for (origin, record) in records {
            guard [origin, record.name].allSatisfy({ value in
                value.utf8.count <= 64 && value.range(of: #"\A[a-z0-9]+(?:-[a-z0-9]+)*\z"#, options: .regularExpression) != nil
            }), seen.insert(record.name).inserted else { throw workflowError("技能名称索引有重复或无效的调用名。") }
        }
        return records
    }

    private func writeOverrides(_ records: [String: NameOverride]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(records).write(to: namesURL, options: .atomic)
    }

    func checkRename(from oldSlug: String, to newSlug: String) throws {
        let records = try overrides()
        if let record = records[newSlug], record.name != oldSlug {
            throw workflowError("调用名 \(newSlug) 是另一项技能的原始名称。")
        }
    }

    func recordRename(from oldSlug: String, to newSlug: String, displayName: String) throws {
        try checkRename(from: oldSlug, to: newSlug)
        var records = try overrides()
        let origin = records.first { $0.value.name == oldSlug }?.key ?? oldSlug
        records[origin] = NameOverride(name: newSlug, displayName: displayName)
        try writeOverrides(records)
    }

    private func applying(_ records: [String: NameOverride], to source: WorkflowPackage) -> WorkflowPackage {
        guard let record = records[source.name] ?? records.values.first(where: { $0.name == source.name }) else { return source }
        return WorkflowPackage(name: record.name, displayName: record.displayName, description: source.description,
                               directory: source.directory, userInvocable: source.userInvocable)
    }

    func list() throws -> [WorkflowPackage] {
        guard let rootType = try itemType(root) else { return [] }
        guard rootType == .typeDirectory else { throw workflowError("工作流技能库目录无效。\n" + root.path) }
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        var result: [WorkflowPackage] = []
        for child in children where try itemType(child) == .typeDirectory {
            let package = try WorkflowPackage.inspect(child)
            guard package.name == child.lastPathComponent else { throw workflowError("库内技能的 name 与目录名不一致。\n" + child.path) }
            result.append(package)
        }
        return result.sorted { $0.name < $1.name }
    }

    func candidates(at url: URL) throws -> [WorkflowPackage] {
        guard try itemType(url) == .typeDirectory else { throw workflowError("请选择技能文件夹，或包含多个技能的上级文件夹。") }
        let folders: [URL]
        if try itemType(url.appendingPathComponent("SKILL.md")) != nil {
            folders = [url]
        } else {
            folders = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                .filter { child in
                    guard try itemType(child) == .typeDirectory else { return false }
                    return try itemType(child.appendingPathComponent("SKILL.md")) != nil
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        guard !folders.isEmpty else { throw workflowError("在所选目录及其直接子目录中均未找到 SKILL.md。") }
        let records = try overrides()
        var names: Set<String> = []
        return try folders.map { folder in
            let package = applying(records, to: try validateSource(folder))
            guard names.insert(package.name).inserted else { throw workflowError("所选目录中有多个技能使用同一名称 " + package.name + "。") }
            return package
        }
    }

    @discardableResult
    func store(_ candidate: WorkflowPackage, replace: Bool = false) throws -> WorkflowPackage {
        let source = try validateSource(candidate.directory)
        let effective = applying(try overrides(), to: source)
        guard effective.name == candidate.name, effective.displayName == candidate.displayName else {
            throw workflowError("技能名称已经改变，请重新选择。")
        }
        let sourceURL = source.directory.resolvingSymlinksInPath().standardizedFileURL
        let rootURL = root.resolvingSymlinksInPath().standardizedFileURL
        guard !rootURL.pathComponents.starts(with: sourceURL.pathComponents) else { throw workflowError("请选取仅包含该技能的文件夹。") }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard try itemType(root) == .typeDirectory else { throw workflowError("工作流技能库目录无效。") }
        let target = root.appendingPathComponent(effective.name, isDirectory: true)
        let existing = try itemType(target)
        if existing != nil {
            guard replace else { throw workflowError("库内已有同名技能 " + effective.name + "，请确认更新。") }
            guard existing == .typeDirectory, try WorkflowPackage.inspect(target).name == effective.name else {
                throw workflowError("库内同名目录与该技能不一致，已保留。")
            }
            guard target.resolvingSymlinksInPath().standardizedFileURL.pathComponents != sourceURL.pathComponents else {
                return try WorkflowPackage.inspect(target)
            }
        }
        let staged = root.appendingPathComponent(".import-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: source.directory, to: staged)
        let copied = try validateSource(staged)
        guard copied.name == source.name else { throw workflowError("复制过程中技能名称发生变化，请重新导入。") }
        if copied.name != effective.name || copied.displayName != effective.displayName {
            try WorkflowNaming.apply(displayName: effective.displayName, invocationName: effective.name, in: staged)
        }
        // Both directories are siblings on the same volume. Swap commits the complete
        // replacement atomically; EXCL never claims a package created by another import.
        let flags = existing == nil ? RENAME_EXCL : RENAME_SWAP
        guard renamex_np(staged.path, target.path, UInt32(flags)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return try WorkflowPackage.inspect(target)
    }

    func remove(_ package: WorkflowPackage) throws {
        let target = root.appendingPathComponent(package.name, isDirectory: true)
        guard try itemType(root) == .typeDirectory,
              target.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
              package.directory.standardizedFileURL.path == target.standardizedFileURL.path,
              try WorkflowPackage.inspect(target).name == package.name else { throw workflowError("未找到对应的库内技能。") }
        var records = try overrides()
        let origin = records.first { $0.value.name == package.name }?.key
        if let origin, let old = records.removeValue(forKey: origin) {
            try writeOverrides(records)
            do { try fm.trashItem(at: target, resultingItemURL: nil) }
            catch {
                records[origin] = old
                try writeOverrides(records)
                throw error
            }
        } else { try fm.trashItem(at: target, resultingItemURL: nil) }
    }

    private func validateSource(_ directory: URL) throws -> WorkflowPackage {
        try WorkflowPackage.validateTree(directory)
        if try itemType(directory.appendingPathComponent(".promptdesk-workflow-install.json")) != nil {
            throw workflowError("选择的是工作台已安装的副本，请从原技能文件夹导入。\n" + directory.path)
        }
        return try WorkflowPackage.inspect(directory)
    }
}
