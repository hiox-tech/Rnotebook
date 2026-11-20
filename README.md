# Rnotebook

Rnotebook 是一个由个人设计、由 AI 完成代码实现的原生 macOS 笔记本应用，面向 Quarto（`.qmd`）和 R Markdown（`.Rmd`）文稿，将 Code / Visual 双模式编辑、交互式 R 会话、变量与包检查器、Quarto 报告导出和 Finder 快速查看整合在同一个应用中。

Rnotebook is a native macOS notebook application designed by one individual and implemented by AI. It brings Code / Visual editing, interactive R sessions, variable and package inspection, Quarto report export, and Finder Quick Look together for Quarto (`.qmd`) and R Markdown (`.Rmd`) documents.

## 项目定位 / Scope

应用以普通 `.qmd` / `.Rmd` 源文件为文档，只管理文稿本身。图片、数据和其他依赖保留为外部文件引用；保存或移动文稿时，不会自动收集、归档或迁移这些资源。应用不提供项目管理、可编辑数据网格或完整 IDE 的调试功能。

The application works directly with plain `.qmd` / `.Rmd` source files and manages only the documents themselves. Images, data, and other dependencies remain external file references; saving or moving a document does not collect, archive, or relocate those resources. Project management, editable data grids, and full IDE debugging are outside its scope.

## 主要功能 / Features

- **Code / Visual 编辑**：两种模式共享同一份 Markdown 源码，切换模式不会重新执行 R 代码。支持语法高亮、公式、Mermaid 图形、图片、表格和原生运行结果展示；Visual 模式不是最终报告的等比例排版预览。

  **Code / Visual editing:** Both modes share the same Markdown source, and switching modes does not rerun R code. Features include syntax highlighting, math, Mermaid diagrams, images, tables, and native result displays. Visual mode is not an exact preview of the final report layout.

- **交互式 R 执行**：每份文稿使用独立的 R 会话，可运行当前块、选区、以上、以下或全部代码块。批量运行遵守受支持的静态 `eval` / `error` 选项；明确的手动执行可以运行被 `eval: false` 禁用的代码块。默认遇到首个错误停止，`error: true` 可允许普通运行时错误后继续；选区执行、中断及进程故障仍会停止。

  **Interactive R execution:** Each document has its own R session. Run the current chunk, selected code, chunks above or below, or all chunks. Batch execution honors supported static `eval` / `error` options; explicit manual execution can run a chunk marked `eval: false`. Execution stops at the first error by default; `error: true` permits continuation after ordinary runtime errors. Selected-code execution, interrupts, and process failures still stop execution.

- **检查器与语言工具**：侧栏提供变量预览、分页查看、R 包库管理和帮助搜索；内置 Raven 提供 R 代码补全，Air 提供 R 代码格式化。

  **Inspector and language tools:** The sidebar provides variable previews, paged inspection, R package library management, and help search. Bundled Raven and Air tools provide R code completion and formatting.

- **Quarto 报告导出**：支持 HTML、Word（`.docx`）、Typst PDF 和 LaTeX PDF，可使用文稿 YAML 或自定义参数。导出通过独立的 Quarto 进程渲染，不直接复用交互式会话结果；内置 Edmund 兼容过滤器可转换受支持的高亮、提示块、wiki 链接及图片尺寸等语法。

  **Quarto report export:** Export to HTML, Word (`.docx`), Typst PDF, or LaTeX PDF using document YAML or custom settings. A separate Quarto process renders the report rather than reusing interactive session results. The bundled Edmund compatibility filter converts supported syntax such as highlighting, callouts, wiki links, and image dimensions.

- **Finder 快速查看**：选中 QMD/RMD 文件后按空格预览，可切换源码和 Visual 展示。预览只读，不执行代码，源文件大小上限为 8 MiB。

  **Finder Quick Look:** Press Space on a QMD/RMD file to preview its source or Visual presentation. Previews are read-only, never execute code, and accept source files up to 8 MiB.

- **原生文档管理与双语界面**：支持自动保存、外部修改检测与合并、未保存文稿恢复、文稿窗口状态记忆及只读比较，并提供中文和英文菜单、设置与应用内帮助。

  **Native document handling and bilingual UI:** Features include autosave, external-change detection and merging, recovery of unsaved documents, per-document window state, and read-only comparison, with Chinese and English menus, settings, and in-app help.

