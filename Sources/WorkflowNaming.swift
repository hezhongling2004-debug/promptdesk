import Foundation

/// Edit individual scalars so resizing a title does not reserialize the author's
/// workflow, comments, Codex policy, dependencies, or relative asset references.
enum WorkflowNaming {
    static func title(in directory: URL) -> String? {
        do {
            guard let url = try interfaceURL(directory), try itemType(url) == .typeRegular else { return nil }
            let file = try Lines(url)
            guard let section = try interface(in: file),
                  let field = try section.field("display_name", file) else { return nil }
            return try textValue(field.value, file: file, index: field.index)
        } catch { return nil }
    }

    static func apply(displayName: String, invocationName: String, in directory: URL) throws {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              displayName.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw workflowError("显示名称需要填写单行文字。")
        }
        guard invocationName.utf8.count <= 64,
              invocationName.range(of: #"\A[a-z0-9]+(?:-[a-z0-9]+)*\z"#, options: .regularExpression) != nil else {
            throw workflowError("调用名限 1–64 个小写英文字母、数字和短横线。")
        }
        try WorkflowPackage.validateTree(directory)
        let old = try WorkflowPackage.inspect(directory)
        let commandChanged = old.name != invocationName
        if !commandChanged && old.displayName == displayName { return }
        let manifest = directory.appendingPathComponent("SKILL.md")
        if commandChanged {
            var file = try Lines(manifest)
            guard let end = file.rows.indices.dropFirst().first(where: { file.rows[$0].text.hasPrefix("---") && file.rows[$0].text.trimmingCharacters(in: .whitespaces) == "---" }),
                  let row = (1..<end).first(where: { field(file.rows[$0].text, key: "name", indent: 0) != nil }),
                  let name = field(file.rows[row].text, key: "name", indent: 0) else {
                throw workflowError("无法定位 SKILL.md 的 name 字段。")
            }
            try replaceScalar(&file, index: row, field: name, newValue: invocationName)
            try file.write(to: manifest)
        }

