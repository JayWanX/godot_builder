class_name TarGzExtractor
extends RefCounted
## 流式 tar.gz 解压器：边解边按清单过滤并直写磁盘，不整包驻留内存、不阻塞主线程。
##
## 不用系统 tar：Windows 仅 10 以后自带、长选项支持不一，跨平台不可靠。
## 不用 ZIPReader：归档是 tar.gz，且导出模板已禁用 ZIP 模块。
##
## 链接处理是这里最容易写错的一段。实测归档里符号链接条目**排在它的目标实体之前**
## （bin/python3 第 8 条、其目标 bin/python3.14 第 10 条），且约三成链接指向归档内
## 不存在的路径。故链接一律先记账、目标实体落盘后再处理；目标被裁剪规则排除时，
## 由清单 deref_links 指定「用实体内容充当链接名」，否则会解出指向空文件的坏链接
## （Linux 解释器 bin/python3 -> python3.14 正是这种形态）。
## 建文件系统链接需要 Windows 开发者模式，不可假定用户开启，故失败即退化为复制。

## tar 头块大小（字节）
const BLOCK_SIZE: int = 512
## 条目名字段偏移与长度
const NAME_OFFSET: int = 0
const NAME_LENGTH: int = 100
## 权限字段偏移与长度
const MODE_OFFSET: int = 100
const MODE_LENGTH: int = 8
## 内容大小字段偏移与长度（八进制文本或基 256）
const SIZE_OFFSET: int = 124
const SIZE_LENGTH: int = 12
## 条目类型标记偏移
const TYPEFLAG_OFFSET: int = 156
## 链接目标字段偏移与长度
const LINKNAME_OFFSET: int = 157
const LINKNAME_LENGTH: int = 100
## ustar 路径前缀字段偏移与长度
const PREFIX_OFFSET: int = 345
const PREFIX_LENGTH: int = 155
## GNU 长名/长链接名条目：内容即下一条目的对应字段
const TYPE_LONG_NAME: String = "L"
const TYPE_LONG_LINK: String = "K"
## pax 扩展头（逐条 / 全局）
const TYPE_PAX_NEXT: String = "x"
const TYPE_PAX_GLOBAL: String = "g"
## 普通文件（含 v7 的空标记）与连续文件
const FILE_TYPES: Array[String] = ["0", "", "7"]
## 目录 / 符号链接 / 硬链接
const TYPE_DIRECTORY: String = "5"
const TYPE_SYMLINK: String = "2"
const TYPE_HARDLINK: String = "1"
## 数字字段首字节置位表示基 256 编码
const BASE_256_FLAG: int = 128
## 基 256 字段去掉标志位后首字节必须为 0
const BASE_256_PAYLOAD_MASK: int = 127
## 八进制数字起止码点
const OCTAL_ZERO: int = 48
const OCTAL_MAX: int = 55
## 权限位掩码（0o777；GDScript 无八进制字面量，写成 0755 会按十进制解析）
const MODE_MASK: int = 511
## 头里没有权限字段时用的默认权限（0o755）
const DEFAULT_MODE: int = 493
## 每次喂给 gzip 的压缩字节数
const GZIP_FEED_SIZE: int = 65536
## 写盘分块大小
const WRITE_CHUNK_SIZE: int = 262144
## 每处理这么多条目让出一帧并回报进度
const YIELD_INTERVAL: int = 64
## 结果字典键
const KEY_OK: String = "ok"
const KEY_REASON: String = "reason"
const KEY_FILE_COUNT: String = "file_count"
const KEY_LINK_COUNT: String = "link_count"
const KEY_SKIPPED: String = "skipped_count"
const KEY_FAILURES: String = "failures"
const KEY_WARNINGS: String = "warnings"
## 相对路径分隔符
const PATH_SEPARATOR: String = "/"
## 条目类型标记占位（typeflag 字段长度为 1）
const TYPEFLAG_FIELD_LENGTH: int = 1

