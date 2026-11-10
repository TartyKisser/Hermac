# Privacy & data flow · 隐私与数据流

## 中文

### 内容交给谁处理

Hermac 是运行在 Mac 上的本地客户端，通过本机 Hermes 的运行时和网关处理消息。**本地客户端不代表模型完全离线**：消息、主动附带的截图与待翻译选区，会交给 Hermes 配置的模型供应商；该供应商可能是本地模型，也可能是云端服务。

Hermac 不配置或另存模型 API 密钥，不建立第二份聊天数据库，也没有独立的分析或遥测上报服务。模型配置、会话历史和已提交附件由 Hermes 管理；Hermac 的启动程序路径及快捷键保存在本机偏好设置中。Hermes 和模型供应商可能有各自的日志与保留规则。

### 权限只用于对应功能

- **普通对话与全局快捷会话**不需要辅助功能或屏幕录制授权。
- **快捷翻译**需要辅助功能权限来读取其他 App 的选区。优先使用原生选区接口；无法读取时可能通过标准复制获取。读取过程中会保留原剪贴板，在能确认仍属于本次操作时恢复，避免覆盖期间产生的新复制内容。VS Code 的复制回退还会检查非空选区及字符数。
- **截图上下文**仅在勾选并发送时捕获快捷窗所在显示器，排除快捷窗本身。选项每次重新呼出默认关闭；屏幕录制权限由 macOS 管理。确认屏幕内容适合提交后再发送。

正常关闭翻译窗或退出 Hermac 时，应用会申请停止并删除自己的隐藏翻译会话。异常退出、网关不可用或清理失败时可能留下会话；本地会话清理不会撤销供应商已经收到的数据。

### 诊断与分享

选区诊断记录来源应用标识、状态、错误码及字符数，不记录所选文字正文。其他错误信息可能含本地路径或上游诊断。提交 Issue 前，请检查日志和截图，移除密钥、会话内容及私人文件信息。

## English

### Where content goes

Hermac is a local macOS client for a local Hermes runtime and gateway. **A local client does not imply an offline model.** Messages, explicitly attached screenshots and selected text submitted for translation go to the model provider configured in Hermes, which may be local or cloud-hosted.

Hermac does not separately store model API keys, maintain a second chat database, or operate its own analytics/telemetry endpoint. Hermes owns model configuration, history and submitted attachments. Hermac stores its launcher path and shortcuts in local preferences. Hermes and the provider have their own logging and retention behavior.

### Feature-specific access

- Ordinary chat and global quick chat do not require Accessibility or Screen Recording permission.
- Translation uses Accessibility to read a selection. It prefers native selection APIs and may use standard Copy as a fallback. Clipboard contents are restored only when the operation can still safely claim them; newer user copies are not overwritten. The VS Code fallback also checks a nonempty selection and character count.
- Screenshot context captures the quick panel's display only when the option is selected and a message is sent, excluding the panel itself. It is off by default whenever the panel is reopened. macOS controls Screen Recording permission.

Normal translation-window close and application quit request cleanup of Hermac's hidden translation session. A crash, unavailable gateway or cleanup error can leave a session behind. Local cleanup does not undo data already received by a provider.

### Diagnostics

Selection diagnostics contain application identifiers, status/error codes and character counts, not selected text. Other errors may include paths or upstream diagnostics. Review logs and screenshots before sharing an issue; remove credentials and private content.
