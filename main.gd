extends Control

const BuildStatus = BuildStatusBar.Status
const ICON_FOLDER_OPEN = preload("uid://bmj7pj12ibi5r")
const ICON_SOURCE_DIR = preload("uid://ij71g4ykokhq")
const ICON_COG = preload("uid://da81yjbhyxym")
const ICON_CLEAR = preload("uid://br3cdi5g07ytx")
const ICON_TERMINAL = preload("uid://de6go24h2tgw2")
const ICON_KEY = preload("uid://crsq41cofycv1")
const ICON_DOWNLOAD = preload("uid://crbgm4t8n8ots")

const KEY_STATUS_TEXT: StringName = &"status_text"
const KEY_STATUS_TOOLTIP: StringName = &"status_tooltip"
const PROFILE_FILE_NAME: String = GodotBuilder.PROFILE_FILE_NAME
## 配置变更刷新防抖时长（秒）：合并相邻字段变更，避免每个按键全量重算
const CONFIG_UPDATE_DEBOUNCE: float = 0.15
## 取消构建中断超时（秒）：中断后仍未退出则强制终止
const CANCEL_FALLBACK_TIMEOUT: float = 3.0
## 复制构建产物时忽略的子目录名（obj 为 SCons 重定向的编译中间文件目录）
const ARTIFACT_IGNORE_DIR_NAMES: PackedStringArray = ["obj"]
## 无界面 DisplayServer 名称：以 --headless 启动时引擎选用该驱动。
const HEADLESS_DISPLAY_SERVER_NAME: String = "headless"
## 字节单位换算基数
const BYTES_PER_MB: float = 1048576.0

enum MoreOptionPopupMenuAction {
	CLEAR_CACHE,
	CLEAR_BUILD_LOGS,
	OPEN_LOG_DIR,
	OPEN_TERMINAL,
	GEN_ENCRYPTION_KEY,
	DOWNLOAD_RUNTIME,
	DOWNLOAD_DEPENDENCIES,
	SETTING,
}

@export var source_button: Button
@export var source_popup_menu: PopupMenu
@export var more_option_button: Button
@export var more_option_popup_menu: PopupMenu
@export var setting_confirmation_dialog: ConfirmationDialog
@export var clear_logs_confirmation_dialog: ConfirmationDialog
@export var dependency_selection_dialog: DependencySelectionDialog
@export var source_info_label: RichTextLabel
@export var build_status_bar: BuildStatusBar
@export var config_preview_button: Button
@export var config_preview_window: ConfigPreviewWindow
@export var config_import_button: Button
@export var config_export_button: Button
@export var import_mode_dialog: ConfirmationDialog

@export var build_button: Button
@export var cancel_button: Button

@export var group_nav_panel: GroupNavPanel
@export var config_form_panel: ConfigFormPanel
@export var summary_panel: SummaryPanel
@export var console_panel: ConsolePanel

@export var file_dialog: FileDialog

var app_data: AppData = null
var builder: GodotBuilder = null
var config_store: ConfigStore = null

var file_dialog_delegate: Callable = Callable()

## 待应用的导入配置（选中文件解析后暂存，用户选择导入方式后消费）
var _pending_import_config: Dictionary = {}
## 待应用导入配置的来源路径（日志展示用）
var _pending_import_path: String = ""
## 导入方式对话框的「合并」按钮（由 add_button 创建，场景不预定义节点）
var _import_merge_button: Button = null

var _env_ready: bool = false
var _env_status: Dictionary[StringName, String] = {}
var _loading: bool = false
var _building: bool = false
## 正在下载装配运行时（防并发重入：同名暂存目录互踩）
var _provisioning: bool = false
var _current_source_dir: String = ""
## 当前构建进程句柄（取消构建用）
var _build_handle: PipeProcessHandle = null
## 是否已请求取消当前构建
var _build_cancelled: bool = false
## 配置变更防抖计时器（合并连续变更，避免每按键全量刷新）
var _config_update_timer: SceneTreeTimer = null
## 当前构建日志记录器
var _build_logger: BuildLogger = null

