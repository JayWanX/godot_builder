@tool
extends EditorExportPlugin
## 导出裁剪：按运行时清单（res://python_runtime_manifest.json）的保留集裁剪嵌入式 Python 运行时与站点包。
##
## 保留判定全部由 PythonRuntimeManifest 给出，与解压装配走同一份规则；本插件只负责
## 把导出路径换算成清单里的相对路径，并裁掉非目标平台的运行时。
## 预设未声明 `embed-python` 特性时不打包整个 python/ 目录（普通版产物）。

## 运行时相对工程根的子目录（其后一级为平台目录）。
const RUNTIME_REL_ROOT: String = "python"
## SCons 站点包相对工程根的子目录。
const SITE_PACKAGES_REL_ROOT: String = "python/site-packages"
## 路径分隔符。
const PATH_SEPARATOR: String = "/"
## 导出预设声明内嵌 Python 运行时的特性标签。
const EMBED_PYTHON_FEATURE: String = "embed-python"

## 运行时清单；加载失败时为空，此时不裁剪（宁可多带，不可裁错）。
var _manifest: PythonRuntimeManifest = null
## 本次导出的目标平台（windows / linux / macos），无法识别时为空。
var _target_platform: String = ""
## 本次导出是否内嵌 Python 运行时（由预设的 custom_features 决定）。
var _is_embed_python: bool = false

func _get_name() -> String:
	return "GodotBuilderExportTrimmer"

func _export_begin(features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	_manifest = null
	_target_platform = _detect_platform(features)
	_is_embed_python = features.has(EMBED_PYTHON_FEATURE)
	if _target_platform.is_empty():
		return
	# 普通版不打包运行时，无需加载清单（避免无谓的清单校验与报错）
	if not _is_embed_python:
		return
	var manifest: PythonRuntimeManifest = PythonRuntimeManifest.new()
	if not manifest.load_manifest():
		return
	if manifest.get_platform(_target_platform).is_empty():
		push_error("运行时清单缺少平台段：%s" % _target_platform)
		return
	_manifest = manifest

func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	# 非内嵌版：python/ 整棵目录不打包
	if not _is_embed_python:
		if not _relative_under(path, RUNTIME_REL_ROOT).is_empty():
			skip()
		return
	if _manifest == null:
		return
	# 站点包必须先判：它的前缀 python/ 同时命中运行时根，顺序颠倒会把 SCons 树整棵跳过
	var site_rel: String = _relative_under(path, SITE_PACKAGES_REL_ROOT)
	if not site_rel.is_empty():
		if not _manifest.is_site_package_kept(site_rel):
			skip()
		return
	var rel: String = _relative_under(path, RUNTIME_REL_ROOT)
	if not rel.is_empty():
		_trim_runtime(rel)

## 裁剪运行时条目：先按平台目录过滤，再查清单保留集。
func _trim_runtime(p_rel: String) -> void:
	var segments: PackedStringArray = p_rel.split(PATH_SEPARATOR, false)
	if segments.is_empty():
		return
	var first: String = segments[0]
	# 清单里没有该名字的平台段即非平台目录（.gitkeep 等散落文件）：原样导出
	if _manifest.get_platform(first).is_empty():
		return
	if first != _target_platform:
		skip()
		return
	if segments.size() < 2:
		return
	var inner: String = PATH_SEPARATOR.join(segments.slice(1, segments.size()))
	if not _manifest.is_runtime_file_kept(inner, _target_platform):
		skip()

## 取 path 在 res://<p_prefix>/ 之下的相对路径；不在该前缀下时返回空串。
func _relative_under(p_path: String, p_prefix: String) -> String:
	var prefix: String = "res://" + p_prefix + PATH_SEPARATOR
	if not p_path.begins_with(prefix):
		return ""
	return p_path.trim_prefix(prefix)

## 从导出预设 features 识别目标平台。
func _detect_platform(p_features: PackedStringArray) -> String:
	for feature: String in p_features:
		match feature.to_lower():
			"windows", "pc":
				return "windows"
			"linux", "x11":
				return "linux"
			"macos":
				return "macos"
	return ""
