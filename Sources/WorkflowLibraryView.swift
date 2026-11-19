import AppKit
import SwiftUI

private enum WorkflowTool: String, CaseIterable {
    case codex = "Codex"
    case harness = "DeepSeek Harness"

    var directory: URL { SkillInstaller.root(rawValue) }

    func status(of package: WorkflowPackage) -> WorkflowDeployment.State {
        WorkflowDeployment.status(source: package.directory, slug: package.name, root: directory,
                                  recognizesFlatFiles: self == .harness)
    }

    func installationURL(for package: WorkflowPackage) -> URL {
        let folder = directory.appendingPathComponent(package.name)
        if self == .harness && !FileManager.default.fileExists(atPath: folder.path) {
            return folder.appendingPathExtension("md")
        }
        return folder
    }

    func invocation(for package: WorkflowPackage, using slug: String) -> String? {
        switch self {
        case .codex: return "$" + slug
        case .harness: return package.userInvocable ? "/" + slug : nil
        }
    }
}

private extension WorkflowDeployment.State {
    var label: String {
        switch self {
        case .absent: return "未安装"
        case .current: return "已写入"
        case .outdated: return "有更新"
        case .modified: return "工具中的文件已修改"
        case .conflict: return "已有同名技能"
        case .unavailable: return "无法核验"
        }
    }
}

private struct WorkflowInspection {
    let name: String
    let states: [WorkflowTool: WorkflowDeployment.State]
    let paths: [String]
    let hasMorePaths: Bool

    static func load(_ package: WorkflowPackage) throws -> Self {
        let states = Dictionary(uniqueKeysWithValues: WorkflowTool.allCases.map { tool in
            (tool, tool.status(of: package))
        })
        let manager = FileManager.default
        var scanError: Error?
        guard let enumerator = manager.enumerator(at: package.directory, includingPropertiesForKeys: [.isDirectoryKey], options: [], errorHandler: { _, error in
            scanError = error
            return false
        }) else { throw CocoaError(.fileReadUnknown) }
        var paths: [String] = []
        var hasMore = false
        let prefix = package.directory.standardizedFileURL.path + "/"
        for case let child as URL in enumerator {
            if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { continue }
            if paths.count == 200 { hasMore = true; break }
            let path = child.standardizedFileURL.path
            if path.hasPrefix(prefix) { paths.append(String(path.dropFirst(prefix.count))) }
        }
        if let scanError { throw scanError }
        return Self(name: package.name, states: states, paths: paths.sorted(), hasMorePaths: hasMore)
    }
}

private struct WorkflowConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let actionLabel: String
    let destructive: Bool
    let action: () -> Void
}

struct WorkflowLibraryView: View {
    private enum NameField: Hashable { case title, slug }
    let root: URL
    @Environment(\.dismiss) private var dismiss
    @State private var packages: [WorkflowPackage] = []
    @State private var selection: String?
    @State private var inspection: WorkflowInspection?
    @State private var revision = 0
    @State private var busy = false
    @State private var message = ""
    @State private var failed = false
    @State private var confirmation: WorkflowConfirmation?
    @State private var renameTarget: String?
    @State private var titleDraft = ""
    @State private var slugDraft = ""
    @FocusState private var focusedName: NameField?

    init(root: URL) { self.root = root }