## 待延后处理的链接：{ 目标相对路径: Array }，元素含键 link/symlink/mode
var _deferred: Dictionary[String, Array] = {}
## 清单解引用表：{ 实体相对路径: 链接相对路径 }
var _deref: Dictionary[String, String] = {}
## 已落盘条目集合（判定链接能否解析）
var _written: Dictionary[String, bool] = {}
## 是否需要在落盘后恢复 Unix 权限位（仅 Unix 宿主为 true）
var _can_set_permissions: bool = false
## 权限设置失败计数（汇总为一条告警，不逐文件刷屏）
var _permission_failures: int = 0
## 覆盖下一条目字段的长名
var _long_name: String = ""
var _long_link: String = ""
## 计数
var _file_count: int = 0
var _link_count: int = 0
var _skipped_count: int = 0
var _failures: PackedStringArray = PackedStringArray()
var _warnings: PackedStringArray = PackedStringArray()
## 保留规则上下文
var _platform: String = ""
var _is_site_packages: bool = false
var _manifest: PythonRuntimeManifest = null
var _target_root: String = ""


## 解压 tar.gz 并按清单过滤落盘。[br][br]
## [param p_archive] 归档绝对路径。[param p_target_root] 目标根目录（绝对；会被清空重建）。[br]
## [param p_platform] windows / linux / macos。[param p_is_site_packages] true 时按站点包规则过滤。[br]
## [param p_progress] 进度回调 f(比例 0..1)。[br]
## [return] 含键：ok(bool)、reason(String)、file_count(int)、link_count(int)、skipped_count(int)、failures(String[])、warnings(String[])
func extract(p_archive: String, p_target_root: String, p_manifest: PythonRuntimeManifest,
		p_platform: String, p_is_site_packages: bool = false,
		p_progress: Callable = Callable()) -> Dictionary:
	_manifest = p_manifest
	_platform = p_platform
	_is_site_packages = p_is_site_packages
	_target_root = p_target_root
	_can_set_permissions = OS.get_name() != "Windows"
	_permission_failures = 0
	_manifest.warm_caches()
	_deferred = {}
	_written = {}
	_deref = {} if p_is_site_packages else p_manifest.get_deref_map(p_platform)
	_long_name = ""
	_long_link = ""
	_file_count = 0
	_link_count = 0
	_skipped_count = 0
	_failures = PackedStringArray()
	_warnings = PackedStringArray()
	if not FileAccess.file_exists(p_archive):
		return _outcome("归档不存在：%s" % p_archive)
	var root_error: Error = DirAccess.make_dir_recursive_absolute(p_target_root)
	if root_error != OK:
		return _outcome("无法创建目标目录：%s（%s）" % [p_target_root, error_string(root_error)])
	var reader: FileAccess = FileAccess.open(p_archive, FileAccess.READ)
	if reader == null:
		return _outcome("无法打开归档：%s（%s）" % [p_archive, error_string(FileAccess.get_open_error())])
	var total_size: int = reader.get_length()
	var gzip: StreamPeerGZIP = StreamPeerGZIP.new()
	if gzip.start_decompression(false) != OK:
		reader.close()
		return _outcome("gzip 解压初始化失败")
	var stream: StreamState = StreamState.new()
	stream.reader = reader
	stream.gzip = gzip
	var entry_index: int = 0
	var is_running: bool = true
	while is_running:
		var head: PackedByteArray = _read_exact(stream, BLOCK_SIZE)
		if head.size() < BLOCK_SIZE:
			break
		if _is_zero_block(head):
			break
		var entry: Dictionary = _parse_head(head)
		if entry.is_empty():
			_warnings.append("第 %d 块不是合法 tar 头（归档可能损坏）" % entry_index)
			break
		entry_index += 1
		is_running = _handle_entry(stream, entry)
		if entry_index % YIELD_INTERVAL != 0:
			continue
		if p_progress.is_valid() and total_size > 0:
			p_progress.call(float(reader.get_position()) / float(total_size))
		await Engine.get_main_loop().process_frame
	reader.close()
	gzip.clear()
	_resolve_deferred()
	return _outcome("")


