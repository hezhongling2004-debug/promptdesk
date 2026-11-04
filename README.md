# 提示词工作台

macOS 本地提示词库：分类拖动、收藏、复制、Markdown 预览，以及导入和管理 Codex、豆包工作、DeepSeek Harness 的本地技能。无需浏览器、账号或 AI API Key。

## 下载与安装

要求 macOS 14 或更新版本。通用应用同时包含 Apple Silicon 和 Intel 架构。将 ZIP 解压，将“提示词工作台.app”拖入“应用程序”再打开。首次启动只创建示例提示词，不会自动安装任何技能，也不包含作者的个人提示词库、调用记录或账号。

**分发状态：当前 PREVIEW 包是未公证测试版。** 本机打开成功不代表网上下载后能直接打开。正式公开发行需 Developer ID 签名和 Apple 公证；项目提供 `release.sh --release`，缺少签名配置时会拒绝生成正式包。测试者请先了解 [Apple 的应用安全检查](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unidentified-developer-mh40616/mac)，本项目不附带关闭安全保护或删除隔离标记的脚本。

## 使用

- 新增或编辑提示词；正文支持 Markdown 的标题、粗体、斜体、行内代码、无序列表、引用、链接和代码块预览。编辑与复制保留原始文本；预览不执行 HTML，不下载远程图片。
- 按住分类上下拖动，松开保存；也可右键上移、下移。
- 选中提示词，点击“导入到工具…”进入管理弹窗；已安装时显示“管理导入…”，需要更新时显示“更新技能…”。批量操作在侧栏“批量导入”。
- 保存修改后自动更新此前已导入且未在外部修改的技能。外部修改会保留，显示“检查更新…”，不会强行覆盖；可先移除并保留备份，再重新安装。
- 管理弹窗可单独移除技能并保留提示词。删除提示词前弹窗说明：同时移除本机受工作台管理的技能，移出的完整技能目录备份到 RemovedSkills；来源无法确认或移除失败则保留提示词。已经进入目标工具对话的内容不会撤回。

## 工具兼容性与边界

| 工具 | 默认技能目录 | 说明 |
| --- | --- | --- |
| Codex | `~/.codex/skills` | 中文技能标题；写入后新建对话，必要时重启工具 |
| 豆包工作 | 与 Codex 共用 `~/.codex/skills` | 仅适用于支持读取本地技能的豆包工作客户端；共用文件，安装、更新和移除会同时影响 Codex |
| DeepSeek Harness | `~/.dsh/skills` | 中文显示名适配本机当前 desktop 配置；其他版本或 CLI 可用稳定的 promptdesk UUID 技能名 |

“已导入”只表示自管技能文件已核验，不代表客户端已读取或运行成功。不安装目标工具也能整理和复制提示词。Claude 不在本版导入范围。

自定义 `CODEX_HOME`、`DSH_HOME` 从应用启动环境读取；Finder 启动不一定继承终端环境变量。自定义配置的用户请从配置好环境的终端启动应用程序包内的可执行文件。暂不支持远程云工作区、其他用户或任意项目目录的自动同步。Harness 中文菜单是可选插件，找不到 desktop 配置时会提示技能已写入而菜单适配未启用。

## 调用次数（可选）

核心功能不需要 Python、Node 或 Homebrew。调用统计当前需要额外安装 Python 3；读取 Harness 压缩记录还需要 zstd。缺少依赖时明确提示，编辑、预览、复制、安装不受影响，不会弹出开发工具安装请求。

Codex 和 Harness 统计可核验的本地技能加载，同一软件、同一对话轮次、同一提示词只记一次；复制和安装不计数，不表示任务成功。每 20 秒补读；应用关闭后，下次启动补读仍保留的记录。日志格式改变、无法识别的访问方式或已被清理的历史记录可能漏记。豆包调用统计尚未接入。

“全部提示词”按已记录次数降序排列。次数保存在本机，不随改名或重启清零。创建副本不继承次数。

## 数据与备份

数据在 `~/Library/Application Support/PromptDesk/`，更新应用不会重置它。

- `prompts.json`：提示词；菜单可导入、导出 JSON。
- `category-order.json`：分类顺序。
- `usage.sqlite`：调用事件及读取游标，不保存对话正文。
- `RemovedSkills/`：移除技能的完整目录备份，可能包含技能正文和用户额外文件。

JSON 导出只包含提示词。备份全部资料时退出工作台后复制整个目录。删除应用不等于卸载已导入技能：请先在工作台移除需要卸载的技能。

## 从源码构建

开发环境：Mac、Xcode Command Line Tools、Python 3、Node.js、zstd（后两者用于测试）。

```sh
zsh build.sh
python3 test-usage.py
node test-harness-labels.mjs
zsh release.sh --preview
```

CI 提供通用架构测试包，不自动发布 Release。正式发布：配置 `SIGN_IDENTITY` 为本机钥匙串中的 Developer ID Application 身份、`NOTARY_PROFILE` 为 notarytool 钥匙串配置，然后运行 `zsh release.sh --release`。不要将证书、密钥、账号或用户数据加入仓库。

验证包含隔离资料读写、安装更新、外部修改保护、移除与恢复、跨共享目录去重、拒绝无所有权文件、Markdown 解析、调用记录去重和重启续读。Intel 和 macOS 14 的二进制已构建，尚需对应真实机器验收；Apple 公证和真实下载隔离环境验收仍是正式发布前的必需步骤。
