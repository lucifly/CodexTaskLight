<p align="center">
  <img src="Assets/AppIcon-preview.png" width="112" height="112" alt="CodexTaskLight app icon">
</p>

<h1 align="center">CodexTaskLight</h1>

<p align="center"><a href="README.md">简体中文</a> · <strong>English</strong></p>

<p align="center"><strong>A small, draggable traffic light for local Codex task status on macOS.</strong></p>

<p align="center">
  <a href="#requirements"><img src="docs/images/badges/macos.svg" alt="macOS 13.0 deployment target; not tested on every version"></a>
  <a href="#requirements"><img src="docs/images/badges/arm64.svg" alt="Apple Silicon arm64 build only"></a>
  <a href="LICENSE"><img src="docs/images/badges/license.svg" alt="MIT license"></a>
</p>

<p align="center">
  <a href="https://github.com/lucifly/CodexTaskLight/releases/download/v2.6/CodexTaskLight-v2.6-macOS-arm64.zip"><img src="docs/images/badges/download.svg" alt="Download CodexTaskLight v2.6 for macOS Apple Silicon"></a>
</p>

<p align="center">
  <a href="https://github.com/lucifly/CodexTaskLight/releases/latest">Download</a> ·
  <a href="#preview">Preview</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="docs/USAGE.md">Usage guide</a> ·
  <a href="CHANGELOG.md">Changelog</a> ·
  <a href="https://github.com/lucifly/CodexTaskLight/issues">Report an issue</a>
</p>

CodexTaskLight is an unofficial native macOS utility. Its **40 × 96 point** vertical floating window automatically follows tasks that are running or waiting for your attention. You can also pin a specific task, so you do not have to keep switching back to the chat window.

The app UI is currently in Chinese. The language links above switch the README; the detailed guides linked below are also currently in Chinese.

## Preview

<p align="center">
  <img src="Assets/Halloween-preview.png" width="680" alt="Classic and Halloween skins: waiting or error, running, completed, and unknown states from left to right">
</p>

The top row shows the classic traffic light; the bottom row shows the Halloween skin. This enlarged preview was exported using the app's drawing code, rather than captured from a desktop. The actual floating window remains **40 × 96 points**.

Switch skins using **悬浮窗外观** (floating window appearance) in the details panel, or **外观** (appearance) in the right-click menu. Your choice is saved locally. The ghost, pumpkin, and bat use static vector shapes with no looping flashing animation.

## Quick start

The current version is **2.6**. Download the compiled app without installing development tools, or build it from source.

### Download the app