func _ready() -> void:
	if _is_cli_mode():
		await _run_cli()
		return
	app_data = AppData.load()
	build_status_bar.set_status(BuildStatus.PROGRESS, "准备嵌入式运行时...")
	if not GodotBuilder.ensure_runtime_extracted() and OS.has_feature("embed-python"):
		build_status_bar.set_status(BuildStatus.ERROR, "嵌入式运行时异常")
		Console.log_error("嵌入式运行时准备失败：请确认程序目录可写")
	# 导入方式对话框的「合并」按钮：此处（await 之前）创建，避免被后续 await 阻断
	_setup_import_mode_dialog()
	builder = await GodotBuilder.create(
		app_data.custom_python_path,
		app_data.custom_scons_dir
	)
	setting_confirmation_dialog.setup(app_data)
	_setup_source_popup_menu()
	_setup_more_option_popup_menu()
	_env_ready = await _check_env()

## 无界面模式（--headless / --display-driver headless）即 CLI 模式，跳过 GUI 初始化。
func _is_cli_mode() -> bool:
	return DisplayServer.get_name() == HEADLESS_DISPLAY_SERVER_NAME

## 跑共享 CLI 核心并以结果码退出主循环（跳过 GUI 初始化）。
func _run_cli() -> void:
	var commands: CliCommands = CliCommands.new()
	var code: int = await commands.run(OS.get_cmdline_user_args())
	get_tree().quit(code)

## 为导入方式对话框追加「合并」按钮（ConfirmationDialog.add_button，场景不预定义节点）。
func _setup_import_mode_dialog() -> void:
	if _import_merge_button != null:
		return
	_import_merge_button = import_mode_dialog.add_button("合并")
	_import_merge_button.pressed.connect(_on_import_mode_dialog_merge_pressed)

func _setup_source_popup_menu() -> void:
	source_popup_menu.clear()
	var scanned_source_dirs: Dictionary[String, String] = Utils.scan_godot_source_dir(app_data.get_source_scan_dir())
	if scanned_source_dirs.is_empty():
		return
	source_popup_menu.add_icon_item(ICON_FOLDER_OPEN, "打开...", 0)
	source_popup_menu.set_item_tooltip(0, "从文件系统选择源码目录")
	source_popup_menu.add_separator()
	for source_path: String in scanned_source_dirs:
		var item_index: int = source_popup_menu.item_count
		source_popup_menu.add_icon_item(ICON_SOURCE_DIR, source_path)
		source_popup_menu.set_item_tooltip(item_index, scanned_source_dirs.get(source_path))

func _setup_more_option_popup_menu() -> void:
	more_option_popup_menu.clear()
	more_option_popup_menu.add_icon_item(ICON_CLEAR, "清除缓存    ", MoreOptionPopupMenuAction.CLEAR_CACHE)
	more_option_popup_menu.add_icon_item(ICON_CLEAR, "清理构建日志    ", MoreOptionPopupMenuAction.CLEAR_BUILD_LOGS)
	more_option_popup_menu.add_icon_item(ICON_FOLDER_OPEN, "打开日志目录    ", MoreOptionPopupMenuAction.OPEN_LOG_DIR)
	more_option_popup_menu.add_icon_item(ICON_TERMINAL, "打开终端    ", MoreOptionPopupMenuAction.OPEN_TERMINAL)
	more_option_popup_menu.add_icon_item(ICON_KEY, "生成加密密钥    ", MoreOptionPopupMenuAction.GEN_ENCRYPTION_KEY)
	if not OS.has_feature("embed-python"):
		more_option_popup_menu.add_icon_item(ICON_DOWNLOAD, "下载 Python 环境    ", MoreOptionPopupMenuAction.DOWNLOAD_RUNTIME)
	more_option_popup_menu.add_icon_item(ICON_DOWNLOAD, "下载编译依赖    ", MoreOptionPopupMenuAction.DOWNLOAD_DEPENDENCIES)
	more_option_popup_menu.add_icon_item(ICON_COG, "设置    ", MoreOptionPopupMenuAction.SETTING)

