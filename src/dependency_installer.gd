class_name DependencyInstaller
extends RefCounted
## 编译依赖安装器：按上游 install_*.py 的规格下载并解压 SDK 包，全程异步不阻塞界面。


## 归档缓存目录名（放在依赖目录旁）
const CACHE_DIR_NAME: String = "install_cache"
## Perfetto latest tag 的临时响应文件
const PERFETTO_TAG_TEMP_FILE: String = "godot_builder_perfetto_latest.json"
## 规格字典键
const KEY_ID: String = "id"
const KEY_BASE: String = "base"
const KEY_FILES: String = "files"
const KEY_CLEAN: String = "clean"
const KEY_RENAME_FROM: String = "rename_from"
const KEY_RENAME_TO: String = "rename_to"
const KEY_NEEDS_MINGW: String = "needs_mingw"
## 文件项键
const KEY_NAME: String = "name"
const KEY_HOST: String = "host"
const KEY_PATH: String = "path"
const KEY_INTO: String = "into"
const KEY_SELECT: String = "select"
## 依赖项键
const KEY_ITEMS: String = "items"
const KEY_TAG: String = "tag"
const KEY_DIRS: String = "dirs"
const KEY_TARGET: String = "target"
## 列表阶段传给解析器的占位 tag：仅用于让 perfetto 出现在候选里，不参与下载
const PERFETTO_LIST_TAG_PLACEHOLDER: String = "latest"
## 结果键
const KEY_OK: String = "ok"
const KEY_ERROR: String = "error"
const KEY_INSTALLED: String = "installed"
const KEY_FAILED: String = "failed"
const KEY_BYTES: String = "bytes"
const KEY_DEPS_DIR: String = "deps_dir"
const KEY_SPECS: String = "specs"
## 落地根
const BASE_DEPS: String = "deps"
## 引擎内第三方目录
const THIRDPARTY_DIR: String = "thirdparty"
## MinGW 工具探测参数与工具名（数组字面量，OS.execute 调用点转 PackedStringArray）
const TOOL_PROBE_ARGUMENTS: Array[String] = ["--version"]
const GENDEF_TOOL: String = "gendef"
const DLLTOOL_TOOL: String = "dlltool"
## WinPix 导入库生成参数（复刻上游 dlltool 命令行）
const DLLTOOL_MACHINE_ARGUMENT: String = "--machine"
const DLLTOOL_NO_UNDERSCORE_ARGUMENT: String = "--no-leading-underscore"
const DLLTOOL_DEF_ARGUMENT: String = "-d"
const DLLTOOL_DLL_ARGUMENT: String = "-D"
const DLLTOOL_LIB_ARGUMENT: String = "-l"
## 动态库后缀与静态库前缀
const DLL_SUFFIX: String = ".dll"
const DEF_SUFFIX: String = ".def"
const STATIC_LIB_PREFIX: String = "lib"
const STATIC_LIB_SUFFIX: String = ".a"
## 字节单位换算
const BYTES_PER_MB: float = 1048576.0
## 失败原因拼接分隔符
const REASON_SEPARATOR: String = " | "

## WinPixEventRuntime 需要为 MinGW 补导入库的两个架构（复刻上游脚本）
const MINGW_ADAPTERS: Array = [
	{"dll": "bin/x64/WinPixEventRuntime.dll", "machine": "i386:x86-64"},
	{"dll": "bin/ARM64/WinPixEventRuntime.dll", "machine": "arm64"},
]


## 列出目标平台可安装的依赖（只解析上游脚本，不发起网络、不写盘）。[br][br]
## [param p_engine_dir] 引擎根（绝对或 res://）。[param p_platform] 构建目标平台名。[br]
## [return] 含键：ok(bool)、error(String)、items(Array[Dictionary])、deps_dir(String)；
## items 每项含键：id(String)、tag(String)、target(String)
func list_available(p_engine_dir: String, p_platform: String) -> Dictionary:
	var engine_dir: String = ProjectSettings.globalize_path(p_engine_dir)
	# perfetto 的 tag 需联网取，列表阶段用占位名，真实版本在安装时解析
	var specs_result: Dictionary = InstallSpecParser.build_specs(
			engine_dir, PERFETTO_LIST_TAG_PLACEHOLDER, p_platform)
	var parse_error: String = str(specs_result.get(KEY_ERROR, ""))
	if not parse_error.is_empty():
		return {KEY_OK: false, KEY_ERROR: parse_error, KEY_ITEMS: [], KEY_DEPS_DIR: ""}
	var deps_dir: String = str(specs_result[KEY_DEPS_DIR])
	var items: Array[Dictionary] = []
	for spec: Dictionary in specs_result[KEY_SPECS] as Array:
		items.append({
			KEY_ID: str(spec.get(KEY_ID, "")),
			KEY_TAG: str(spec.get(KEY_TAG, "")),
			KEY_TARGET: _install_target(spec, engine_dir, deps_dir),
		})
	return {KEY_OK: true, KEY_ERROR: "", KEY_ITEMS: items, KEY_DEPS_DIR: deps_dir}


