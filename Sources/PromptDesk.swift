import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct Prompt: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var category: String
    var tool: String
    var body: String
    var favorite = false
}

final class Library: ObservableObject {
    @Published var items: [Prompt] = []
    @Published var message = ""
    @Published var importRevision = 0
    @Published var categoryOrder: [String] = []
    private var orderWritable = true
    var orderURL: URL { url.deletingLastPathComponent().appendingPathComponent("category-order.json") }
    var categories: [String] {
        let current=Set(items.map(\.category))
        return categoryOrder.filter { current.contains($0) } + current.subtracting(categoryOrder).sorted()
    }
    func moveCategory(_ source:String, onto target:String) {
        var order=categories
        guard orderWritable, let from=order.firstIndex(of:source), let to=order.firstIndex(of:target), from != to else { return }
        order.remove(at:from); order.insert(source,at:to)
        do {
            try FileManager.default.createDirectory(at:orderURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            try JSONEncoder().encode(order).write(to:orderURL,options:.atomic)
            categoryOrder=order
        } catch { message="分类顺序保存失败，已保留原顺序。" }
    }
    let url: URL
    var writable = true
    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PromptDesk/prompts.json")
        if FileManager.default.fileExists(atPath: self.url.path) {
            do { items = try JSONDecoder().decode([Prompt].self, from: Data(contentsOf: self.url)) }
            catch { writable = false; message = "资料读取失败，原文件已保留。请通过“打开资料文件夹”检查，或导入有效备份。" }
        } else { items = Self.examples; persist() }
        if FileManager.default.fileExists(atPath:orderURL.path) {
            do {
                let saved=try JSONDecoder().decode([String].self,from:Data(contentsOf:orderURL))
                var seen=Set<String>(); categoryOrder=saved.filter { seen.insert($0).inserted }
            } catch { orderWritable=false; message="分类顺序读取失败，原文件已保留。" }
        }
    }
    static var examples: [Prompt] { [
        Prompt(title: "资料整理成文档", category: "文档整理", tool: "通用", body: "请根据我提供的文件整理资料。\n\n要求：\n1. 先核对资料是否完整，按人物或主题逐项整理。\n2. 保留原文中的关键事实、数字和姓名，不补编缺失信息。\n3. 用标题和段落呈现，图片放在对应内容下方。\n4. 完成后核对条目数量、图片与文字的对应关系。\n\n待处理资料：\n【在这里补充文件或任务】", favorite: true),
        Prompt(title: "修改前先确认范围", category: "开发协作", tool: "Codex", body: "请先阅读相关代码和项目说明，明确本次修改范围，然后完成实现。\n\n只修改实现本次需求所必需的内容。发现不相关的问题请单独说明。完成后运行与变更有关的检查，并告诉我实际改了什么、如何验证、还有哪些限制。\n\n我的需求：\n【填写需求】"),
        Prompt(title: "调研与来源核实", category: "研究分析", tool: "DeepSeek Harness", body: "请调研下面的主题，优先使用官方文档和原始资料。\n\n将已证实的事实、推断和仍不确定的问题区分清楚。注明信息日期，给出可直接打开的来源链接。最后列出可执行的建议。\n\n主题：\n【填写主题】"),
        Prompt(title: "润色中文表达", category: "文字写作", tool: "豆包工作", body: "请润色下面的文字，保持原意和事实不变。使用自然、清楚的中文，删去空话和重复表达。不要夸张，不要添加没有依据的信息。\n\n面向读者：【填写读者】\n使用场景：【填写场景】\n原文：\n【粘贴原文】")
    ] }
    @discardableResult func persist() -> Bool {
        guard writable else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(items).write(to: url, options: .atomic)
            return true
        } catch { message = "保存失败：\(error.localizedDescription)"; return false }
    }
    func put(_ p: Prompt) {
        let old = items
        if let i = items.firstIndex(where: {$0.id == p.id}) { items[i] = p } else { items.insert(p, at: 0) }
        guard persist() else { items=old; return }
        if let prior=old.first(where:{$0.id==p.id}), prior.title != p.title || prior.category != p.category || prior.body != p.body {
            let targets=["Codex","DeepSeek Harness"].filter { ImportStatus.status(prior,tool:$0) != "未导入" }
            if !targets.isEmpty { installSkills([p],tools:targets) }
        }
        importRevision += 1
    }
    var removedRoot:URL { url.deletingLastPathComponent().appendingPathComponent("RemovedSkills") }
    func uninstall(_ p:Prompt, tools:[String], deleting:Bool=false) {
        guard writable else { message="资料处于只读保护状态，未移除技能。"; return }
        do {
            let plan=try SkillInstaller.removalPlan(p,roots:tools.map { ImportStatus.root($0) },backupRoot:removedRoot)
            try SkillInstaller.detach(plan)
            if deleting {
                let prior=items; items.removeAll {$0.id==p.id}
                if !persist() { items=prior; SkillInstaller.restore(plan); return }
            }
            importRevision += 1
            message=deleting ? "提示词及其本机技能已移除，可在资料文件夹的 RemovedSkills 中找回技能备份。" : "技能已从所选目录移除，本地提示词仍保留。"
        } catch { message="移除失败，提示词已保留：\(error.localizedDescription)" }
    }
    func delete(_ p:Prompt) { uninstall(p,tools:ImportStatus.tools,deleting:true) }
    func installLabel(_ p:Prompt)->String {
        let states=ImportStatus.tools.map { ImportStatus.status(p,tool:$0) }
        if states.contains("需要更新") { return "更新技能…" }
        if states.contains("外部已修改") { return "检查更新…" }
        return states.contains("已导入") ? "管理导入…" : "导入到工具…"
    }
    func copy(_ p: Prompt) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(p.body, forType: .string) { message = "已复制「\(p.title)」，切换到工具后按 ⌘V 粘贴。" }
        else { message = "复制失败，请重试。" }
    }
    func exportFile() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "提示词备份.json"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; try e.encode(items).write(to: dest, options: .atomic); message = "备份已导出。" }
        catch { message = "导出失败：\(error.localizedDescription)" }
    }
    func installSkills(_ prompts: [Prompt], tools: [String]) {
        var changed=0, unchanged=0; var errors:[String]=[]
        var installedRoots=Set<String>()
        for tool in tools {
            guard installedRoots.insert(ImportStatus.root(tool).standardizedFileURL.path).inserted else { continue }
            if tool != "DeepSeek Harness" {
                do { try SkillInstaller.migrateOwnedTitles(root:ImportStatus.root(tool)) }
                catch { errors.append("旧技能名称迁移：\(error.localizedDescription)") }
            }
            for p in prompts {
                do { if try SkillInstaller.install(p,root:ImportStatus.root(tool),originalName:tool != "DeepSeek Harness") { changed += 1 } else { unchanged += 1 } }
                catch { errors.append("\(tool) · \(p.title)：\(error.localizedDescription)") }
            }
            if tool == "DeepSeek Harness" {
                do { try HarnessDisplay.install(root:SkillInstaller.root(tool)) }
                catch { errors.append(error.localizedDescription) }
            }
        }
        importRevision += 1
        message="已更新 \(changed) 项，\(unchanged) 项无需更新。新建目标工具对话后使用。" + (errors.isEmpty ? "" : "\n需处理："+errors.joined(separator:"；"))
    }
    func importSummary(_ p: Prompt)->String {
        let _ = importRevision
        let installed=ImportStatus.tools.filter { ImportStatus.status(p,tool:$0).hasPrefix("已导入") }
        let pending=ImportStatus.tools.filter { ImportStatus.status(p,tool:$0)=="需要更新" }
        return (installed.isEmpty ? "尚未导入任何软件" : "已导入："+installed.joined(separator:"、")) + (pending.isEmpty ? "" : " · 待更新："+pending.joined(separator:"、"))
    }
    func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let incoming = try JSONDecoder().decode([Prompt].self, from: Data(contentsOf: source))
            guard incoming.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw NSError(domain: "PromptDesk", code: 1, userInfo: [NSLocalizedDescriptionKey:"备份包含空标题或空内容。"] ) }
            let old = items; var added = 0
            for p in incoming where !items.contains(where: {$0.id == p.id || ($0.title == p.title && $0.body == p.body)}) { items.append(p); added += 1 }
            if !writable { message = "原资料文件损坏，未覆盖。请先移走原文件并重新打开应用，再导入备份。"; items = old; return }
            if persist() { message = "已合并导入 \(added) 条提示词，现有条目已保留。" } else { items = old }
        } catch { message = "导入失败：\(error.localizedDescription)" }
    }
}

