class_name CliCommands
extends RefCounted
## GodotBuilder 命令行共享核心：解析用户参数并分发 build / options / config / check-options / help。[br][br]
## 两个入口（已导出可执行文件的 headless 模式与 --script 脚本）共用本类，保证行为一致。

#region 常量：退出码
const EXIT_OK: int = 0
const EXIT_FAILED: int = 1
const EXIT_USAGE: int = 2
#endregion

#region 常量：命令与子命令
const CMD_BUILD: String = "build"
const CMD_OPTIONS: String = "options"
const CMD_CONFIG: String = "config"
const CMD_CHECK_OPTIONS: String = "check-options"
const CMD_FETCH_PYTHON_RUNTIME: String = "fetch-python-runtime"
const CMD_DEPS: String = "deps"
const CMD_GEN_KEY: String = "gen-key"
const CMD_HELP: String = "help"
const SUBCMD_EXPORT: String = "export"
const SUBCMD_IMPORT: String = "import"
const SUBCMD_LIST: String = "list"
const SUBCMD_INSTALL: String = "install"
#endregion

#region 常量：参数名
const OPT_SOURCE: String = "source"
const OPT_ENGINE_DIR: String = "engine-dir"
const OPT_PROFILE: String = "profile"
const OPT_OUTPUT: String = "output"
const OPT_INPUT: String = "input"
const OPT_OUTPUT_DIR: String = "output-dir"
const OPT_PYTHON: String = "python"
const OPT_SCONS_DIR: String = "scons-dir"
const OPT_GROUP: String = "group"
const OPT_SEARCH: String = "search"
const OPT_ID: String = "id"
const OPT_ALL: String = "all"
const OPT_KEEP_CACHE: String = "keep-cache"
const OPT_JSON: String = "json"
const OPT_SAVE: String = "save"
const OPT_HELP: String = "help"
const OPT_VERSION: String = "version"
#endregion

#region 常量：参数解析规则
## 需要取值的参数（支持 --key=value 与 --key value 两种写法）。
const VALUE_OPTIONS: PackedStringArray = [
	"source", "engine-dir", "profile", "output", "input", "output-dir",
	"python", "scons-dir", "group", "search", "id",
]
## 开关型参数（出现即为 true）。
const FLAG_OPTIONS: PackedStringArray = ["json", "save", "help", "version", "all", "keep-cache"]
#endregion

#region 常量：分项安装列表与字节换算
## 依赖 id 分隔符（--id=a,b 与汇总输出共用）。
const ID_SEPARATOR: String = ","
## 字节到 MB 的换算基数。
const BYTES_PER_MB: float = 1048576.0
#endregion
#region 常量：输出与文件
## 复制构建产物时忽略的子目录名（obj 为 SCons 重定向的编译中间文件目录）。
const ARTIFACT_IGNORE_DIR_NAMES: PackedStringArray = ["obj"]
## 选项元数据字段键名。
const KEY_ACTUAL: String = "actual"
## 完整帮助文本（逐行拼接，避免依赖多行字符串语法）。
const HELP_LINES: PackedStringArray = [
	"GodotBuilder CLI —— 图形化引擎编译工具的命令行入口",
	"",
	"用法（已导出的可执行文件）：",
	"  GodotBuilder --headless -- <命令> [参数] [键=值 ...]",
	"用法（工程脚本）：",
	"  godot --headless --path <工程目录> --script res://tools/cli.gd -- <命令> [参数] [键=值 ...]",
	"",
	"-- 是 Godot 引擎的用户参数分隔符，其后参数才由 CLI 读取，不可省略。",
	"命令之后的裸 键=值 为 SCons 构建选项（无需 --set 前缀）；带 -- 前缀的是本工具自身的应用参数。",
	"",
	"命令：",
	"  build           编译引擎源码",
	"  options         列出 scons --help 构建选项",
	"  config export   导出配置为 custom.py",
	"  config import   从 custom.py 读取配置",
	"  check-options   检查 build_options_zh.json 汉化覆盖",
	"  fetch-python-runtime   下载并装配嵌入式 Python 运行时与 SCons",
	"  deps list       列出当前源码可安装的编译依赖",
	"  deps install    安装编译依赖（--all 装全部，否则需 --id）",
	"  gen-key         生成 PCK 加密编译密钥（ENCRYPTION_KEY）",
	"  help            显示本帮助",
	"",
	"应用参数（带 -- 前缀）：",
	"  --source=<目录>      Godot 引擎源码目录（build / options / config / check-options / deps 必需）",
	"  --profile=<文件>     直接透传 custom.py 给 SCons（build，与裸 键=值 互斥）",
	"  --output-dir=<目录>  build 成功后复制产物到该目录（忽略 obj 中间文件目录）",
	"  --python=<路径>      自定义 Python 解释器（默认取 GUI 设置，否则内置运行时）",
	"  --scons-dir=<目录>   自定义 SCons 库目录",
	"  --group=<键>         options 只显示指定分组",
	"  --search=<文本>      options 按选项名或中文名过滤",
	"  --output=<文件>      config export 写出的 custom.py 路径",
	"  --input=<文件>       config import 待读取的 custom.py",
	"  --id=<id,id>         deps install 要安装的依赖 id（逗号分隔）",
	"  --all                deps install 安装全部候选依赖",
	"  --keep-cache         deps install 保留已下载的归档",
	"  --json               options / config import / deps list 以 JSON 输出",
	"  --save               gen-key 时同时写入本机密钥存储（secrets.dat）",
	"  --help               显示本帮助",
	"  --version            显示 Godot 运行时版本",
	"",
	"示例：",
	"  GodotBuilder --headless -- build --source=D:/godot target=template_release optimize=size_extra",
	"  GodotBuilder --headless -- options --source=D:/godot --group=optimize",
	"  GodotBuilder --headless -- config export --source=D:/godot --output=D:/custom.py target=template_release",
	"  GodotBuilder --headless -- fetch-python-runtime",
	"  GodotBuilder --headless -- deps list --source=D:/godot",
	"  GodotBuilder --headless -- deps install --source=D:/godot --all",
	"  GodotBuilder --headless -- deps install --source=D:/godot --id=angle,accesskit",
	"  GodotBuilder --headless -- gen-key",
	"  GodotBuilder --headless -- gen-key --save",
	"",
	"退出码：0 成功 / 1 执行失败 / 2 参数或环境错误",
	"说明：构建的完整 SCons 日志落盘到 user:// 下的 logs/，终端只输出关键节点与错误，结束打印日志路径。",
]
#endregion