## 处理一条已解析的 tar 条目。[br][br]
## [return] false 表示应停止读取归档
func _handle_entry(p_stream: StreamState, p_entry: Dictionary) -> bool:
	var kind: String = str(p_entry.get("type", ""))
	var size: int = int(p_entry.get("size", 0))
	if kind == TYPE_LONG_NAME or kind == TYPE_LONG_LINK:
		var payload: String = _read_text(p_stream, size)
		if kind == TYPE_LONG_NAME:
			_long_name = payload
		else:
			_long_link = payload
		return not p_stream.is_exhausted
	if kind == TYPE_PAX_NEXT or kind == TYPE_PAX_GLOBAL:
		_skip(p_stream, size)
		return not p_stream.is_exhausted
	var name: String = str(p_entry.get("name", ""))
	var raw_link: String = str(p_entry.get("link_name", ""))
	if not _long_name.is_empty():
		name = _long_name
		_long_name = ""
	if not _long_link.is_empty():
		raw_link = _long_link
		_long_link = ""
	var rel: String = _relative_path(name)
	if rel.is_empty():
		_skip(p_stream, size)
		_skipped_count += 1
		return not p_stream.is_exhausted
	if kind == TYPE_DIRECTORY:
		DirAccess.make_dir_recursive_absolute(_target_root.path_join(rel))
		_skip(p_stream, size)
		return not p_stream.is_exhausted
	if kind == TYPE_SYMLINK or kind == TYPE_HARDLINK:
		_record_link(rel, _manifest_relative(_resolve_target(name, raw_link,
				kind == TYPE_SYMLINK)), kind == TYPE_SYMLINK, int(p_entry.get("mode", 0)))
		_skip(p_stream, size)
		return not p_stream.is_exhausted
	if not FILE_TYPES.has(kind):
		_skipped_count += 1
		_skip(p_stream, size)
		return not p_stream.is_exhausted
	_write_file_entry(rel, p_stream, size, int(p_entry.get("mode", 0)))
	return not p_stream.is_exhausted


## 写一个文件条目：自身保留即落盘；自身被裁但清单指定它充当某链接名的内容时，
## 只把内容写到该链接名（避免把 31 MB 实体白写一遍）。
func _write_file_entry(p_rel: String, p_stream: StreamState, p_size: int, p_mode: int) -> void:
	var is_kept: bool = _is_kept(p_rel)
	var deref_name: String = _deref.get(p_rel, "")
	var serves_deref: bool = not deref_name.is_empty() and _is_kept(deref_name)
	if not is_kept and not serves_deref:
		_skipped_count += 1
		_skip(p_stream, p_size)
		return
	var destination: String = p_rel if is_kept else deref_name
	if _write_stream(p_stream, p_size, destination, p_mode):
		_written[destination] = true
		_file_count += 1
		if not is_kept:
			# 实体内容已充当链接名落盘，撤掉该实体名下的延后链接，
			# 否则收尾会因「目标未落盘」报出误导告警
			_settle_deferred_link(p_rel, deref_name)


## 撤销已由各引用落盘的延后链接条目。
func _settle_deferred_link(p_entity_rel: String, p_link_rel: String) -> void:
	var pending: Array = _deferred.get(p_entity_rel, [])
	var remaining: Array = []
	for item: Dictionary in pending:
		if str(item.get("link", "")) != p_link_rel:
			remaining.append(item)
	if remaining.is_empty():
		_deferred.erase(p_entity_rel)
	else:
		_deferred[p_entity_rel] = remaining


