import SwiftUI

// Offline preview: no HTML execution, scripts, remote images or browser dependency.
struct MarkdownBody: View {
    let source:String
    struct Block:Identifiable { let id:Int; let kind:String; let text:String; let level:Int }
    static func parse(_ source:String)->[Block] {
        var blocks:[Block]=[], paragraph:[String]=[], code:[String]=[]; var fenced=false
        func add(_ kind:String,_ text:String,_ level:Int=0) { blocks.append(Block(id:blocks.count,kind:kind,text:text,level:level)) }
        func flush() { if !paragraph.isEmpty { add("paragraph",paragraph.joined(separator:"\n")); paragraph=[] } }
        for line in source.components(separatedBy:"\n") {
            if line.trimmingCharacters(in:.whitespaces).hasPrefix("```") { flush(); if fenced { add("code",code.joined(separator:"\n")); code=[] }; fenced.toggle(); continue }
            if fenced { code.append(line); continue }
            if line.trimmingCharacters(in:.whitespaces).isEmpty { flush(); continue }
            let hashes=line.prefix(while:{$0=="#"}).count
            if hashes>0 && hashes<=6 { flush(); add("heading",String(line.dropFirst(hashes)).trimmingCharacters(in:.whitespaces),hashes) }
            else if line.hasPrefix("> ") { flush(); add("quote",String(line.dropFirst(2))) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { flush(); add("list",String(line.dropFirst(2))) }
            else { paragraph.append(line) }
        }
        flush(); if fenced { add("code",code.joined(separator:"\n")) }; return blocks
    }
    static func inline(_ text:String)->AttributedString {
        (try? AttributedString(markdown:text,options:.init(interpretedSyntax:.inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            ForEach(Self.parse(source)) { block in
                switch block.kind {
                case "heading": Text(Self.inline(block.text)).font(.system(size:block.level==1 ? 24 : block.level==2 ? 20 : 17,weight:.bold)).padding(.top,6)
                case "code": ScrollView(.horizontal) { Text(block.text).font(.system(size:13,design:.monospaced)).padding(12) }.background(Color.secondary.opacity(0.07)).cornerRadius(6)
                case "quote": HStack(alignment:.top) { Text("▎").foregroundStyle(.secondary); Text(Self.inline(block.text)).foregroundStyle(.secondary) }
                case "list": HStack(alignment:.top) { Text("•"); Text(Self.inline(block.text)) }
                default: Text(Self.inline(block.text)).font(.system(size:15)).lineSpacing(6)
                }
            }
        }.textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
    }
}