#region Public
## 解析并执行 CLI 命令。[br][br]
## [param p_args] 用户参数（不含引擎级参数）。[br]
## [return] 0 成功 / 1 执行失败 / 2 参数或环境错误。
func run(p_args: PackedStringArray) -> int:
	Console.set_cli_mode(true)
	# 详细日志不刷终端：关键信息由本核心直接 print，SCons 输出在 build 期间重定向到日志文件。
	Console.set_cli_quiet(true)
	var parsed: ParsedArgs = ParsedArgs.parse(p_args, VALUE_OPTIONS, FLAG_OPTIONS)
	if not parsed.error.is_empty():
		printerr(parsed.error)
		return EXIT_USAGE
	for item: String in parsed.assignments:
		var eq: int = item.find("=")
		if eq <= 0 or eq == item.length() - 1:
			printerr("构建选项格式应为 <键>=<值>：%s" % item)
			return EXIT_USAGE
	if parsed.options.has(OPT_VERSION):
		_print_version()
		return EXIT_OK
	if parsed.command.is_empty() or parsed.command == CMD_HELP or parsed.options.has(OPT_HELP):
		_print_help()
		return EXIT_OK
	var code: int = EXIT_USAGE
	match parsed.command:
		CMD_BUILD:
			code = await _cmd_build(parsed)
		CMD_OPTIONS:
			code = await _cmd_options(parsed)
		CMD_CONFIG:
			code = await _cmd_config(parsed)
		CMD_CHECK_OPTIONS:
			code = await _cmd_check_options(parsed)
		CMD_FETCH_PYTHON_RUNTIME:
			code = await _cmd_fetch_python_runtime(parsed)
		CMD_DEPS:
			code = await _cmd_deps(parsed)
		CMD_GEN_KEY:
			code = _cmd_gen_key(parsed)
		_:
			printerr("未知命令：%s" % parsed.command)
			_print_help()
			code = EXIT_USAGE
	return code
#endregion

