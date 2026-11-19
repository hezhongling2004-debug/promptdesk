import Foundation
import CryptoKit
import Darwin

/// Synchronizes complete workflow folders, including nested resources and executable modes.
enum WorkflowDeployment {
    enum State: Equatable { case absent, current, outdated, modified, conflict, unavailable }

    private struct Receipt: Codable {
        let slug: String
        let rootDevice: dev_t
        let rootInode: ino_t
        let digest: String
    }

    private static let marker = ".promptdesk-workflow-install.json"
    private static let fm = FileManager.default

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "PromptDesk.WorkflowDeployment", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func target(_ slug: String, in root: URL) throws -> URL {
        guard slug.range(of: #"\A[a-z0-9]+(?:-[a-z0-9]+)*\z"#, options: .regularExpression) != nil else {
            throw failure("技能调用名需由小写英文字母、数字和短横线组成。")
        }
        return root.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(slug)
    }

    private static func statEntry(_ url: URL) throws -> stat? {
        var info = Darwin.stat()
        if lstat(url.path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    /// Digest of deterministic, length-delimited paths, types, modes and regular-file bytes.
    /// Each component is checked with lstat before descending so a linked script is never copied as a managed resource.
    static func digest(_ folder: URL, installed: Bool) throws -> String {
        var hasher = SHA256()
        func field(_ string: String) {
            hasher.update(data: Data(string.utf8))
            hasher.update(data: Data([0])) // POSIX path components cannot include NUL.
        }
        func walk(_ url: URL, relative: String) throws {
            guard let info = try statEntry(url) else { throw failure("文件已移动：" + url.path) }
            field(relative)
            field(String(info.st_mode))
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                let children = try fm.contentsOfDirectory(atPath: url.path).sorted()
                for child in children {
                    let childURL = url.appendingPathComponent(child)
                    if child == ".DS_Store", let metadata = try statEntry(childURL),
                       metadata.st_mode & S_IFMT == S_IFREG { continue }
                    if relative.isEmpty && child == marker {
                        if installed { continue }
                        throw failure("技能来源包含工作台的安装凭证，请选择原始技能文件夹。")
                    }
                    try walk(childURL, relative: relative.isEmpty ? child : relative + "/" + child)
                }
            case S_IFREG where !relative.isEmpty:
                field(String(info.st_size))
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                    hasher.update(data: chunk)
                }
            default:
                throw failure("技能包中有链接或特殊文件：" + url.path)
            }
        }
        guard let entry = try statEntry(folder.appendingPathComponent("SKILL.md")),
              entry.st_mode & S_IFMT == S_IFREG else {
            throw failure("技能文件夹缺少普通文件 SKILL.md。")
        }
        try walk(folder, relative: "")
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func ownedReceipt(at destination: URL) throws -> Receipt? {
        guard let info = try statEntry(destination), info.st_mode & S_IFMT == S_IFDIR else { return nil }
        let url = destination.appendingPathComponent(marker)
        guard let entry = try statEntry(url), entry.st_mode & S_IFMT == S_IFREG, entry.st_size < 16384,
              let receipt = try? JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url)),
              let parent = try statEntry(destination.deletingLastPathComponent()),
              receipt.slug == destination.lastPathComponent,
              receipt.rootDevice == parent.st_dev, receipt.rootInode == parent.st_ino else { return nil }
        return receipt
    }

    static func status(source: URL, slug: String, root: URL, recognizesFlatFiles: Bool = false) -> State {
        do {
            let destination = try target(slug, in: root)
            let flatFile = destination.deletingLastPathComponent().appendingPathComponent(slug + ".md")
            if recognizesFlatFiles, try statEntry(flatFile) != nil { return .conflict }
            guard try statEntry(destination) != nil else { return .absent }
            guard let receipt = try ownedReceipt(at: destination) else { return .conflict }
            guard let actual = try? digest(destination, installed: true), actual == receipt.digest else { return .modified }
            return (try digest(source, installed: false)) == actual ? .current : .outdated
        } catch { return .unavailable }
    }

    private static func verifiedReceipt(_ destination: URL) throws -> Receipt {
        guard let receipt = try ownedReceipt(at: destination) else {
            throw failure("目标目录有其他来源的同名技能，已保留：" + destination.path)
        }
        guard let actual = try? digest(destination, installed: true), actual == receipt.digest else {
            throw failure("目标技能在工作台外被修改，已保留：" + destination.path)
        }
        return receipt
    }

    /// Only existing PromptDesk installations migrate when a library skill is renamed.
    static func digestForRename(at folder: URL, recognizesFlatFiles: Bool) throws -> String? {
        guard try ownedReceipt(at: folder) != nil else {
            if let entry = try statEntry(folder), entry.st_mode & S_IFMT == S_IFDIR,
               try statEntry(folder.appendingPathComponent(marker)) != nil {
                throw failure("无法核对技能的安装凭证：" + folder.path)
            }
            return nil
        }
        let flat = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".md")
        if recognizesFlatFiles, try statEntry(flat) != nil {
            throw failure("Harness 同时存在同名目录和单文件技能：" + folder.path)
        }
        return try verifiedReceipt(folder).digest
    }

    /// Prepare a complete sibling directory before it is made visible to an agent.
    static func prepareInstalledCopy(source: URL, desired: String, stage: URL, slug: String, parent: URL) throws {
        try fm.copyItem(at: source, to: stage)
        guard try digest(stage, installed: false) == desired,
              let copied = try statEntry(stage), let parentInfo = try statEntry(parent)
        else { throw failure("复制期间来源发生变化，请再次安装。") }
        let receipt = Receipt(slug: slug, rootDevice: parentInfo.st_dev, rootInode: parentInfo.st_ino, digest: desired)
        let fileMode = Int(copied.st_mode & 0o7777)
        try fm.setAttributes([.posixPermissions: fileMode | 0o700], ofItemAtPath: stage.path)
        try JSONEncoder().encode(receipt).write(to: stage.appendingPathComponent(marker), options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: fileMode], ofItemAtPath: stage.path)
    }

    static func install(source: URL, slug: String, root: URL, recognizesFlatFiles: Bool = false) throws {
        let destination = try target(slug, in: root)
        let flatFile = destination.deletingLastPathComponent().appendingPathComponent(slug + ".md")
        if recognizesFlatFiles, try statEntry(flatFile) != nil {
            throw failure("Harness 有同名的单文件技能，已保留：" + flatFile.path)
        }
        let parent = destination.deletingLastPathComponent()
        let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath().path
        guard destination.path != sourcePath, !destination.path.hasPrefix(sourcePath + "/"),
              !sourcePath.hasPrefix(destination.path + "/") else {
            throw failure("技能库和安装目录不能相互包含。")
        }
        let desired = try digest(source, installed: false)
        let exists = try statEntry(destination) != nil
        if exists, try verifiedReceipt(destination).digest == desired { return }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".promptdesk-stage-" + UUID().uuidString)
        defer { try? fm.removeItem(at: stage) }
        try prepareInstalledCopy(source: source, desired: desired, stage: stage, slug: slug, parent: parent)

        // A same-volume swap keeps the old installation available until the new one is complete.
        if exists { _ = try verifiedReceipt(destination) }
        let flag = exists ? RENAME_SWAP : RENAME_EXCL
        guard renamex_np(stage.path, destination.path, UInt32(flag)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func remove(slug: String, root: URL, backupRoot: URL? = nil) throws {
        let destination = try target(slug, in: root)
        guard try statEntry(destination) != nil else { return }
        _ = try verifiedReceipt(destination)
        let defaultBackup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PromptDesk/RemovedSkills")
        let archive = (backupRoot ?? defaultBackup).appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        try fm.moveItem(at: destination, to: archive.appendingPathComponent(slug))
    }
}
