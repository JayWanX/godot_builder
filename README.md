# GodotBuilder

用 Godot 编写的 **Godot 引擎源码图形化编译工具**。解析 `scons --help` 自动生成分组式构建选项界面（含中文汉化），一键调用 SCons 完成引擎编译，无需手动编辑 `custom.py`。

## 功能特性

- **图形化构建选项**
  - 解析源码 `scons --help` 输出，动态生成全部编译选项（bool / 枚举 / 整数 / 字符串 / 路径类型），无需硬编码选项列表
  - 选项按「基础构建目标 / 优化与性能 / 功能开关 / 渲染与图形驱动 / 构建加速与产物 / 性能分析器 / 编译器与工具链 / Windows 平台特定 / 模块 / 内置库」等分组展示，支持分组导航、搜索过滤与逐组重置
  - 中文汉化：`build_options_zh.json` 提供选项名、描述与分组的中文翻译（`version` 字段标注适用的引擎版本）
- **差异式配置模型**
  - 仅将偏离默认值的选项写入 `custom.py`，保持配置文件最小化
  - `modules_enabled_by_default` 总开关自动派生模块选项默认值；依赖规则自动补全强制项（如 ANGLE 未禁用时强制保留 `module_astcenc_enabled`，避免链接失败）
  - 首次解析自动识别源码 `custom.py`，导入后即保留原工程配置
- **配置管理**
  - 一键构建、取消构建（先发送中断让 SCons 优雅退出，超时后强制终止）
  - `custom.py` 导入 / 导出、配置预览窗口
  - 构建日志实时捕获并落盘到 `user://logs/`，可在「更多」菜单一键清理或打开日志目录
  - 可配置构建产物输出目录：构建成功后把源码目录 `bin/` 下的产物复制到该目录（忽略 `obj` 编译中间文件目录），控制台输出链接同步指向该目录（留空保持默认位置）
- **免安装环境**
  - 内置嵌入式 Python 3.14 运行时（Windows / Linux / macOS 三平台）与 SCons 4.11，首次运行自动解压到 `user://python/`，无需手动安装依赖（仅 `… Embed Python` 预设产物；普通版需自备 Python）
  - 设置中可自定义 Python 解释器路径、SCons 库目录与构建产物输出目录，校验失败自动回退内置
- **源码目录管理**
  - 自动扫描源码扫描目录下的一级子目录，识别 Godot 版本并快速切换；扫描目录可在设置中自定义（留空使用可执行文件旁的 `sources/`）
  - 构建前自动检测当前环境可构建的平台列表（`scons platform=list`）
  - 一键在源码目录或程序目录打开系统终端
- **命令行（CLI）**
  - 同一份核心逻辑双入口：已导出的可执行文件以 `--headless` 启动即进入无界面模式；开发期用 `godot --headless --script res://tools/cli.gd` 运行
  - `build` 编译引擎（裸 `键=值` 构建选项对齐 SCons，或 `--profile` 透传 custom.py）、`options` 列选项（表格 / `--json`）、`config export/import` 配置往返、`check-options` 汉化覆盖检查、`gen-key` 生成 PCK 加密密钥
  - 终端只输出关键节点与错误，完整 SCons 日志落盘到 `logs/` 并打印路径；退出码区分 0 成功 / 1 执行失败 / 2 参数或环境错误