#region Private：命令实现
## 编译引擎源码。
func _cmd_build(p_parsed: ParsedArgs) -> int:
	if not _ensure_runtime(p_parsed):
		return EXIT_USAGE
	var source: String = _resolve_source(p_parsed)
	if source.is_empty():
		return EXIT_USAGE
	var builder: GodotBuilder = await _create_builder(p_parsed)
	var profile_path: String = ""
	if p_parsed.options.has(OPT_PROFILE):
		if not p_parsed.assignments.is_empty():
			printerr("--profile 与裸 键=值 互斥：透传模式下不能叠加配置")
			return EXIT_USAGE
		profile_path = _globalize(p_parsed.options.get(OPT_PROFILE, ""))
		if not FileAccess.file_exists(profile_path):
			printerr("编译配置文件不存在：%s" % profile_path)
			return EXIT_USAGE
	else:
		var build_options: BuildOptions = await _get_build_options(builder, source)
		if build_options == null:
			return EXIT_FAILED
		var config: Dictionary = _parse_assignments(p_parsed.assignments, build_options)
		if config.is_empty() and not p_parsed.assignments.is_empty():
			return EXIT_USAGE
		var store: ConfigStore = ConfigStore.new(config, build_options)
		var profile_text: String = ProfileConverter.config_to_profile(
			store.get_full_config(), build_options, true
		)
		var profile_file: FileAccess = FileAccess.create_temp(
			FileAccess.WRITE, "godot_build_profile", ".py"
		)
		if profile_file == null:
			printerr("写入临时编译配置文件失败：%s" % FileAccess.get_open_error())
			return EXIT_FAILED
		profile_file.store_string(profile_text)
		profile_file.close()
		profile_path = profile_file.get_path_absolute()

	var logger: BuildLogger = _start_build_log()
	SecretStore.reload()
	print("开始构建：%s" % source)
	if logger != null:
		print("完整日志：%s" % logger.get_path())
	# SCons 输出经 GodotBuilder 的 runner 回调统一进 Console，Console 已重定向到日志器，
	# 无需再把 handle 的 stdout/stderr 直连日志器（否则同一行会写两遍）。
	var handle: PipeProcessHandle = builder.build(source, profile_path)
	if handle == null:
		_finish_build_log(logger)
		printerr("启动构建进程失败")
		return EXIT_FAILED
	var record: PipeProcessRecord = await handle.exited
	_finish_build_log(logger)
	if record.exit_code != 0:
		printerr("构建失败：退出码 %d" % record.exit_code)
		return EXIT_FAILED
	var output_dir: String = _publish_artifacts(source, _globalize(p_parsed.options.get(OPT_OUTPUT_DIR, "")))
	print("构建成功，产物目录：%s" % output_dir)
	return EXIT_OK

## 列出 scons --help 构建选项。
func _cmd_options(p_parsed: ParsedArgs) -> int:
	if not _ensure_runtime(p_parsed):
		return EXIT_USAGE
	var source: String = _resolve_source(p_parsed)
	if source.is_empty():
		return EXIT_USAGE
	var builder: GodotBuilder = await _create_builder(p_parsed)
	var build_options: BuildOptions = await _get_build_options(builder, source)
	if build_options == null:
		return EXIT_FAILED
	var group_filter: String = p_parsed.options.get(OPT_GROUP, "")
	var search: String = p_parsed.options.get(OPT_SEARCH, "")
	var rows: Array[Dictionary] = []
	for group_key: String in build_options.get_all_groups():
		if not group_filter.is_empty() and group_key != group_filter:
			continue
		var group_display: String = str(
			build_options.get_all_groups()[group_key].get(BuildOptions.KEY_DISPLAY_NAME, "")
		)
		var group_options: Dictionary = build_options.get_options_of(group_key)
		for option_key: String in group_options:
			var display_name: String = build_options.get_display_name(option_key)
			if not search.is_empty() and not option_key.contains(search) and not display_name.contains(search):
				continue
			var option: Dictionary = build_options.get_option(option_key)
			rows.append({
				"key": option_key,
				"name": display_name,
				"group": group_key,
				"group_name": group_display,
				"type": str(option.get(ConfigStore.KEY_TYPE, "")),
				"default": str(option.get(ConfigStore.KEY_DEFAULT, "")),
				"actual": str(option.get(KEY_ACTUAL, "")),
			})
	if p_parsed.options.has(OPT_JSON):
		print(JSON.stringify(rows, "\t"))
		return EXIT_OK
	print("选项名\t中文名\t分组\t分组名\t类型\t默认值\t实际值")
	for row: Dictionary in rows:
		print("%s\t%s\t%s\t%s\t%s\t%s\t%s" % [
			row.get("key", ""), row.get("name", ""), row.get("group", ""),
			row.get("group_name", ""), row.get("type", ""),
			row.get("default", ""), row.get("actual", ""),
		])
	return EXIT_OK

## 配置导入 / 导出。
func _cmd_config(p_parsed: ParsedArgs) -> int:
	if not _ensure_runtime(p_parsed):
		return EXIT_USAGE
	var source: String = _resolve_source(p_parsed)
	if source.is_empty():
		return EXIT_USAGE
	var builder: GodotBuilder = await _create_builder(p_parsed)
	var build_options: BuildOptions = await _get_build_options(builder, source)
	if build_options == null:
		return EXIT_FAILED
	match p_parsed.subcommand:
		SUBCMD_EXPORT:
			return _config_export(p_parsed, build_options)
		SUBCMD_IMPORT:
			return _config_import(p_parsed, build_options)
		_:
			printerr("config 需要子命令 export 或 import")
			return EXIT_USAGE

