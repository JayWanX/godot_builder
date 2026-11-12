class_name PythonRuntimeManifest
extends RefCounted
## 运行时清单（python_runtime_manifest.json）的读取与保留判定：裁剪规则的唯一来源。


## 清单文件路径
const MANIFEST_REL_PATH: String = "res://python_runtime_manifest.json"
## 归档顶层目录层数（PBS 为 python/，均剥一层）
const ARCHIVE_STRIP_LEVEL: int = 1
## 字节码缓存目录名（一律不保留）
const PYCACHE_DIR_NAME: String = "__pycache__"
## 字节码文件后缀（一律不保留）
const PYC_SUFFIX: String = ".pyc"
## Python 源文件后缀
const PY_SUFFIX: String = ".py"
## 站点包根目录名
const SITE_PACKAGES_ROOT: String = "SCons"
## 站点包判定缓存键
const SITE_PACKAGES_CACHE_KEY: String = "site_packages"
## 站点包默认白名单顶层单位（清单缺失时不猜，交由校验报错）
const RELATIVE_PATH_SEPARATOR: String = "/"
## 平台名与归档键映射（macOS 两架构合并为 universal）
const ASSET_KEYS: Dictionary = {
	"windows": ["windows"],
	"linux": ["linux"],
	"macos": ["macos_arm64", "macos_x86_64"],
}
## 下载主机候选：按 Godot HTTPClient 实测可达性排序（curl 可用不代表引擎可用）
const HOST_CANDIDATES: Array[Dictionary] = [
	{"kind": "pbs_mirror", "host": "registry.npmmirror.com", "port": 443},
	{"kind": "pbs_upstream", "host": "github.com", "port": 443},
	{"kind": "github_api", "host": "api.github.com", "port": 443},
	{"kind": "pypi_mirror", "host": "pypi.tuna.tsinghua.edu.cn", "port": 443},
	{"kind": "pypi_upstream", "host": "files.pythonhosted.org", "port": 443},
]
## URL 模板占位符
const URL_PLACEHOLDER_TAG: String = "{tag}"
const URL_PLACEHOLDER_FILE: String = "{file}"
const URL_PLACEHOLDER_PATH: String = "{path}"

## 清单原始数据（JSON 边界按规范以无类型 Dictionary 接收）
var _data: Dictionary = {}
## 保留判定用的归一化集合缓存：{ 平台或站点包键: 集合 }
var _keeps: Dictionary[String, Dictionary] = {}

## 加载并校验清单。[br][br]
## [param p_path] 清单路径；为空时用 MANIFEST_REL_PATH。[br]
## [return] 成功返回 true。
func load_manifest(p_path: String = MANIFEST_REL_PATH) -> bool:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(p_path))
	if not parsed is Dictionary:
		push_error("运行时清单解析失败：%s" % p_path)
		return false
	_data = parsed
	for key: String in ["pbs_tag", "python_version", "assets", "scons", "platforms", "site_packages"]:
		if not _data.has(key):
			push_error("运行时清单缺少字段：%s" % key)
			return false
	return true

## 平台段数据。[br][br]
## [param p_platform] windows / linux / macos。[br]
## [return] 含键：stdlib_dir(String)、top_allow(Array)、bin_allow(Array)、dlls_allow(Array)、stdlib_allow_files(Array)、top_file_drop(Array)、deref_links(Dictionary)；平台不存在时为空
func get_platform(p_platform: String) -> Dictionary:
	var platforms: Dictionary = _data.get("platforms", {})
	return platforms.get(p_platform, {})

## 站点包保留规则。[br][br]
## [return] 含键：root(String)、top_allow(Array)、py_only(bool)
func get_site_packages() -> Dictionary:
	return _data.get("site_packages", {})

## 指定平台需下载的资产。[br][br]
## [param p_platform] windows / linux / macos。[br]
## [return] 每项含键：key(String)、file(String)、sha256(String)
func get_assets(p_platform: String) -> Array[Dictionary]:
	var assets: Dictionary = _data.get("assets", {})
	var result: Array[Dictionary] = []
	for key: String in _string_array(ASSET_KEYS.get(p_platform, [])):
		var item: Dictionary = assets.get(key, {})
		if item.is_empty():
			continue
		result.append({
			"key": key,
			"file": str(item.get("file", "")),
			"sha256": str(item.get("sha256", "")),
		})
	return result