## 文件类型兼容与应用更新 / File type compatibility and application updates

应用与 Quick Look 扩展新增对 `org.quarto.qmarkdown` 和 `com.rstudio.rmarkdown` 的支持，并兼容 0.1.0 的旧类型标识。打开面板按 `.qmd` / `.rmd` 扩展名筛选，忽略大小写，避免因系统识别为其他 UTI 而将文稿置灰。0.1.2 改为独立打开面板，避免继承文档控制器的类型限制；文件可选性不再依赖完整的元数据。新增仅更新应用的 PKG，固定安装到 `/Applications` 并核对应用和预览插件版本。按用户要求未运行本机功能测试，实际行为需在问题电脑验收。

The application and Quick Look extension now support `org.quarto.qmarkdown` and `com.rstudio.rmarkdown`, while retaining the legacy identifiers used by 0.1.0. The Open dialog filters `.qmd` / `.rmd` filenames without regard to case, avoiding disabled documents when the system assigns a different UTI. Version 0.1.2 uses an independent Open panel to avoid inherited document-controller restrictions and no longer requires complete metadata to enable a supported filename. An app-only PKG installs to `/Applications` and verifies the app and preview extension versions. Local functional tests were not run at the user's request; acceptance on the affected computer is pending.

## 安装包 / Distribution

当前本地 `dist/` 目录包含以下 0.1.2 安装产物。该目录被 Git 忽略，不随源码克隆；公开下载是否可用，以仓库实际发布的 Release 附件为准。

The local `dist/` directory currently contains the following 0.1.2 artifacts. This directory is excluded from Git and is not included in a source clone. Public download availability depends on the assets actually published with a repository release.

| 架构 / Architecture | 应用更新包 / App-only installer | DMG | 完整离线包 / Full offline installer |
| --- | --- | --- | --- |
| Apple silicon（arm64） | `Rnotebook-0.1.2-arm64-app-only.pkg` | `Rnotebook-0.1.2-arm64.dmg` | `Rnotebook-0.1.2-arm64.pkg` |
| Intel（x86_64） | `Rnotebook-0.1.2-x86_64-app-only.pkg` | `Rnotebook-0.1.2-x86_64.dmg` | `Rnotebook-0.1.2-x86_64.pkg` |

### 应用更新包 / App-only installer

已有运行环境时，推荐使用 `app-only.pkg`。安装前退出旧版应用，安装后从 `/Applications/Rnotebook.app` 启动并确认版本为 0.1.2。仅从 DMG 启动应用不会替换 `/Applications` 中的旧副本。安装脚本验证应用与预览扩展的版本，尝试为当前图形登录用户刷新该应用及扩展的注册，不修改默认打开方式或扩展启用偏好。

Use `app-only.pkg` when a runtime is already installed. Quit the old app first, then launch `/Applications/Rnotebook.app` after installation and confirm version 0.1.2. Launching an app from a DMG does not replace the installed copy. The installer verifies app and preview extension versions and attempts to refresh their registrations for the active graphical user without changing default handlers or extension enablement preferences.

### DMG

包含应用、Quick Look 扩展、帮助和 Air / Raven 语言工具，不包含 R、Quarto 或 PDF 排版环境。编辑文稿无需安装这些运行组件；执行 R 代码和导出报告需要另行准备相应依赖，也可使用 PKG 安装的组件。

Includes the application, Quick Look extension, help, and Air / Raven language tools. R, Quarto, and PDF typesetting tools are not included. Editing does not require those runtime components; executing R code and exporting reports require the corresponding dependencies, which can also be installed from the PKG.

### PKG

提供可分别选择的应用和离线运行组件：

Provides independently selectable application and offline runtime components:

| 组件 / Component | 内容 / Contents |
| --- | --- |
| 应用 / Application | Rnotebook 与 Quick Look 扩展 / Rnotebook and its Quick Look extension |
| R | 独立安装的 R 4.6.2 / Separate R 4.6.2 installation |
| 基础 R 包 / Basic R packages | `evaluate`、`jsonlite`、`rlang`、`knitr`、`rmarkdown` 及其依赖 / and their dependencies |
| Quarto | 1.10.18 |
| TinyTeX | TeX Live 2026，含常用及中文排版宏包（ctex / xeCJK） / TeX Live 2026 with common and Chinese typesetting packages (ctex / xeCJK) |
| Chrome Headless Shell | 158.0.8127.36 |
| PATH 链接 / PATH links | 可选，默认关闭 / Optional, disabled by default |

