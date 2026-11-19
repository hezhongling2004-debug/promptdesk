import Foundation

@main
enum WorkflowRoundTrip {
    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("workflow-test-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        try verifyWorkflowRename(in: temporary.appendingPathComponent("rename-suite"))

        let sources = temporary.appendingPathComponent("collection")
        try fm.createDirectory(at: sources, withIntermediateDirectories: false)
        let original = sources.appendingPathComponent("meeting-brief")
        try fm.copyItem(at: URL(fileURLWithPath: "Examples/meeting-brief"), to: original)
        let another = sources.appendingPathComponent("meeting-actions")
        try fm.copyItem(at: original, to: another)
        let manifest = another.appendingPathComponent("SKILL.md")
        try String(contentsOf: manifest, encoding: .utf8)
            .replacingOccurrences(of: "name: meeting-brief", with: "name: meeting-actions")
            .write(to: manifest, atomically: true, encoding: .utf8)
        let helper = original.appendingPathComponent("helper.sh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let library = WorkflowPackageLibrary(root: temporary.appendingPathComponent("library"))
        let candidates = try library.candidates(at: sources)
        precondition(Set(candidates.map(\.name)) == ["meeting-brief", "meeting-actions"])
        for candidate in candidates { _ = try library.store(candidate) }
        let items = try library.list()
        let item = items.first { $0.name == "meeting-brief" }!
        let roots = ["codex", "harness"].map { temporary.appendingPathComponent($0 + "/skills") }
        func state(_ root: URL) -> WorkflowDeployment.State {
            WorkflowDeployment.status(source: item.directory, slug: item.name, root: root,
                                      recognizesFlatFiles: root == roots[1])
        }
        func install(_ root: URL) throws {
            try WorkflowDeployment.install(source: item.directory, slug: item.name, root: root,
                                           recognizesFlatFiles: root == roots[1])
        }
        for root in roots {
            precondition(state(root) == .absent)
            try install(root)
            let copy = root.appendingPathComponent(item.name)
            precondition(state(root) == .current)
            precondition(fm.contentsEqual(atPath: original.appendingPathComponent("SKILL.md").path,
                                          andPath: copy.appendingPathComponent("SKILL.md").path))
            precondition(fm.isExecutableFile(atPath: copy.appendingPathComponent("helper.sh").path))
        }
        let template = "assets/brief.md"
        let updated = Data("新版模板".utf8)
        try updated.write(to: original.appendingPathComponent(template))
        let revision = try library.candidates(at: original)
        _ = try library.store(revision[0], replace: true)
        for root in roots {
            precondition(state(root) == .outdated)
            try install(root)
            let data = try Data(contentsOf: root.appendingPathComponent(item.name).appendingPathComponent(template))
            precondition(data == updated)
        }
        let editedFile = roots[0].appendingPathComponent(item.name).appendingPathComponent(template)
        try Data("外部编辑".utf8).write(to: editedFile)
        precondition(state(roots[0]) == .modified)
        do { try install(roots[0]); preconditionFailure("external changes overwritten") } catch {}
        try WorkflowDeployment.remove(slug: item.name, root: roots[1], backupRoot: temporary.appendingPathComponent("backups"))
        precondition(state(roots[1]) == .absent && fm.fileExists(atPath: original.path))
        let flat = roots[1].appendingPathComponent(item.name + ".md")
        try fm.copyItem(at: original.appendingPathComponent("SKILL.md"), to: flat)
        precondition(state(roots[1]) == .conflict)
        do { try install(roots[1]); preconditionFailure("shadowed a Harness flat skill") } catch {}
        try fm.removeItem(at: flat)
        let foreign = roots[1].appendingPathComponent(item.name)
        try fm.copyItem(at: original, to: foreign)
        precondition(state(roots[1]) == .conflict)
        do { try install(roots[1]); preconditionFailure("foreign skill overwritten") } catch {}
        try fm.createSymbolicLink(at: original.appendingPathComponent("external-link"), withDestinationURL: another)
        do {
            let unsafe = try library.candidates(at: original)
            _ = try library.store(unsafe[0], replace: true)
            preconditionFailure("linked files entered the library")
        } catch {}
        print("PASS: collection import, two-target install, executable resources, template update, external edits and removal")
    }
}
