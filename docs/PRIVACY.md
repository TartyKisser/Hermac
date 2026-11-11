# Privacy & data flow · 隐私与数据流

## 中文

### 内容交给谁处理

Hermac 是运行在 Mac 上的本地客户端，通过本机 Hermes 的运行时和网关处理消息。**本地客户端不代表模型完全离线**：消息、提交的截图、待翻译选区及日程上下文，会交给 Hermes 配置的模型供应商；该供应商可能是本地模型，也可能是云端服务。

Hermac 不配置或另存模型 API 密钥，不建立第二份聊天数据库，也没有独立的分析或遥测上报服务。模型配置、会话历史和已提交附件由 Hermes 管理；Hermac 的启动程序路径及三个全局快捷键保存在本机偏好设置中。Hermes 和模型供应商可能有各自的日志与保留规则。

### 权限只用于对应功能

- **普通对话与全局快捷会话**不需要辅助功能或屏幕录制授权。
- **快捷翻译与日程选区**需要辅助功能权限来读取其他 App 的文字。优先使用原生选区接口；无法读取时可能通过标准复制获取。读取过程中会保留原剪贴板，在能确认仍属于本次操作时恢复，避免覆盖期间产生的新复制内容。VS Code 的复制回退还会检查非空选区及字符数。
- **快捷会话截图**仅在勾选并发送时捕获快捷窗所在显示器，排除快捷窗本身。选项每次重新呼出默认关闭，权限由 macOS 管理。
- **快捷日程的 OCR／图像回退**与快捷会话勾选截图是两条独立路径。触发日程后，如果原生上下文不足，可能自动请求屏幕录制权限并捕获来源窗口。具体过程见下文。
- **系统提醒事项**使用 EventKit 完全访问权限；读取可写清单或确认创建时可能请求授权。当前实现读取可写清单的名称／标识，并在你确认后创建事项，不读取已有提醒事项正文。事项的存储和同步遵循所选系统清单的配置。

### 快捷日程如何收集上下文

按 **⌃⇧R** 后，Hermac 先读取选区，以及选区所在会话／文档中已加载的邻近文字。收集有数量和长度限制：会话容器最多取近期 30 项，文档优先取选区周围的小范围文字，不保证取得完整历史。

原生上下文不足时，应用可对**当前来源窗口**的当前及上方最多两屏进行本地中英文 OCR。它会尝试恢复原滚动位置，并在编辑卡中说明实际收集范围和恢复状态。切换应用／来源窗口或主动操作会停止收集；无法可靠估计滚动时会停止继续翻页。请以界面提示为准，未确认恢复时检查原窗口。

OCR 在本机执行，但识别出的文字会作为日程提取输入提交给 Hermes。若 OCR 内容仍稀疏，应用可能另外附带**一张当前窗口图像**；上方各屏图像仅用于本地识别，不逐张上传。提交内容包括选中文字、来源应用名称、窗口标题和收集的上下文。**模型处理发生在草稿审核之前；“确认创建”控制的是写入系统提醒事项。**

提醒事项草稿可修改标题、日期／时间、地点、备注、优先级和清单。只有确认后才写入；关闭未保存草稿不会创建事项。临时窗口图像文件会在该流程关闭、替换或正常退出时清理；已提交附件及供应商数据遵循 Hermes 和供应商的保留行为。

### 临时模型会话与诊断

翻译使用隐藏会话，正常关闭翻译窗或退出 Hermac 时申请停止并删除。日程整理使用独立、禁用工具的隐藏模型会话，在返回可审核草稿前申请删除。异常退出、网关不可用或清理失败时可能留下会话；本地清理不会撤销供应商已经收到的数据，也不会删除你已确认创建的系统提醒事项。

选区诊断记录来源应用标识、状态、错误码及字符数；上下文采集诊断还记录页数、滚动／几何测量及恢复结果，不记录选中文字或 OCR 正文。其他错误信息可能含本地路径或上游诊断。提交 Issue 前，请检查日志和截图，移除密钥、会话内容及私人文件信息。

## English

### Where content goes

Hermac is a local macOS client for a local Hermes runtime and gateway. **A local client does not imply an offline model.** Messages, submitted screenshots, text selected for translation, and reminder context go to the model provider configured in Hermes, which may be local or cloud-hosted.

Hermac does not separately store model API keys, maintain a second chat database, or operate its own analytics/telemetry endpoint. Hermes owns model configuration, history and submitted attachments. Hermac stores its launcher path and three global shortcuts in local preferences. Hermes and the provider have their own logging and retention behavior.

### Feature-specific access

- Ordinary chat and global quick chat do not require Accessibility or Screen Recording permission.
- Translation and reminder selection use Accessibility. They prefer native selection APIs and may use standard Copy as a fallback. Clipboard contents are restored only when the operation can still safely claim them; newer user copies are not overwritten. The VS Code fallback also checks a nonempty selection and character count.
- Quick-chat screenshot context captures the quick panel's display only when the option is selected and a message is sent, excluding the panel itself. It is off by default whenever the panel is reopened.
- Reminder OCR/image fallback is separate from that checkbox. After you trigger reminder extraction, insufficient native context can lead to a Screen Recording permission request and source-window capture.
- Apple Reminders uses EventKit full-access permission, requested when loading writable lists or confirming creation. The current implementation reads writable-list names/identifiers and creates an item after confirmation; it does not read existing reminder bodies. Storage and synchronization follow the selected system list's configuration.

### Reminder context collection

After **⌃⇧R**, Hermac first reads the selected text and nearby loaded text in the source conversation or document. Collection is bounded: conversation containers contribute up to 30 recent loaded items; documents use small ranges around the selection. This is not a complete-history export.

When native context is insufficient, it can capture the current and up to two preceding views of the **source window** for local Chinese/English OCR. It attempts to restore the original scroll position and reports the actual collection scope and restoration status in the review card. A source/app change or active user interaction stops collection; unreliable motion estimates stop further paging. Check the source window if restoration could not be verified.

OCR runs locally, but the recognized text is submitted to Hermes for extraction. Sparse OCR may additionally attach **one current-window image**; images of preceding views are used locally, not uploaded individually. Inputs include selected text, source app name, window title and collected context. **Model processing happens before draft review; confirmation controls writing to Apple Reminders.**

The draft lets you edit the title, date/time, location, notes, priority and list. Only confirmation writes an item; dismissing an unsaved draft creates none. Temporary window-image files are removed when the flow is closed, replaced, or the app exits normally. Submitted attachments and provider data follow Hermes/provider retention behavior.

### Temporary sessions and diagnostics

Translation uses a hidden session, with cleanup requested on normal window close or app quit. Reminder extraction uses a separate tool-disabled hidden model session, with deletion requested before returning the reviewable draft. A crash, unavailable gateway or cleanup error can leave a session behind. Local cleanup does not undo data already received by a provider or delete a system reminder you already confirmed.

Selection diagnostics contain application identifiers, status/error codes and character counts. Context diagnostics also contain page counts, scroll/geometry measurements and restoration results, not selected or OCR text. Other errors may include paths or upstream diagnostics. Review logs and screenshots before sharing an issue; remove credentials and private content.