## 加载源码目录并构建选项界面。[br][br]
## [param source_dir] Godot 源码目录路径（res:// 或绝对路径）
func _load_source(source_dir: String) -> void:
	if _loading: return

	# 1. 环境未就绪则中止（python / SCons 已在启动时检查）
	if not _env_ready:
		Console.log_error("编译环境未就绪（Python / SCons），无法加载源码")
		return
	_loading = true

	# 2. 校验目录并获取版本
	build_status_bar.staging_status()
	build_status_bar.set_status(BuildStatus.PROGRESS, "校验源码目录...")
	var godot_version: String = Utils.parse_godot_version(source_dir)
	if godot_version.is_empty():
		Console.log_error("所选目录不是有效的 Godot 源码目录或源码已损坏：[url=%s]%s[/url]" % [
				source_dir, source_dir])
		build_status_bar.restore_status()
		_loading = false
		return

	# 3. 检测可构建平台
	if (await _check_supported_platforms(source_dir)).is_empty():
		Console.log_error("无可构建的平台，请下载相关的编译工具链！")
	build_status_bar.staging_status()

	# 4. 解析 scons --help 构建选项元数据（磁盘缓存，缓存键含源码内容哈希，第三方改动自动失效）
	build_status_bar.set_status(BuildStatus.PROGRESS, "解析源码构建选项元数据...")
	var scons_help_output: String = await builder.get_scons_help_cached(source_dir)
	if scons_help_output.is_empty():
		Console.log_error("获取 scons --help 失败：[url=%s]%s[/url]" % [source_dir, source_dir])
		build_status_bar.restore_status()
		_loading = false
		return
	var new_options: BuildOptions = BuildOptions.new(scons_help_output)
	_warn_unlocalized_options(new_options)

	# 5. 加载源码目录 custom.py 构建配置
	build_status_bar.set_status(BuildStatus.PROGRESS, "加载默认编译配置...")
	var new_config: Dictionary = {}
	var profile_text: String = FileAccess.get_file_as_string(
		source_dir.path_join(PROFILE_FILE_NAME)
	)
	if not profile_text.is_empty():
		new_config = ProfileConverter.profile_to_config(
			profile_text, new_options
		)

	# 6. 构建界面
	build_status_bar.set_status(BuildStatus.PROGRESS, "构建用户界面...")
	config_store = ConfigStore.new(new_config, new_options)
	summary_panel.setup(config_store)
	config_form_panel.setup(config_store)
	group_nav_panel.setup(new_options.get_all_groups())
	Console.log_info("[color=#65d98b]构建选项加载完成（%d 个分组）[/color]" % new_options.get_all_groups().size())

	# 7. 更新源码路径显示
	_current_source_dir = source_dir
	source_info_label.text = "[url=%s]%s[/url]" % [source_dir, godot_version]
	source_info_label.tooltip_text = source_dir

	build_status_bar.restore_status()
	_loading = false

## 控制台提示未汉化的构建选项，提醒补充 build_options_zh.json。[br][br]
## [param p_options] 解析后的构建选项仓库
func _warn_unlocalized_options(p_options: BuildOptions) -> void:
	var unlocalized: Dictionary[String, String] = p_options.get_unlocalized_options()
	if unlocalized.is_empty():
		return
	var items: PackedStringArray = PackedStringArray()
	for option_key: String in unlocalized:
		items.append("%s（建议分组：%s）" % [option_key, unlocalized[option_key]])
	Console.log_warning(
		"检测到 %d 个未汉化构建选项，请补充到 build_options_zh.json：%s"
		% [items.size(), "、".join(items)]
	)

## 检查编译环境（python / SCons）是否就绪。
func _check_env() -> bool:
	build_status_bar.set_status(BuildStatus.PROGRESS, "检测 Python 环境...")
	var python_version: String = await builder.check_python()
	if python_version.is_empty():
		build_status_bar.set_status(BuildStatus.ERROR, "Python 环境异常")
		build_status_bar.set_tooltip("")
		_env_status = {
			KEY_STATUS_TEXT: build_status_bar.get_current_status_text(),
			KEY_STATUS_TOOLTIP: build_status_bar.get_current_status_tooltip()
		}
		return false
	build_status_bar.set_status(BuildStatus.OK, "Python 已就绪")
	build_status_bar.set_tooltip("[color=#65d98b]✓ Python %s[/color]" % python_version)

	build_status_bar.set_status(BuildStatus.PROGRESS, "检测 SCons 构建工具...")
	var scons_version: String = await builder.check_scons()
	if scons_version.is_empty():
		build_status_bar.set_status(BuildStatus.ERROR, "SCons 构建工具异常")
		_env_status = {
			KEY_STATUS_TEXT: build_status_bar.get_current_status_text(),
			KEY_STATUS_TOOLTIP: build_status_bar.get_current_status_tooltip()
		}
		return false
	build_status_bar.set_status(BuildStatus.OK, "SCons 已就绪")
	build_status_bar.append_tooltip("\n[color=#65d98b]✓ SCons %s[/color]" % scons_version)
	_env_status = {
		KEY_STATUS_TEXT: build_status_bar.get_current_status_text(),
		KEY_STATUS_TOOLTIP: build_status_bar.get_current_status_tooltip()
	}
	return true

