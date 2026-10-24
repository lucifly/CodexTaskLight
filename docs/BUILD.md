# 构建与检查

[返回 README](../README.md)

## 工具要求

- Apple Silicon Mac。
- Xcode Command Line Tools 或 Xcode，可运行 `xcrun swiftc`。
- Python 3：重新生成图标时使用，仅依赖标准库。
- macOS 自带的 `sips`、`iconutil` 和 `codesign`。

构建不需要 GitHub CLI、API Key、Homebrew 包或第三方 Python 库。

可先检查工具是否可用：

```bash
xcrun swiftc --version
python3 --version
```

如未安装 Apple 开发工具，可运行 `xcode-select --install` 并完成系统安装流程。

## 编译应用

在仓库根目录运行：

```bash
./build.command
```

脚本执行以下工作：

1. 必要时重新生成图标。
2. 编译 `Sources/` 中的三个 Swift 文件。
3. 生成应用的 `Info.plist` 并复制图标。
4. 为本地应用执行 ad hoc 签名。

输出：`dist/CodexTaskLight.app`。

当前脚本明确指定 `arm64-apple-macosx13.0`，不生成 Intel 或 Universal 版本。`13.0` 是部署目标，不代表已在所有 macOS 版本上测试。

已有应用在运行时，请先退出再编译。

## 运行

```bash
open dist/CodexTaskLight.app
```

需要长期使用时，也可以在访达中将构建后的应用复制到应用程序文件夹，再从那里打开。

## 检查

状态识别、任务优先级、确认请求关联和增量状态补丁检查：

```bash
./dist/CodexTaskLight.app/Contents/MacOS/CodexTaskLight --test
```

真实文件事件检查：

```bash
./dist/CodexTaskLight.app/Contents/MacOS/CodexTaskLight --file-test
```

文件事件检查会在当前工作目录创建并清理 `.codextasklight-test-*` 合成任务目录，验证追加、分段写入、新任务发现、替换与截断；不会修改真实 Codex 任务，也不会接入真实状态订阅。请从仓库目录运行；macOS 可能不向临时或缓存目录发送 FSEvents 事件。

大量历史任务与句柄限制回归检查：

```bash
./dist/CodexTaskLight.app/Contents/MacOS/CodexTaskLight --resource-test
```

此检查仅将自己的测试进程句柄上限降至 64，验证 131 个合成任务、最旧日志重新执行、新任务发现、事件丢失后的校准和事件流重建。不会修改系统上限或其他应用。

检查签名及应用配置：

```bash
codesign --verify --verbose dist/CodexTaskLight.app
plutil -lint dist/CodexTaskLight.app/Contents/Info.plist
```

这些检查不替代实际的悬浮窗交互、审批流程、多屏幕和系统兼容性测试。

## 代码风格检查

Swift 使用 Xcode Command Line Tools 自带的 `swift-format`。仓库的 `.swift-format` 固定四空格缩进、120 列换行目标及完整规则配置；严格模式下任何诊断都会使检查失败。构建同样将编译器警告视为错误。

Python 使用 `requirements-dev.txt` 固定版本的 Ruff，规则见 `.ruff.toml`，覆盖格式、导入顺序、未使用变量、常见错误及 Python 3.9 兼容写法。只需为开发检查安装 Ruff，构建应用本身不需要它：

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-dev.txt
./lint.command
```

`lint.command` 检查 `Sources/`、`Tools/` 中的 Swift、Python 文件及仓库内 Zsh 入口脚本的语法，不修改文件。它优先使用 `.venv/bin/ruff`，也支持 PATH 中的 Ruff，或通过 `CODEXTASKLIGHT_RUFF` 指定工具路径。`.venv/` 与 Ruff 缓存不会纳入源码提交。

手动应用格式修正：

```bash
xcrun swift-format format --in-place --recursive --configuration .swift-format Sources Tools
.venv/bin/ruff check --fix .
.venv/bin/ruff format .
```

`swift-format` 随开发工具更新，修改其版本后应重新检查配置兼容性和格式结果。

## 图标资源

- `Assets/AppIcon.png`：1024 像素原图。
- `Assets/AppIcon-preview.png`：README 使用的预览。
- `Assets/AppIcon.icns`：macOS 多尺寸图标。
- `Tools/DrawAppIcon.swift`：图标绘制源文件。
- `Tools/BuildIcon.py`：生成、缩放、打包和清理图像元数据。

修改图标绘制代码后，可运行：

```bash
python3 Tools/BuildIcon.py
./build.command
```

README 的预览图需要另行同步更新。默认构建会在图标不存在或生成工具较新时重新打包图标。

## 发布与版本

`build.command` 中的 `CFBundleShortVersionString` 和 `CFBundleVersion` 是当前版本来源。`CFBundleIdentifier` 沿用 `local.codex.statuslight`，用于保留已有用户偏好，不因应用显示名称变化而更换。

`dist/`、应用包和压缩包不纳入源码提交。若后续发布二进制，可作为 GitHub Release 附件上传；发布前应核实内容、签名及公证状态。仓库当前不包含自动上传或发布流程。
