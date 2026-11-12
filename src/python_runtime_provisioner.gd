class_name PythonRuntimeProvisioner
extends RefCounted
## 运行时装配编排：按清单下载 Python 运行时与 SCons，边下边校验，解压时按保留集裁剪落盘。
##
## 全程异步（HTTPClient 逐帧轮询 + 解压逐条目让出帧），不阻塞界面。
## 下载缓存与装配产物统一落在 user://（可写），与 src/godot_builder.gd 的布局契约一致：
## user://python/<平台>/、user://python/site-packages/、user://runtime_cache/。

## 运行时根目录（可写目录；安装产物与解压源分离）
const PYTHON_RUNTIME_ROOT: String = "user://python"
## 站点包目录名
const SITE_PACKAGES_DIR_NAME: String = "site-packages"
## 已装配版本标记文件名
const VERSION_FILE_NAME: String = ".runtime_version"
## 归档缓存目录（可写目录，属生成物）
const CACHE_REL_DIR: String = "user://runtime_cache"
## 清单键
const KEY_FILE: String = "file"
const KEY_SHA256: String = "sha256"
const KEY_PATH: String = "path"
const KEY_OK: String = "ok"
const KEY_REASON: String = "reason"
## URL 模板键
const URL_PBS_MIRROR: String = "pbs_mirror"
const URL_PBS_UPSTREAM: String = "pbs_upstream"
const URL_PYPI_MIRROR: String = "pypi_mirror"
const URL_PYPI_UPSTREAM: String = "pypi_upstream"
## 资产字典键
const KEY_KEY: String = "key"
## 第二架构解释器后缀：非 macOS 主机无 lipo，保留待 macOS 上合并
const SECONDARY_INTERPRETER_SUFFIX: String = ".x86_64"
## 摘要计算的分块大小（字节）
const DIGEST_READ_SIZE: int = 65536
## 摘要十六进制单字节格式串
const HEX_BYTE_FORMAT: String = "%02x"

## 清单
var _manifest: PythonRuntimeManifest = null
## 归档缓存目录（绝对路径）
var _cache_dir: String = ""
## 进度回调 f(阶段说明, 比例 0..1)
var _progress: Callable = Callable()


## 初始化装配器。[br][br]
## [param p_cache_dir] 归档缓存目录（绝对）；留空时用 user://runtime_cache。[br]
## [param p_progress] 进度回调 f(阶段说明(String), 比例(float))。[br]
## [return] 清单可用返回 true
func initialize(p_cache_dir: String = "", p_progress: Callable = Callable()) -> bool:
	_progress = p_progress
	_manifest = PythonRuntimeManifest.new()
	if not _manifest.load_manifest():
		return false
	_cache_dir = p_cache_dir if not p_cache_dir.is_empty() \
			else ProjectSettings.globalize_path(CACHE_REL_DIR)
	var dir_error: Error = DirAccess.make_dir_recursive_absolute(_cache_dir)
	if dir_error != OK:
		push_error("无法创建归档缓存目录：%s（%s）" % [_cache_dir, error_string(dir_error)])
		return false
	return true


## 已装配版本与清单版本是否一致（一致则无需重新下载）。[br][br]
## [param p_target_root] 装配目标根（绝对）；留空时用 PYTHON_RUNTIME_ROOT。[br]
## [return] 一致返回 true
func is_up_to_date(p_target_root: String = "") -> bool:
	var marker: String = _resolve_root(p_target_root).path_join(VERSION_FILE_NAME)
	if not FileAccess.file_exists(marker):
		return false
	return _read_line(marker) == _manifest.get_runtime_version()


## 装配指定平台的运行时与站点包。[br][br]
## [param p_platform] windows / linux / macos；all 表示三平台齐备（导出成品用）。[br]
## [param p_target_root] 装配目标根（绝对）；留空时用 PYTHON_RUNTIME_ROOT。[br]
## [param p_skip_fresh] 已装配且版本一致时直接返回成功。[br]
## [return] 含键：ok(bool)、reason(String)、files(int)、bytes(int)
func provision(p_platform: String = "", p_target_root: String = "",
		p_skip_fresh: bool = false) -> Dictionary:
	var platforms: PackedStringArray = _platforms_of(p_platform)
	if platforms.is_empty():
		return {KEY_OK: false, KEY_REASON: "平台参数无效：%s" % p_platform}
	var root: String = _resolve_root(p_target_root)
	if p_skip_fresh and is_up_to_date(p_target_root):
		return {KEY_OK: true, KEY_REASON: "已是最新（%s）" % _manifest.get_runtime_version(),
				"files": 0, "bytes": 0}
	var total_files: int = 0
	var total_bytes: int = 0
	for plat: String in platforms:
		var outcome: Dictionary = await _provision_platform(plat, root)
		if not bool(outcome.get(KEY_OK, false)):
			return outcome
		total_files += int(outcome.get("files", 0))
		total_bytes += int(outcome.get("bytes", 0))
	var site_outcome: Dictionary = await _provision_site_packages(root)
	if not bool(site_outcome.get(KEY_OK, false)):
		return site_outcome
	_write_line(root.path_join(VERSION_FILE_NAME), _manifest.get_runtime_version())
	return {KEY_OK: true, KEY_REASON: "", "files": total_files + int(site_outcome.get("files", 0)),
			"bytes": total_bytes + int(site_outcome.get("bytes", 0))}