## 检测源码目录可构建的平台列表（失败仅降级提示，不中止流程）。
func _check_supported_platforms(source_dir: String) -> PackedStringArray:
	var supported_platforms: PackedStringArray = PackedStringArray()
	if source_dir.is_empty() or not DirAccess.dir_exists_absolute(source_dir):
		return supported_platforms

	build_status_bar.set_status(BuildStatus.PROGRESS, "检测可构建平台...")
	supported_platforms = await builder.check_supported_platforms(ProjectSettings.globalize_path(source_dir))
	if supported_platforms.is_empty():
		build_status_bar.set_status(BuildStatus.ERROR, "构建环境异常")
		return supported_platforms

	build_status_bar.set_tooltip(_env_status.get(KEY_STATUS_TOOLTIP))
	for platform_name: String in supported_platforms:
		build_status_bar.append_tooltip("\n[color=#65d98b]✓ %s[/color]" % platform_name)
	build_status_bar.set_status(BuildStatus.OK, "环境就绪 · 可构建 %d 个平台" % supported_platforms.size())
	return supported_platforms

func _reset_file_dialog_state() -> void:
	file_dialog_delegate = Callable()
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_ANY
	file_dialog.filters = PackedStringArray()
	file_dialog.current_file = ""

func _on_config_changed(_option_key: String) -> void:
	# 防抖：合并相邻变更（如字符串字段逐键触发），超时后一次性刷新
	if _config_update_timer:
		return
	_config_update_timer = get_tree().create_timer(CONFIG_UPDATE_DEBOUNCE)
	_config_update_timer.timeout.connect(_flush_config_update)

## 防抖刷新回调：重算分组修改计数与摘要。
func _flush_config_update() -> void:
	_config_update_timer = null
	if not is_instance_valid(config_store):
		return
	group_nav_panel.set_modified_counts(config_store.count_modified_by_group())
	summary_panel.refresh()

func _on_more_option_button_pressed() -> void:
	var anchor: Vector2 = more_option_button.global_position + Vector2(0, more_option_button.size.y)
	more_option_popup_menu.popup(Rect2i(anchor, more_option_button.size))

func _on_source_button_pressed() -> void:
	if source_popup_menu.item_count == 0:
		file_dialog_delegate = _load_source
		file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		file_dialog.popup_file_dialog()
		return
	var anchor: Vector2 = source_button.global_position + Vector2(0, source_button.size.y)
	source_popup_menu.popup(Rect2i(anchor, source_button.size))

func _on_file_dialog_selected(context: String) -> void:
	if file_dialog_delegate.is_valid():
		file_dialog_delegate.call(context)
	_reset_file_dialog_state()

func _on_file_dialog_close_requested() -> void:
	_reset_file_dialog_state()

func _on_build_button_pressed() -> void:
	if _building or _current_source_dir.is_empty():
		Console.log_warning("未加载源码")
		return

	_building = true
	_build_cancelled = false
	build_status_bar.staging_status()
	build_status_bar.set_status(BuildStatus.PROGRESS, "写入临时编译配置文件...")
	var profile_text: String = ProfileConverter.config_to_profile(
		config_store.get_full_config(), config_store.get_options(), true
	)
	var profile_file: FileAccess = FileAccess.create_temp(
		FileAccess.WRITE, "godot_build_profile", ".py"
	)
	if profile_file == null:
		Console.log_error("写入临时编译配置文件失败：%s" % FileAccess.get_open_error())
		build_status_bar.restore_status()
		_building = false
		return
	profile_file.store_string(profile_text)
	profile_file.close()
	var profile_path: String = profile_file.get_path_absolute()

	build_status_bar.set_status(BuildStatus.PROGRESS, "正在构建源码...")
	# 重新加载 PCK 加密编译密钥（设置保存后立即生效），并在构建时注入环境变量
	SecretStore.reload()
	if SecretStore.get_key().is_empty():
		Console.log_info("未注入 PCK 加密编译密钥")
	else:
		Console.log_info("已注入 PCK 加密编译密钥")
	var handle: PipeProcessHandle = builder.build(_current_source_dir, profile_path)
	if handle == null:
		Console.log_error("启动构建进程失败")
		build_status_bar.restore_status()
		_building = false
		return
	_build_handle = handle
	_set_building_controls(true)
	# 启动构建日志：捕获进程 stdout/stderr 原始输出
	_build_logger = BuildLogger.new()
	if _build_logger.start(AppData.get_log_dir()):
		handle.stdout_received.connect(_build_logger.append)
		handle.stderr_received.connect(_build_logger.append)
	else:
		_build_logger = null
	var record: PipeProcessRecord = await handle.exited
	_build_handle = null
	_set_building_controls(false)
	if _build_cancelled:
		build_status_bar.set_status(BuildStatus.WARNING, "构建已取消")
		Console.log_warning("构建已取消")
		_finish_build()
		return
	if record.exit_code != 0:
		build_status_bar.set_status(BuildStatus.ERROR, "构建失败")
		Console.log_error("构建失败: %s" % record.exit_code)
		_finish_build()
		return

	build_status_bar.set_status(BuildStatus.OK, "构建成功")
	var output_dir: String = _publish_build_artifacts(_current_source_dir.path_join("bin"))
	Console.log_info(
		"[color=#65d98b]构建成功：[url=%s]%s[/url][/color]" % [output_dir, output_dir]
	)
	_finish_build()

