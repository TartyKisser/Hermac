<div align="center">
  <img src="docs/assets/icon.svg" width="96" height="96" alt="Hermac 六翼图标">
  <h1>Hermac</h1>
  <p><strong>你的 Hermes，触手可及。</strong></p>
  <p>面向本地 Hermes Agent 的原生 macOS 客户端。<br>流畅对话、全局快捷会话、划词翻译与快捷日程，融入 Mac 的日常工作。</p>
  <p><a href="README.md">English</a> · 简体中文</p>
  <p>
    <img src="https://img.shields.io/badge/macOS-26%2B-111111?logo=apple&amp;logoColor=white" alt="macOS 26 或更新版本">
    <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&amp;logoColor=white" alt="Swift 6">
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-2878C7" alt="MIT 许可"></a>
  </p>
</div>

<p align="center"><img src="docs/assets/hero.svg" width="100%" alt="Hermac：主会话、快捷会话与英译中功能概览；示意图"></p>

**Hermac = Hermes + Mac。** 沿用你已经配置好的 Hermes 模型、工具和会话，以 SwiftUI 与 AppKit 构建原生界面，让 AI 助手更自然地出现在工作流程里。

这是独立的社区项目，与 Nous Research 或 Apple 没有隶属关系。当前版本为 **0.6.0**，通过**源码构建**使用，不提供预编译安装包。

## 四种方式，让想法继续

| 你正在做什么 | Hermac 如何接上 |
| --- | --- |
| 整理思路、撰写内容、解决问题 | 在主窗口持续对话，搜索、重命名会话，或从回复创建分支 |
| 想在当前工作中快速提问 | 按 **⌃⇧Space** 呼出轻量输入框；可选择附带所在屏幕的截图，发送后展开为会话小窗 |
| 阅读英文资料 | 在支持读取选区的 App 中选中英文，按 **⌃⇧T**，直接查看简体中文译文 |
| 把聊天、邮件或文档中的安排记下来 | 选中日程文字，按 **⌃⇧R** 整理为可编辑草稿，确认后写入系统提醒事项 |

## 你会用到的细节

- **原生 Mac 体验。** 系统窗口、红黄绿按钮、连续曲率圆角、Liquid Glass 输入区，以及跟随系统外观的界面。
- **认真呈现回答。** 原生 Markdown 排版支持标题、表格、列表、引用、链接和代码块；较宽表格与代码可独立横向滚动。
- **会话仍归 Hermes 管理。** 主窗口与快捷会话共享 Hermes 的历史；关闭快捷会话小窗后，记录仍留在侧边栏。
- **保留好用的上下文。** 从 AI 回复创建独立分支，继承该回复之前的对话；原会话继续保留。
- **快捷会话按需截图。** 截图选项每次呼出时默认关闭，开启后捕获快捷窗所在显示器，并排除快捷窗本身。
- **日程先整理，再确认。** 选区旁显示玻璃药丸，整理完成后可编辑标题、日期/时间、地点、备注、优先级及清单。只有点击“确认创建”才保存到系统提醒事项。
- **读懂选区附近的安排。** 日程提取先读取当前会话或文档已加载的邻近文字；不足时可对当前及上方最多两屏进行本地 OCR，并尝试恢复滚动位置。识别仍不足时仅附带当前窗口图像，编辑卡会说明实际读取范围。
- **复制有反馈。** 用户消息、AI 回复及代码均可复制，点击后短暂显示“已复制”；整条回复复制保留 Markdown 原文。
- **对中文输入友好。** 原生输入法预编辑与候选词交互，支持 Return 发送、Shift-Return 换行。
- **工作区更清爽。** 侧边栏展示本地交互会话，隐藏 QQ、微信等通讯平台和自动任务会话；隐藏不会删除它们。

## 开始使用

### 1. 准备本地环境

| 依赖 | 要求 |
| --- | --- |
| macOS | 26 或更新版本 |
| Xcode | 26 或更新版本，包含相应 macOS SDK |
| Hermes Agent | 已在本机安装、完成模型配置，并能在终端正常对话 |