        let agents = directory.appendingPathComponent("agents")
        let ui = agents.appendingPathComponent("openai.yaml")
        let existing = try interfaceURL(directory)
        var file = try existing.map { try Lines($0) } ?? Lines("")
        // Preserve any existing display model if the user only changes a call
        // name. If the old title was the implicit slug, pin that title explicitly.
        if let section = try interface(in: file) {
            if commandChanged, let prompt = try section.field("default_prompt", file) {
                let token = try NSRegularExpression(pattern: "\\$" + NSRegularExpression.escapedPattern(for: old.name) + "(?![A-Za-z0-9_-])")
                let last = file.endOfValue(at: prompt.index)
                for i in prompt.index..<last {
                    let row = file.rows[i].text
                    let literalLine = i > prompt.index && (prompt.value.hasPrefix("|") || prompt.value.hasPrefix(">"))
                    if !literalLine && row.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
                    let prefixSize = i == prompt.index ? prompt.prefix.count : 0
                    let prefix = String(row.prefix(prefixSize))
                    let raw = String(row.dropFirst(prefixSize))
                    let (body, comment) = literalLine ? (raw, "") : splitComment(raw)
                    let replaced = token.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body),
                                                                 withTemplate: NSRegularExpression.escapedTemplate(for: "$" + invocationName))
                    file.rows[i].text = prefix + replaced + comment
                }
            }
            if let title = try section.field("display_name", file) {
                if try textValue(title.value, file: file, index: title.index) != displayName {
                    try replaceScalar(&file, index: title.index, field: (title.prefix, title.value), newValue: displayName)
                }
            } else {
                let line = String(repeating: " ", count: section.indent) + "display_name: " + (try quote(displayName))
                file.insert([line], at: section.start + 1)
            }
        } else {
            let end = file.rows.firstIndex(where: { $0.text.trimmingCharacters(in: .whitespaces) == "..." }) ?? file.rows.count
            file.insert(["interface:", "  display_name: " + (try quote(displayName))], at: end)
        }
        if existing == nil { try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true) }
        try file.write(to: ui)
    }

    private static func interfaceURL(_ directory: URL) throws -> URL? {
        let agents = directory.appendingPathComponent("agents")
        guard let kind = try itemType(agents) else { return nil }
        guard kind == .typeDirectory else { throw workflowError("agents 需要是普通文件夹。") }
        let url = agents.appendingPathComponent("openai.yaml")
        guard let type = try itemType(url) else { return nil }
        guard type == .typeRegular else { throw workflowError("agents/openai.yaml 需要是普通文件。") }
        return url
    }

    private struct Row { var text: String; var ending: String }
    private struct Lines {
        var rows: [Row] = []
        var bom = ""
        init(_ url: URL) throws {
            let bytes = try Data(contentsOf: url)
            guard let input = String(data: bytes, encoding: .utf8) else {
                throw workflowError(url.lastPathComponent + " 需要使用 UTF-8 编码。")
            }
            self.init(input)
            if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bom = "\u{feff}" }
        }
        init(_ input: String) {
            let hasBOM = input.first == "\u{feff}"
            if hasBOM { bom = "\u{feff}" }
            let source = (hasBOM ? String(input.dropFirst()) : input) as NSString
            var index = 0
            while index < source.length {
                var end = 0, contentEnd = 0
                source.getLineStart(nil, end: &end, contentsEnd: &contentEnd, for: NSRange(location: index, length: 0))
                rows.append(Row(text: source.substring(with: NSRange(location: index, length: contentEnd-index)),
                                ending: source.substring(with: NSRange(location: contentEnd, length: end-contentEnd))))
                index = end
            }
        }
        mutating func insert(_ lines: [String], at index: Int) {
            let eol = rows.first(where: { !$0.ending.isEmpty })?.ending ?? "\n"
            if index > 0 && rows[index-1].ending.isEmpty { rows[index-1].ending = eol }
            rows.insert(contentsOf: lines.map { Row(text: $0, ending: eol) }, at: index)
        }
        func endOfValue(at index: Int) -> Int {
            let indent = rows[index].text.prefix(while: { $0 == " " }).count
            var end = index+1
            while end < rows.count {
                let row = rows[end].text
                if !row.trimmingCharacters(in: .whitespaces).isEmpty && row.prefix(while: { $0 == " " }).count <= indent { break }
                end += 1
            }
            return end
        }
        func write(to url: URL) throws {
            let output = Data((bom + rows.map { $0.text + $0.ending }.joined()).utf8)
            if try itemType(url) == .typeRegular {
                guard try Data(contentsOf: url) != output else { return }
                let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                try output.write(to: url, options: .atomic)
                if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
            } else { try output.write(to: url, options: .withoutOverwriting) }
        }
    }

    private struct Section {
        let start: Int, end: Int, indent: Int
        func field(_ key: String, _ file: Lines) throws -> (index: Int, prefix: String, value: String)? {
            var found: (Int, String, String)?
            for i in (start+1)..<end {
                guard let (prefix, value) = WorkflowNaming.field(file.rows[i].text, key: key, indent: indent) else { continue }
                guard found == nil else { throw workflowError("agents/openai.yaml 有重复的 " + key + " 字段。") }
                found = (i, prefix, value)
            }
            return found
        }
    }

    private static func interface(in file: Lines) throws -> Section? {
        var section: Section?
        for i in file.rows.indices {
            let row = file.rows[i].text
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            if !row.hasPrefix(" "), (trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || trimmed.hasPrefix("<<:") || trimmed.hasPrefix("- ")) {
                throw workflowError("此 openai.yaml 的界面配置需要先展开为分行的 YAML 字段。")
            }
            guard let (_, value) = field(row, key: "interface", indent: 0) else { continue }
            guard section == nil, splitComment(value).0.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw workflowError("请将 openai.yaml 的 interface 写成单独一行，并在下方缩进填写字段。")
            }
            var end = i+1, indents: [Int] = []
            while end < file.rows.count {
                let child = file.rows[end].text
                let trimmed = child.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                    let indent = child.prefix(while: { $0 == " " }).count
                    if indent == 0 { break }
                    indents.append(indent)
                }
                end += 1
            }
            section = Section(start: i, end: end, indent: indents.min() ?? 2)
        }
        return section
    }

    private static func field(_ row: String, key: String, indent: Int) -> (prefix: String, value: String)? {
        guard row.prefix(while: { $0 == " " }).count == indent, let colon = row.firstIndex(of: ":") else { return nil }
        let name = row[..<colon].trimmingCharacters(in: .whitespaces)
        guard [key, "\"" + key + "\"", "'" + key + "'"].contains(name) else { return nil }
        let after = row.index(after: colon)
        let valueStart = row[after...].firstIndex(where: { !$0.isWhitespace }) ?? row.endIndex
        return (String(row[..<valueStart]), String(row[valueStart...]))
    }

    private static func quote(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func splitComment(_ text: String) -> (String, String) {
        let quote = text.first == "\"" || text.first == "'" ? text.first : nil
        var inside = quote != nil, escaped = false, previousSpace = true
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "#" && previousSpace && !inside {
                let prefix = text[..<i]
                let core = prefix.reversed().drop(while: { $0.isWhitespace }).reversed()
                return (String(core), String(text.dropFirst(core.count)))
            }
            if i != text.startIndex && inside && !escaped && c == quote {
                let next = text.index(after: i)
                if c == "'", next < text.endIndex, text[next] == "'" { i = next }
                else { inside = false }
            }
            previousSpace = c.isWhitespace
            escaped = quote == "\"" && c == "\\" && !escaped
            i = text.index(after: i)
        }
        return (text, "")
    }

    private static func textValue(_ value: String, file: Lines, index: Int) throws -> String {
        let (body, _) = splitComment(value)
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        let continuation = file.rows[(index+1)..<file.endOfValue(at: index)].map { $0.text.trimmingCharacters(in: .whitespaces) }
        if trimmed.hasPrefix("|") || trimmed.hasPrefix(">") {
            return continuation.joined(separator: trimmed.first == "|" ? "\n" : " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let joined = ([trimmed] + continuation.filter { !$0.isEmpty && !$0.hasPrefix("#") }).joined(separator: " ")
        if joined.first == "\"" { return try JSONDecoder().decode(String.self, from: Data(joined.utf8)) }
        if joined.first == "'", joined.last == "'", joined.count >= 2 {
            return joined.dropFirst().dropLast().replacingOccurrences(of: "''", with: "'")
        }
        if let first = joined.first, "[{&*!".contains(first) { throw workflowError("显示名称需要使用文字字段。") }
        return joined
    }

    private static func replaceScalar(_ file: inout Lines, index: Int, field: (prefix: String, value: String), newValue: String) throws {
        let (body, comment) = splitComment(field.value)
        if let first = body.first, "[{&*!".contains(first) { throw workflowError("无法修改引用其他配置的名称字段。") }
        let end = file.endOfValue(at: index)
        // Blank lines and ordinary YAML comments between fields belong to the surrounding file.
        let block = body.hasPrefix("|") || body.hasPrefix(">")
        for i in ((index+1)..<end).reversed() {
            let next = file.rows[i].text.trimmingCharacters(in: .whitespaces)
            if !next.isEmpty && (block || !next.hasPrefix("#")) { file.rows.remove(at: i) }
        }
        let prefix = field.prefix.hasSuffix(":") ? field.prefix + " " : field.prefix
        file.rows[index].text = prefix + (try quote(newValue)) + (comment.hasPrefix("#") ? " " : "") + comment
    }
}
