class_name ZipExtractor
extends RefCounted
## ZIP 解压器：用引擎 ZIPReader（minizip 后端）列目录并读出成员内容，逐成员写入目标目录。
##
## 依赖引擎构建时开启 minizip（本工具自身即 build/profile.py 的 minizip=yes）。
## ZIPReader 只能整成员读出，故内存占用以「单个最大成员」为上限，不做整包驻留。


## 结果键
const KEY_OK: String = "ok"
const KEY_ERROR: String = "error"
const KEY_FILES: String = "files"
const KEY_BYTES: String = "bytes"
const KEY_SKIPPED: String = "skipped"
## 路径分隔符
const PATH_SEPARATOR: String = "/"
## 反斜杠替换目标（zip 规范用正斜杠，Windows 打包器偶尔写反斜杠）
const BACKSLASH: String = "\\"


## 解压 ZIP 到目标目录。[br][br]
## [param p_archive] 归档绝对路径。[br]
## [param p_target_root] 目标根目录（绝对，不存在会创建）。[br]
## [param p_select] 只解这些成员名（空表示全部）。[br]
## [param p_keep] 逐成员保留判定 f(相对路径) -> bool；无效应值时全部保留。[br]
## [return] 含键：ok(bool)、error(String)、files(int)、bytes(int)、skipped(int)
func extract(p_archive: String, p_target_root: String,
		p_select: PackedStringArray = PackedStringArray(),
		p_keep: Callable = Callable()) -> Dictionary:
	if not FileAccess.file_exists(p_archive):
		return _fail("归档不存在：%s" % p_archive)
	var reader: ZIPReader = ZIPReader.new()
	if reader.open(p_archive) != OK:
		return _fail("无法打开归档：%s（不是有效 ZIP 或未启用 minizip）" % p_archive)
	var dir_error: Error = DirAccess.make_dir_recursive_absolute(p_target_root)
	if dir_error != OK:
		reader.close()
		return _fail("无法创建目标目录：%s（%s）" % [p_target_root, error_string(dir_error)])
	var select_set: Dictionary[String, bool] = {}
	for name: String in p_select:
		select_set[name.replace(BACKSLASH, PATH_SEPARATOR)] = true
	var result: Dictionary = _write_members(reader, p_target_root, select_set,
			not p_select.is_empty(), p_keep)
	reader.close()
	return result


## 遍历成员并逐个落盘。
func _write_members(p_reader: ZIPReader, p_target_root: String,
		p_select_set: Dictionary[String, bool], p_is_selective: bool,
		p_keep: Callable) -> Dictionary:
	var written_files: int = 0
	var written_bytes: int = 0
	var skipped: int = 0
	for member: String in p_reader.get_files():
		var member_name: String = member.replace(BACKSLASH, PATH_SEPARATOR)
		if member_name.is_empty() or not _is_safe_member(member_name):
			skipped += 1
			continue
		if p_is_selective and not p_select_set.has(member_name):
			skipped += 1
			continue
		if member_name.ends_with(PATH_SEPARATOR):
			DirAccess.make_dir_recursive_absolute(p_target_root.path_join(member_name))
			continue
		if p_keep.is_valid() and not bool(p_keep.call(member_name)):
			skipped += 1
			continue
		# 读取必须用归档内的原始成员名，写入才用归一化后的路径
		var content: PackedByteArray = p_reader.read_file(member)
		var destination: String = p_target_root.path_join(member_name)
		DirAccess.make_dir_recursive_absolute(destination.get_base_dir())
		var writer: FileAccess = FileAccess.open(destination, FileAccess.WRITE)
		if writer == null:
			return _fail("写入失败：%s（%s）" % [
					member_name, error_string(FileAccess.get_open_error())])
		if not content.is_empty():
			writer.store_buffer(content)
		writer.close()
		written_files += 1
		written_bytes += content.size()
	return {KEY_OK: true, KEY_ERROR: "", KEY_FILES: written_files,
			KEY_BYTES: written_bytes, KEY_SKIPPED: skipped}


## 成员路径安全性（防目录穿越与绝对路径）。
func _is_safe_member(p_name: String) -> bool:
	if p_name.is_empty() or p_name.begins_with(PATH_SEPARATOR) or p_name.is_absolute_path():
		return false
	if p_name.contains(":"):
		return false
	for segment: String in p_name.split(PATH_SEPARATOR, false):
		if segment == "..":
			return false
	return true


## 构造失败结果。
func _fail(p_reason: String) -> Dictionary:
	return {KEY_OK: false, KEY_ERROR: p_reason, KEY_FILES: 0, KEY_BYTES: 0, KEY_SKIPPED: 0}