## 复制构建产物：配置了输出目录时把源码 bin/ 产物复制过去（忽略 obj 中间文件目录），
## 否则保持默认位置。[br]
## [param default_output_dir] 源码目录默认产物目录（bin/）[br]
## [return] 实际展示的产物目录（未配置或复制失败时为默认目录）
func _publish_build_artifacts(default_output_dir: String) -> String:
	var configured_dir: String = app_data.output_dir.strip_edges()
	if configured_dir.is_empty():
		return default_output_dir
	# 目标位于产物目录（或其子目录）内时跳过：复制会截断同名产物甚至无限递归
	var source_root: String = _path_key(default_output_dir)
	var target_root: String = _path_key(configured_dir)
	if target_root == source_root or target_root.begins_with(source_root + "/"):
		Console.log_warning("构建产物输出目录位于源码产物目录内，已跳过复制：[url=%s]%s[/url]" % [
				configured_dir, configured_dir])
		return default_output_dir
	var count: int = GodotBuilder.copy_tree(
		default_output_dir, configured_dir, ARTIFACT_IGNORE_DIR_NAMES
	)
	if count < 0:
		Console.log_error("构建产物复制失败：[url=%s]%s[/url]" % [
				configured_dir, configured_dir])
		return default_output_dir
	Console.log_info(
		"[color=#65d98b]已复制 %d 个产物到：[url=%s]%s[/url][/color]" % [count, configured_dir, configured_dir]
	)
	return configured_dir

## 路径比较键：去尾斜杠、统一分隔符，Windows 下大小写不敏感。
func _path_key(path: String) -> String:
	var key: String = path.simplify_path().replace("\\", "/").trim_suffix("/")
	return key.to_lower() if OS.get_name() == "Windows" else key

## 收尾构建：关闭日志文件、恢复构建前状态并解锁构建入口。
func _finish_build() -> void:
	if _build_logger:
		_build_logger.stop()
		Console.log_info(
			"[color=#65d98b]构建日志：[url=%s]%s[/url][/color]" % [_build_logger.get_path(), _build_logger.get_path()]
		)
		_build_logger = null
	build_status_bar.restore_status()
	_building = false

## 构建期间禁用构建按钮、启用取消按钮；构建结束反向切换。[br]
## 两按钮常驻避免工具栏布局跳动，禁用态即状态提示。
func _set_building_controls(building: bool) -> void:
	build_button.disabled = building
	cancel_button.disabled = not building

## 取消当前构建：发送中断信号，超时未退出则强制终止。
func _on_cancel_build_requested() -> void:
	if not _building or _build_handle == null:
		return
	_build_cancelled = true
	build_status_bar.set_status(BuildStatus.WARNING, "正在取消构建...")
	var cancel_error: Error = builder.cancel_build(_build_handle)
	if cancel_error != OK:
		Console.log_error("中断构建进程失败：%s" % cancel_error)
	var fallback: SceneTreeTimer = get_tree().create_timer(CANCEL_FALLBACK_TIMEOUT)
	fallback.timeout.connect(
		func() -> void:
			if _build_handle != null and OS.is_process_running(_build_handle.pid):
				Console.log_warning("中断超时，强制终止构建进程")
				builder.kill_build(_build_handle)
	)