Hermac 不捆绑 Hermes、Python 运行时或模型。请先按照 [Hermes 官方安装指南](https://hermes-agent.nousresearch.com/docs/getting-started/installation) 安装并配置上游。

当前连接方式要求 Hermes 支持 `--print-runtime-command`、本地 `hermes-gateway-v1` 会话接口及 `hermes_cli.gateway_client`。上游接口可能随版本变化，Hermac 暂不提供完整的 Hermes 版本兼容矩阵。

已验证的开发环境为 Apple Silicon、macOS 27.0.1、Xcode 27.2；Intel Mac 尚未验证。

### 2. 用 Xcode 运行

下载或克隆本仓库，在项目根目录打开：

```sh
open Hermac.xcodeproj
```

选择 **Hermac → My Mac**，按 **⌘R**。

首次运行默认查找 `~/.local/bin/hermes`。如果你的安装位置不同，在 **Hermac → 设置 → 本地连接** 中填写 Hermes 启动程序路径，然后点击“连接”。模型与供应商密钥继续在 Hermes 中配置。

<details>
<summary><strong>命令行构建 Release 版本</strong></summary>

在项目根目录执行：

```sh
xcodebuild -project Hermac.xcodeproj -scheme Hermac \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData build
```

构建产物位于：

```text
build/DerivedData/Build/Products/Release/Hermac.app
```

可以在 Finder 中将它复制到“应用程序”。当前项目使用本地 ad hoc 签名；如需自行分发安装包，应另外配置自己的签名与公证流程。

</details>

### 3. 开始对话

在主窗口直接提问，或在 Hermac 运行期间使用全局快捷键。快捷会话首次发送后会展开，你可以继续追问、移动窗口或调整大小。

| 快捷键 | 操作 |
| --- | --- |
| **⌃⇧Space** | 呼出／收起快捷会话 |
| **⌃⇧T** | 将选中的英文翻译为简体中文 |
| **⌃⇧R** | 将选中文字及邻近上下文整理为提醒事项草稿 |
| **⌘N** | 新建主会话 |
| **⌘R** | 刷新会话 |
| **⌘.** | 停止当前生成 |
| **Return** / **⇧Return** | 发送 / 换行 |
| **Esc** | 收起快捷小窗、翻译窗或未保存的日程草稿；输入法组词期间优先交给输入法 |

三个全局快捷键均可在 **设置 → 全局快捷键** 中自定义。保存前会检查可检测的系统快捷键及全局注册冲突；其他 App 自定义的局部快捷键仍可能需要自行协调。确认后的提醒事项保存会运行至完成。

## 权限与数据

| 功能 | 何时需要权限 |
| --- | --- |
| 普通对话、全局快捷会话 | 不需要辅助功能或屏幕录制权限 |
| 快捷翻译、日程选区与上下文 | 读取其他 App 的文字时需要辅助功能权限 |
| 快捷会话截图 | 勾选截图并发送时需要屏幕录制权限 |
| 日程 OCR 与图像回退 | 原生上下文不足时可能自动请求屏幕录制权限；捕获来源窗口而非整个显示器 |
| 系统提醒事项 | 读取可写清单或确认创建时请求 EventKit 提醒事项完全访问权限；写入只发生在确认之后 |

不同 macOS 版本的权限名称可能不同，例如“辅助功能”或“设备控制和数据访问”。只需为要使用的功能授权。

**本地客户端不等于完全离线的模型。** 你发送的消息、选中文字或截图会经 Hermes 交给其配置的模型供应商；供应商可以是本地模型，也可以是云端服务。日程提取还会提交来源应用／窗口标题、收集的邻近文字，以及必要时的一张当前窗口图像；这些模型处理发生在草稿确认之前，确认按钮控制的是系统提醒事项写入。Hermac 不另存模型 API 密钥或建立第二份会话数据库。

翻译使用独立隐藏会话，正常关闭翻译窗时会申请清理；日程整理也使用隐藏会话，并在返回草稿前清理。更多信息见 [隐私与数据流](docs/PRIVACY.md)。

## 当前范围

- 当前界面以中文为主；快捷翻译固定为英文 → 简体中文。
- 只连接本机 Hermes，不提供远程网关、多配置管理或 App 内模型切换。
- 支持截图上下文及确认后创建系统提醒事项，暂不提供任意文件附件。
- 日程上下文读取有范围限制，不保证取得完整历史；切换来源应用或主动操作会停止收集。滚动恢复状态会在界面中说明，未确认恢复时请检查原窗口。
- 部分 App 不暴露所选文本；兼容读取会尽可能使用原生选区或标准复制。VS Code 首次初始化辅助功能树时可能需要等待几秒。
- Hermes 已压缩归档的旧回复可以查看与复制，但不支持从此处创建分支。
- 需要密码或 sudo 的服务端交互目前不支持。
- 本地 ad hoc 构建更新后，macOS 可能要求刷新辅助功能授权；可退出 Hermac，移除旧条目，再添加更新后的 App。

## 开发与测试

Hermac 没有第三方 Swift 包依赖。解析和界面使用苹果原生框架；一个轻量 Python stdio 桥接复用 Hermes 已安装的运行时和网关客户端。

```text
Hermac/
├── ChatStore.swift                 会话与流式消息状态
├── HermacController.swift          主窗口、快捷会话与翻译的协调
├── MarkdownDocument.swift          原生 Markdown 块结构
├── ReminderStore.swift             日程草稿与确认状态
├── HermesToolSession.swift         隐藏模型请求与会话清理
├── Services/                       Hermes 连接、选区与上下文/OCR、截图及 EventKit
├── Shortcuts/                      全局快捷键与录制
├── Views/                          SwiftUI / AppKit 界面
└── Resources/hermac_bridge.py       stdio ↔ Hermes 网关
HermacTests/                        Swift / AppKit 测试
Tests/                              Python 桥接与可选真实网关测试
```

当前单元测试包含 **87 项 Swift/XCTest 测试与 3 项 Python 测试**。真实网关与模型 smoke test 单独运行，详见 [测试指南](TESTING.md)。

## 一起改进 Hermac

欢迎提交可复现的问题、界面反馈和小而聚焦的 Pull Request。报告问题时，请提供 macOS、Xcode 与 Hermes 版本、复现步骤及经过脱敏的错误信息；不要附上密钥、真实会话或未经检查的屏幕截图。

适合一起探索的方向包括：更多应用的选区兼容、无障碍体验、界面本地化，以及复用 Hermes 能力的轻量工具。新功能请先通过 Issue 讨论范围。

## 许可与致谢

以 [MIT License](LICENSE) 开源，版权归 **Hermac contributors**。

感谢 [Hermes Agent](https://github.com/NousResearch/hermes-agent) 提供本地 Agent 运行时。Hermes 是独立维护、独立许可的上游项目。Apple、macOS、Swift 和 SwiftUI 等名称归各自权利人所有。
