import Darwin
import Foundation

private func renameError(_ message: String) -> NSError {
    NSError(domain: "PromptDesk.WorkflowRename", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private func entryExists(_ url: URL) throws -> Bool {
    var info = stat()
    if lstat(url.path, &info) == 0 { return true }
    if errno == ENOENT { return false }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
}

private struct RenameLocation {
    let old: URL
    let new: URL
    let stage: URL
    let oldDigest: String
    let installed: Bool
    let recognizesFlatFiles: Bool

    func check() throws {
        let current = installed
            ? try WorkflowDeployment.digestForRename(at: old, recognizesFlatFiles: recognizesFlatFiles)
            : try WorkflowDeployment.digest(old, installed: false)
        guard current == oldDigest else { throw renameError("改名期间文件已更改，请刷新后再试。\n" + old.path) }
        if old.path != new.path, try entryExists(new) { throw renameError("新调用名已被使用。\n" + new.path) }
        let flat = new.deletingLastPathComponent().appendingPathComponent(new.lastPathComponent + ".md")
        if recognizesFlatFiles, try entryExists(flat) { throw renameError("Harness 已有同名的单文件技能。\n" + flat.path) }
    }
}

private struct RenameStep {
    let from: URL
    let to: URL
    let swap: Bool

    func run(reverse: Bool = false) throws {
        let source = reverse ? to : from
        let destination = reverse ? from : to
        guard renamex_np(source.path, destination.path, UInt32(swap ? RENAME_SWAP : RENAME_EXCL)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
        }
    }
}

extension WorkflowPackageLibrary {
    @discardableResult
    func rename(_ package: WorkflowPackage, displayName: String, invocationName: String,
                targets: [(root: URL, recognizesFlatFiles: Bool)]) throws -> WorkflowPackage {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !displayName.contains(where: \.isNewline) else { throw renameError("请输入单行显示名称。") }
        guard invocationName.count <= 64,
              invocationName.range(of: #"\A[a-z0-9]+(-[a-z0-9]+)*\z"#, options: .regularExpression) != nil else {
            throw renameError("调用名请使用小写英文字母、数字和短横线，最长 64 个字符。")
        }
        let old = root.appendingPathComponent(package.name)
        guard old.standardizedFileURL.path == package.directory.standardizedFileURL.path,
              old.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path else {
            throw renameError("请选择工作台技能库中的技能。")
        }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw renameError("技能库正在改名，请稍后再试。") }
        let current = try WorkflowPackage.inspect(old)
        guard current.name == package.name, current.displayName == package.displayName else {
            throw renameError("技能名称已经改变，请刷新后再试。")
        }
        if invocationName == package.name && displayName == current.displayName { return current }
        try checkRename(from: package.name, to: invocationName)

        let manager = FileManager.default
        let stageName = ".promptdesk-rename-" + UUID().uuidString
        let source = RenameLocation(old: old, new: root.appendingPathComponent(invocationName),
                                    stage: root.appendingPathComponent(stageName),
                                    oldDigest: try WorkflowDeployment.digest(old, installed: false),
                                    installed: false, recognizesFlatFiles: false)
        try source.check()
        var locations = [RenameLocation]()
        let roots = Dictionary(grouping: targets, by: { $0.root.resolvingSymlinksInPath().standardizedFileURL.path })
        for (path, configurations) in roots.sorted(by: { $0.key < $1.key }) {
            let target = URL(fileURLWithPath: path, isDirectory: true)
            let folder = target.appendingPathComponent(package.name)
            let flat = configurations.contains { $0.recognizesFlatFiles }
            guard let digest = try WorkflowDeployment.digestForRename(at: folder, recognizesFlatFiles: flat) else { continue }
            let location = RenameLocation(old: folder, new: target.appendingPathComponent(invocationName),
                                          stage: target.appendingPathComponent(stageName), oldDigest: digest,
                                          installed: true, recognizesFlatFiles: flat)
            try location.check()
            locations.append(location)
        }
        // Stage all participants first. The source moves last; until commit its path
        // still refers to the old library package.
        var keepStages = false
        defer {
            if !keepStages {
                for location in locations + [source] { try? manager.removeItem(at: location.stage) }
            }
        }
        try manager.copyItem(at: source.old, to: source.stage)
        guard try WorkflowDeployment.digest(source.stage, installed: false) == source.oldDigest else {
            throw renameError("技能内容在复制期间发生变化，请重试。")
        }
        try WorkflowNaming.apply(displayName: displayName, invocationName: invocationName, in: source.stage)
        let staged = try WorkflowPackage.inspect(source.stage)
        guard staged.name == invocationName, staged.displayName == displayName else {
            throw renameError("无法核验改名后的技能文件。")
        }
        let desired = try WorkflowDeployment.digest(source.stage, installed: false)
        for location in locations {
            try WorkflowDeployment.prepareInstalledCopy(source: source.stage, desired: desired, stage: location.stage,
                                                       slug: invocationName, parent: location.old.deletingLastPathComponent())
        }

        var completed = [RenameStep]()
        do {
            for location in locations + [source] {
                try location.check()
                let same = location.new.path == location.old.path
                let steps = same
                    ? [RenameStep(from: location.stage, to: location.old, swap: true)]
                    : [RenameStep(from: location.stage, to: location.new, swap: false),
                       RenameStep(from: location.old, to: location.stage, swap: false)]
                for step in steps {
                    try step.run()
                    completed.append(step)
                }
                guard try WorkflowDeployment.digest(location.stage, installed: location.installed) == location.oldDigest else {
                    throw renameError("检测到并发修改，请刷新后重试。")
                }
            }
            let result = try WorkflowPackage.inspect(source.new)
            try recordRename(from: package.name, to: invocationName, displayName: displayName)
            return result
        } catch {
            let failure = error
            for step in completed.reversed() {
                do { try step.run(reverse: true) }
                catch {
                    keepStages = true
                    throw renameError("改名中断，部分位置需要恢复。已保留改名前后的文件。\n\(step.from.path)\n\(step.to.path)\n\(failure.localizedDescription)")
                }
            }
            throw failure
        }
    }
}