应用安装到 `/Applications/Rnotebook.app`，离线运行组件安装到 `/Library/Rnotebook`；系统级安装需要管理员权限。安装包不修改已有 R、Quarto、TeX 或浏览器安装及其包库。可选 PATH 链接位于 `/usr/local/bin`，不会覆盖已有命令。设置中明确指定的 R / Quarto 路径优先于自动发现的离线或系统安装。

The application installs to `/Applications/Rnotebook.app`, and offline runtime components install to `/Library/Rnotebook`; system-wide installation requires administrator privileges. The installer does not modify existing R, Quarto, TeX, or browser installations or their libraries. Optional PATH links go in `/usr/local/bin` and do not overwrite existing commands. R / Quarto paths explicitly selected in Settings take precedence over automatically discovered offline or system installations.

安装前的检测提示会列出已有 R、Quarto、TeX 等组件的版本与路径。该提示依赖图形登录会话，45 秒后自动继续；当前构建环境尚未完成真实管理员安装验证。离线组件仅覆盖随包提供的依赖；远程资源、额外 R 包、字体或 TeX 宏包仍可能需要另行获取。

Before installation, a detection dialog lists versions and paths of existing components such as R, Quarto, and TeX. It requires a graphical login session and continues automatically after 45 seconds; an actual administrator installation has not yet been validated in the current build environment. Offline components cover only the supplied dependencies; remote resources, additional R packages, fonts, or TeX packages may still need to be obtained separately.

**签名与验证状态 / Signing and validation status**

应用使用临时签名（ad hoc），安装包未使用 Developer ID Installer 签名，应用与安装包均未公证。macOS 可能拦截首次打开。Intel 版本在 Apple silicon 上交叉编译并完成静态检查，尚未在 Intel 实机运行，应视为预览版本。当前发布记录中的测试环境为 macOS 27 arm64，未对 macOS 14 进行实机复测。

The application is ad-hoc signed; installers are not signed with a Developer ID Installer certificate. Neither the application nor the installers are notarized, so macOS may block them on first open. The Intel build was cross-compiled and statically checked on Apple silicon but has not been run on Intel hardware; treat it as a preview. The recorded release test environment is macOS 27 arm64; macOS 14 has not been physically retested.

## 环境要求 / Requirements

| 场景 / Use | 要求 / Requirements |
| --- | --- |
| 运行应用 / Run the application | macOS 14 Sonoma 或更高版本；Apple silicon 或 Intel Mac / macOS 14 Sonoma or later; Apple silicon or Intel Mac |
| 执行 R / Execute R | 可用的 R / Rscript 及应用所需 R 包 / Working R / Rscript and the R packages required by the application |
| 导出报告 / Export reports | Quarto；运行 R 代码需要对应 R 环境；PDF 需要可用的 Typst 或 TeX 环境 / Quarto; an R environment to execute R code; working Typst or TeX tools for PDF |
| 从源码构建 / Build from source | Xcode 27 或更高版本、Python 3 / Xcode 27 or later and Python 3 |

## 从源码构建 / Build from source

获取源码并构建 Apple silicon Release 应用：

Clone the repository and build the Apple silicon Release application:

```sh
git clone https://github.com/hiox-tech/Rnotebook.git
cd Rnotebook
bash scripts/build.sh Release
open .build/Rnotebook/Build/Products/Release/Rnotebook.app
```

构建 Intel 版本：

Build the Intel version:

```sh
ARCHS=x86_64 RNOTEBOOK_DERIVED_DATA=.build/Rnotebook-x86_64 \
  bash scripts/build.sh Release
```

在 Apple silicon 上运行完整 XCTest 测试：

Run the full XCTest suite on Apple silicon:

```sh
bash scripts/test.sh
```