## SCons wheel 信息。[br][br]
## [return] 含键：version(String)、file(String)、path(String)、sha256(String)
func get_scons_asset() -> Dictionary:
	var scons: Dictionary = _data.get("scons", {})
	return {
		"version": str(scons.get("version", "")),
		"file": str(scons.get("file", "")),
		"path": str(scons.get("path", "")),
		"sha256": str(scons.get("sha256", "")),
	}

## URL 模板表。[br][br]
## [return] 含键：pbs_upstream、pbs_mirror、pypi_upstream、pypi_mirror（值均为 String）
func get_url_templates() -> Dictionary:
	var result: Dictionary[String, String] = {}
	for key: Variant in _data.get("urls", {}).keys():
		result[str(key)] = str(_data.get("urls", {}).get(key, ""))
	return result

## 已安装运行时的版本标识（用于与 .version 比对，决定是否需要重新装配）。[br][br]
## [return] 形如 "3.14.10+20261026"；不完整时返回空串
func get_runtime_version() -> String:
	var version: String = str(_data.get("python_version", ""))
	var tag: String = str(_data.get("pbs_tag", ""))
	if version.is_empty() or tag.is_empty():
		return ""
	return "%s+%s" % [version, tag]

## 展开 URL 模板。[br][br]
## [param p_template] 含 {tag}/{file}/{path} 占位的模板。[br]
## [param p_file_name] 文件名。[br]
## [param p_asset_path] 路径型模板（PyPI files 含内容哈希）用的固定路径，无则留空。[br]
## [return] 可用 URL；模板为空时返回空串
func build_url(p_template: String, p_file_name: String = "", p_asset_path: String = "") -> String:
	if p_template.is_empty():
		return ""
	return p_template.replace(URL_PLACEHOLDER_TAG, str(_data.get("pbs_tag", ""))) \
			.replace(URL_PLACEHOLDER_FILE, p_file_name) \
			.replace(URL_PLACEHOLDER_PATH, p_asset_path)

## 归档内条目路径 → 剥掉顶层目录后的相对路径。[br][br]
## [param p_member_path] tar 条目名。[br]
## [return] 相对路径；层级不足时返回空串（该条目为顶层壳，跳过）
func to_member_rel_path(p_member_path: String) -> String:
	var segments: PackedStringArray = p_member_path.split(RELATIVE_PATH_SEPARATOR, false)
	if segments.size() <= ARCHIVE_STRIP_LEVEL:
		return ""
	return RELATIVE_PATH_SEPARATOR.join(
			segments.slice(ARCHIVE_STRIP_LEVEL, segments.size()))

## 运行时条目是否保留（与 fetch_python_runtime.keep_runtime 同构）。[br][br]
## [param p_rel_path] 已剥顶层目录的相对路径（正斜杠）。[br]
## [param p_platform] windows / linux / macos。[br]
## [return] 保留返回 true
func is_runtime_file_kept(p_rel_path: String, p_platform: String) -> bool:
	var config: Dictionary = get_platform(p_platform)
	if config.is_empty():
		return false
	if not _keeps.has(p_platform):
		warm_caches()
	var cache: Dictionary = _keeps.get(p_platform, {})
	var stdlib_dir: String = str(config.get("stdlib_dir", ""))
	var segments: PackedStringArray = p_rel_path.split(RELATIVE_PATH_SEPARATOR, false)
	if segments.is_empty():
		return false
	for segment: String in segments:
		if segment == PYCACHE_DIR_NAME:
			return false
	if p_rel_path.ends_with(PYC_SUFFIX):
		return false
	var lower_path: String = p_rel_path.to_lower()
	if segments.size() == 1:
		return not (cache.get("drop", {}) as Dictionary).has(lower_path)
	var first: String = segments[0]
	if not (cache.get("top", {}) as Dictionary).has(first):
		return false
	if p_platform == "windows" and first == "DLLs":
		return (cache.get("dlls", {}) as Dictionary).has(segments[segments.size() - 1])
	if first == "bin":
		return (cache.get("bin", {}) as Dictionary).has(segments[segments.size() - 1])
	var stdlib_parts: PackedStringArray = stdlib_dir.split(RELATIVE_PATH_SEPARATOR, false)
	if stdlib_parts.is_empty():
		push_error("运行时清单平台 %s 的 stdlib_dir 缺失或为空，拒绝保留：%s" % [p_platform, p_rel_path])
		return false
	if p_platform != "windows" and first == stdlib_parts[0]:
		if segments.size() > 1 and stdlib_parts.size() > 1 and segments[1] != stdlib_parts[1]:
			return false
	var is_stdlib_inner: bool = segments.size() > stdlib_parts.size()
	if is_stdlib_inner:
		var matched: bool = true
		for index: int in stdlib_parts.size():
			if segments[index] != stdlib_parts[index]:
				matched = false
				break
		is_stdlib_inner = matched
	if is_stdlib_inner:
		return (cache.get("files", {}) as Dictionary).has(lower_path)
	return true