## 检查汉化数据是否覆盖 scons --help 全部选项。
func _cmd_check_options(p_parsed: ParsedArgs) -> int:
	if not _ensure_runtime(p_parsed):
		return EXIT_USAGE
	var source: String = _resolve_source(p_parsed)
	if source.is_empty():
		return EXIT_USAGE
	var builder: GodotBuilder = await _create_builder(p_parsed)
	var help_text: String = await builder.get_scons_help_cached(source)
	if help_text.is_empty():
		printerr("获取 scons --help 失败：%s" % source)
		return EXIT_USAGE
	var parsed_options: Dictionary = SconsHelpParser.parse(help_text)
	var localization: Dictionary = BuildOptions.BUILD_OPTIONS_ZH.data
	var localized_options: Dictionary = localization.get(BuildOptions.KEY_OPTIONS, {})
	var groups: Dictionary = localization.get(BuildOptions.KEY_GROUPS, {})
	var missing: Array[String] = _collect_missing(parsed_options, localized_options)
	var stale: Array[String] = _collect_stale(parsed_options, localized_options)
	var bad_group: Array[String] = _collect_bad_groups(localized_options, groups)
	print("scons --help 选项 %d 个 / 汉化条目 %d 个" % [parsed_options.size(), localized_options.size()])
	var has_gap: bool = false
	if not missing.is_empty():
		has_gap = true
		print("缺失汉化 %d 个（help 有、json 无）：" % missing.size())
		for option_key: String in missing:
			print("  - %s（建议分组：%s）" % [option_key, SconsHelpParser.infer_group(option_key)])
	if not stale.is_empty():
		has_gap = true
		print("过时条目 %d 个（json 有、引擎已无）：" % stale.size())
		for option_key: String in stale:
			print("  - %s" % option_key)
	if not bad_group.is_empty():
		has_gap = true
		print("无效分组引用 %d 个：" % bad_group.size())
		for option_key: String in bad_group:
			print("  - %s → %s" % [
				option_key, str(localized_options[option_key].get(BuildOptions.KEY_GROUP, ""))
			])
	var json_version: String = str(localization.get("version", ""))
	var engine_version: String = "godot-" + Utils.parse_godot_version(source)
	if json_version != engine_version:
		print("警告：版本不一致 json=%s 引擎=%s，选项集可能已变化，请同步 version 字段" % [json_version, engine_version])
	if has_gap:
		return EXIT_FAILED
	print("覆盖完整")
	return EXIT_OK

## 下载并装配嵌入式 Python 运行时与 SCons（同 GUI「下载 Python 环境」，只备宿主平台）。
func _cmd_fetch_python_runtime(_p_parsed: ParsedArgs) -> int:
	var platform: String = GodotBuilder.get_host_platform()
	var provisioner: PythonRuntimeProvisioner = PythonRuntimeProvisioner.new()
	if not provisioner.initialize("", _make_provision_progress(true)):
		printerr("运行时清单加载失败：%s" % PythonRuntimeManifest.MANIFEST_REL_PATH)
		return EXIT_FAILED
	print("开始装配运行时（平台 %s）" % platform)
	var outcome: Dictionary = await provisioner.provision(platform, "", false)
	if not bool(outcome.get("ok", false)):
		printerr("运行时装配失败：%s" % str(outcome.get("reason", "")))
		return EXIT_FAILED
	print("运行时装配完成：%d 个文件，%.1f MB" % [
		int(outcome.get("files", 0)), int(outcome.get("bytes", 0)) / BYTES_PER_MB])
	print("安装位置：%s" % ProjectSettings.globalize_path(PythonRuntimeProvisioner.PYTHON_RUNTIME_ROOT))
	return EXIT_OK

## 编译依赖：list 列出候选，install 按 --id / --all 安装。
func _cmd_deps(p_parsed: ParsedArgs) -> int:
	# 参数冲突先于任何 I/O 报出：--all 与 --id 同时给出属用法错误
	if p_parsed.subcommand == SUBCMD_INSTALL and p_parsed.options.has(OPT_ALL) \
			and p_parsed.options.has(OPT_ID):
		printerr("--all 与 --id 互斥")
		return EXIT_USAGE
	if not _ensure_runtime(p_parsed):
		return EXIT_USAGE
	var source: String = _resolve_source(p_parsed)
	if source.is_empty():
		return EXIT_USAGE
	var installer: DependencyInstaller = DependencyInstaller.new()
	var available: Dictionary = installer.list_available(source, GodotBuilder.get_host_platform())
	if not bool(available.get("ok", false)):
		printerr("解析编译依赖清单失败：%s" % str(available.get("error", "")))
		return EXIT_FAILED
	var items: Array[Dictionary] = []
	for item: Variant in available.get("items", []) as Array:
		items.append(item as Dictionary)
	match p_parsed.subcommand:
		SUBCMD_LIST:
			return _deps_list(p_parsed, items)
		SUBCMD_INSTALL:
			return await _deps_install(p_parsed, source, installer, items)
		_:
			printerr("deps 需要子命令 list 或 install")
			return EXIT_USAGE

