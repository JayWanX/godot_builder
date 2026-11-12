class_name AppData
extends Resource
## 应用数据。配置文件、密钥与源码扫描目录留在可执行文件旁；
## 构建日志与 scons --help 缓存写入 user://（可写目录）。

const DEFAULT_SAVE_PATH: String = "app_data.tres"
const SCAN_DIR_NAME: String = "sources"
## 运行期状态根目录（user://，可写）
const STATE_ROOT: String = "user://"
## 构建日志目录名
const LOG_DIR_NAME: String = "logs"
## scons --help 缓存目录名
const HELP_CACHE_DIR_NAME: String = "scons_help"

static var executable_path: String = OS.get_executable_path().get_base_dir()

## 自定义源码扫描目录（空串表示使用可执行文件旁的 sources/）
@export_storage var custom_source_scan_dir: String = ""
## 自定义 Python 解释器路径（空串表示使用内置运行时）
@export_storage var custom_python_path: String = ""
## 自定义 SCons 库路径（空串表示使用内置 SCons）
@export_storage var custom_scons_dir: String = ""
## 构建产物输出目录（空串表示不复制，产物保留在源码目录 bin/）
@export_storage var output_dir: String = ""

## 应用数据文件路径（可执行文件旁 app_data.tres）。
static func get_data_path() -> String:
	return executable_path.path_join(DEFAULT_SAVE_PATH)

## 构建日志目录（user://logs）。
static func get_log_dir() -> String:
	return STATE_ROOT.path_join(LOG_DIR_NAME)

## scons --help 缓存目录（user://scons_help）。
static func get_help_cache_dir() -> String:
	return STATE_ROOT.path_join(HELP_CACHE_DIR_NAME)

## 获取源码扫描目录（未配置时回退可执行文件旁的 sources/）。
func get_source_scan_dir() -> String:
	if custom_source_scan_dir.strip_edges().is_empty():
		return executable_path.path_join(SCAN_DIR_NAME)
	return custom_source_scan_dir

static func load() -> AppData:
	var data_path: String = get_data_path()
	# 磁盘已有且类型正确的数据时直接复用，不重复写盘
	if ResourceLoader.exists(data_path):
		var app_data: Resource = ResourceLoader.load(data_path)
		if app_data is AppData:
			app_data.take_over_path(data_path)
			return app_data
	# 文件缺失或损坏时重建
	var new_app_data: Resource = AppData.new()
	new_app_data.take_over_path(data_path)
	ResourceSaver.save(new_app_data)
	return new_app_data

func save() -> Error:
	return ResourceSaver.save(self, get_data_path())