## 站点包条目是否保留（只保留 SCons 树内的 .py，且顶层单位在白名单内）。[br][br]
## [param p_rel_path] 已剥顶层目录的相对路径。[br]
## [return] 保留返回 true
func is_site_package_kept(p_rel_path: String) -> bool:
	var root: String = str(get_site_packages().get("root", SITE_PACKAGES_ROOT))
	if not p_rel_path.begins_with(root + RELATIVE_PATH_SEPARATOR):
		return false
	if p_rel_path.ends_with(PYC_SUFFIX):
		return false
	for segment: String in p_rel_path.split(RELATIVE_PATH_SEPARATOR, false):
		if segment == PYCACHE_DIR_NAME:
			return false
	var config: Dictionary = get_site_packages()
	if config.is_empty():
		return false
	if not _keeps.has(SITE_PACKAGES_CACHE_KEY):
		warm_caches()
	if bool(config.get("py_only", true)) and not p_rel_path.ends_with(PY_SUFFIX):
		return false
	var cache: Dictionary = _keeps.get(SITE_PACKAGES_CACHE_KEY, {})
	var inner: String = p_rel_path.trim_prefix(root + RELATIVE_PATH_SEPARATOR)
	var unit: String = inner.split(RELATIVE_PATH_SEPARATOR, false)[0]
	return (cache.get("units", {}) as Dictionary).has(unit.trim_suffix(PY_SUFFIX))

## 实体文件在保留集里对应的链接名（解引用：链接名保留而实体被裁时由实体承担内容）。[br][br]
## [param p_rel_path] 条目相对路径。[br]
## [param p_platform] 平台名。[br]
## [return] 链接名；无对应时返回空串
func get_deref_link_name(p_rel_path: String, p_platform: String) -> String:
	var deref: Dictionary = get_platform(p_platform).get("deref_links", {})
	return str(deref.get(p_rel_path, ""))

## 平台解引用表（JSON 边界在此收敛为类型化字典）。[br][br]
## [param p_platform] 平台名。[br]
## [return] 实体相对路径 → 链接相对路径
func get_deref_map(p_platform: String) -> Dictionary[String, String]:
	var raw: Dictionary = get_platform(p_platform).get("deref_links", {})
	var result: Dictionary[String, String] = {}
	for entity_path: Variant in raw.keys():
		result[str(entity_path)] = str(raw.get(entity_path, ""))
	return result

## 预建保留判定用的集合缓存（逐条目判定不重建）。
func warm_caches() -> void:
	_keeps.clear()
	for plat: String in ["windows", "linux", "macos"]:
		var config: Dictionary = get_platform(plat)
		if config.is_empty():
			continue
		_keeps[plat] = {
			"top": _to_set(_string_array(config.get("top_allow", []))),
			"bin": _to_set(_string_array(config.get("bin_allow", []))),
			"dlls": _to_set(_string_array(config.get("dlls_allow", []))),
			"drop": _to_set(_lower(_string_array(config.get("top_file_drop", [])))),
			"files": _to_set(_lower(_string_array(config.get("stdlib_allow_files", [])))),
		}
	var sp: Dictionary = get_site_packages()
	_keeps["site_packages"] = {"units": _to_set(_string_array(sp.get("top_allow", [])))}

## 把数组元素统一成字符串。
func _string_array(p_value: Variant) -> Array[String]:
	var result: Array[String] = []
	if not p_value is Array:
		return result
	for item: Variant in p_value as Array:
		result.append(str(item))
	return result

## 字符串数组整体转小写。
func _lower(p_items: Array[String]) -> Array[String]:
	var result: Array[String] = []
	for item: String in p_items:
		result.append(item.to_lower())
	return result

## 数组转集合（判定为 O(1)）。
func _to_set(p_items: Array[String]) -> Dictionary[String, bool]:
	var result: Dictionary[String, bool] = {}
	for item: String in p_items:
		result[item] = true
	return result