## 列出可安装的编译依赖。
func _deps_list(p_parsed: ParsedArgs, p_items: Array[Dictionary]) -> int:
	if p_parsed.options.has(OPT_JSON):
		print(JSON.stringify(p_items, "\t"))
		return EXIT_OK
	print("依赖 ID\t版本\t安装位置")
	for item: Dictionary in p_items:
		print("%s\t%s\t%s" % [
			str(item.get(DependencyInstaller.KEY_ID, "")),
			str(item.get(DependencyInstaller.KEY_TAG, "")),
			str(item.get(DependencyInstaller.KEY_TARGET, "")),
		])
	return EXIT_OK

## 安装编译依赖：--all 装全部，否则按 --id 逐个校验后安装。
func _deps_install(p_parsed: ParsedArgs, p_source: String,
		p_installer: DependencyInstaller, p_items: Array[Dictionary]) -> int:
	var ids: PackedStringArray = _resolve_dependency_ids(p_parsed, p_items)
	if ids.is_empty():
		return EXIT_USAGE
	print("开始安装编译依赖：%s" % ID_SEPARATOR.join(ids))
	var outcome: Dictionary = await p_installer.install_all(p_source,
			GodotBuilder.get_host_platform(), ids, _make_dependency_progress(),
			p_parsed.options.has(OPT_KEEP_CACHE))
	var installed_dirs: Dictionary = outcome.get("dirs", {})
	for id: Variant in outcome.get("installed", []) as Array:
		var target: String = str(installed_dirs.get(str(id), outcome.get("deps_dir", "")))
		print("已安装 %s → %s" % [str(id), target])
	if not bool(outcome.get("ok", false)):
		printerr("编译依赖安装失败：%s" % str(outcome.get("error", "")))
		return EXIT_FAILED
	print("编译依赖安装完成：%d 项，%.1f MB" % [
		(outcome.get("installed", []) as Array).size(),
		int(outcome.get("bytes", 0)) / BYTES_PER_MB])
	return EXIT_OK

## 解析待安装 id：--all 取全部候选，--id 逐个校验是否存在于候选清单。
func _resolve_dependency_ids(p_parsed: ParsedArgs,
		p_items: Array[Dictionary]) -> PackedStringArray:
	var known: PackedStringArray = PackedStringArray()
	for item: Dictionary in p_items:
		known.append(str(item.get(DependencyInstaller.KEY_ID, "")))
	if p_parsed.options.has(OPT_ALL):
		if known.is_empty():
			printerr("当前源码没有可安装的编译依赖")
			return PackedStringArray()
		return known
	var raw: String = p_parsed.options.get(OPT_ID, "")
	if raw.is_empty():
		printerr("deps install 需要 --all 或 --id=<id,id>；可用：%s" % ID_SEPARATOR.join(known))
		return PackedStringArray()
	var result: PackedStringArray = PackedStringArray()
	for piece: String in raw.split(ID_SEPARATOR, false):
		var id: String = piece.strip_edges()
		if id.is_empty() or result.has(id):
			continue
		if not known.has(id):
			printerr("未知依赖 id：%s；可用：%s" % [id, ID_SEPARATOR.join(known)])
			return PackedStringArray()
		result.append(id)
	return result

## 生成 PCK 加密编译密钥（64 位十六进制），默认打印，--save 时同时写入本机密钥存储。
func _cmd_gen_key(p_parsed: ParsedArgs) -> int:
	var key: String = EncryptionKey.generate()
	if not EncryptionKey.is_valid(key):
		printerr("生成失败：系统熵不可用或结果不合法（OS.get_entropy）")
		return EXIT_FAILED
	print(key)
	if p_parsed.options.has(OPT_SAVE):
		if not SecretStore.set_key(key):
			printerr("写入本机密钥存储失败：%s" % AppData.executable_path.path_join(SecretStore.FILE_NAME))
			return EXIT_FAILED
		print("已写入本机密钥存储：%s" % AppData.executable_path.path_join(SecretStore.FILE_NAME))
	return EXIT_OK
