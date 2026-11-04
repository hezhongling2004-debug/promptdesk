import AppKit
import Foundation
import SwiftUI

struct UsageSnapshot: Decodable {
    var counts: [String:[String:Int]] = [:]
    var last: [String:Double] = [:]
    var status: [String:String] = [:]
    var updated: Double = 0
}

final class UsageMonitor: ObservableObject {
    @Published var snapshot = UsageSnapshot()
    @Published var busy = false
    @Published var error = ""
    private let store: URL
    init(store: URL = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("PromptDesk/usage.sqlite")) { self.store=store }
    func total(_ p:Prompt)->Int { snapshot.counts[p.id.uuidString.lowercased(),default:[:]].values.reduce(0,+) }
    func last(_ p:Prompt)->Double { snapshot.last[p.id.uuidString.lowercased(),default:0] }
    func refresh(_ prompts:[Prompt]) {
        guard !busy else { return }
        guard let script=Bundle.main.url(forResource:"usage-scan",withExtension:"py") else { error="缺少调用统计组件"; return }
        let candidates=["/opt/homebrew/bin/python3","/usr/local/bin/python3","/Library/Developer/CommandLineTools/usr/bin/python3","/Applications/Xcode.app/Contents/Developer/usr/bin/python3"]
        guard let python=candidates.first(where:{FileManager.default.isExecutableFile(atPath:$0)}) else {
            error="调用统计需要 Python 3（可选功能）；提示词编辑、预览和导入不受影响。"
            snapshot.status=Dictionary(uniqueKeysWithValues:ImportStatus.tools.map { ($0,"统计未启用：未找到 Python 3") })
            return
        }
        busy=true
        let store=self.store
        DispatchQueue.global(qos:.utility).async {
            do {
                let process=Process(); process.executableURL=URL(fileURLWithPath:python); process.arguments=[script.path]
                let input=Pipe(), output=Pipe(), errors=Pipe(); process.standardInput=input; process.standardOutput=output; process.standardError=errors
                let request:[String:Any] = ["store":store.path,"prompts":prompts.map { ["id":$0.id.uuidString,"title":$0.title] }]
                let data=try JSONSerialization.data(withJSONObject:request)
                try process.run()
                input.fileHandleForWriting.write(data); try input.fileHandleForWriting.close()
                let response=output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus==0 else { throw NSError(domain:"Usage",code:1) }
                let snapshot=try JSONDecoder().decode(UsageSnapshot.self,from:response)
                DispatchQueue.main.async { self.snapshot=snapshot; self.error=""; self.busy=false }
            } catch {
                DispatchQueue.main.async { self.error="调用记录读取失败，已有累计保留。"; self.busy=false }
            }
        }
    }
}

struct UsageDetails: View {
    @ObservedObject var usage:UsageMonitor
    @ObservedObject var library:Library
    let prompt:Prompt?
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(prompt.map { "「\($0.title)」调用统计" } ?? "调用统计").font(.title2.bold()).fixedSize(horizontal:false,vertical:true)
            Text("已记录调用 \(prompt.map { usage.total($0) } ?? library.items.reduce(0) { $0+usage.total($1) }) 次").font(.headline)
            ForEach(ImportStatus.tools,id:\.self) { tool in
                HStack(alignment:.top) {
                    Text(tool).frame(width:145,alignment:.leading)
                    VStack(alignment:.leading,spacing:4) {
                        if tool == "Codex" || tool == "DeepSeek Harness" {
                            let prompts=prompt.map { [$0] } ?? library.items
                            let count=prompts.reduce(0) { $0 + usage.snapshot.counts[$1.id.uuidString.lowercased(),default:[:]][tool,default:0] }
                            Text(usage.snapshot.updated == 0 ? "—" : "\(count) 次").monospacedDigit()
                        } else { Text("—").foregroundStyle(.secondary) }
                        Text(usage.snapshot.status[tool] ?? "等待读取记录").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("统计口径：本机记录中可核验的技能加载；同一轮对话中同一提示词去重记一次。复制、安装、打开列表不会计数，也不代表任务成功完成。未接入的软件不计入累计。").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Text("工作台运行时每 20 秒刷新，重新打开时补读仍保留的记录。累计保存在本地 usage.sqlite，记录被清理也不会扣减；提示词 JSON 备份不包含调用统计。").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if usage.snapshot.updated > 0 { Text("上次刷新：\(Date(timeIntervalSince1970:usage.snapshot.updated).formatted(date:.omitted,time:.standard))").font(.caption).foregroundStyle(.secondary) }
            if !usage.error.isEmpty { Text(usage.error).foregroundStyle(.red) }
            HStack { Button(usage.busy ? "正在读取…" : "刷新调用统计") { usage.refresh(library.items) }.disabled(usage.busy); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width:570)
    }
}
