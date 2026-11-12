@abstract
class_name Console
extends Object

const KEY_TEXT = ConsolePanel.KEY_TEXT
const KEY_TYPE = ConsolePanel.KEY_TYPE
const OutputType = ConsolePanel.OutputType

## GUI 实际使用的 BBCode 标签白名单（CLI 输出为纯文本，只剥离这些，避免误伤 SCons 原始输出里的方括号文本）。
const _BBCODE_TAG_PATTERN: String = r'\[/?(color|url|br|b|i|u|code|center|right|left)(=[^\]]*)?\]'

## 全局日志入口（静态转发到当前实例）
static var _instance: ConsolePanel
## 实例未就绪时的待回放日志缓冲（防止丢失）
static var _pending_messages: Array[Dictionary] = []
## CLI 模式：true 时不走 GUI 面板；详细输出由 _cli_quiet / _cli_log 决定去向。
static var _cli_mode: bool = false
## CLI 静默：true 时详细日志不输出到终端（关键节点由 CLI 核心直接输出）。
static var _cli_quiet: bool = false
## CLI 日志落盘目标：非空时所有日志只写入该文件。
static var _cli_log: BuildLogger = null
## BBCode 标签正则（延迟编译）。
static var _bbcode_tag_regex: RegEx = null

static func initialize(instance: ConsolePanel) -> void:
	_instance = instance
	for message: Dictionary in _pending_messages:
		_push_message(message)
	_pending_messages.clear()

## 切换 CLI 输出模式并清空 GUI 待回放缓冲（CLI 不回放历史 GUI 消息）。
static func set_cli_mode(enabled: bool) -> void:
	_cli_mode = enabled
	if enabled:
		_instance = null
		_pending_messages.clear()

## 切换 CLI 静默：静默期间详细日志不刷终端，由 CLI 核心输出关键节点。
static func set_cli_quiet(enabled: bool) -> void:
	_cli_quiet = enabled

## 挂载 CLI 日志落盘目标；挂载期间日志只写文件。
static func set_cli_log(logger: BuildLogger) -> void:
	_cli_log = logger

## 卸载 CLI 日志落盘目标。
static func clear_cli_log() -> void:
	_cli_log = null

static func log_info(message: String) -> void:
	_push_message({ KEY_TEXT: message, KEY_TYPE: OutputType.INFO })

static func log_error(message: String) -> void:
	_push_message({ KEY_TEXT: message, KEY_TYPE: OutputType.ERROR })

static func log_warning(message: String) -> void:
	_push_message({ KEY_TEXT: message, KEY_TYPE: OutputType.WARNING })

static func _push_message(message: Dictionary) -> void:
	var text: String = _strip_bbcode(message.get(KEY_TEXT, ""))
	if _cli_log != null:
		_cli_log.append(text)
		return
	if _cli_quiet:
		return
	if _cli_mode:
		if message.get(KEY_TYPE, OutputType.INFO) == OutputType.INFO:
			print(text)
		else:
			printerr(text)
		return
	if _instance:
		_instance.append_message(message.get(KEY_TEXT), message.get(KEY_TYPE))
	else:
		_pending_messages.append(message)

## 剥离 BBCode 标签（[color=...]、[url=...]、[br] 等），保留标签间文本。
static func _strip_bbcode(text: String) -> String:
	if _bbcode_tag_regex == null:
		_bbcode_tag_regex = RegEx.create_from_string(_BBCODE_TAG_PATTERN)
	return _bbcode_tag_regex.sub(text, "", true)