## 依赖项的最终落地目录（含包内子目录，供界面展示）。[br][br]
## [param p_spec] 解析出的规格。[param p_engine_dir] 引擎根（绝对）。[param p_deps_dir] 依赖目录。[br]
## [return] 绝对路径；含多个落地目录时返回根目录
func _install_target(p_spec: Dictionary, p_engine_dir: String, p_deps_dir: String) -> String:
	var root: String = _install_root(p_spec, p_engine_dir, p_deps_dir)
	# 含多个包（如 d3d12 的 mesa 各架构 + pix + agility）时只报根目录
	var sub_dirs: PackedStringArray = PackedStringArray()
	for file_item: Variant in p_spec.get(KEY_FILES, []) as Array:
		var into: String = str((file_item as Dictionary).get(KEY_INTO, ""))
		if not into.is_empty() and not sub_dirs.has(into):
			sub_dirs.append(into)
	if sub_dirs.size() == 1:
		return root.path_join(sub_dirs[0])
	if not sub_dirs.is_empty():
		return root
	# 包内无子目录时看改名目标（accesskit 解出 accesskit-c-<版本> 后改名为 accesskit）
	var rename_to: String = str(p_spec.get(KEY_RENAME_TO, ""))
	return root if rename_to.is_empty() else root.path_join(rename_to)


## 安装全部解析出的依赖。[br][br]
## [param p_engine_dir] 引擎根（绝对或 res://）。[param p_platform] 构建目标平台名。[br]
## [param p_ids] 只装这些 id（空表示全部）。[param p_progress] 进度回调 f(文本)。[br]
## [param p_keep_cache] 下载完保留归档。[br]
## [return] 含键：ok(bool)、error(String)、installed(String[])、failed(String[])、bytes(int)、deps_dir(String)、dirs(Dictionary)
func install_all(p_engine_dir: String, p_platform: String,
		p_ids: PackedStringArray = PackedStringArray(),
		p_progress: Callable = Callable(), p_keep_cache: bool = false) -> Dictionary:
	var engine_dir: String = ProjectSettings.globalize_path(p_engine_dir)
	var perfetto_tag: String = ""
	if _wants(p_ids, "perfetto"):
		perfetto_tag = await _fetch_perfetto_tag()
	var specs_result: Dictionary = InstallSpecParser.build_specs(
			engine_dir, perfetto_tag, p_platform)
	var parse_error: String = str(specs_result.get(KEY_ERROR, ""))
	if not parse_error.is_empty():
		return {KEY_OK: false, KEY_ERROR: parse_error, KEY_INSTALLED: [],
				KEY_FAILED: [parse_error], KEY_BYTES: 0, KEY_DEPS_DIR: ""}
	var deps_dir: String = str(specs_result[KEY_DEPS_DIR])
	var installed: Array[String] = []
	var failed: Array[String] = []
	var installed_dirs: Dictionary[String, String] = {}
	var total_bytes: int = 0
	for spec: Dictionary in specs_result[KEY_SPECS] as Array:
		var id: String = str(spec.get(KEY_ID, ""))
		if not _wants(p_ids, id):
			continue
		var outcome: Dictionary = await _install_spec(spec, engine_dir, deps_dir,
				p_progress, p_keep_cache)
		if not bool(outcome.get(KEY_OK, false)):
			failed.append("%s：%s" % [id, str(outcome.get(KEY_ERROR, ""))])
			continue
		installed.append(id)
		installed_dirs[id] = _install_root(spec, engine_dir, deps_dir)
		total_bytes += int(outcome.get(KEY_BYTES, 0))
	return {
		KEY_OK: failed.is_empty(),
		KEY_ERROR: REASON_SEPARATOR.join(failed),
		KEY_INSTALLED: installed, KEY_FAILED: failed,
		KEY_DIRS: installed_dirs,
		KEY_BYTES: total_bytes, KEY_DEPS_DIR: deps_dir,
	}


## 依赖项实际的落地根目录：deps 类落在依赖目录，其余（perfetto/swappy）落在引擎 thirdparty。[br][br]
## [param p_spec] 解析出的规格。[param p_engine_dir] 引擎根（绝对）。[param p_deps_dir] 依赖目录。[br]
## [return] 绝对路径
func _install_root(p_spec: Dictionary, p_engine_dir: String, p_deps_dir: String) -> String:
	if str(p_spec.get(KEY_BASE, BASE_DEPS)) == BASE_DEPS:
		return p_deps_dir
	return p_engine_dir.path_join(THIRDPARTY_DIR)