## 装配单平台：逐个归档下载→解压裁剪落盘。
func _provision_platform(p_platform: String, p_root: String) -> Dictionary:
	var assets: Array[Dictionary] = _manifest.get_assets(p_platform)
	if assets.is_empty():
		return {KEY_OK: false, KEY_REASON: "%s 在清单里没有可用资产" % p_platform}
	var target: String = p_root.path_join(p_platform)
	var total_files: int = 0
	var total_bytes: int = 0
	for index: int in assets.size():
		var asset: Dictionary = assets[index]
		var archive_result: Dictionary = await _ensure_archive(asset, p_platform)
		if not bool(archive_result.get(KEY_OK, false)):
			return archive_result
		var archive: String = str(archive_result.get("archive", ""))
		# 首个资产解压时清空重建，后续资产（macOS 第二架构）只补解释器
		var extractor: TarGzExtractor = TarGzExtractor.new()
		var stage: String = _stage_dir(p_platform, index)
		var extracted: String = "%d/%d" % [index, assets.size()]
		_notify("%s：解压 %s" % [p_platform, str(asset.get(KEY_FILE, ""))],
				float(extracted.split("/")[0]) / float(assets.size()))
		var outcome: Dictionary = await extractor.extract(archive, stage, _manifest, p_platform)
		if not bool(outcome.get(KEY_OK, false)):
			_remove_tree(stage)
			return {KEY_OK: false, KEY_REASON: "%s 解压失败：%s" % [
					p_platform, _join_lines(outcome.get("failures", []))]}
		for warning: String in outcome.get("warnings", []):
			Console.log_warning(str(warning))
		total_files += int(outcome.get("file_count", 0))
		if index == 0:
			_replace_dir(stage, target)
		else:
			_merge_secondary_runtime(stage, target, str(asset.get(KEY_KEY, "")))
		_remove_tree(stage)
		_notify("%s：完成 %d 个条目" % [p_platform, total_files],
				float(index + 1) / float(assets.size()))
	total_bytes = _dir_bytes(target)
	return {KEY_OK: true, KEY_REASON: "", "files": total_files, "bytes": total_bytes}


## 装配站点包（SCons wheel 按 ZIP 解，解压时按清单保留集裁剪）。
func _provision_site_packages(p_root: String) -> Dictionary:
	var asset: Dictionary = _manifest.get_scons_asset()
	var file_name: String = str(asset.get(KEY_FILE, ""))
	if file_name.is_empty():
		return {KEY_OK: false, KEY_REASON: "清单里没有 SCons wheel 信息"}
	var archive_result: Dictionary = await _ensure_archive(asset, "scons")
	if not bool(archive_result.get(KEY_OK, false)):
		return archive_result
	var stage: String = _stage_dir("scons", 0)
	_notify("SCons：解压 %s" % file_name, 0.95)
	var extractor: ZipExtractor = ZipExtractor.new()
	_manifest.warm_caches()
	var outcome: Dictionary = extractor.extract(str(archive_result.get("archive", "")),
			stage, PackedStringArray(), _manifest.is_site_package_kept)
	if not bool(outcome.get(KEY_OK, false)):
		_remove_tree(stage)
		return {KEY_OK: false, KEY_REASON: "SCons 解压失败：%s" % str(
				outcome.get("error", ""))}
	var target: String = p_root.path_join(SITE_PACKAGES_DIR_NAME)
	_replace_dir(stage, target)
	_remove_tree(stage)
	return {KEY_OK: true, KEY_REASON: "", "files": int(outcome.get("files", 0)),
			"bytes": _dir_bytes(target)}