func _on_source_info_label_meta_clicked(meta: Variant) -> void:
	OS.shell_show_in_file_manager(str(meta))

func _on_source_popup_menu_id_pressed(id: int) -> void:
	if id == 0:
		file_dialog_delegate = _load_source
		file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		file_dialog.popup_file_dialog()
		return
	var source_path: String = source_popup_menu.get_item_text(id)
	await _load_source(source_path)

func _on_config_preview_button_pressed() -> void:
	if _current_source_dir.is_empty() or not is_instance_valid(config_store):
		Console.log_warning("未加载源码")
		return
	await get_tree().process_frame
	config_preview_window.setup(config_store)

func _on_config_import_button_pressed() -> void:
	if _current_source_dir.is_empty() or not is_instance_valid(config_store):
		Console.log_warning("未加载源码")
		return
	file_dialog_delegate = _on_import_file_selected
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.filters = ["*.py"]
	file_dialog.popup_file_dialog()

## 导入文件选中：解析显式键值（含等于 Godot 默认的项）并弹出导入方式选择。
func _on_import_file_selected(file_path: String) -> void:
	var profile_text: String = FileAccess.get_file_as_string(file_path)
	var config: Dictionary = ProfileConverter.profile_to_config(
		profile_text, config_store.get_options(), true
	)
	if config.is_empty():
		Console.log_warning("导入的配置为空")
		return
	_pending_import_config = config
	_pending_import_path = file_path
	import_mode_dialog.popup_centered()

## 丢弃未应用的导入（用户取消或关闭对话框时）。
func _on_import_mode_dialog_canceled() -> void:
	_pending_import_config = {}
	_pending_import_path = ""

## 确认按钮（替换）：完全使用导入文件的配置。
func _on_import_mode_dialog_confirmed() -> void:
	_apply_import(true)

## 附加按钮（合并）：导入项覆盖同名项，其余保持现状。
func _on_import_mode_dialog_merge_pressed() -> void:
	_apply_import(false)

## 按所选方式应用导入的配置。[param replace] true=替换，false=合并。
func _apply_import(replace: bool) -> void:
	if _pending_import_config.is_empty():
		return
	var path: String = _pending_import_path
	var count: int = _pending_import_config.size()
	config_form_panel.apply_config(_pending_import_config, replace)
	_pending_import_config = {}
	_pending_import_path = ""
	# add_button 创建的按钮不会自动关闭对话框（仅 OK 按钮触发 confirmed 时隐藏），此处统一关闭
	import_mode_dialog.hide()
	Console.log_info(
		"[color=#65d98b]已%s配置（%d 项显式选项）：[url=%s]%s[/url][/color]"
		% ["替换" if replace else "合并", count, path, path]
	)

func _on_config_export_button_pressed() -> void:
	if _current_source_dir.is_empty() or not is_instance_valid(config_store):
		Console.log_warning("未加载源码")
		return
	file_dialog_delegate = (
		func(file_path: String) -> void:
			var profile_text: String = ProfileConverter.config_to_profile(config_store.get_profile_config(), config_store.get_options())
			var file: FileAccess = FileAccess.open(file_path, FileAccess.WRITE)
			if file == null:
				Console.log_error("文件写入失败： %s" % FileAccess.get_open_error())
				return
			file.store_string(profile_text)
			file.close()
			Console.log_info("[color=#65d98b]已导出配置：[url=%s]%s[/url][/color]" % [file_path, file_path])
	)
	file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	file_dialog.filters = ["*.py"]
	file_dialog.current_file = PROFILE_FILE_NAME
	file_dialog.popup_file_dialog()

func _on_more_option_popup_menu_id_pressed(id: int) -> void:
	match id:
		MoreOptionPopupMenuAction.CLEAR_CACHE:
			GodotBuilder.clear_scons_help_cache()
			Console.log_info("已清除 scons --help 缓存")
		MoreOptionPopupMenuAction.CLEAR_BUILD_LOGS:
			clear_logs_confirmation_dialog.popup_centered()
		MoreOptionPopupMenuAction.OPEN_LOG_DIR:
			_open_log_dir()
		MoreOptionPopupMenuAction.OPEN_TERMINAL:
			if _current_source_dir.is_empty():
				Utils.open_terminal(AppData.executable_path)
				return
			Utils.open_terminal(_current_source_dir)
		MoreOptionPopupMenuAction.GEN_ENCRYPTION_KEY:
			_generate_encryption_key()
		MoreOptionPopupMenuAction.DOWNLOAD_RUNTIME:
			await _download_runtime()
		MoreOptionPopupMenuAction.DOWNLOAD_DEPENDENCIES:
			_open_dependency_selection()
		MoreOptionPopupMenuAction.SETTING:
			setting_confirmation_dialog.popup_centered()

