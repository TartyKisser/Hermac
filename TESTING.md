# Testing Hermac

Hermac 0.5.2 has **59 Swift/XCTest unit tests** and **3 Python transport tests**. Run the ordinary unit suites first; live gateway tests are separate and opt-in.

## Requirements

- macOS 26 or later and Xcode 26 or later.
- A logged-in macOS development session for AppKit and input-method tests.
- Python 3 for the transport suite. It uses the standard library and does not require a Hermes installation.
- Run all commands from the repository root.

## Unit tests — no model calls

```sh
xcodebuild -project Hermac.xcodeproj -scheme Hermac \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData test

python3 -m unittest discover -s Tests -p 'test_*.py' -v
```

The Xcode test host does not start Hermes or register the application's global shortcuts. The Python transport tests use fake clients; they do not import an installed Hermes runtime or read credentials.

Coverage includes:

- Transcript projection, session-source filtering, branch boundaries and streaming events.
- Translation-session creation, close/cleanup races and stale-event isolation.
- Global shortcut validation, recording and conflict handling.
- Chinese input composition, Return/Shift-Return behavior and native editor updates.
- Screenshot dimensions, selection decoding and conditional clipboard restoration. Clipboard tests use a separate named pasteboard.
- Markdown headings, tables, alignment, inline styles, nested lists, quotes, code and unfinished fences.
- Brand-mark geometry and motion behavior.

Xcode test results are written beneath `build/DerivedData/Logs/Test/`. Build outputs and logs are ignored by Git.

## Optional live gateway test — no model prompt

First configure a compatible local Hermes installation. The scripts currently expect its launcher at `~/.local/bin/hermes` and use the launcher's runtime discovery interface.

```sh
python3 Tests/smoke_bridge.py
```

This connects to the real local gateway, checks live/stored session-list metadata, creates and renames its own temporary test session, stages a synthetic 1×1 PNG, and cleans up its own session and image. It does **not** submit a model prompt or capture the screen. It requires access to the user's running/configured Hermes environment.

## Optional real-model test — may incur provider charges

```sh
python3 Tests/smoke_translation.py
```

This submits the synthetic sentence `The window can be moved and resized.` to the model configured in Hermes. It checks for Chinese output, verifies the temporary translation session is hidden, and attempts to delete that session afterward. It does not read an actual selection, clipboard, screenshot or existing conversation body.

The model request follows the provider configuration and data-retention rules of the local Hermes installation. Cleanup can fail if the gateway is unavailable or the process is forcibly interrupted; do not assume an aborted smoke test cleaned itself up.

## Manual interface checks

Build and run the `Hermac` scheme on **My Mac**. Use synthetic, non-private content for these checks.

1. Send a short message in the main window; verify streaming, stop, copy feedback and history restore.
2. Render a Markdown response with headings, a wide table, nested lists, a quote and fenced code. Verify the same formatting in the main window and quick-chat panel; wide content should scroll horizontally without widening the window.
3. Use a real keyboard to test **⌃⇧Space** in another App. Before sending, verify Esc/outside-click dismissal; after sending, verify follow-up messages, dragging, resizing and history persistence.
4. Enter Chinese with a system input method. Confirm candidate selection and that Return commits composition before sending.
5. Select synthetic English in a supported App and use **⌃⇧T**. Verify translation, copy feedback and normal close. Accessibility permission is needed for this feature.
6. Optionally enable screenshot context on a display containing only test material. Confirm the captured display and that the quick panel itself is excluded. This requires screen-recording permission and sends the image through Hermes to its configured model.
7. Record a custom shortcut, check a known reserved/system conflict, then restore the defaults.

Real global shortcuts and independent input-method candidate windows may need physical keyboard validation; targeted automation keystrokes are not sufficient evidence.

## Reporting a failure

Include the relevant macOS, Xcode and Hermes versions, the test command, expected behavior and a minimal reproduction. Review logs before attaching them: errors may contain local paths, application identifiers or upstream diagnostics. Remove credentials, private file names, conversation text and screenshot content. See [Privacy & data flow](docs/PRIVACY.md).