## 把条目内容分块直写目标文件。
func _write_stream(p_stream: StreamState, p_size: int, p_rel: String, p_mode: int) -> bool:
	var absolute: String = _target_root.path_join(p_rel)
	DirAccess.make_dir_recursive_absolute(absolute.get_base_dir())
	var file: FileAccess = FileAccess.open(absolute, FileAccess.WRITE)
	if file == null:
		_failures.append("写入失败：%s（%s）" % [p_rel, error_string(FileAccess.get_open_error())])
		_skip(p_stream, p_size)
		return false
	var remaining: int = p_size
	while remaining > 0:
		var block: PackedByteArray = _read_exact(p_stream, mini(remaining, WRITE_CHUNK_SIZE))
		if block.is_empty():
			file.close()
			_failures.append("归档内容提前结束：%s" % p_rel)
			return false
		file.store_buffer(block)
		remaining -= block.size()
	file.close()
	# 权限位只对「在 Unix 宿主上解出的 Unix 运行时」有意义；Windows 宿主无法设置，
	# 且此处判定对象必须是宿主而非目标平台（在 Windows 上装配 linux 运行时时目标
	# 平台是 linux，但设权限必然失败，按目标平台判定会产生数百条无效告警）。
	if _can_set_permissions:
		var permissions: int = (p_mode & MODE_MASK) if p_mode != 0 else DEFAULT_MODE
		if FileAccess.set_unix_permissions(absolute, permissions) != OK:
			_permission_failures += 1
	_skip_padding(p_stream, p_size)
	return true


## 记账一条链接：目标实体稍后落盘时再建链或复制。
func _record_link(p_rel: String, p_target_rel: String, p_is_symlink: bool, p_mode: int) -> void:
	if not _is_kept(p_rel):
		_skipped_count += 1
		return
	if p_target_rel.is_empty():
		_skipped_count += 1
		_warnings.append("链接目标越出归档范围，已丢弃：%s" % p_rel)
		return
	var pending: Array = _deferred.get(p_target_rel, [])
	pending.append({"link": p_rel, "symlink": p_is_symlink, "mode": p_mode})
	_deferred[p_target_rel] = pending
	_skipped_count += 1


## 归档读取结束后处理延后链接。
func _resolve_deferred() -> void:
	for target_rel: String in _deferred:
		var source_absolute: String = _target_root.path_join(target_rel)
		var is_present: bool = FileAccess.file_exists(source_absolute)
		for item: Dictionary in _deferred[target_rel] as Array:
			var link_rel: String = str(item.get("link", ""))
			var link_absolute: String = _target_root.path_join(link_rel)
			DirAccess.make_dir_recursive_absolute(link_absolute.get_base_dir())
			if not is_present:
				_warnings.append("链接目标未落盘（被裁剪或不在归档内）：%s -> %s" % [link_rel, target_rel])
				continue
			if _make_link(source_absolute, link_absolute, target_rel, link_rel,
					bool(item.get("symlink", false))):
				_link_count += 1
				_written[link_rel] = true
			else:
				_failures.append("链接与复制均失败：%s" % link_rel)


## 先试文件系统链接，失败退化为复制。[br][br]
## 符号链接按归档原样写相对目标（保持可迁移），硬链接必须给绝对路径。
func _make_link(p_source_absolute: String, p_link_absolute: String, p_source_rel: String,
		p_link_rel: String, p_is_symlink: bool) -> bool:
	var dir: DirAccess = DirAccess.open(p_link_absolute.get_base_dir())
	if dir != null:
		var link_target: String = p_source_rel if p_is_symlink else p_source_absolute
		if dir.create_link(link_target, p_link_absolute) == OK:
			return true
	var copy_error: Error = DirAccess.copy_absolute(p_source_absolute, p_link_absolute)
	if copy_error == OK:
		_warnings.append("改用复制代替%s链接：%s" % ["符号" if p_is_symlink else "硬", p_link_rel])
		return true
	return false