## 下载并装配嵌入式运行时（按清单裁剪），装配后重新校验环境。
func _download_runtime() -> void:
	if _building:
		Console.log_warning("构建进行中，请先等待构建结束")
		return
	if _provisioning:
		Console.log_warning("运行时下载进行中，请先等待当前下载结束")
		return
	_provisioning = true
	build_status_bar.staging_status()
	build_status_bar.set_status(BuildStatus.PROGRESS, "准备下载运行时...")
	var provisioner: PythonRuntimeProvisioner = PythonRuntimeProvisioner.new()
	if not provisioner.initialize("", _make_provision_progress()):
		build_status_bar.set_status(BuildStatus.ERROR, "运行时清单加载失败")
		Console.log_error("运行时清单加载失败，无法下载运行时")
		build_status_bar.restore_status()
		_provisioning = false
		return
	var outcome: Dictionary = await provisioner.provision(
		GodotBuilder.get_host_platform(), "", false)
	if not bool(outcome.get("ok", false)):
		build_status_bar.set_status(BuildStatus.ERROR, "运行时下载失败")
		Console.log_error("运行时下载失败：%s" % str(outcome.get("reason", "")))
		build_status_bar.restore_status()
		_provisioning = false
		return
	build_status_bar.set_status(BuildStatus.OK, "运行时已就绪")
	Console.log_info("[color=#65d98b]运行时装配完成：%d 个文件，%.1f MB[/color]" % [
		int(outcome.get("files", 0)), int(outcome.get("bytes", 0)) / BYTES_PER_MB])
	build_status_bar.restore_status()
	_env_ready = await _check_env()
	_provisioning = false

## 装配进度回调：同一文案只打印一次，比例非负时折算成百分比。
func _make_provision_progress() -> Callable:
	var last_text: Dictionary[String, String] = {"text": ""}
	return func(p_text: String, p_ratio: float) -> void:
		var ratio_suffix: String = "（%.0f%%）" % (p_ratio * 100.0) if p_ratio >= 0.0 else ""
		var line: String = p_text + ratio_suffix
		if line == last_text.get("text", ""):
			return
		last_text["text"] = line
		build_status_bar.set_status(BuildStatus.PROGRESS, "正在下载..." + ratio_suffix)
		Console.log_info(line)

## 解析引擎源码里的依赖清单并弹出选择对话框（不联网、不写盘）。
func _open_dependency_selection() -> void:
	if _building:
		Console.log_warning("构建进行中，请先等待构建结束")
		return
	if _current_source_dir.is_empty():
		Console.log_warning("未加载源码：下载编译依赖需要先选择 Godot 引擎源码目录")
		return
	build_status_bar.staging_status()
	build_status_bar.set_status(BuildStatus.PROGRESS, "解析编译依赖清单...")
	var installer: DependencyInstaller = DependencyInstaller.new()
	var available: Dictionary = installer.list_available(
			_current_source_dir, GodotBuilder.get_host_platform())
	build_status_bar.restore_status()
	if not bool(available.get("ok", false)):
		Console.log_error("解析编译依赖失败：%s" % str(available.get("error", "")))
		return
	var items: Array[Dictionary] = []
	for item: Variant in available.get("items", []) as Array:
		items.append(item as Dictionary)
	dependency_selection_dialog.setup(items)
	dependency_selection_dialog.popup_centered()

func _on_dependency_selection_dialog_install_requested(dependency_ids: PackedStringArray) -> void:
	await _install_dependencies(dependency_ids)