## 取归档：缓存命中且摘要一致则复用，否则按「镜像→上游」下载并校验摘要。
func _ensure_archive(p_asset: Dictionary, p_kind: String) -> Dictionary:
	var file_name: String = str(p_asset.get(KEY_FILE, ""))
	var want_sha: String = str(p_asset.get(KEY_SHA256, "")).to_lower()
	var dest: String = _cache_dir.path_join(file_name)
	# 缓存命中：摘要与清单一致即复用，避免每次装配重下二十余 MB
	if FileAccess.file_exists(dest) and not want_sha.is_empty() \
			and _sha256_of(dest) == want_sha:
		_notify("复用缓存 %s" % file_name, 0.0)
		return {KEY_OK: true, KEY_REASON: "", "archive": dest, "host": "cache"}
	var templates: Dictionary = _manifest.get_url_templates()
	var sources: Array[Dictionary] = _sources_of(p_kind, p_asset, templates)
	if sources.is_empty():
		return {KEY_OK: false, KEY_REASON: "%s 没有可用的下载源" % file_name}
	var downloader: RuntimeDownloader = RuntimeDownloader.new()
	downloader.configure(sources)
	_notify("下载 %s（%s）" % [file_name, str(sources[0].get("host", ""))], 0.0)
	var result: Dictionary = await downloader.download(dest, want_sha,
			_make_progress(file_name), _make_stage(file_name))
	if not bool(result.get(KEY_OK, false)):
		return {KEY_OK: false, KEY_REASON: "%s 下载失败：%s" % [file_name,
				str(result.get(KEY_REASON, ""))]}
	return {KEY_OK: true, KEY_REASON: "", "archive": dest,
			"host": str(result.get("host", ""))}


## 流式计算文件 sha256（小写十六进制）；读不出返回空串。
func _sha256_of(p_path: String) -> String:
	var reader: FileAccess = FileAccess.open(p_path, FileAccess.READ)
	if reader == null:
		return ""
	var hasher := HashingContext.new()
	if hasher.start(HashingContext.HASH_SHA256) != OK:
		reader.close()
		return ""
	while not reader.eof_reached():
		var block: PackedByteArray = reader.get_buffer(DIGEST_READ_SIZE)
		if block.is_empty():
			break
		hasher.update(block)
	reader.close()
	var digest: PackedByteArray = hasher.finish()
	var text: String = ""
	for byte_value: int in digest:
		text += HEX_BYTE_FORMAT % byte_value
	return text


