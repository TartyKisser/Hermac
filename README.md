<div align="center">

<img src="docs/assets/hero.svg" alt="Hermac — Your Hermes. At home on Mac." width="100%" />

# Hermac

**A native macOS client for your local Hermes Agent.**

Chat, ask from anywhere, translate selected text, and turn plans into reminders — with SwiftUI and Liquid Glass.

[![macOS](https://img.shields.io/badge/macOS-26%2B-1F6FEB?logo=apple&logoColor=white)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](#development)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-6875F5)](#why-hermac)
[![License](https://img.shields.io/badge/License-MIT-34A853)](LICENSE)

**English** · [简体中文](README.zh-CN.md)

[Get started](#get-started) · [Features](#what-you-can-do) · [Privacy](docs/PRIVACY.md) · [Testing](TESTING.md)

</div>

## Why Hermac?

Hermes already handles the models, tools, and conversations. Hermac gives that local agent a home on your Mac: a familiar sidebar, readable Markdown, a quick input window, and shortcuts for translation and reminders while you work.

The name brings **Hermes + Mac** together. The app is built with native SwiftUI and AppKit, uses Apple's Liquid Glass APIs, and keeps its architecture small so more Hermes-powered tools can grow from the same foundation.

**Current release: 0.6.0.** This is a source-first project: build it in Xcode. A signed, notarized installer is not included. The current app interface is in Chinese.

## What you can do

| Feature | How it helps |
| --- | --- |
| **Native chat & session management** | Stream replies, stop generation, search and rename sessions, and return to earlier conversations. The sidebar focuses on local interactive sessions and filters messaging-platform and background sessions. |
| **Readable Markdown** | Headings, tables, nested lists, quotes, links, inline code, and fenced code blocks render in both the main app and quick chat. Wide tables and code scroll horizontally. |
| **Conversation branches** | Branch from a saved assistant reply into a separate session, keeping the original conversation intact. |
| **Quick chat from anywhere** | Press **⌃⇧Space** while Hermac is running. Start with a slim input box; after sending, continue in a movable, resizable conversation window. Closing it keeps the session in the sidebar. |
| **Quick-chat screen context** | Tick the screenshot option to attach the display containing the quick window. The quick window itself is excluded. The option starts unchecked. |
| **Selected-text translation** | Select English in a supported app and press **⌃⇧T** for a Chinese translation. Copy the result, then close the window to clean up its temporary Hermes session. |
| **Quick reminders** | Select scheduling text in a supported app and press **⌃⇧R**. Review and edit a proposed title, date/time, location, notes, priority, and list; **Confirm Create** writes it to Apple Reminders. |
| **Shortcuts that fit your setup** | Record your own combinations in Settings. Hermac checks system shortcuts and detectable global registrations before saving. |

Replies and code have copy buttons with a brief confirmation. Copying an entire reply preserves its Markdown source. Chinese input composition follows native macOS behavior.

Reminder extraction gathers nearby loaded text from the source conversation or document. When that is insufficient, it can read the current and up to two preceding views using local OCR, then attempt to restore the original scroll position. Sparse OCR can fall back to one current-window image. The review panel reports the context actually collected; it does not promise a complete conversation history.

## Requirements

| Component | Requirement |
| --- | --- |
| macOS | **26 or newer** |
| Xcode | **26 or newer**; development and tests verified with Xcode 27.2 on Apple Silicon |
| Hermes Agent | Installed and configured **on the same Mac**, with working terminal chat |
| Hermes interfaces | A launcher supporting `--print-runtime-command`, plus the local gateway client/session APIs used by `hermac_bridge.py` |

Hermac uses your Hermes installation's Python runtime and model configuration. Hermes, Python, and a model are not bundled in this repository. Compatibility depends on these gateway interfaces; an arbitrary older Hermes version may not provide them.

## Get started

### 1. Set up Hermes

Follow the [official Hermes installation guide](https://hermes-agent.nousresearch.com/docs/getting-started/installation), configure your model, and confirm that you can chat in Terminal:

```sh
hermes
```

If you need to locate the launcher:

```sh
command -v hermes
```

### 2. Build in Xcode

Clone this repository or download its ZIP, then open `Hermac.xcodeproj`.

1. Select the **Hermac** scheme and **My Mac** destination.
2. Press **⌘R**.
3. Hermac looks for a local Hermes launcher, starting with `~/.local/bin/hermes`. If yours is elsewhere, choose its path in **Hermac → Settings** and connect.

The project uses local ad hoc signing by default. A paid Apple Developer membership is not required for this local build.

### 3. Keep a local app build

From the repository root:

```sh
xcodebuild -project Hermac.xcodeproj -scheme Hermac \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData build
```

Quit any older Hermac copy, then install your build in your user Applications folder:

```sh
mkdir -p "$HOME/Applications"
ditto build/DerivedData/Build/Products/Release/Hermac.app \
  "$HOME/Applications/Hermac.app"
open "$HOME/Applications/Hermac.app"
```

Build outputs stay in the ignored `build/` directory.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| **⌃⇧Space** | Open or hide quick chat |
| **⌃⇧T** | Translate selected English into Simplified Chinese |
| **⌃⇧R** | Extract a reminder draft from selected text and nearby context |
| **⌘N** | New conversation |
| **⌘R** | Refresh sessions |
| **⌘.** | Stop generation |
| **Return** / **⇧Return** | Send / insert a newline |
| **Esc** | Dismiss quick/translation windows or an unsaved reminder draft; input composition is handled first |

Global shortcuts are active while Hermac is running. Configure all three in Settings if they overlap with your workflow. Conflict detection cannot cover every app-specific custom binding. Reminder saving runs to completion after confirmation.

## Permissions & data

- **Normal chat and the quick-chat shortcut:** no Accessibility or Input Monitoring permission is required.
- **Translation and reminder selection/context:** macOS Accessibility permission is needed. On some system versions it appears under **Device Control and Data Access**.
- **Quick-chat screenshots:** Screen Recording permission is needed when you tick the screenshot option and send.
- **Reminder OCR/image fallback:** Screen Recording permission may be requested automatically after triggering a reminder when native context is insufficient. This captures the source window, not the whole display.
- **Apple Reminders:** EventKit full-access permission is requested when loading writable lists or confirming creation. A reminder is written only after confirmation.

Hermac connects to a local Hermes installation. **Where model processing happens depends on your Hermes provider configuration.** Messages, submitted screenshots, and selected text are passed to that configured model through Hermes. Reminder extraction also sends the source app/window title and collected context text, with a current-window image only when needed. This model processing happens **before** draft review; confirmation controls writing to Apple Reminders.

Hermac does not maintain a second chat database or independently store model API keys. See [the privacy notes](docs/PRIVACY.md) for clipboard fallback, diagnostics, context collection, and temporary tool sessions.

After rebuilding an ad hoc signed app, macOS may retain an outdated Accessibility entry. If the toggle is on but translation still requests access, quit Hermac, remove its old entry in System Settings, and add the app you actually launch. Reusing a stable development signing identity can reduce this issue.

## Development

There are **no third-party Swift package dependencies**. Parsing uses Foundation Markdown; the interface uses SwiftUI and AppKit; screenshots use ScreenCaptureKit.

```text
Hermac/
├── ChatStore.swift              # Conversations, drafts and streaming state
├── HermacController.swift       # Main app and small-window coordination
├── MarkdownDocument.swift       # Native Markdown block structure
├── TranslationStore.swift       # Translation prompt and session lifecycle
├── ReminderStore.swift          # Editable reminder draft and confirmation
├── HermesToolSession.swift      # Hidden model operation and session cleanup
├── Services/                    # Hermes transport, context/OCR, screenshots and EventKit
├── Shortcuts/                   # Global hotkeys and shortcut recording
├── Views/                       # Native chat, Markdown and window content
├── Resources/hermac_bridge.py   # Bridge using Hermes's own Python runtime
└── AppIcon.icon/                # Layered six-wing glass icon
```

Run the offline unit tests:

```sh
xcodebuild -project Hermac.xcodeproj -scheme Hermac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData test
python3 -m unittest discover -s Tests -v
```

The current suite contains **87 Swift tests and 3 Python tests**. Optional gateway and model smoke tests have different data access and cost implications; see [TESTING.md](TESTING.md) before running them.

## Current scope

Hermac currently supports a local Hermes instance, its configured model, screenshot attachments, English-to-Chinese translation, and confirmed creation in Apple Reminders. Remote Hermes connections, in-app model switching, arbitrary file attachments, and multi-profile management are outside the current release.

Selection/context reading depends on the source app's accessibility or standard-copy support. Reminder context collection is bounded and stops on source changes or active user interaction; scroll restoration is attempted and its status is shown. Branching from replies already compacted by Hermes is unavailable. Password and `sudo` interactions requested by server-side tools are not handled by the client.

## Contributing

Bug reports, usability improvements, and focused pull requests are welcome. Include your macOS, Xcode, and Hermes versions; use synthetic examples or redact private conversation text. Run the unit tests for code changes and keep generated files out of commits.

## License & acknowledgements

Hermac is available under the [MIT License](LICENSE), © 2026 Hermac contributors.

Built to work with [Hermes Agent](https://github.com/NousResearch/hermes-agent), maintained separately by Nous Research and its contributors under its own license. Hermac is an independent community project; Hermes and Apple product names belong to their respective owners.