#endregion

#region Private：配置命令子过程
## 导出配置为 custom.py。
func _config_export(p_parsed: ParsedArgs, p_build_options: BuildOptions) -> int:
	var output_path: String = _globalize(p_parsed.options.get(OPT_OUTPUT, ""))
	if output_path.is_empty():
		printerr("config export 缺少 --output=<文件>")
		return EXIT_USAGE
	var config: Dictionary = {}
	if p_parsed.options.has(OPT_PROFILE):
		var profile_path: String = _globalize(p_parsed.options.get(OPT_PROFILE, ""))
		var profile_text: String = FileAccess.get_file_as_string(profile_path)
		if profile_text.is_empty():
			printerr("读取编译配置失败：%s" % profile_path)
			return EXIT_FAILED
		config = ProfileConverter.profile_to_config(profile_text, p_build_options, true)
	var overrides: Dictionary = _parse_assignments(p_parsed.assignments, p_build_options)
	if overrides.is_empty() and not p_parsed.assignments.is_empty():
		return EXIT_USAGE
	if not overrides.is_empty():
		config.merge(overrides, true)
	var store: ConfigStore = ConfigStore.new(config, p_build_options)
	var text: String = ProfileConverter.config_to_profile(store.get_profile_config(), p_build_options)
	var file: FileAccess = FileAccess.open(output_path, FileAccess.WRITE)
	if file == null:
		printerr("文件写入失败：%s" % FileAccess.get_open_error())
		return EXIT_FAILED
	file.store_string(text)
	file.close()
	print("已导出配置：%s" % output_path)
	return EXIT_OK

## 读取 custom.py 并输出配置项。
func _config_import(p_parsed: ParsedArgs, p_build_options: BuildOptions) -> int:
	var input_path: String = _globalize(p_parsed.options.get(OPT_INPUT, ""))
	if input_path.is_empty():
		printerr("config import 缺少 --input=<文件>")
		return EXIT_USAGE
	var text: String = FileAccess.get_file_as_string(input_path)
	if text.is_empty():
		printerr("读取编译配置失败：%s" % input_path)
		return EXIT_FAILED
	var config: Dictionary = ProfileConverter.profile_to_config(text, p_build_options, true)
	if p_parsed.options.has(OPT_JSON):
		print(JSON.stringify(config, "\t"))
		return EXIT_OK
	for option_key: String in config:
		print("%s = %s" % [option_key, _format_config_value(config[option_key])])
	return EXIT_OK

## 按 profile 字面量格式展示配置值（bool 转 yes/no）。
func _format_config_value(p_value: Variant) -> String:
	if p_value is bool:
		return "yes" if p_value else "no"
	return str(p_value)
#endregion

#region Private：进度回调
## 装配进度回调：同一文案只打印一次，比例非负时折算成百分比。[br][br]
## [param p_show_ratio] 是否在文案后附百分比（下载类回调的比率为 0..1，装配阶段可能是状态量）。[br]
## [return] 回调 f(阶段说明, 比例)
func _make_provision_progress(p_show_ratio: bool) -> Callable:
	var last_text: Dictionary[String, String] = {"text": ""}
	return func(p_text: String, p_ratio: float) -> void:
		var ratio_suffix: String = ""
		if p_show_ratio and p_ratio >= 0.0:
			ratio_suffix = "（%.0f%%）" % (p_ratio * 100.0)
		var line: String = p_text + ratio_suffix
		if line == last_text.get("text", ""):
			return
		last_text["text"] = line
		print(line)

## 依赖安装进度回调：同一文案只打印一次。[br][br]
## [return] 回调 f(说明文本)
func _make_dependency_progress() -> Callable:
	var last_text: Dictionary[String, String] = {"text": ""}
	return func(p_text: String) -> void:
		if p_text == last_text.get("text", ""):
			return
		last_text["text"] = p_text
		print(p_text)
#endregion

#region Private：构建日志
## 开启构建日志落盘：成功后挂载到 Console，使 SCons 全量输出只进文件。
func _start_build_log() -> BuildLogger:
	var logger: BuildLogger = BuildLogger.new()
	if not logger.start(ProjectSettings.globalize_path(AppData.get_log_dir())):
		printerr("警告：构建日志目录不可写，本次构建的详细日志不会保存")
		return null
	Console.set_cli_log(logger)
	return logger

## 收尾构建日志：卸载挂载并关闭文件句柄。
func _finish_build_log(p_logger: BuildLogger) -> void:
	Console.clear_cli_log()
	if p_logger != null:
		p_logger.stop()
#endregion