    private var library: WorkflowPackageLibrary { WorkflowPackageLibrary(root: root) }
    private var selected: WorkflowPackage? { packages.first { $0.name == selection } }
    private var backup: URL { root.deletingLastPathComponent().appendingPathComponent("RemovedSkills") }
    private var editingName: Bool { renameTarget != nil }
    private var titleInput: String { titleDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var slugInput: String { slugDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var draftIssue: String? {
        if titleInput.isEmpty { return "请填写显示名称。" }
        if slugInput.count > 64 || slugInput.range(of: #"\A[a-z0-9]+(-[a-z0-9]+)*\z"#, options: .regularExpression) == nil {
            return "调用名限 1–64 个字符，可用小写英文字母、数字和单个连接号。"
        }
        if packages.contains(where: { $0.name == slugInput && $0.name != renameTarget }) {
            return "工作台已有这个调用名，请换一个。"
        }
        return nil
    }

    private func visibleTitle(_ package: WorkflowPackage) -> String {
        renameTarget == package.name && !titleInput.isEmpty ? titleInput : package.displayName
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("工作流技能", systemImage: "folder").font(.title2.weight(.semibold))
                Spacer()
                Button("导入技能文件夹…", action: chooseFolder).disabled(busy || editingName)
            }.padding(18)
            Divider()
            HStack(spacing: 0) {
                List(packages, selection: $selection) { package in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(visibleTitle(package)).fontWeight(.medium).lineLimit(2)
                        Text(package.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.padding(.vertical, 4).tag(package.name)
                }
                .listStyle(.sidebar).frame(width: 202).disabled(busy || editingName)
                Divider()
                if let selected {
                    detail(selected)
                } else {
                    ContentUnavailableView {
                        Label("导入你的工作流", systemImage: "folder.badge.plus")
                    } description: {
                        Text("选择含 SKILL.md 的文件夹，或选择包含多个技能的上一级文件夹。")
                    }
                }
            }
            Divider()
            HStack {
                if busy { ProgressView().controlSize(.small) }
                ScrollView {
                    Text(message).font(.callout).foregroundStyle(failed ? Color.red : Color.secondary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: message.contains("\n") ? 65 : 23)
                if editingName, let package = selected {
                    Button("取消", action: cancelRename).keyboardShortcut(.cancelAction).disabled(busy)
                    Button("保存名称") { saveRename(package) }
                        .keyboardShortcut(.defaultAction).disabled(busy || draftIssue != nil)
                } else {
                    Button("刷新") { perform { try await reload() } }.disabled(busy)
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction).disabled(busy)
                }
            }.padding(14)
        }
        .frame(width: 804, height: 552)
        .interactiveDismissDisabled(busy || editingName)
        .onAppear { perform { try await reload() } }
        .task(id: "\(selection ?? "")-\(revision)") {
            inspection = nil
            guard let package = selected else { return }
            do {
                let result = try await Task.detached { try WorkflowInspection.load(package) }.value
                if !Task.isCancelled { inspection = result }
            } catch {
                if !Task.isCancelled { notify(error.localizedDescription, isError: true) }
            }
        }
        .alert(item: $confirmation) { item in
            let confirm: Alert.Button = item.destructive
                ? .destructive(Text(item.actionLabel), action: item.action)
                : .default(Text(item.actionLabel), action: item.action)
            return Alert(title: Text(item.title), message: Text(item.detail), primaryButton: confirm, secondaryButton: .cancel(Text("取消")))
        }
    }

    private func detail(_ package: WorkflowPackage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if renameTarget == package.name {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            Text("显示名称")
                            TextField("技能名称，可使用中文", text: $titleDraft)
                                .focused($focusedName, equals: .title)
                                .accessibilityLabel("显示名称")
                        }
                        GridRow {
                            Text("调用名")
                            TextField("course-plan-grill", text: $slugDraft)
                                .font(.system(.body, design: .monospaced))
                                .focused($focusedName, equals: .slug)
                                .accessibilityLabel("调用名")
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .disabled(busy)
                    .onSubmit { saveRename(package) }
                    .onAppear { focusedName = .title }
                    if let issue = draftIssue {
                        Text(issue).font(.callout).foregroundStyle(.red)
                    } else {
                        Text("保存后同步更新已安装的技能副本。").font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Text(package.displayName).font(.title3.bold()).textSelection(.enabled)
                        Spacer()
                        Button("重命名", systemImage: "pencil") { beginRename(package) }
                            .disabled(busy)
                    }
                }
                Text(package.description).foregroundStyle(.secondary).textSelection(.enabled)
                if let inspection, inspection.name == package.name {
                    Divider()
                    ForEach(WorkflowTool.allCases, id: \.self) { tool in
                        targetRow(tool, package, inspection.states[tool] ?? .unavailable)
                    }
                    Divider()
                    HStack {
                        Text("包内文件").font(.headline)
                        Spacer()
                        Button("在访达中查看") {
                            NSWorkspace.shared.activateFileViewerSelecting([package.directory])
                        }
                    }
                    ForEach(inspection.paths, id: \.self) { path in
                        Text(path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    }
                    if inspection.hasMorePaths { Text("更多文件可在访达中查看。").foregroundStyle(.secondary) }
                    Divider()
                    Button("从工作台移除…", role: .destructive) { requestLibraryRemoval(package) }
                        .disabled(busy || editingName)
                } else { ProgressView().controlSize(.small) }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func targetRow(_ tool: WorkflowTool, _ package: WorkflowPackage, _ state: WorkflowDeployment.State) -> some View {
        let preview = renameTarget == package.name
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(tool.rawValue).font(.headline)
                Text(preview ? "调用预览" : state.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !preview && (state == .absent || state == .outdated) {
                    Button(state == .absent ? "安装" : "更新") { deploy(package, to: tool) }
                }
                if !preview && (state == .current || state == .outdated) {
                    Button("移除…") { requestToolRemoval(package, tool) }
                } else if !preview && (state == .conflict || state == .modified) {
                    Button("在访达中定位") {
                        NSWorkspace.shared.activateFileViewerSelecting([tool.installationURL(for: package)])
                    }
                }
            }
            if let invocation = tool.invocation(for: package, using: preview ? slugInput : package.name) {
                HStack {
                    Text(invocation).font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("复制调用") {
                        NSPasteboard.general.clearContents()
                        let ok = NSPasteboard.general.setString(invocation, forType: .string)
                        notify(ok ? "已复制，可粘贴到 \(tool.rawValue) 的聊天框。" : "复制失败，请重试。", isError: !ok)
                    }.disabled(preview || (state != .current && state != .outdated))
                }
            } else {
                Text("技能作者已关闭 Harness 聊天框手动调用。").font(.callout).foregroundStyle(.secondary)
            }
        }.disabled(busy).help(tool.directory.path)
    }

    private func beginRename(_ package: WorkflowPackage) {
        titleDraft = package.displayName
        slugDraft = package.name
        renameTarget = package.name
        notify("")
    }

    private func cancelRename() {
        focusedName = nil
        renameTarget = nil
        notify("")
    }

    private func saveRename(_ package: WorkflowPackage) {
        guard renameTarget == package.name, !busy, draftIssue == nil else { return }
        let title = titleInput
        let slug = slugInput
        guard title != package.displayName || slug != package.name else { cancelRename(); return }
        let targets = WorkflowTool.allCases.map { (root: $0.directory, recognizesFlatFiles: $0 == .harness) }
        let library = self.library
        perform {
            let renamed = try await Task.detached {
                try library.rename(package, displayName: title, invocationName: slug, targets: targets)
            }.value
            if let index = packages.firstIndex(where: { $0.name == package.name }) {
                packages[index] = renamed
                packages.sort { $0.name < $1.name }
            }
            selection = renamed.name
            cancelRename()
            notify("已保存「\(renamed.displayName)」。")
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "导入"
        panel.message = "选择技能文件夹，或选择包含多个技能文件夹的上一级目录。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let library = self.library
        perform {
            let candidates = try await Task.detached { try library.candidates(at: url) }.value
            let known = Set(packages.map(\.name))
            let collisions = candidates.map(\.name).filter(known.contains)
            if collisions.isEmpty {
                try await store(candidates, replacing: [])
            } else {
                confirmation = WorkflowConfirmation(title: "更新库中的同名技能？",
                    detail: collisions.joined(separator: "、") + "\n安装过的工具可在详情中更新到这个版本。",
                    actionLabel: "导入并更新", destructive: false) {
                        perform { try await store(candidates, replacing: Set(collisions)) }
                    }
            }
        }
    }

    @MainActor private func store(_ candidates: [WorkflowPackage], replacing names: Set<String>) async throws {
        let library = self.library
        let result = await Task.detached {
            var stored: [String] = []
            var errors: [String] = []
            for candidate in candidates {
                do {
                    let item = try library.store(candidate, replace: names.contains(candidate.name))
                    stored.append(item.name)
                } catch { errors.append("\(candidate.name) · \(error.localizedDescription)") }
            }
            return (stored, errors)
        }.value
        try await reload(preferred: result.0.first)
        notify((["已导入 \(result.0.count) 个工作流技能。"] + result.1).joined(separator: "\n"), isError: !result.1.isEmpty)
    }

    private func deploy(_ package: WorkflowPackage, to tool: WorkflowTool) {
        perform {
            try await Task.detached {
                try WorkflowDeployment.install(source: package.directory, slug: package.name, root: tool.directory,
                                               recognizesFlatFiles: tool == .harness)
            }.value
            notify("技能已写入 \(tool.rawValue) 的技能目录。")
        }
    }

    private func requestToolRemoval(_ package: WorkflowPackage, _ tool: WorkflowTool) {
        let backup = self.backup
        confirmation = WorkflowConfirmation(title: "从 \(tool.rawValue) 移除 \(package.name)？",
            detail: "工作台会将工具中的技能副本备份到 RemovedSkills。", actionLabel: "移除", destructive: true) {
            perform {
                try await Task.detached {
                    try WorkflowDeployment.remove(slug: package.name, root: tool.directory, backupRoot: backup)
                }.value
                notify("已从 \(tool.rawValue) 移除技能。")
            }
        }
    }

    private func requestLibraryRemoval(_ package: WorkflowPackage) {
        let library = self.library
        confirmation = WorkflowConfirmation(title: "从工作台移除 \(package.name)？",
            detail: "技能库内的副本将移到废纸篓。已安装的副本需先从对应工具移除。", actionLabel: "移到废纸篓", destructive: true) {
            perform {
                try await Task.detached {
                    for tool in WorkflowTool.allCases {
                        let state = tool.status(of: package)
                        guard state == .absent || state == .conflict else {
                            throw SkillInstaller.failure("请先核对并移除 \(tool.rawValue) 中的工作台副本。")
                        }
                    }
                    try library.remove(package)
                }.value
                try await reload()
                notify("技能库内的副本已移到废纸篓。")
            }
        }
    }

    @MainActor private func reload(preferred: String? = nil) async throws {
        let library = self.library
        let result = try await Task.detached { try library.list() }.value
        packages = result
        let preferred = preferred ?? selection
        selection = result.first { $0.name == preferred }?.name ?? result.first?.name
    }

    private func notify(_ text: String, isError: Bool = false) {
        failed = isError
        message = text
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        notify("")
        Task { @MainActor in
            defer { busy = false; revision += 1 }
            do { try await operation() }
            catch { notify(error.localizedDescription, isError: true) }
        }
    }
}