## 安装选中的编译依赖（逐个下载解压，失败项汇总后继续）。
func _install_dependencies(p_dependency_ids: PackedStringArray) -> void:
	if p_dependency_ids.is_empty():
		Console.log_warning("未选择任何编译依赖")
		return
	if _current_source_dir.is_empty():
		Console.log_warning("未加载源码，无法安装编译依赖")
		return
	build_status_bar.staging_status()
	build_status_bar.set_status(BuildStatus.PROGRESS, "安装编译依赖...")
	Console.log_info("[color=#65d98b]开始安装编译依赖：%s[/color]" % ",".join(p_dependency_ids))
	var installer: DependencyInstaller = DependencyInstaller.new()
	var outcome: Dictionary = await installer.install_all(_current_source_dir,
			GodotBuilder.get_host_platform(), p_dependency_ids,
			_make_dependency_progress(), false)
	var installed: Array = outcome.get("installed", [])
	var installed_dirs: Dictionary = outcome.get("dirs", {})
	for item: Variant in installed:
		var id: String = str(item)
		var target: String = str(installed_dirs.get(id, outcome.get("deps_dir", "")))
		Console.log_info("已安装 %s → [color=#65d98b][url=%s]%s[/url][/color]" % [id, target, target])
	if not bool(outcome.get("ok", false)):
		build_status_bar.set_status(BuildStatus.ERROR, "编译依赖安装失败")
		Console.log_error("编译依赖安装失败：%s" % str(outcome.get("error", "")))
		build_status_bar.restore_status()
		return
	build_status_bar.set_status(BuildStatus.OK, "编译依赖已就绪")
	Console.log_info("[color=#65d98b]编译依赖安装完成：%d 项，%.1f MB[/color]" % [
		installed.size(), int(outcome.get("bytes", 0)) / BYTES_PER_MB])
	build_status_bar.restore_status()

## 依赖安装进度回调：同一文案只打印一次。
func _make_dependency_progress() -> Callable:
	var last_text: Dictionary[String, String] = {"text": ""}
	return func(p_text: String) -> void:
		if p_text == last_text.get("text", ""):
			return
		last_text["text"] = p_text
		build_status_bar.set_status(BuildStatus.PROGRESS, p_text)
		Console.log_info(p_text)

## 生成 PCK 加密密钥并输出到控制台（密钥为可点击复制的链接文本，不写入本机存储）。
func _generate_encryption_key() -> void:
	var key: String = EncryptionKey.generate()
	if not EncryptionKey.is_valid(key):
		Console.log_error("生成加密密钥失败：系统熵不可用")
		return
	Console.log_info(
		"[color=#65d98b]已生成 PCK 加密编译密钥（ENCRYPTION_KEY）：[/color]"
		+ "[url=copy://" + key + "][color=#8ab4f8]" + key + "[/color][/url]"
	)

## 在系统文件管理器中打开构建日志目录（目录不存在时先创建）。
func _open_log_dir() -> void:
	var log_dir: String = ProjectSettings.globalize_path(AppData.get_log_dir())
	DirAccess.make_dir_recursive_absolute(log_dir)
	OS.shell_show_in_file_manager(log_dir)

## 清理构建日志：删除 user://logs/ 下的全部日志文件。
func _on_clear_logs_confirmation_dialog_confirmed() -> void:
	var count: int = BuildLogger.clear_all(
			ProjectSettings.globalize_path(AppData.get_log_dir()))
	if count > 0:
		Console.log_info("[color=#65d98b]已清理 %d 个构建日志[/color]" % count)
	else:
		Console.log_info("没有可清理的构建日志")

func _on_setting_confirmation_dialog_settings_changed(python_path: String, scons_dir: String) -> void:
	if not python_path.is_empty():
		await builder.set_custom_python(python_path)
	if not scons_dir.is_empty():
		await builder.set_scons_dir(scons_dir)
	# 扫描目录可能已变更，按最新设置重建源码选择菜单
	_setup_source_popup_menu()
	Console.log_info("[color=#65d98b]设置已保存[/color]")
	_env_ready = await _check_env()

func _on_group_nav_panel_group_selected(group_key: String) -> void:
	await config_form_panel.show_group(group_key)
	# 搜索模式下点击分组：滚动右侧面板定位到该分组的命中区段
	if not group_nav_panel.search_line_edit.text.is_empty():
		config_form_panel.scroll_to_group(group_key)

func _on_group_nav_panel_search_text_changed(query: String) -> void:
	config_form_panel.set_search_filter(query)
	group_nav_panel.set_search_match_counts(config_form_panel.get_search_match_counts())

func _on_group_nav_panel_reset_group_requested(group_key: String) -> void:
	config_form_panel.reset_group(group_key)