#region Private：公共辅助
## 确保嵌入式 Python/SCons 运行时就绪；普通版产物已指定自定义解释器（--python 或 GUI 设置）时放行。[br][br]
## [param p_parsed] 解析后的用户参数。[br]
## [return] 运行时就绪或可由自定义解释器驱动时为 true。
func _ensure_runtime(p_parsed: ParsedArgs) -> bool:
	if OS.has_feature(GodotBuilder.EMBED_PYTHON_FEATURE):
		if not GodotBuilder.ensure_runtime_extracted():
			printerr("内嵌 Python/SCons 运行时未就绪")
			return false
		return true
	var has_custom_python: bool = p_parsed.options.has(OPT_PYTHON) \
			or not _load_app_data().custom_python_path.is_empty()
	if not has_custom_python:
		printerr("当前为普通版产物（未内嵌 Python 运行时）：请用 --python 指定解释器，或在 GUI 设置里配置 Python 与 SCons")
		return false
	return true

## 创建构建器：自定义 Python / SCons 路径优先 CLI 参数，其次 GUI 持久化设置。
func _create_builder(p_parsed: ParsedArgs) -> GodotBuilder:
	var app_data: AppData = _load_app_data()
	var python_path: String = p_parsed.options.get(OPT_PYTHON, app_data.custom_python_path)
	var scons_dir: String = p_parsed.options.get(OPT_SCONS_DIR, app_data.custom_scons_dir)
	var builder: GodotBuilder = await GodotBuilder.create(python_path, scons_dir)
	return builder

## 只读加载 GUI 持久化设置（不写盘，避免 CLI 在引擎目录产生副作用）。
func _load_app_data() -> AppData:
	var data_path: String = AppData.executable_path.path_join(AppData.DEFAULT_SAVE_PATH)
	if ResourceLoader.exists(data_path):
		var loaded: Resource = ResourceLoader.load(data_path)
		if loaded is AppData:
			return loaded as AppData
	return AppData.new()

## 取并校验源码目录：--source 优先，兼容 check-options 的 --engine-dir 别名。
func _resolve_source(p_parsed: ParsedArgs) -> String:
	var source: String = p_parsed.options.get(OPT_SOURCE, p_parsed.options.get(OPT_ENGINE_DIR, ""))
	if source.is_empty():
		printerr("缺少 --source=<Godot 引擎源码目录>")
		return ""
	if Utils.parse_godot_version(source).is_empty():
		printerr("所选目录不是有效的 Godot 源码目录或源码已损坏：%s" % source)
		return ""
	return ProjectSettings.globalize_path(source)

## 把用户给出的相对路径转成绝对路径（res:// / user:// 亦适用）。
func _globalize(p_path: String) -> String:
	return ProjectSettings.globalize_path(p_path) if not p_path.is_empty() else ""

## 解析 scons --help 生成选项元数据。
func _get_build_options(p_builder: GodotBuilder, p_source: String) -> BuildOptions:
	var help_text: String = await p_builder.get_scons_help_cached(p_source)
	if help_text.is_empty():
		printerr("获取 scons --help 失败：%s" % p_source)
		return null
	return BuildOptions.new(help_text)

## 解析裸 键=值：未知键报错退出，并给出相近键提示；全部合法时拼成 profile 文本复用 ProfileConverter 转换。
func _parse_assignments(p_items: Array[String], p_build_options: BuildOptions) -> Dictionary:
	var lines: PackedStringArray = PackedStringArray()
	for item: String in p_items:
		var eq: int = item.find("=")
		var option_key: String = item.substr(0, eq)
		if not p_build_options.has_option(option_key):
			printerr("未知构建选项：%s%s" % [option_key, _suggest_similar(option_key, p_build_options)])
			return {}
		var value: String = item.substr(eq + 1)
		var escaped: String = value.replace("\\", "\\\\").replace('"', '\\"')
		lines.append("%s = \"%s\"" % [option_key, escaped])
	if lines.is_empty():
		return {}
	return ProfileConverter.profile_to_config("\n".join(lines), p_build_options, true)

## 为未知键给出相近键提示（同前缀或子串匹配，最多 3 个）。
func _suggest_similar(p_key: String, p_build_options: BuildOptions) -> String:
	var candidates: Array[String] = []
	for group_key: String in p_build_options.get_all_groups():
		for option_key: String in p_build_options.get_options_of(group_key):
			if option_key.begins_with(p_key.substr(0, 3)) or p_key in option_key or option_key in p_key:
				candidates.append(option_key)
	candidates.sort()
	if candidates.is_empty():
		return ""
	var limited: PackedStringArray = PackedStringArray()
	for i: int in mini(candidates.size(), 3):
		limited.append(candidates[i])
	return "（相近选项：%s）" % ", ".join(limited)