## 解析 tar 头块。[br][br]
## [return] 含键：name(String)、type(String)、size(int)、link_name(String)、mode(int)；非法头返回空字典
func _parse_head(p_head: PackedByteArray) -> Dictionary:
	var name: String = _text_field(p_head, NAME_OFFSET, NAME_LENGTH)
	var prefix: String = _text_field(p_head, PREFIX_OFFSET, PREFIX_LENGTH)
	var full_name: String = name if prefix.is_empty() else prefix.path_join(name)
	if full_name.is_empty():
		return {}
	return {
		"name": full_name,
		"type": _text_field(p_head, TYPEFLAG_OFFSET, TYPEFLAG_FIELD_LENGTH),
		"size": _numeric_field(p_head, SIZE_OFFSET, SIZE_LENGTH),
		"link_name": _text_field(p_head, LINKNAME_OFFSET, LINKNAME_LENGTH),
		"mode": _numeric_field(p_head, MODE_OFFSET, MODE_LENGTH),
	}


## 读定长文本字段并去掉尾部空字节与空白。
func _text_field(p_block: PackedByteArray, p_offset: int, p_length: int) -> String:
	if p_offset + p_length > p_block.size():
		return ""
	return p_block.slice(p_offset, p_offset + p_length).get_string_from_utf8().strip_edges()


## 解析 tar 数字字段。八进制文本逐位自算（GDScript 无八进制转整数内建函数）；
## 首字节置位走基 256；空字段按 0。
func _numeric_field(p_block: PackedByteArray, p_offset: int, p_length: int) -> int:
	if p_offset + p_length > p_block.size():
		return 0
	if int(p_block[p_offset]) & BASE_256_FLAG != 0:
		return _base_256_value(p_block, p_offset, p_length)
	var text: String = _text_field(p_block, p_offset, p_length)
	if text.is_empty():
		return 0
	var result: int = 0
	for character: String in text:
		var digit: int = character.unicode_at(0) - OCTAL_ZERO
		if digit < 0 or digit > OCTAL_MAX:
			return 0
		result = result * 8 + digit
	return result


## 解析基 256 编码字段（大端；去掉标志位后首字节须为 0，否则超出可用范围）。
func _base_256_value(p_block: PackedByteArray, p_offset: int, p_length: int) -> int:
	if int(p_block[p_offset]) & BASE_256_PAYLOAD_MASK != 0:
		return 0
	var result: int = 0
	for index: int in range(1, p_length):
		result = (result << 8) | int(p_block[p_offset + index])
	return result


## 归档条目名 → 剥离顶层目录后的相对路径；越界或非 POSIX 风格返回空串。
func _relative_path(p_name: String) -> String:
	if p_name.is_empty():
		return ""
	var normalized: String = p_name.replace("\\", PATH_SEPARATOR)
	if normalized.contains(":") or normalized.is_absolute_path():
		return ""
	var segments: PackedStringArray = normalized.split(PATH_SEPARATOR, false)
	if segments.size() <= 1:
		return ""
	for segment: String in segments:
		if segment == "..":
			return ""
	var parts: PackedStringArray = segments.slice(
			PythonRuntimeManifest.ARCHIVE_STRIP_LEVEL, segments.size())
	return PATH_SEPARATOR.join(parts)


## 归档内路径（含顶层目录）→ 清单相对路径。硬链接的 linkname 存的是这种全路径。
func _manifest_relative(p_member_path: String) -> String:
	return _relative_path(p_member_path)


## 按条目名与链接字段算出目标的归档内路径。
func _resolve_target(p_entry_name: String, p_link_name: String, p_is_symlink: bool) -> String:
	if p_link_name.is_empty():
		return ""
	if p_link_name.begins_with("/") or p_link_name.contains(":"):
		# 绝对链接目标不在归档命名空间内
		return p_link_name
	if not p_is_symlink:
		# 硬链接的 linkname 是归档内完整路径，不做相对化
		return p_link_name
	var base_dir: String = p_entry_name.get_base_dir()
	return base_dir.path_join(p_link_name)


## 保留判定：运行时条目或站点包条目按上下文二选一。
func _is_kept(p_rel: String) -> bool:
	if _is_site_packages:
		return _manifest.is_site_package_kept(p_rel)
	return _manifest.is_runtime_file_kept(p_rel, _platform)