struct ImportDetails: View {
    @ObservedObject var library:Library
    let prompt:Prompt
    @Environment(\.dismiss) var dismiss
    @State private var removing:String?
    var live:Prompt { library.items.first(where:{$0.id==prompt.id}) ?? prompt }
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("导入管理").font(.title2.bold())
            Text(live.title).font(.headline)
            ForEach(ImportStatus.tools,id:\.self) { tool in
                HStack {
                    Text(tool).frame(width:145,alignment:.leading)
                    Text(ImportStatus.status(live,tool:tool)).foregroundStyle(.secondary)
                    Spacer()
                    Button("安装 / 更新") { library.installSkills([live],tools:[tool]) }
                    Button("移除",role:.destructive) { removing=tool }.disabled(ImportStatus.status(live,tool:tool)=="未导入")
                }.help(ImportStatus.root(tool).path)
            }
            Text("保存修改后自动更新已导入的技能；外部修改会保留并提示处理。Codex 与豆包共用技能目录，安装、更新或移除会同时影响两者。技能写入后，请在目标工具中新建对话；已打开的对话不会撤回历史内容。").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if !library.message.isEmpty { Text(library.message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
            HStack { Button("刷新状态") { library.importRevision += 1 }; Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width:690)
        .alert("从工具中移除技能？",isPresented:Binding(get:{removing != nil},set:{if !$0 {removing=nil}})) {
            Button("取消",role:.cancel) { removing=nil }
            Button("移除",role:.destructive) { if let tool=removing { library.uninstall(live,tools:[tool]) }; removing=nil }
        } message: { Text("本地提示词保留。技能文件会移出目标目录并备份。移除 Codex 或豆包技能会同时影响两者。已打开对话中的历史指令不会消失。") }
    }
}

struct Editor: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var library: Library
    @State var draft: Prompt
    var saved: (UUID) -> Void
    var valid: Bool { !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("编辑提示词").font(.title2.bold())
            TextField("标题（必填）", text: $draft.title).textFieldStyle(.roundedBorder)
            HStack {
                TextField("分类，如：文档整理", text: $draft.category).textFieldStyle(.roundedBorder)
            }
            Text("提示词正文").font(.headline)
            TextEditor(text: $draft.body).font(.system(size: 14)).padding(8).background(Color(nsColor: .textBackgroundColor)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            HStack {
                Toggle("收藏", isOn: $draft.favorite)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if draft.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft.category = "未分类" }
                    library.put(draft); if library.items.contains(draft) { saved(draft.id); dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(!valid || !library.writable)
            }
        }.padding(24).frame(width: 660, height: 560)
    }
}