## 复制构建产物到配置的输出目录（目录位于产物目录内时跳过）。
func _publish_artifacts(p_source: String, p_output_dir: String) -> String:
	var default_dir: String = p_source.path_join("bin")
	if p_output_dir.is_empty():
		return default_dir
	var source_root: String = _path_key(default_dir)
	var target_root: String = _path_key(p_output_dir)
	if target_root == source_root or target_root.begins_with(source_root + "/"):
		printerr("构建产物输出目录位于源码产物目录内，已跳过复制：%s" % p_output_dir)
		return default_dir
	var count: int = GodotBuilder.copy_tree(default_dir, p_output_dir, ARTIFACT_IGNORE_DIR_NAMES)
	if count < 0:
		printerr("构建产物复制失败：%s" % p_output_dir)
		return default_dir
	return p_output_dir

## 路径比较键：去尾斜杠、统一分隔符，Windows 下大小写不敏感。
func _path_key(p_path: String) -> String:
	var key: String = p_path.simplify_path().replace("\\", "/").trim_suffix("/")
	return key.to_lower() if OS.get_name() == "Windows" else key

## 收集缺失汉化项，按字典序排序。
func _collect_missing(p_parsed: Dictionary, p_localized: Dictionary) -> Array[String]:
	var missing: Array[String] = []
	for option_key: String in p_parsed:
		if not p_localized.has(option_key):
			missing.append(option_key)
	missing.sort()
	return missing

## 收集过时条目，按字典序排序。
func _collect_stale(p_parsed: Dictionary, p_localized: Dictionary) -> Array[String]:
	var stale: Array[String] = []
	for option_key: String in p_localized:
		if not p_parsed.has(option_key):
			stale.append(option_key)
	stale.sort()
	return stale

## 收集无效分组引用，按字典序排序。
func _collect_bad_groups(p_localized: Dictionary, p_groups: Dictionary) -> Array[String]:
	var bad_group: Array[String] = []
	for option_key: String in p_localized:
		var group_key: String = str(p_localized[option_key].get(BuildOptions.KEY_GROUP, ""))
		if group_key.is_empty():
			continue
		if not p_groups.has(group_key) and group_key != BuildOptions.FALLBACK_GROUP_KEY:
			bad_group.append(option_key)
	bad_group.sort()
	return bad_group

## 打印完整用法。
func _print_help() -> void:
	print("\n".join(HELP_LINES))

## 打印 Godot 运行时版本。
func _print_version() -> void:
	var version_info: Dictionary = Engine.get_version_info()
	print("GodotBuilder CLI / Godot %s" % str(version_info.get("string", "")))
#endregion

#region Inner classes
## 解析后的命令行参数。
class ParsedArgs:
	var command: String = ""
	var subcommand: String = ""
	var options: Dictionary[String, String] = {}
	## 裸 键=值（SCons 构建选项）。
	var assignments: Array[String] = []
	var error: String = ""

	## 解析用户参数：-- 前缀为应用选项，裸 键=值 为构建选项，其余位置参数为命令 / 子命令。[br][br]
	## [param p_args] 原始用户参数。[br]
	## [param p_value_options] 需取值的参数名列表。[br]
	## [param p_flag_options] 开关型参数名列表。[br]
	## [return] 解析结果；error 非空表示参数不合法。
	static func parse(
		p_args: PackedStringArray,
		p_value_options: PackedStringArray,
		p_flag_options: PackedStringArray
	) -> ParsedArgs:
		var result: ParsedArgs = ParsedArgs.new()
		var index: int = 0
		while index < p_args.size():
			var token: String = p_args[index]
			if token.begins_with("--"):
				var body: String = token.trim_prefix("--")
				var key: String = body
				var inline_value: String = ""
				var eq: int = body.find("=")
				if eq >= 0:
					key = body.substr(0, eq)
					inline_value = body.substr(eq + 1)
				if p_value_options.has(key):
					var value: String = inline_value
					if value.is_empty() and index + 1 < p_args.size() and not p_args[index + 1].begins_with("--"):
						index += 1
						value = p_args[index]
					if value.is_empty():
						result.error = "--%s 缺少取值" % key
						return result
					result.options[key] = value
				elif p_flag_options.has(key):
					result.options[key] = "1"
				else:
					result.error = "未知参数：--%s" % key
					return result
			elif token.contains("="):
				result.assignments.append(token)
			elif result.command.is_empty():
				result.command = token
			elif result.subcommand.is_empty():
				result.subcommand = token
			else:
				result.error = "多余的位置参数：%s" % token
				return result
			index += 1
		return result
#endregion