## 跳过条目内容（连同填充）。
func _skip(p_stream: StreamState, p_size: int) -> void:
	_read_exact(p_stream, p_size)
	_skip_padding(p_stream, p_size)


## 只跳填充字节（内容已被读完时使用）。
func _skip_padding(p_stream: StreamState, p_size: int) -> void:
	var padding: int = (BLOCK_SIZE - p_size % BLOCK_SIZE) % BLOCK_SIZE
	if padding > 0:
		_read_exact(p_stream, padding)


## 读取指定字节数并作为文本返回。
func _read_text(p_stream: StreamState, p_size: int) -> String:
	return _read_exact(p_stream, p_size).get_string_from_utf8().strip_edges()


## 读满指定字节数；不足时返回实际读到的部分。
func _read_exact(p_stream: StreamState, p_count: int) -> PackedByteArray:
	var result: PackedByteArray = PackedByteArray()
	while result.size() < p_count:
		if p_stream.pending.is_empty():
			if not _pump(p_stream):
				break
		var take: int = mini(p_count - result.size(), p_stream.pending.size())
		result.append_array(p_stream.pending.slice(0, take))
		p_stream.pending = p_stream.pending.slice(take)
	return result


## 从 gzip 流取一批解压数据。[br][br]
## 必须「先排空输出、再喂输入」交替进行：gzip 输出环满时 put_partial_data 会停止消费
## 输入，未喂完的字节必须留下一次，否则归档会缺尾（实测报「tar 头无法解析」）。
func _pump(p_stream: StreamState) -> bool:
	if _drain(p_stream):
		return true
	while not p_stream.is_exhausted:
		if p_stream.compressed.is_empty():
			p_stream.compressed = p_stream.reader.get_buffer(GZIP_FEED_SIZE)
			if p_stream.compressed.is_empty():
				p_stream.is_exhausted = true
				return false
		var put_result: Array = p_stream.gzip.put_partial_data(p_stream.compressed)
		if int(put_result[0]) != OK:
			p_stream.is_exhausted = true
			return false
		var sent: int = int(put_result[1])
		p_stream.compressed = p_stream.compressed.slice(sent)
		if sent <= 0:
			continue
		if _drain(p_stream):
			return true
		if p_stream.reader.eof_reached() and p_stream.compressed.is_empty():
			p_stream.is_exhausted = true
			return false
	return false


## 取走 gzip 输出环里已有的解压数据。
func _drain(p_stream: StreamState) -> bool:
	var available: int = p_stream.gzip.get_available_bytes()
	if available <= 0:
		return false
	var output: PackedByteArray = p_stream.gzip.get_partial_data(available)[1]
	if output.is_empty():
		return false
	p_stream.pending = output
	return true


## 该块是否全零（归档结束标记）。
func _is_zero_block(p_block: PackedByteArray) -> bool:
	for byte_value: int in p_block:
		if byte_value != 0:
			return false
	return true


## 汇总结果。
func _outcome(p_reason: String) -> Dictionary:
	if _permission_failures > 0:
		_warnings.append("有 %d 个文件未能恢复 Unix 权限位（通常只在跨平台装配时出现）"
				% _permission_failures)
	return {
		KEY_OK: p_reason.is_empty() and _failures.is_empty(),
		KEY_REASON: p_reason,
		KEY_FILE_COUNT: _file_count,
		KEY_LINK_COUNT: _link_count,
		KEY_SKIPPED: _skipped_count,
		KEY_FAILURES: _failures,
		KEY_WARNINGS: _warnings,
	}


## 流式读取状态（跨调用保持游标与缓冲）。
class StreamState extends RefCounted:
	## 归档文件
	var reader: FileAccess = null
	## 已起解压的 gzip 流
	var gzip: StreamPeerGZIP = null
	## 已解压但尚未消费的字节
	var pending: PackedByteArray = PackedByteArray()
	## 已读出但尚未喂进 gzip 的压缩字节
	var compressed: PackedByteArray = PackedByteArray()
	## 归档是否已读到尽头
	var is_exhausted: bool = false