struct CategoryFrames: PreferenceKey {
    static var defaultValue:[String:CGRect] = [:]
    static func reduce(value:inout [String:CGRect],nextValue:()->[String:CGRect]) { value.merge(nextValue(),uniquingKeysWith:{$1}) }
}

struct Workbench: View {
    @ObservedObject var library: Library
    @ObservedObject var usage: UsageMonitor
    @State private var showUsage=false
    @State private var usagePrompt:Prompt?
    @State private var dropTarget:String?
    @State private var draggingCategory:String?
    @State private var categoryFrames:[String:CGRect] = [:]
    @State private var query = ""
    @State private var category = "全部提示词"
    @State private var selection: UUID?
    @State private var editing: Prompt?
    @State private var deleting: Prompt?
    @State private var importDetails: Prompt?
    var categories: [String] { library.categories }
    var filtered: [Prompt] {
        let result=library.items.filter { p in
            (category == "全部提示词" || (category == "我的收藏" ? p.favorite : p.category == category)) &&
            (query.isEmpty || [p.title,p.category,p.tool,p.body].joined(separator:" ").localizedCaseInsensitiveContains(query))
        }
        guard category == "全部提示词" else { return result }
        return result.enumerated().sorted {
            let a=usage.total($0.element), b=usage.total($1.element)
            if a != b { return a>b }
            let x=usage.last($0.element), y=usage.last($1.element)
            return x != y ? x>y : $0.offset<$1.offset
        }.map(\.element)
    }
    var current: Prompt? { filtered.first(where: {$0.id == selection}) }
    func nav(_ title: String, _ symbol: String) -> some View {
        Button { category = title; selection = nil } label: {
            HStack { Image(systemName: symbol).frame(width: 20); Text(title); Spacer() }.padding(.vertical, 7).padding(.horizontal, 10)
                .background(category == title ? Color.accentColor.opacity(0.14) : Color.clear).cornerRadius(6)
        }.buttonStyle(.plain)
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing:6) { Image(nsImage:BrandIcon.image).resizable().frame(width:30,height:30).accessibilityLabel("提示词工作台蛛网图标"); Text("提示词工作台").font(.headline) }.padding(.bottom,16)
                nav("全部提示词", "square.stack")
                nav("我的收藏", "star")
                Text("分类").font(.caption).foregroundStyle(.secondary).padding(.top, 20)
                ScrollView { VStack(spacing: 3) { ForEach(categories, id: \.self) { title in
                    nav(title,"folder")
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key:CategoryFrames.self,value:[title:geometry.frame(in:.named("category-list"))])
                        })
                        .highPriorityGesture(DragGesture(minimumDistance:6,coordinateSpace:.named("category-list"))
                            .onChanged { value in
                                draggingCategory=title
                                dropTarget=categoryFrames.min(by:{abs($0.value.midY-value.location.y)<abs($1.value.midY-value.location.y)})?.key
                            }
                            .onEnded { value in
                                let target=categoryFrames.min(by:{abs($0.value.midY-value.location.y)<abs($1.value.midY-value.location.y)})?.key
                                if let target=target { library.moveCategory(title,onto:target) }
                                draggingCategory=nil; dropTarget=nil
                            })
                        .background(dropTarget==title ? Color.accentColor.opacity(0.12) : Color.clear)
                        .opacity(draggingCategory==title ? 0.65 : 1)
                        .help("按住分类并上下拖动，松开后保存顺序")
                        .contextMenu {
                            Button("上移") { if let i=categories.firstIndex(of:title), i>0 { library.moveCategory(title,onto:categories[i-1]) } }.disabled(categories.first==title)
                            Button("下移") { if let i=categories.firstIndex(of:title), i+1<categories.count { library.moveCategory(title,onto:categories[i+1]) } }.disabled(categories.last==title)
                        }
                } }.coordinateSpace(name:"category-list").onPreferenceChange(CategoryFrames.self) { categoryFrames=$0 } }
                Button("新增提示词", systemImage: "plus") { newPrompt() }.keyboardShortcut("n").controlSize(.large)
                Menu("批量导入") {
                    ForEach(ImportStatus.tools,id:\.self) { tool in Button("导入到"+tool) { library.installSkills(library.items,tools:[tool]) } }
                    Button("导入到全部工具") { library.installSkills(library.items,tools:ImportStatus.tools) }
                }
                Menu("资料与备份") {
                    Button("导入 JSON 备份…") { library.importFile() }
                    Button("导出 JSON 备份…") { library.exportFile() }
                    Button("调用统计…") { usagePrompt=nil; showUsage=true; usage.refresh(library.items) }
                    Button("打开资料文件夹") { NSWorkspace.shared.open(library.url.deletingLastPathComponent()) }
                }.padding(.top, 8)
                Text("离线保存 · 菜单栏常驻").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }.padding(20).frame(width: 195).background(Color(nsColor: .windowBackgroundColor))
            VStack(alignment: .leading, spacing: 0) {
                HStack { Text(category).font(.headline); Spacer(); Text("\(filtered.count) 条").foregroundStyle(.secondary) }.padding(18)
                HStack {
                    Text(category == "全部提示词" ? "按已记录调用次数排序" : "提示词列表").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("调用统计") { usagePrompt=nil; showUsage=true; usage.refresh(library.items) }.buttonStyle(.plain).font(.caption)
                }.padding(.horizontal,18).padding(.bottom,10)
                TextField("搜索标题、正文或工具", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.bottom, 14)
                List(selection: $selection) {
                    ForEach(filtered) { p in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack { Text(p.title).font(.headline).lineLimit(2); Spacer(); if p.favorite { Image(systemName:"star.fill").foregroundStyle(.orange) } }
                            Text(library.importSummary(p)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(usage.snapshot.updated == 0 ? (usage.busy ? "调用统计读取中…" : "调用统计未启用") : "已记录调用 \(usage.total(p)) 次").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            Text(p.body.replacingOccurrences(of:"\n", with:" ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }.padding(.vertical, 9).tag(p.id)
                            .contextMenu { Button("复制") { library.copy(p) }; Button("编辑") { editing = p } }
                    }
                }.listStyle(.inset)
                if filtered.isEmpty { Text("没有找到提示词。换个关键词，或新建一条。").foregroundStyle(.secondary).padding(18) }
            }.frame(minWidth: 250, idealWidth: 290, maxWidth: 330).background(Color(nsColor:.controlBackgroundColor))
            VStack(alignment: .leading, spacing: 0) {
                if let p = current {
                    HStack(alignment:.top) {
                        VStack(alignment:.leading,spacing:8) {
                            Text(p.title).font(.title2.bold())
                            Button(library.importSummary(p)) { importDetails=p }.buttonStyle(.plain).foregroundStyle(.secondary).help("查看每个软件的实际导入状态")
                            Button(usage.snapshot.updated == 0 ? (usage.busy ? "调用统计读取中…" : "调用统计未启用") : "已记录调用 \(usage.total(p)) 次 · 查看明细") { usagePrompt=p; showUsage=true; usage.refresh(library.items) }.buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { var v = p; v.favorite.toggle(); library.put(v) } label: { Image(systemName: p.favorite ? "star.fill" : "star") }.help("收藏或取消收藏")
                    }.padding(24)
                    ScrollView { MarkdownBody(source:p.body).frame(maxWidth:.infinity,alignment:.topLeading).padding(24) }.background(Color(nsColor:.textBackgroundColor))
                    HStack {
                        Button("编辑") { editing = p }.keyboardShortcut("e")
                        Button("创建副本") { var v = p; v.id = UUID(); v.title += "（副本）"; library.put(v); selection = v.id }
                        Button("删除", role:.destructive) { deleting = p }
                        Button(library.installLabel(p)) { importDetails=p }
                        Spacer()
                        Button("复制提示词", systemImage:"doc.on.doc") { library.copy(p) }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut("c",modifiers:[.command,.shift])
                    }.padding(20)
                } else {
                    Spacer()
                    VStack(alignment:.leading,spacing:14) {
                        Image(nsImage:BrandIcon.image).resizable().interpolation(.high).frame(width:56,height:56).accessibilityLabel("提示词工作台蛛网图标")
                        Text("你的提示词，随手可用").font(.system(size:26,weight:.bold)).fixedSize(horizontal:false,vertical:true)
                        Text("从左侧选择提示词，可一键导入到常用 AI 工具。\n支持分类整理、收藏和导入，让好用的提示词持续积累。").lineSpacing(6).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        Button("写一条提示词") { newPrompt() }.controlSize(.large)
                    }.padding(40).frame(maxWidth:.infinity,alignment:.leading)
                    Spacer()
                }
                if !library.message.isEmpty { Text(library.message).font(.callout).foregroundStyle(.secondary).padding(.horizontal,20).padding(.bottom,14).textSelection(.enabled) }
            }.frame(minWidth:390,maxWidth:.infinity)
        }.frame(minWidth: 1000, minHeight: 620)
            .sheet(item:$editing) { p in Editor(library:library,draft:p,saved:{ id in category = "全部提示词"; query = ""; selection = id }) }
            .sheet(item:$importDetails) { p in ImportDetails(library:library,prompt:p) }
            .sheet(isPresented:$showUsage) { UsageDetails(usage:usage,library:library,prompt:usagePrompt) }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in library.importRevision += 1; usage.refresh(library.items) }
            .alert("删除这条提示词？",isPresented:Binding(get:{deleting != nil},set:{if !$0 {deleting=nil}})) {
                Button("取消",role:.cancel) { deleting=nil }
                Button("删除",role:.destructive) { if let p=deleting { library.delete(p); selection=nil }; deleting=nil }
            } message: { Text("同时移除本机 Codex、豆包工作和 DeepSeek Harness 中由工作台管理的对应技能，技能文件会备份到 RemovedSkills。来源无法确认或移除失败时保留提示词；已打开对话中的历史内容不会撤回。") }
    }
    func newPrompt() { editing = Prompt(title:"",category:"未分类",tool:"通用",body:"") }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let library = Library()
    let usage = UsageMonitor()
    var usageTimer:Timer?
    var window: NSWindow!
    var status: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage=BrandIcon.image
        let mainMenu=NSMenu(); let root=NSMenuItem(); mainMenu.addItem(root)
        let appMenu=NSMenu(); root.submenu=appMenu
        appMenu.addItem(withTitle:"显示工作台",action:#selector(show),keyEquivalent:"0").target=self
        appMenu.addItem(.separator()); appMenu.addItem(withTitle:"退出提示词工作台",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editRoot=NSMenuItem(); mainMenu.addItem(editRoot); let edit=NSMenu(title:"编辑"); editRoot.submenu=edit
        for (title,action,key) in [("撤销","undo:","z"),("剪切","cut:","x"),("复制","copy:","c"),("粘贴","paste:","v"),("全选","selectAll:","a")] { edit.addItem(withTitle:title,action:Selector(action),keyEquivalent:key) }
        NSApp.mainMenu=mainMenu
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1120,height:740),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="提示词工作台"; window.isReleasedWhenClosed=false
        window.contentView=NSHostingView(rootView:Workbench(library:library,usage:usage)); window.center()
        status=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        status.button?.image=BrandIcon.menuBar
        status.button?.imageScaling = .scaleProportionallyDown
        status.button?.toolTip="提示词工作台"
        let menu=NSMenu(); menu.delegate=self; status.menu=menu
        usage.refresh(library.items)
        usageTimer=Timer.scheduledTimer(withTimeInterval:20,repeats:true) { [weak self] _ in guard let self=self else { return }; self.usage.refresh(self.library.items) }
        show()
    }
    @objc func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true) }
    @objc func copyFavorite(_ sender:NSMenuItem) { if let id=sender.representedObject as? UUID, let p=library.items.first(where:{$0.id==id}) { library.copy(p) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool)->Bool { show(); return true }
}
extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu:NSMenu) {
        menu.removeAllItems(); menu.addItem(withTitle:"打开提示词工作台",action:#selector(show),keyEquivalent:"").target=self
        menu.addItem(.separator())
        let favorites=library.items.filter(\.favorite)
        if favorites.isEmpty { let item=menu.addItem(withTitle:"收藏提示词后可在这里直接复制",action:nil,keyEquivalent:""); item.isEnabled=false }
        for p in favorites.prefix(15) { let item=menu.addItem(withTitle:"复制 · "+p.title,action:#selector(copyFavorite(_:)),keyEquivalent:""); item.target=self; item.representedObject=p.id }
        menu.addItem(.separator()); menu.addItem(withTitle:"退出",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"")
    }
}

@main enum Main {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let url=dir.appendingPathComponent("prompts.json"); let a=Library(url:url)
            precondition(a.items.count==4)
            let p=Prompt(title:"测试中文与换行",category:"测试",tool:"通用",body:"第一行\n第二行 😀")
            a.put(p); let b=Library(url:url); precondition(b.items.contains(p))
            var changed=p; changed.body="修改后"; b.put(changed); precondition(Library(url:url).items.contains(changed))
            b.delete(changed); precondition(!Library(url:url).items.contains(changed))
            let original=b.categories
            b.moveCategory(original[0],onto:original[1])
            precondition(b.categories[0]==original[1])
            precondition(Library(url:url).categories==b.categories)
            b.put(p)
            let usage=UsageMonitor(store:dir.appendingPathComponent("usage.sqlite"))
            usage.snapshot.counts[p.id.uuidString.lowercased()]=["Codex":2]
            precondition(Workbench(library:b,usage:usage).filtered.first?.id==p.id)
            var renamed=p; renamed.title="已改名"; b.put(renamed)
            precondition(usage.total(renamed)==2)
            let skillRoot=dir.appendingPathComponent("skills")
            precondition(try! SkillInstaller.install(p,root:skillRoot))
            precondition(!(try! SkillInstaller.install(p,root:skillRoot)))
            precondition(try! SkillInstaller.install(changed,root:skillRoot))
            let entry=skillRoot.appendingPathComponent(SkillInstaller.name(p)).appendingPathComponent("SKILL.md")
            let namedRoot=dir.appendingPathComponent("named-skills")
            precondition(try! SkillInstaller.install(p,root:namedRoot,originalName:true))
            let named=try! String(contentsOf:namedRoot.appendingPathComponent(SkillInstaller.name(p)).appendingPathComponent("SKILL.md"),encoding:.utf8)
            precondition(named.contains("name: "+SkillInstaller.quoted(p.title)))
            precondition(named.contains(p.body))
            precondition(ImportStatus.status(p,tool:"Codex",localRoot:namedRoot)=="已导入")
            precondition(ImportStatus.status(changed,tool:"Codex",localRoot:namedRoot)=="需要更新")
            let namedEntry=namedRoot.appendingPathComponent(SkillInstaller.name(p)).appendingPathComponent("SKILL.md")
            try! Data("external modification".utf8).write(to:namedEntry)
            precondition(ImportStatus.status(p,tool:"Codex",localRoot:namedRoot)=="外部已修改")
            try! FileManager.default.removeItem(at:namedRoot)
            precondition(ImportStatus.status(p,tool:"Codex",localRoot:namedRoot)=="未导入")
            let removalPrompt=Prompt(title:"卸载测试",category:"测试",tool:"通用",body:"内容")
            let removeRoot=dir.appendingPathComponent("remove-skills")
            precondition(try! SkillInstaller.install(removalPrompt,root:removeRoot,originalName:true))
            let plan=try! SkillInstaller.removalPlan(removalPrompt,roots:[removeRoot,removeRoot],backupRoot:dir.appendingPathComponent("removed"))
            precondition(plan.count==1)
            try! SkillInstaller.detach(plan)
            precondition(!FileManager.default.fileExists(atPath:plan[0].source.path))
            precondition(FileManager.default.fileExists(atPath:plan[0].backup.appendingPathComponent("SKILL.md").path))
            SkillInstaller.restore(plan)
            precondition(FileManager.default.fileExists(atPath:plan[0].source.path))
            try! Data("foreign".utf8).write(to:plan[0].source.appendingPathComponent(".promptdesk-owner.json"))
            do { _ = try SkillInstaller.removalPlan(removalPrompt,roots:[removeRoot],backupRoot:dir); preconditionFailure("Foreign receipt must survive") } catch { }
            precondition(FileManager.default.fileExists(atPath:plan[0].source.path))
            let previousCodex=getenv("CODEX_HOME").map { String(cString:$0) }
            let previousHarness=getenv("DSH_HOME").map { String(cString:$0) }
            setenv("CODEX_HOME",dir.appendingPathComponent("isolated-codex").path,1)
            setenv("DSH_HOME",dir.appendingPathComponent("isolated-harness").path,1)
            let lifecycle=Library(url:dir.appendingPathComponent("lifecycle/prompts.json"))
            let local=Prompt(title:"生命周期",category:"测试",tool:"通用",body:"v1")
            lifecycle.put(local)
            precondition(try! SkillInstaller.install(local,root:ImportStatus.root("Codex"),originalName:true))
            var edited=local; edited.body="v2"; lifecycle.put(edited)
            precondition(ImportStatus.status(edited,tool:"Codex")=="已导入")
            precondition(ImportStatus.status(edited,tool:"豆包工作")=="已导入")
            lifecycle.delete(edited)
            precondition(!lifecycle.items.contains(where:{$0.id==edited.id}))
            precondition(ImportStatus.status(edited,tool:"Codex")=="未导入")
            if let value=previousCodex { setenv("CODEX_HOME",value,1) } else { unsetenv("CODEX_HOME") }
            if let value=previousHarness { setenv("DSH_HOME",value,1) } else { unsetenv("DSH_HOME") }
            let rendered=MarkdownBody.parse("# 标题\n\n**粗体**\n\n- 条目\n```\ncode\n```")
            precondition(rendered.map(\.kind)==["heading","paragraph","list","code"])
            try! Data("manual edit".utf8).write(to:entry)
            do { _ = try SkillInstaller.install(p,root:skillRoot); preconditionFailure("Manual edit must survive") } catch { }
            precondition(try! String(contentsOf:entry,encoding:.utf8)=="manual edit")
            try! Data("invalid".utf8).write(to:url); let broken=Library(url:url); precondition(!broken.writable); precondition(String(data:try! Data(contentsOf:url),encoding:.utf8)=="invalid")
            try? FileManager.default.removeItem(at:dir)
            print("PASS: UTF-8, CRUD, persistence, corrupt-file protection, skill install/update, idempotence, manual-edit protection")
            return
        }
        if CommandLine.arguments.contains("--install-current") {
            let library=Library(); library.installSkills(library.items,tools:["DeepSeek Harness","Codex","豆包工作"]); print(library.message); return
        }
        let app=NSApplication.shared; let delegate=AppDelegate(); app.delegate=delegate; app.run()
    }
}