- **工程集成**
  - `scons --help` 磁盘缓存：缓存键含源码内容哈希，第三方改动 `SConstruct` / `version.py` 后自动失效，可在「更多」菜单手动清除
  - PCK 加密编译密钥注入：设置中配置的密钥以 `SCRIPT_AES256_ENCRYPTION_KEY` 环境变量注入 SCons 子进程，`secrets.dat` 做混淆存储（绑定本机与可执行文件路径）；「更多 → 生成加密密钥」或 CLI `gen-key` 可生成 64 位十六进制密钥并输出到控制台（点击密钥复制到剪贴板），不自动写入本机存储
  - 配套 GitHub Actions 工作流：云端远程编译 Godot 引擎（Linux / Windows / macOS / Android / iOS / visionOS / Web），并可一键构建导出模板、产出本工具三平台成品；推送 `v*` Tag 时自动导出成品并上传为 Release 附件。CI 资产本体在独立仓库 **`godot_ci`**（`JayWanX/godot_ci`，本地 `../godot_ci/`），使用说明见其 `.github/docs/workflows.md`；本仓库只留契约与薄触发器（L2 触发层）

## 获取构建版本

- **预构建版**：从本仓库 **Releases** 页面下载（若已发布）
- **自行构建**：使用 Godot 4.7.x 打开项目，按下方「导出打包」章节导出

## 环境要求

| 环境         | 说明                                                                                      |
| ------------ | ----------------------------------------------------------------------------------------- |
| Godot 编辑器 | 4.7.x（项目使用 gl_compatibility 渲染器与 GDScript 4 语法）                          |
| 目标引擎源码 | 任意版本 Godot 引擎源码（依赖 `SConstruct` 与 `version.py` 完整性校验）                   |
| 编译工具链   | 与官方编译文档一致（如 Windows 需 VS Build Tools，Linux 需 gcc 等）——工具本身不内置编译器 |