## 安装单个依赖组：清目录 → 逐个下载解压 → 改名与 MinGW 后处理。
func _install_spec(p_spec: Dictionary, p_engine_dir: String, p_deps_dir: String,
		p_progress: Callable, p_keep_cache: bool) -> Dictionary:
	var root: String = p_deps_dir if str(p_spec.get(KEY_BASE, BASE_DEPS)) == BASE_DEPS \
			else p_engine_dir.path_join(THIRDPARTY_DIR)
	var cache_dir: String = p_deps_dir.path_join(CACHE_DIR_NAME)
	if DirAccess.make_dir_recursive_absolute(cache_dir) != OK:
		return {KEY_OK: false, KEY_ERROR: "无法创建缓存目录：%s" % cache_dir, KEY_BYTES: 0}
	_clean_targets(root, p_spec.get(KEY_CLEAN, []))
	var total_bytes: int = 0
	for file_item: Dictionary in p_spec.get(KEY_FILES, []) as Array:
		var name: String = str(file_item.get(KEY_NAME, ""))
		var archive: String = cache_dir.path_join(name)
		var download_outcome: Dictionary = await _download(file_item, archive, p_progress)
		if not bool(download_outcome.get(KEY_OK, false)):
			_cleanup_download(archive, p_keep_cache)
			return {KEY_OK: false, KEY_ERROR: str(download_outcome.get(KEY_ERROR, "")),
					KEY_BYTES: total_bytes}
		var into: String = str(file_item.get(KEY_INTO, ""))
		var target_dir: String = root if into.is_empty() else root.path_join(into)
		if not into.is_empty() and DirAccess.make_dir_recursive_absolute(target_dir) != OK:
			return {KEY_OK: false, KEY_ERROR: "无法创建目录：%s" % target_dir,
					KEY_BYTES: total_bytes}
		var extractor: ZipExtractor = ZipExtractor.new()
		var extracted: Dictionary = extractor.extract(archive, target_dir,
				_string_array(file_item.get(KEY_SELECT, [])))
		_cleanup_download(archive, p_keep_cache)
		if not bool(extracted.get(KEY_OK, false)):
			return {KEY_OK: false, KEY_ERROR: str(extracted.get(KEY_ERROR, "")),
					KEY_BYTES: total_bytes}
		total_bytes += int(extracted[KEY_BYTES])
	_apply_rename(root, p_spec)
	if bool(p_spec.get(KEY_NEEDS_MINGW, false)):
		_adapt_mingw(root, p_progress)
	return {KEY_OK: true, KEY_ERROR: "", KEY_BYTES: total_bytes}


## 下载单个归档到指定文件（依赖包无官方摘要，只下载不比对）。
func _download(p_file_item: Dictionary, p_dest: String, p_progress: Callable) -> Dictionary:
	var name: String = str(p_file_item.get(KEY_NAME, ""))
	var host: String = str(p_file_item.get(KEY_HOST, ""))
	_notify(p_progress, "下载 %s（%s）" % [name, host])
	var downloader: RuntimeDownloader = RuntimeDownloader.new()
	downloader.configure([{"host": host, "port": 443, "tls": true,
			"path": str(p_file_item.get(KEY_PATH, ""))}])
	return await downloader.download(p_dest, "", _make_byte_progress(name, p_progress))


## 删除旧的落地目录，保证安装结果不残留上一版文件。
func _clean_targets(p_root: String, p_entries: Variant) -> void:
	if not p_entries is Array:
		return
	for entry: Variant in p_entries as Array:
		var path: String = p_root.path_join(str(entry))
		if DirAccess.dir_exists_absolute(path):
			_remove_tree(path)


## AccessKit 形态：解出 accesskit-c-<版本> 后改名为 accesskit。
func _apply_rename(p_root: String, p_spec: Dictionary) -> void:
	if not p_spec.has(KEY_RENAME_FROM):
		return
	var source: String = p_root.path_join(str(p_spec[KEY_RENAME_FROM]))
	var destination: String = p_root.path_join(str(p_spec[KEY_RENAME_TO]))
	if not DirAccess.dir_exists_absolute(source):
		return
	if DirAccess.dir_exists_absolute(destination):
		_remove_tree(destination)
	DirAccess.rename_absolute(source, destination)