## 组装某归档的下载源（顺序：镜像优先，失败换上游）。
func _sources_of(p_kind: String, p_asset: Dictionary, p_templates: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var file_name: String = str(p_asset.get(KEY_FILE, ""))
	var asset_path: String = str(p_asset.get(KEY_PATH, ""))
	if p_kind == "scons":
		for key: String in [URL_PYPI_MIRROR, URL_PYPI_UPSTREAM]:
			_append_source(result, _manifest.build_url(str(p_templates.get(key, "")),
					file_name, asset_path))
		return result
	for key: String in [URL_PBS_MIRROR, URL_PBS_UPSTREAM]:
		_append_source(result, _manifest.build_url(str(p_templates.get(key, "")),
				file_name, asset_path))
	return result


## 把 URL 拆成 host/path 并登记为下载源。
func _append_source(p_list: Array[Dictionary], p_url: String) -> void:
	if p_url.is_empty() or not p_url.contains("://"):
		return
	var rest: String = p_url.split("://", false)[1]
	var slash_index: int = rest.find("/")
	if slash_index <= 0:
		return
	p_list.append({
		"host": rest.substr(0, slash_index),
		"port": 443,
		"tls": true,
		"path": rest.substr(slash_index),
	})


## 生成字节级进度回调，折算成 0..1 后转给上层。
func _make_progress(p_label: String) -> Callable:
	return func(p_done_bytes: int, p_total_bytes: int) -> void:
		if p_total_bytes <= 0:
			_notify("%s：已下载 %.1f MB" % [p_label, p_done_bytes / 1048576.0], -1.0)
			return
		_notify("%s：%.0f%%（%.1f / %.1f MB）" % [p_label,
				100.0 * float(p_done_bytes) / float(p_total_bytes),
				p_done_bytes / 1048576.0, p_total_bytes / 1048576.0],
				float(p_done_bytes) / float(p_total_bytes))


## 生成下载阶段回调：连接与失败信息也走同一进度通道，避免界面长时间无输出。
func _make_stage(p_label: String) -> Callable:
	return func(p_text: String) -> void:
		_notify("%s：%s" % [p_label, p_text], -1.0)


func _notify(p_text: String, p_ratio: float) -> void:
	if _progress.is_valid():
		_progress.call(p_text, p_ratio)


## 平台清单参数 → 待装配平台序列。
func _platforms_of(p_platform: String) -> PackedStringArray:
	if p_platform == "all" or p_platform.is_empty():
		return PackedStringArray(["windows", "linux", "macos"])
	if p_platform == "windows" or p_platform == "linux" or p_platform == "macos":
		return PackedStringArray([p_platform])
	return PackedStringArray()


## 目标根：默认 user://python（可写目录）。
func _resolve_root(p_override: String) -> String:
	if not p_override.is_empty():
		return p_override
	return ProjectSettings.globalize_path(PYTHON_RUNTIME_ROOT)


## 解压暂存目录（按平台与序号区分，避免并发覆盖）。
func _stage_dir(p_kind: String, p_index: int) -> String:
	return _cache_dir.path_join("stage_%s_%d" % [p_kind, p_index])


## 用暂存目录整体替换目标目录。[br][br]
## rename 在同卷是原子移动、跨卷会失败，故失败时退化为复制。
func _replace_dir(p_stage: String, p_target: String) -> void:
	_remove_tree(p_target)
	DirAccess.make_dir_recursive_absolute(p_target.get_base_dir())
	if DirAccess.rename_absolute(p_stage, p_target) == OK:
		return
	DirAccess.make_dir_recursive_absolute(p_target)
	_copy_tree(p_stage, p_target)


## 并入第二架构运行时：只取解释器与平台专属扩展，改名为带架构后缀的独立文件，
## 不覆盖主架构的任何内容（lipo 只能在 macOS 做，非 macOS 主机留待 CI 合并）。
func _merge_secondary_runtime(p_stage: String, p_target: String, p_asset_key: String) -> void:
	var arch_tag: String = "x86_64" if p_asset_key.ends_with("x86_64") else "arm64"
	var stage_bin: String = p_stage.path_join("bin")
	var target_bin: String = p_target.path_join("bin")
	DirAccess.make_dir_recursive_absolute(target_bin)
	var interpreter: String = stage_bin.path_join("python3")
	if FileAccess.file_exists(interpreter):
		DirAccess.copy_absolute(interpreter,
				target_bin.path_join("python3." + arch_tag))
	var stage_dynload: String = p_stage.path_join("lib").path_join("python3.14").path_join("lib-dynload")
	var target_dynload: String = p_target.path_join("lib").path_join("python3.14").path_join("lib-dynload")
	_copy_only_missing(stage_dynload, target_dynload)


## 复制源目录中目标目录缺失的文件（不覆盖已有内容）。
func _copy_only_missing(p_from: String, p_to: String) -> void:
	var dir: DirAccess = DirAccess.open(p_from)
	if dir == null:
		return
	DirAccess.make_dir_recursive_absolute(p_to)
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var dst: String = p_to.path_join(entry)
			if not FileAccess.file_exists(dst) and not DirAccess.dir_exists_absolute(dst):
				DirAccess.copy_absolute(p_from.path_join(entry), dst)
		entry = dir.get_next()
	dir.list_dir_end()


## 递归复制目录内容（存在即覆盖）。
func _copy_tree(p_from: String, p_to: String) -> void:
	var dir: DirAccess = DirAccess.open(p_from)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var src: String = p_from.path_join(entry)
			var dst: String = p_to.path_join(entry)
			if dir.current_is_dir():
				DirAccess.make_dir_recursive_absolute(dst)
				_copy_tree(src, dst)
			else:
				DirAccess.copy_absolute(src, dst)
		entry = dir.get_next()
	dir.list_dir_end()


## 删除目录树。
func _remove_tree(p_path: String) -> void:
	var dir: DirAccess = DirAccess.open(p_path)
	if dir == null:
		DirAccess.remove_absolute(p_path)
		return
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var full: String = p_path.path_join(entry)
			if dir.current_is_dir():
				_remove_tree(full)
			else:
				dir.remove(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(p_path)


## 目录总字节数。
func _dir_bytes(p_path: String) -> int:
	var dir: DirAccess = DirAccess.open(p_path)
	if dir == null:
		return 0
	var total: int = 0
	dir.list_dir_begin()
	var entry: String = dir.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var full: String = p_path.path_join(entry)
			total += _dir_bytes(full) if dir.current_is_dir() else _file_bytes(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return total


func _file_bytes(p_path: String) -> int:
	if not FileAccess.file_exists(p_path):
		return 0
	var file: FileAccess = FileAccess.open(p_path, FileAccess.READ)
	if file == null:
		return 0
	var size: int = file.get_length()
	file.close()
	return size


func _read_line(p_path: String) -> String:
	var file: FileAccess = FileAccess.open(p_path, FileAccess.READ)
	if file == null:
		return ""
	var line: String = file.get_line().strip_edges()
	file.close()
	return line


func _write_line(p_path: String, p_text: String) -> void:
	var file: FileAccess = FileAccess.open(p_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_line(p_text)
	file.close()


## 失败原因合并成一行。
func _join_lines(p_items: Array) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for item: Variant in p_items:
		parts.append(str(item))
	return " | ".join(parts) if parts.size() <= 3 else "%s（共 %d 项）" % [" | ".join(parts.slice(0, 3)), parts.size()]