**[Download CodexTaskLight v2.6 · macOS Apple Silicon](https://github.com/lucifly/CodexTaskLight/releases/download/v2.6/CodexTaskLight-v2.6-macOS-arm64.zip)**

1. Download and unzip the archive, then drag `CodexTaskLight.app` into **Applications**.
2. Open the Codex desktop app, then double-click CodexTaskLight. It displays only a floating window, with no menu bar or Dock icon.
3. Before upgrading, quit the old version from its right-click menu, then replace the app.

The release uses an **ad hoc signature, with no Developer ID signature or Apple notarization**. macOS may block the first launch. After checking the source and file checksum, follow [Apple's instructions](https://support.apple.com/en-us/102445) to allow this specific app to open.

See the [release notes](https://github.com/lucifly/CodexTaskLight/releases/tag/v2.6) for requirements and validation results, and the [SHA-256 checksum file](https://github.com/lucifly/CodexTaskLight/releases/download/v2.6/SHA256SUMS.txt) to verify download integrity. GitHub's automatically generated `Source code` archives contain source code, not the compiled app.

### Requirements

| Item | Requirement and scope |
| :--- | :--- |
| Mac | Apple Silicon / `arm64`; the current build does not include Intel or Universal binaries |
| macOS | Deployment target of macOS 13.0; not tested on every version |
| Codex | A running ChatGPT/Codex desktop app under the same user account, with readable data in the default `~/.codex` directory |
| Build tools | Xcode Command Line Tools or Xcode for source builds only; Python 3 is also needed to regenerate the icon |
| Tracked tasks | Local, unarchived main tasks; excludes subagents, cloud execution, and tasks on other computers |

**Compatibility:** This project relies on internal desktop IPC and local data formats, rather than a stable official API. The implementation targets state protocol v11 and may need changes after desktop app updates. Installing only the Codex CLI does not provide the required desktop status channel.

### Build and open

```bash
git clone https://github.com/lucifly/CodexTaskLight.git
cd CodexTaskLight
./build.command
open dist/CodexTaskLight.app
```

You can also double-click `build.command` in Finder, then open `dist/CodexTaskLight.app` when the build finishes. Start the Codex desktop app before launching this utility.

Source builds also use ad hoc signing. Local build output in `dist/` is excluded from Git; compiled packages are distributed as GitHub Release assets.

<details>
<summary><strong>Install development tools and upgrade a local build</strong></summary>

If Apple development tools are missing, run the following command and finish the system installation process:

```bash
xcode-select --install
```

To upgrade, quit the utility from its right-click menu, update the source, run `./build.command`, and reopen the app. Saved preferences are retained when the application identifier stays the same. See [Build and checks](docs/BUILD.md) for details.

</details>

## Features and states

| Feature | Behavior |
| :--- | :--- |
| Automatic tracking | Prioritizes tasks waiting for your attention, followed by running tasks |
| Manual selection | Search for and pin a local task, switch back to automatic mode at any time, and restore the selection after restart |
| Task name updates | Prefers custom names set in Codex and updates details and search results when the task index changes |
| Live updates | Combines desktop status subscriptions with file events, without periodic log scanning |
| Waiting indicators | Recognizes exposed approval and input requests, plus asynchronous confirmation questions with explicit request IDs |
| Mini floating window | Supports dragging, position memory, and display across desktops; no menu bar or Dock icon |
| Two skins | Classic traffic light and Halloween designs share the same light positions and state rules |
| Local operation | No API key, model calls, or proxy configuration required |

### What the colors mean

| Color | Meaning |
| :--- | :--- |
| 🔴 Red | Waiting for confirmation, approval, or input; also indicates recognized errors. Click for the specific reason |
| 🟡 Yellow | The task is running |
| 🟢 Green | The current execution has ended |
| ⚪ Gray | Unknown state, unavailable live connection, or no valid status received yet |

**Green means the current execution ended; it does not mean tests passed or the whole project is complete.** A question in ordinary chat text alone does not trigger red. See [confirmation detection](docs/USAGE.md#等待确认的识别范围) for the supported scope.

## Everyday use

| Action | Result |
| :--- | :--- |
| Drag the floating window | Move it and save the position on release; the default is near the top-right of the screen |
| Click the floating window | View task details, change tracking mode, or select a skin |
| Right-click the floating window | View details, switch skins, reset the position, or quit |
| Open the app again | Try bringing the floating window back if it is not visible |

Automatic mode prioritizes waiting or running tasks. To follow a fixed target, click the light, choose **手动指定** (manual selection), and search for a task. Red indicates that the selected task needs attention; after you respond, subsequent status updates determine whether it turns yellow or reaches an ended state.

See the [usage guide and FAQ](docs/USAGE.md) for more operations, unavailable manual targets, and persistent gray states.

## How it works and privacy

The desktop status stream supplies task states. File events discover new tasks and identify explicit asynchronous confirmation requests. Incremental log reads, event coalescing, and fixed drawing layers reduce repeated work.

The utility reads task names, states, and relevant log fragments locally; live snapshots may also include task context. It retains only the fields needed for state detection, does not save chat content to a separate log or upload it, and does not read Codex login credentials. Window position, skin, and tracking preferences are saved locally.

Read the [architecture guide](docs/ARCHITECTURE.md) and [privacy notes](docs/PRIVACY.md) for details.

## Development and feedback

| Document | Contents |
| :--- | :--- |
| [Build and checks](docs/BUILD.md) | Compilation, code style, state tests, file events, and resource checks |
| [Contributing](CONTRIBUTING.md) | Guidelines for code changes and contributions |
| [Changelog](CHANGELOG.md) | Features and fixes |
| [Issues and suggestions](https://github.com/lucifly/CodexTaskLight/issues) | Report problems or suggest improvements |

Include versions, reproduction steps, and relevant redacted screenshots in reports. Do not submit your full `~/.codex` directory, real chat logs, or access tokens.

## Star History

<a href="https://www.star-history.com/#lucifly/CodexTaskLight&amp;Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=lucifly/CodexTaskLight&amp;type=Date&amp;theme=dark">
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=lucifly/CodexTaskLight&amp;type=Date">
    <img src="https://api.star-history.com/svg?repos=lucifly/CodexTaskLight&amp;type=Date" alt="GitHub star history for CodexTaskLight, generated dynamically by Star History">
  </picture>
</a>

Star History generates this chart dynamically with light and dark theme support. A new repository without stars may have no visible curve. If the image is temporarily unavailable, follow the chart link above.

## License

[MIT License](LICENSE) · This project is not affiliated with OpenAI and makes no claim of official support or guaranteed compatibility.