## MinGW 形态：用 gendef + dlltool 给 WinPix 补 .a 导入库；缺工具则只保留 MSVC 支持。
func _adapt_mingw(p_deps_dir: String, p_progress: Callable) -> void:
	if not _tool_exists(GENDEF_TOOL) or not _tool_exists(DLLTOOL_TOOL):
		_notify(p_progress, "未找到 gendef/dlltool，WinPixEventRuntime 仅装 MSVC 支持")
		return
	for adapter: Dictionary in MINGW_ADAPTERS:
		var dll_path: String = p_deps_dir.path_join("pix").path_join(str(adapter["dll"]))
		if not FileAccess.file_exists(dll_path):
			continue
		_notify(p_progress, "为 MinGW 生成 %s 的导入库" % str(adapter["dll"]))
		OS.execute(GENDEF_TOOL, PackedStringArray([dll_path]))
		var def_path: String = dll_path.trim_suffix(DLL_SUFFIX) + DEF_SUFFIX
		if not FileAccess.file_exists(def_path):
			continue
		var lib_path: String = dll_path.get_base_dir().path_join(
				"%s%s%s" % [STATIC_LIB_PREFIX, dll_path.get_file().get_basename(),
					STATIC_LIB_SUFFIX])
		OS.execute(DLLTOOL_TOOL, PackedStringArray([
			DLLTOOL_MACHINE_ARGUMENT, str(adapter["machine"]),
			DLLTOOL_NO_UNDERSCORE_ARGUMENT,
			DLLTOOL_DEF_ARGUMENT, def_path,
			DLLTOOL_DLL_ARGUMENT, dll_path,
			DLLTOOL_LIB_ARGUMENT, lib_path,
		]))


## 探测命令行工具是否在 PATH 里（存在即返回 0）。
func _tool_exists(p_tool: String) -> bool:
	var output_lines: Array[String] = []
	return OS.execute(p_tool, PackedStringArray(TOOL_PROBE_ARGUMENTS), output_lines) == 0


## 取 Perfetto 的 latest tag（上游脚本每次现取，这里同样不硬编码版本）。
func _fetch_perfetto_tag() -> String:
	var downloader: RuntimeDownloader = RuntimeDownloader.new()
	downloader.configure([{"host": InstallSpecParser.PERFETTO_LATEST_API_HOST,
			"port": 443, "tls": true,
			"path": InstallSpecParser.PERFETTO_LATEST_API_PATH}])
	var temp_path: String = OS.get_temp_dir().path_join(PERFETTO_TAG_TEMP_FILE)
	var outcome: Dictionary = await downloader.download(temp_path, "")
	if not bool(outcome.get(KEY_OK, false)):
		push_warning("取 Perfetto latest tag 失败：%s" % str(outcome.get(KEY_ERROR, "")))
		return ""
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(temp_path))
	DirAccess.remove_absolute(temp_path)
	# JSON 边界：无类型 Dictionary 接收后立即收敛
	if not parsed is Dictionary:
		return ""
	return str((parsed as Dictionary).get("tag_name", ""))


## 归档落点：保留则原地留着，否则删除。
func _cleanup_download(p_path: String, p_keep: bool) -> void:
	if p_keep:
		return
	DirAccess.remove_absolute(p_path)


## 递归删除目录或文件。
func _remove_tree(p_path: String) -> void:
	if not DirAccess.dir_exists_absolute(p_path):
		DirAccess.remove_absolute(p_path)
		return
	var dir: DirAccess = DirAccess.open(p_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var child: String = p_path.path_join(entry)
			if dir.current_is_dir():
				_remove_tree(child)
			else:
				dir.remove(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(p_path)


## 该 id 是否在请求范围内（p_ids 为空表示全部）。
func _wants(p_ids: PackedStringArray, p_id: String) -> bool:
	return p_ids.is_empty() or p_ids.has(p_id)


## 字节级进度转一行文本进度。
func _make_byte_progress(p_label: String, p_progress: Callable) -> Callable:
	return func(p_done_bytes: int, p_total_bytes: int) -> void:
		if not p_progress.is_valid():
			return
		if p_total_bytes <= 0:
			p_progress.call("%s：已下载 %.1f MB" % [p_label, p_done_bytes / BYTES_PER_MB])
			return
		p_progress.call("%s：%.0f%%" % [p_label,
				100.0 * float(p_done_bytes) / float(p_total_bytes)])


func _notify(p_progress: Callable, p_text: String) -> void:
	if p_progress.is_valid():
		p_progress.call(p_text)


## 数组转字符串数组（规格里的 select 名单来自解析结果）。
func _string_array(p_value: Variant) -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	if not p_value is Array:
		return result
	for item: Variant in p_value as Array:
		result.append(str(item))
	return result