编译目标引擎时所需工具链请参考 [Godot 官方编译文档](https://docs.godotengine.org/en/stable/contributing/development/compiling/)。

## 开发运行

1. 使用 Godot 4.7.x 编辑器打开本项目
2. 直接运行主场景 `res://main.tscn`
3. 将 Godot 引擎源码放入可执行文件（编辑器运行模式下为项目目录）旁的 `sources/` 文件夹，或点击源码按钮手动选择

> 运行时的**源**是项目内的 `python/` 资源目录（仅 `… Embed Python` 预设打包进 PCK，普通版不含）；**运行位置**统一在 `user://python/`，首次运行从 PCK 解压到那里。两处目录结构一致：`<平台>/` 与 `site-packages/` 直接平铺在根下。下载缓存同样落在 `user://runtime_cache/`。

## 导出打包

- 项目根目录 `export_presets.cfg` 为唯一导出预设，本地与云端共用；本地点导出写回的本机路径由 CI 导出前清洗（`prepare_presets.py`），无需还原或另存干净版本
- **每平台两个预设**：普通版（`Windows Desktop` / `Linux/X11` / `macOS`，不含 `python/` 目录，需用户自备 Python）与 `… Embed Python` 版（`custom_features="embed-python"`，内嵌运行时并裁剪）。两个版本各自独立打包上传，产物名随预设名带 `_embed_python` 后缀
- 项目自带导出裁剪插件 `addons/godot_builder_export/`：内嵌版按 `python_runtime_manifest.json` 的保留集裁掉非目标平台运行时与未使用的标准库/站点包，缩减体积；普通版整个 `python/` 目录不打包
- 运行时由 CI 钩子 `tools/fetch_python_runtime.py` 在导出前装配（仅内嵌版预设触发，见 `.github/ci-hooks.json`），幂等跳过已齐备的情况
- 用于编译本工具自身精简版引擎的配置集中在 `build/` 目录：`profile.py`（SCons 参考配置）、`project.gdbuild`（类型裁剪）
- 可在 GitHub Actions 云端一键构建模板并导出三平台成品（自导出工作流），使用说明见 CI 资产仓库 `godot_ci` 的 `.github/docs/workflows.md`

## 目录结构

```
.
├── main.gd / main.tscn      # 主场景与逻辑
├── src/                     # 核心逻辑
│   ├── godot_builder.gd     # 构建器：运行时解压、SCons 调用、环境探测、help 缓存
│   ├── scons_help_parser.gd # scons --help 输出解析
│   ├── build_options.gd     # 选项元数据仓库与分组（含中文汉化合并）
│   ├── config_store.gd      # 配置差异字典 + 依赖规则 + 模块开关派生
│   ├── profile_converter.gd # custom.py <-> 配置字典双向转换
│   ├── secret_store.gd      # PCK 加密密钥混淆存取
│   ├── encryption_key.gd    # PCK 加密密钥生成与校验（CLI / GUI 共享）
│   ├── build_logger.gd      # 构建日志落盘
│   ├── console.gd           # 控制台输出（GUI 面板 / CLI stdout 双通道）
│   ├── cli_commands.gd      # CLI 共享核心：参数解析 + build/options/config/check-options
│   ├── app_data.gd          # 应用数据（exe 旁 app_data.tres）
│   ├── python_runtime_manifest.gd  # 运行时清单读取与保留判定（与 fetch_python_runtime 同构）
│   ├── python_runtime_provisioner.gd # 运行时装配编排（下载→解压裁剪→落盘）
│   ├── install_spec_parser.gd # 从引擎 misc/scripts/install_*.py 解析依赖下载规格
│   ├── dependency_installer.gd # 编译依赖安装（列候选、下载解压、MinGW 适配）
│   └── utils.gd             # 版本解析、源码扫描、打开终端等工具
├── ui/                      # 界面：panels（表单/分组导航/摘要/控制台）、
│                            #   windows（配置预览）、dialogs（设置、编译依赖选择）、controls（字段控件/状态栏）
├── addons/
│   ├── pipe_process_runner/ # 进程管道运行器（stdout/stderr 捕获、中断/终止）
│   └── godot_builder_export/ # 导出裁剪插件
├── python/                  # 打包进 PCK 的运行时源（<平台>/ + site-packages/SCons），与 user://python/ 同构
├── assets/                  # 资源目录（UI 图标等）
├── icon.svg / project.godot # 应用图标与 Godot 项目设置
├── build/                   # 本工具自身的构建配置
│   ├── profile.py           # 编译本工具自身的 custom.py 参考配置
│   └── project.gdbuild      # 精简构建配置（类型裁剪）
├── export_presets.cfg       # 导出预设（本地/云端共用，CI 导出前清洗）
├── build_options_zh.json    # 构建选项中文汉化数据
├── python_runtime_manifest.json    # 运行时清单：下载资产与裁剪保留集的唯一来源
├── tools/                   # 本地工具脚本（不进 CI）
│   ├── cli.gd               # CLI 独立入口：--script 转发到 CliCommands
│   ├── check_build_options_zh.gd  # 汉化覆盖检查入口（委托 CliCommands 的 check-options）
│   └── fetch_python_runtime.py # CI 专用：无参数准备三平台 Python 运行时到 python/（产物不入库）
└── .github/                 # 触发层：CI 资产本体在独立仓库 godot_ci（@main 跟随更新；40 位 SHA 锁版本）
	├── ci-contract.json     # 项目契约实例（唯一项目配置入口，字段以 godot_ci 的 contract/*.schema.json 为准）
	└── workflows/           # 3 个薄触发器（build / export / release），uses: godot_ci@<ref> 转发
```

## 使用流程

1. **选择源码**：点击左上角源码按钮，从扫描结果或文件对话框中选取 Godot 引擎源码目录（扫描目录默认取可执行文件旁的 `sources/`，可在设置中自定义）
2. **配置选项**：在左侧分组导航与右侧表单中调整编译选项，修改项实时汇总到顶部摘要；支持搜索定位与整组重置
3. **导入/导出**：可将现有 `custom.py` 导入作为配置基础，或将当前配置导出为 `custom.py`
4. **开始构建**：点击「构建」按钮，控制台实时显示 SCons 输出；构建产物位于源码目录 `bin/`（若配置了输出目录则同时复制过去），日志保存至 `user://logs/`
5. **设置 / 更多**：在「更多」菜单中配置自定义 Python / SCons 路径、引擎源码扫描目录、构建产物输出目录、PCK 加密编译密钥，清除 help 缓存、清理或打开构建日志、打开终端、生成加密密钥、按需下载 Python 环境与编译依赖

## 命令行用法

CLI 与 GUI 共用 `src/cli_commands.gd` 一份逻辑，仅入口不同。**已导出的可执行文件以 `--headless` 启动即自动进入 CLI**

```sh
# 已导出的可执行文件（无界面）
GodotBuilder --headless -- <命令> [参数] [键=值 ...]
# 工程脚本（开发期）
godot --headless --path <本项目> --script res://tools/cli.gd -- <命令> [参数] [键=值 ...]
```

| 命令 | 说明 |
| --- | --- |
| `build` | 编译引擎源码：裸 `键=值` 可重复（差异式，生成全量 profile 压住源码 custom.py），或 `--profile <文件>` 直接透传（两者互斥）；`--output-dir` 复制产物。未知构建选项报错退出并提示相近键 |
| `options` | 列出 `scons --help` 选项：`--group` / `--search` 过滤，`--json` 输出结构化数据 |
| `config export` | 把配置写为 custom.py：`--output <文件>`，可用 `--profile` 作基础、裸 `键=值` 覆盖 |
| `config import` | 读取 custom.py：`--input <文件>`，`--json` 输出键值 |
| `check-options` | 检查 `build_options_zh.json` 汉化覆盖（原 `check_build_options_zh.gd` 已委托此命令） |
| `fetch-python-runtime` | 下载并装配嵌入式 Python 运行时与 SCons 到 `user://python/`（同「更多 → 下载 Python 环境」） |
| `deps list` | 列出当前源码可安装的编译依赖：`--json` 输出结构化数据 |
| `deps install` | 安装编译依赖：`--all` 装全部，或 `--id=angle,accesskit` 按项安装；`--keep-cache` 保留归档 |
| `gen-key` | 生成 64 位十六进制 PCK 加密密钥（`ENCRYPTION_KEY`），`--save` 时同时写入本机 `secrets.dat` |
| `help` | 显示完整帮助 |

应用参数：`--source <引擎源码目录>`、`--python`、`--scons-dir`、`--id`、`--all`、`--keep-cache`、`--json`、`--save`、`--version` 等。退出码 `0` 成功 / `1` 执行失败 / `2` 参数或环境错误。

示例：

```sh
# 列出「优化与性能」分组的选项
godot --headless --path <本项目> --script res://tools/cli.gd -- options --source=D:/godot --group=optimize
# 差异式配置编译（等价于 GUI 里勾选后构建；裸 键=值 对齐 SCons 风格）
GodotBuilder --headless -- build --source=D:/godot target=template_release optimize=size_extra
# 直接透传现成 custom.py
GodotBuilder --headless -- build --source=D:/godot --profile=D:/my_custom.py
# 装配嵌入式运行时（同「更多 → 下载 Python 环境」）
GodotBuilder --headless -- fetch-python-runtime
# 查看可安装的编译依赖
GodotBuilder --headless -- deps list --source=D:/godot
# 安装全部编译依赖，或只装指定项
GodotBuilder --headless -- deps install --source=D:/godot --all
GodotBuilder --headless -- deps install --source=D:/godot --id=angle,accesskit
# 生成 PCK 加密密钥（复制输出填入 GitHub Secrets 或设置对话框）
GodotBuilder --headless -- gen-key
# 生成并直接写入本机密钥存储
GodotBuilder --headless -- gen-key --save
```

> 终端只输出关键节点（开始 / 成功 / 失败）与错误；完整 SCons 日志经 `BuildLogger` 落盘到 `user://logs/`，启动时打印路径。自定义 Python / SCons 路径未指定时沿用 GUI 设置，否则回退内置运行时。

## 许可证

[MIT](LICENSE)