常规应用构建使用仓库内固定版本的依赖、Air / Raven 二进制及 Tree-sitter 源码，无需 Rust、R、Quarto 或网络访问。重建 Raven 或准备离线运行组件有额外要求，详见[构建说明](docs/BUILDING.md)。

Normal application builds use pinned dependencies, Air / Raven binaries, and Tree-sitter sources included in the repository; Rust, R, Quarto, and network access are not required. Rebuilding Raven or preparing offline runtime components has additional requirements; see the [build instructions](docs/BUILDING.md).

## 文件位置 / File locations

| 数据 / Data | 默认位置 / Default location |
| --- | --- |
| 应用 / Application | `/Applications/Rnotebook.app` |
| 离线运行组件 / Offline runtime | `/Library/Rnotebook` |
| 用户 R 包 / User R packages | `~/Library/Application Support/Rnotebook/R/library` |
| 用户 TeX 宏包 / User TeX packages | `~/Library/Application Support/Rnotebook/texmf` |
| 缓存 / Cache | `~/Library/Caches/org.hiox.Rnotebook` |
| 未保存文稿恢复数据 / Unsaved document recovery | `~/Library/Application Support/Rnotebook` |

保存操作只写入 QMD/RMD 源文件，不保存 R 会话内存或历史输出。重新打开文稿不会自动运行代码。应用不包含遥测、分析或自动更新检查；文稿执行、导出引用的远程资源和在线 R 帮助搜索可能访问网络。

Saving writes only the QMD/RMD source file; R session memory and historical output are not persisted. Reopening a document does not run its code automatically. The application includes no telemetry, analytics, or automatic update checks. Document execution, remote resources referenced during export, and online R help searches may access the network.

## 验证记录 / Verification record

原有发布记录报告：离线运行组件集成前的完整验收共涉及 369 项测试，其中 367 项通过、1 项对时序敏感的编辑器布局测试首次失败但单独重跑通过、1 项既有可选探测跳过。运行组件集成另有 38 项相关测试全部通过。`BatchExecutionPerformance` 的阅读区域测试受环境影响，也曾在未修改的基线上复现失败，因此这些记录不代表完整测试套件无失败通过。

The existing release record reports 369 tests in the full acceptance run before offline runtime integration: 367 passed, one timing-sensitive editor layout test failed initially but passed in isolation, and one existing optional probe was skipped. Another 38 tests related to runtime integration passed. The `BatchExecutionPerformance` reading-band tests are environment-sensitive and also failed on an unmodified baseline, so these records do not establish a clean full-suite pass.

上述为既有验证记录，不构成对后续源码修改的验证。修改后应按构建说明重新运行相关检查；已知平台、执行语义和导出限制见[已知限制](docs/LIMITATIONS.md)。

These are historical verification records and do not validate subsequent source changes. Rerun the relevant checks after changes, following the build instructions. See [known limitations](docs/LIMITATIONS.md) for platform, execution, and export constraints.

## 文档 / Documentation

- [从源码构建 / Building from source](docs/BUILDING.md)
- [架构说明 / Architecture](docs/ARCHITECTURE.md)
- [已知限制 / Known limitations](docs/LIMITATIONS.md)
- [第三方组件与许可证 / Third-party components and licenses](docs/THIRD-PARTY.md)
- [贡献指南 / Contributing](CONTRIBUTING.md)

## 许可证与贡献 / License and contributing

Rnotebook 自身采用 [MIT 许可证](LICENSE)。第三方组件保留各自许可证；相关声明见[第三方组件说明](docs/THIRD-PARTY.md)、`DesktopApp/Resources/ThirdPartyNotices` 和 `ThirdParty/LanguageTools`。

Rnotebook itself is released under the [MIT License](LICENSE). Third-party components retain their own licenses; see the [third-party documentation](docs/THIRD-PARTY.md), `DesktopApp/Resources/ThirdPartyNotices`, and `ThirdParty/LanguageTools` for notices.

贡献前请阅读[贡献指南](CONTRIBUTING.md)。修改应保持范围明确并保留文稿源码；涉及布局、持久化、执行或文件关联的修复应补充回归测试。

Read the [contributing guide](CONTRIBUTING.md) before making changes. Keep changes focused and preserve document source. Add regression tests for fixes affecting layout, persistence, execution, or file associations.
