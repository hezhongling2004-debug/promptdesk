import Foundation

func verifyWorkflowRename(in temporary: URL) throws {
    let files = FileManager.default
    let original = temporary.appendingPathComponent("course-plan-grill")
    try files.createDirectory(at: original.appendingPathComponent("agents"), withIntermediateDirectories: true)
    let manifest = "---\nname: course-plan-grill\ndescription: Review a plan.\n---\n\n# 审核流程\n保留原文。\n"
    let metadata = """
    interface:
      display_name: "课程方案拷问"
      short_description: "审核课程方案"
      default_prompt: "请使用 $course-plan-grill 审核课程方案。"
    policy:
      allow_implicit_invocation: false
    """
    let entry = original.appendingPathComponent("SKILL.md")
    let ui = original.appendingPathComponent("agents/openai.yaml")
    try Data(manifest.utf8).write(to: entry)
    try Data(metadata.utf8).write(to: ui)
    let library = WorkflowPackageLibrary(root: temporary.appendingPathComponent("library"))
    let imported = try library.store(WorkflowPackage.inspect(original))
    precondition(imported.displayName == "课程方案拷问")
    let codex = temporary.appendingPathComponent("codex/skills")
    let harness = temporary.appendingPathComponent("harness/skills")
    let targets = [(root: codex, recognizesFlatFiles: false), (root: harness, recognizesFlatFiles: true)]
    try WorkflowDeployment.install(source: imported.directory, slug: imported.name, root: codex)

    func expectRefusal(_ action: () throws -> Void) {
        do { try action(); preconditionFailure("unsafe rename unexpectedly succeeded") } catch {}
    }
    func status(_ package: WorkflowPackage, in root: URL) -> WorkflowDeployment.State {
        WorkflowDeployment.status(source: package.directory, slug: package.name, root: root,
                                  recognizesFlatFiles: root == harness)
    }
    let titled = try library.rename(imported, displayName: "课程方案评审", invocationName: imported.name, targets: targets)
    precondition(titled.displayName == "课程方案评审" && titled.name == imported.name)
    precondition(status(titled, in: codex) == .current && status(titled, in: harness) == .absent)
    let savedManifest = try String(contentsOf: titled.directory.appendingPathComponent("SKILL.md"), encoding: .utf8)
    precondition(savedManifest == manifest)

    try WorkflowDeployment.install(source: titled.directory, slug: titled.name, root: harness)
    let flat = harness.appendingPathComponent("other.md")
    try Data("既有技能".utf8).write(to: flat)
    expectRefusal { _ = try library.rename(titled, displayName: "评审", invocationName: "other", targets: targets) }
    precondition(status(titled, in: codex) == .current && status(titled, in: harness) == .current)
    precondition(!files.fileExists(atPath: codex.appendingPathComponent("other").path))
    expectRefusal { _ = try library.rename(titled, displayName: "评审", invocationName: "../x", targets: targets) }

    let renamed = try library.rename(titled, displayName: "课程方案评审", invocationName: "course-review", targets: targets)
    for target in targets {
        precondition(status(renamed, in: target.root) == .current)
        precondition(!files.fileExists(atPath: target.root.appendingPathComponent(titled.name).path))
        let folder = target.root.appendingPathComponent(renamed.name)
        let registered = try WorkflowPackage.inspect(folder)
        precondition(registered.name == "course-review" && registered.displayName == "课程方案评审")
        let yaml = try String(contentsOf: folder.appendingPathComponent("agents/openai.yaml"), encoding: .utf8)
        precondition(yaml.contains("$course-review") && !yaml.contains("$course-plan-grill"))
        precondition(yaml.contains("allow_implicit_invocation: false") && yaml.contains("审核课程方案"))
    }
    let restored = try WorkflowPackageLibrary(root: library.root).list()
    precondition(restored.count == 1 && restored.first?.name == renamed.name && restored.first?.displayName == renamed.displayName)
    let savedOriginal = try String(contentsOf: ui, encoding: .utf8)
    precondition(savedOriginal == metadata)
    let candidate = try library.candidates(at: original).first!
    precondition(candidate.name == renamed.name)
    let reimported = try library.store(candidate, replace: true)
    precondition(reimported.name == renamed.name && reimported.displayName == renamed.displayName)
    precondition(!files.fileExists(atPath: library.root.appendingPathComponent(imported.name).path))
    let changed = harness.appendingPathComponent(renamed.name + "/SKILL.md")
    try Data("工具中的外部编辑".utf8).write(to: changed)
    expectRefusal { _ = try library.rename(renamed, displayName: "新名称", invocationName: "final-review", targets: targets) }
    precondition(status(renamed, in: codex) == .current && status(renamed, in: harness) == .modified)
    print("PASS: display-only and command rename, managed targets, conflict protection, original files and restart persistence")
}
