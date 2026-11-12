class_name InstallSpecParser
extends RefCounted
## 引擎安装脚本解析器：从 misc/scripts/install_*.py 源码提取下载规格。
##
## 上游脚本是唯一事实源：版本号、arch 名单、Release 仓库名一律提取，绝不硬编码。
## 任一必需项解析不到即整体报错中止——宁可拒绝安装，也不装出半套错误依赖。
## 变体追加口径与上游一致（按宿主 platform.system 而非目标平台），
## 保证本安装器与官方脚本装出来的依赖目录可互相替换。

const SCRIPT_ANGLE: String = "install_angle.py"
const SCRIPT_D3D12: String = "install_d3d12_sdk_windows.py"
const SCRIPT_ACCESSKIT: String = "install_accesskit.py"
const SCRIPT_WINRT: String = "install_winrt.py"
const SCRIPT_PERFETTO: String = "install_perfetto.py"
const SCRIPT_SWAPPY: String = "install_swappy_android.py"
const SCRIPTS_REL_DIR: String = "misc/scripts"

## Perfetto latest tag 接口（上游每次现取，这里同样不写死版本）
const PERFETTO_LATEST_API_HOST: String = "api.github.com"
const PERFETTO_LATEST_API_PATH: String = "/repos/google/perfetto/releases/latest"

## 顶层字面量赋值行（排除比较行与列表行）
const LIST_ITEM_PATTERN: String = r'"([^"]*)"'
## 列表定义：变量赋值形式与 for 内联形式都支持，组 1 为变量名
const LIST_DEF_PATTERN: String = r'(?:([a-z_][a-z0-9_]*)\s*=\s*\[|for\s+([a-z_][a-z0-9_]*)\s+in\s*\[)'
## 拼接式右侧的引号段与标识符段
const TOKEN_PATTERN: String = r'"([^"]*)"|([a-z_][a-z0-9_]*)'
## 上游 Release URL 的原文形态（组 1 owner、组 2 repo、组 3 tag 段）。
## 上游把 URL 内联在 urlretrieve 的 f-string 里，不存在赋值形式，只能扫原文。
const RELEASE_URL_PATTERN: String = r"https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)"
## URL 段里的 f-string 占位符（组 1 为变量名）
const URL_VAR_PATTERN: String = r"\{([a-z_][a-z0-9_]*)\}"
## 正则缓存
static var _regex_cache: Dictionary[String, RegEx] = {}

## 规格字典键
const KEY_ID: String = "id"
const KEY_BASE: String = "base"
const KEY_TAG: String = "tag"
const KEY_FILES: String = "files"
const KEY_CLEAN: String = "clean"
const KEY_RENAME_FROM: String = "rename_from"
const KEY_RENAME_TO: String = "rename_to"
const KEY_NEEDS_MINGW: String = "needs_mingw"
const KEY_SPEC: String = "spec"
## 文件项键
const KEY_NAME: String = "name"
const KEY_HOST: String = "host"
const KEY_PATH: String = "path"
const KEY_INTO: String = "into"
const KEY_SELECT: String = "select"
## 结果键
const KEY_OK: String = "ok"
const KEY_ERROR: String = "error"
const KEY_SPECS: String = "specs"
const KEY_DEPS_DIR: String = "deps_dir"
## 仓库名解析结果的键
const PARSED_REPO: String = "repo"

## 落地根：依赖目录或引擎 thirdparty
const BASE_DEPS: String = "deps"
const BASE_ENGINE: String = "engine"

## GitHub 主机与 Release 路径格式（tag 一律经 _release_path 转义）
const GITHUB_HOST: String = "github.com"
const RELEASE_PATH_FORMAT: String = "/%s/releases/download/%s/%s"
const TAG_SLASH: String = "/"
const TAG_SLASH_ESCAPED: String = "%2F"
## nuget 主机与包地址（Pix/Agility 上游写死 nuget 模板，非版本资产）
const NUGET_HOST: String = "www.nuget.org"
const NUGET_PACKAGE_PATH_FORMAT: String = "/api/v2/package/%s/%s"
const NUGET_PIX: String = "WinPixEventRuntime"
const NUGET_AGILITY: String = "Microsoft.Direct3D.D3D12"

## 上游脚本里各版本的常量名（解析键，不是值）
const VAR_ANGLE_VERSION: String = "angle_version"
const VAR_MESA_VERSION: String = "mesa_version"
const VAR_PIX_VERSION: String = "pix_version"
const VAR_AGILITY_VERSION: String = "agility_sdk_version"
const VAR_AC_VERSION: String = "ac_version"
const VAR_AC_FILENAME: String = "ac_filename"
const VAR_WINRT_VERSION: String = "winrt_version"
const VAR_WINRT_FILENAME: String = "winrt_filename"
const VAR_PERFETTO_URL: String = "perfetto_url"
const VAR_PERFETTO_FILENAME: String = "perfetto_filename"
const VAR_PERFETTO_FOLDER: String = "perfetto_folder"
const VAR_SWAPPY_TAG: String = "swappy_tag"
const VAR_SWAPPY_FILENAME: String = "swappy_filename"
const VAR_SWAPPY_FOLDER: String = "swappy_folder"
## arch 名单变量名（angle 是赋值式 archs，d3d12 是 for arch in 内联式）
const LIST_ANGLE_ARCHS: String = "archs"
const LIST_D3D12_ARCH: String = "arch"
const LIST_SWAPPY_ARCHS: String = "swappy_archs"

## 宿主平台追加的变体后缀（与上游 platform.system 分支一致）
const WINDOWS_HOST: String = "Windows"
const MACOS_HOST: String = "macOS"
const ARCH_WINDOWS_SUFFIXES: Array[String] = ["arm64-msvc", "x86_32-msvc", "x86_64-msvc"]
const ARCH_MACOS_SUFFIXES: Array[String] = [
	"arm64-ios", "arm64-ios-sim", "arm64-macos", "x86_64-macos"]

## 依赖落地目录：LOCALAPPDATA 存在且不在 MSYSTEM 内时优先用（与上游脚本一致）
const ENV_LOCALAPPDATA: String = "LOCALAPPDATA"
const ENV_MSYSTEM: String = "MSYSTEM"
const DEPS_SUBPATH: String = "Godot/build_deps"
const DEPS_FALLBACK: String = "bin/build_deps"
## Perfetto/Swappy 落地在引擎 thirdparty 下的前缀
const THIRDPARTY_PREFIX: String = "thirdparty/"

## 文件名模板（与上游 f-string 对齐）
const ANGLE_FILE_FORMAT: String = "godot-angle-static-%s-release.zip"
const ANGLE_DIR_FORMAT: String = "angle-%s"
const MESA_FILE_FORMAT: String = "godot-nir-static-%s-release.zip"
const MESA_DIR_FORMAT: String = "mesa-%s"
const PIX_FILE_FORMAT: String = "WinPixEventRuntime_%s.nupkg"
const PIX_DIR: String = "pix"
const AGILITY_FILE_FORMAT: String = "Agility_SDK_%s.nupkg"
const AGILITY_DIR: String = "agility_sdk"
const ACCESSKIT_DIR: String = "accesskit"
const WINRT_DIR: String = "winrt_mingw"
## Swappy 包内每个 ABI 只取这一个静态库
const SWAPPY_MEMBER_FORMAT: String = "%s/libswappy_static.a"


## 解析六个脚本并生成规格列表（同步，不发起网络；perfetto 的 tag 由调用方传入）。[br][br]
## [param p_engine_dir] 引擎源码根（绝对或 res://）。[param p_perfetto_tag] latest tag；空则跳过。[br]
## [param p_platform] 目标构建平台 windows|linux|macos|android，决定 d3d12/swappy 取舍。[br]
## [return] 含键：specs(Array)、deps_dir(String)、error(String)；error 非空表示解析失败
static func build_specs(p_engine_dir: String, p_perfetto_tag: String = "",
		p_platform: String = "") -> Dictionary:
	var engine_dir: String = ProjectSettings.globalize_path(p_engine_dir)
	var deps: String = resolve_deps_dir(engine_dir)
	var scripts: Dictionary[String, String] = {}
	for name: String in [SCRIPT_ANGLE, SCRIPT_D3D12, SCRIPT_ACCESSKIT,
			SCRIPT_WINRT, SCRIPT_PERFETTO, SCRIPT_SWAPPY]:
		var path: String = engine_dir.path_join(SCRIPTS_REL_DIR).path_join(name)
		if not FileAccess.file_exists(path):
			return {KEY_ERROR: "缺少上游安装脚本：%s" % path,
					KEY_SPECS: [], KEY_DEPS_DIR: deps}
		scripts[name] = FileAccess.get_file_as_string(path)
	var specs: Array = []
	for entry: Array in _spec_order(p_platform, p_perfetto_tag):
		var spec_name: String = str(entry[0])
		var result: Dictionary = _build_one_spec(spec_name, str(scripts[spec_name]),
				str(entry[1]))
		if not str(result.get(KEY_ERROR, "")).is_empty():
			return {KEY_ERROR: str(result[KEY_ERROR]), KEY_SPECS: [], KEY_DEPS_DIR: deps}
		specs.append(result[KEY_SPEC])
	return {KEY_ERROR: "", KEY_SPECS: specs, KEY_DEPS_DIR: deps}


## 依赖落地目录（复刻上游逻辑：有 LOCALAPPDATA 且非 MSYSTEM 时装进用户目录）。[br][br]
## [param p_engine_dir] 引擎根绝对路径（相对回退时以此为基）。[br]
## [return] 绝对路径
static func resolve_deps_dir(p_engine_dir: String) -> String:
	var local_appdata: String = OS.get_environment(ENV_LOCALAPPDATA)
	if local_appdata.is_empty() or not OS.get_environment(ENV_MSYSTEM).is_empty():
		return p_engine_dir.path_join(DEPS_FALLBACK)
	return local_appdata.path_join(DEPS_SUBPATH)


## 按目标平台决定要解析哪些脚本；perfetto 需要调用方先取到 tag。
static func _spec_order(p_platform: String, p_perfetto_tag: String) -> Array:
	var result: Array = [[SCRIPT_ANGLE, ""], [SCRIPT_ACCESSKIT, ""], [SCRIPT_WINRT, ""]]
	if p_platform == "windows":
		result.insert(1, [SCRIPT_D3D12, ""])
	if p_platform == "android":
		result.append([SCRIPT_SWAPPY, ""])
	if not p_perfetto_tag.is_empty():
		result.append([SCRIPT_PERFETTO, p_perfetto_tag])
	return result


## 分派单脚本解析。
static func _build_one_spec(p_script: String, p_text: String,
		p_perfetto_tag: String) -> Dictionary:
	match p_script:
		SCRIPT_ANGLE:
			return _spec_angle(p_text)
		SCRIPT_D3D12:
			return _spec_d3d12(p_text)
		SCRIPT_ACCESSKIT:
			return _spec_accesskit(p_text)
		SCRIPT_WINRT:
			return _spec_winrt(p_text)
		SCRIPT_PERFETTO:
			return _spec_perfetto(p_text, p_perfetto_tag)
		SCRIPT_SWAPPY:
			return _spec_swappy(p_text)
	return {KEY_ERROR: "未知安装脚本：%s" % p_script}


## ANGLE：arch 名单按宿主追加 msvc / ios+macos 变体（与上游 platform.system 分支一致）。
static func _spec_angle(p_text: String) -> Dictionary:
	var values: Dictionary[String, String] = assignments(p_text)
	var version: String = _need(values, VAR_ANGLE_VERSION, SCRIPT_ANGLE)
	if version.is_empty():
		return {KEY_ERROR: "%s 的 %s 解析失败" % [SCRIPT_ANGLE, VAR_ANGLE_VERSION]}
	var archs: PackedStringArray = _list_values(p_text, LIST_ANGLE_ARCHS)
	if archs.is_empty():
		return {KEY_ERROR: "%s 的 %s 列表解析为空（上游改版？）" % [
				SCRIPT_ANGLE, LIST_ANGLE_ARCHS]}
	var suffixes: PackedStringArray = PackedStringArray()
	match OS.get_name():
		WINDOWS_HOST:
			suffixes = PackedStringArray(ARCH_WINDOWS_SUFFIXES)
		MACOS_HOST:
			suffixes = PackedStringArray(ARCH_MACOS_SUFFIXES)
	for suffix: String in suffixes:
		if not archs.has(suffix):
			archs.append(suffix)
	var repo: String = _repo_or_fail(p_text, SCRIPT_ANGLE, VAR_ANGLE_VERSION)
	if repo.is_empty():
		return {KEY_ERROR: "%s 解析不到 Release 仓库名" % SCRIPT_ANGLE}
	var files: Array = []
	for arch: String in archs:
		files.append({
			KEY_NAME: ANGLE_FILE_FORMAT % arch,
			KEY_HOST: GITHUB_HOST,
			KEY_PATH: _release_path(repo, version, ANGLE_FILE_FORMAT % arch),
			KEY_INTO: ANGLE_DIR_FORMAT % arch,
		})
	return _ok_spec("angle", BASE_DEPS, version, _dirs_of(files), files)


## D3D12：Mesa 多架构 + WinPix nupkg + Agility SDK nupkg（后两者按 zip 解）。
static func _spec_d3d12(p_text: String) -> Dictionary:
	var values: Dictionary[String, String] = assignments(p_text)
	var mesa_version: String = _need(values, VAR_MESA_VERSION, SCRIPT_D3D12)
	var pix_version: String = _need(values, VAR_PIX_VERSION, SCRIPT_D3D12)
	var agility_version: String = _need(values, VAR_AGILITY_VERSION, SCRIPT_D3D12)
	if mesa_version.is_empty() or pix_version.is_empty() or agility_version.is_empty():
		return {KEY_ERROR: "%s 的版本常量解析失败" % SCRIPT_D3D12}
	var archs: PackedStringArray = _list_values(p_text, LIST_D3D12_ARCH)
	if archs.is_empty():
		return {KEY_ERROR: "%s 的 arch 列表解析为空（上游改版？）" % SCRIPT_D3D12}
	var repo: String = _repo_or_fail(p_text, SCRIPT_D3D12, VAR_MESA_VERSION)
	if repo.is_empty():
		return {KEY_ERROR: "%s 解析不到 Release 仓库名" % SCRIPT_D3D12}
	var files: Array = []
	for arch: String in archs:
		files.append({
			KEY_NAME: MESA_FILE_FORMAT % arch,
			KEY_HOST: GITHUB_HOST,
			KEY_PATH: _release_path(repo, mesa_version, MESA_FILE_FORMAT % arch),
			KEY_INTO: MESA_DIR_FORMAT % arch,
		})
	files.append({
		KEY_NAME: PIX_FILE_FORMAT % pix_version,
		KEY_HOST: NUGET_HOST,
		KEY_PATH: NUGET_PACKAGE_PATH_FORMAT % [NUGET_PIX, pix_version],
		KEY_INTO: PIX_DIR,
	})
	files.append({
		KEY_NAME: AGILITY_FILE_FORMAT % agility_version,
		KEY_HOST: NUGET_HOST,
		KEY_PATH: NUGET_PACKAGE_PATH_FORMAT % [NUGET_AGILITY, agility_version],
		KEY_INTO: AGILITY_DIR,
	})
	var spec: Dictionary = _ok_spec("d3d12", BASE_DEPS, mesa_version,
			_dirs_of(files), files)
	spec[KEY_SPEC][KEY_NEEDS_MINGW] = true
	return spec


## AccessKit：解到依赖目录后把 accesskit-c-<版本> 改名为 accesskit。
static func _spec_accesskit(p_text: String) -> Dictionary:
	var values: Dictionary[String, String] = assignments(p_text)
	var version: String = _need(values, VAR_AC_VERSION, SCRIPT_ACCESSKIT)
	var file_name: String = _need(values, VAR_AC_FILENAME, SCRIPT_ACCESSKIT)
	if version.is_empty() or file_name.is_empty():
		return {KEY_ERROR: "%s 的版本/文件名常量解析失败" % SCRIPT_ACCESSKIT}
	var repo: String = _repo_or_fail(p_text, SCRIPT_ACCESSKIT, VAR_AC_VERSION)
	if repo.is_empty():
		return {KEY_ERROR: "%s 解析不到 Release 仓库名" % SCRIPT_ACCESSKIT}
	var files: Array = [{
		KEY_NAME: file_name,
		KEY_HOST: GITHUB_HOST,
		KEY_PATH: _release_path(repo, version, file_name),
		KEY_INTO: "",
	}]
	var spec: Dictionary = _ok_spec("accesskit", BASE_DEPS, version,
			PackedStringArray([ACCESSKIT_DIR]), files)
	spec[KEY_SPEC][KEY_RENAME_FROM] = "%s-c-%s" % [ACCESSKIT_DIR, version]
	spec[KEY_SPEC][KEY_RENAME_TO] = ACCESSKIT_DIR
	return spec


## WinRT：MinGW 交叉编译用的头文件包。
static func _spec_winrt(p_text: String) -> Dictionary:
	var values: Dictionary[String, String] = assignments(p_text)
	var version: String = _need(values, VAR_WINRT_VERSION, SCRIPT_WINRT)
	var file_name: String = _need(values, VAR_WINRT_FILENAME, SCRIPT_WINRT)
	if version.is_empty() or file_name.is_empty():
		return {KEY_ERROR: "%s 的版本/文件名常量解析失败" % SCRIPT_WINRT}
	var repo: String = _repo_or_fail(p_text, SCRIPT_WINRT, VAR_WINRT_VERSION)
	if repo.is_empty():
		return {KEY_ERROR: "%s 解析不到 Release 仓库名" % SCRIPT_WINRT}
	var files: Array = [{
		KEY_NAME: file_name,
		KEY_HOST: GITHUB_HOST,
		KEY_PATH: _release_path(repo, version, file_name),
		KEY_INTO: WINRT_DIR,
	}]
	return _ok_spec("winrt", BASE_DEPS, version,
			PackedStringArray([WINRT_DIR]), files)


## Perfetto：源码包解进引擎 thirdparty；仓库名从上游 URL 常量解析，不硬编码。
static func _spec_perfetto(p_text: String, p_tag: String) -> Dictionary:
	var values: Dictionary[String, String] = assignments(p_text)
	var file_name: String = _need(values, VAR_PERFETTO_FILENAME, SCRIPT_PERFETTO)
	var folder: String = _need(values, VAR_PERFETTO_FOLDER, SCRIPT_PERFETTO)
	if file_name.is_empty() or folder.is_empty():
		return {KEY_ERROR: "%s 的文件名/目录常量解析失败" % SCRIPT_PERFETTO}
	# 上游不写仓库名常量：从它拼装的 URL 里取（perfetto_url 或任一 Release 前缀值）
	var repo: String = _repo_or_fail(p_text, SCRIPT_PERFETTO, "")
	if repo.is_empty():
		return {KEY_ERROR: "%s 解析不到 Release 仓库名（上游 URL 写法变化？）" % SCRIPT_PERFETTO}
	var into: String = folder.trim_prefix(THIRDPARTY_PREFIX)
	var files: Array = [{
		KEY_NAME: file_name,
		KEY_HOST: GITHUB_HOST,
		KEY_PATH: _release_path(repo, p_tag, file_name),
		KEY_INTO: into,
	}]
	return _ok_spec("perfetto", BASE_ENGINE, p_tag, PackedStringArray([into]), files)


## Swappy：整包下载后只抽各 ABI 的静态库进引擎 thirdparty。
static func _spec_swappy(p_text: String) -> Dictionary:
	var values: Dictionary[String, String] = assignments(p_text)
	var tag: String = _need(values, VAR_SWAPPY_TAG, SCRIPT_SWAPPY)
	var file_name: String = _need(values, VAR_SWAPPY_FILENAME, SCRIPT_SWAPPY)
	var folder: String = _need(values, VAR_SWAPPY_FOLDER, SCRIPT_SWAPPY)
	var archs: PackedStringArray = _list_values(p_text, LIST_SWAPPY_ARCHS)
	if tag.is_empty() or file_name.is_empty() or folder.is_empty() or archs.is_empty():
		return {KEY_ERROR: "%s 的常量或 arch 名单解析失败" % SCRIPT_SWAPPY}
	var repo: String = _repo_or_fail(p_text, SCRIPT_SWAPPY, VAR_SWAPPY_TAG)
	if repo.is_empty():
		return {KEY_ERROR: "%s 解析不到 Release 仓库名" % SCRIPT_SWAPPY}
	var into: String = folder.trim_prefix(THIRDPARTY_PREFIX)
	var selects: PackedStringArray = PackedStringArray()
	var clean: PackedStringArray = PackedStringArray()
	for arch: String in archs:
		selects.append(SWAPPY_MEMBER_FORMAT % arch)
		clean.append("%s/%s" % [into, arch])
	var files: Array = [{
		KEY_NAME: file_name,
		KEY_HOST: GITHUB_HOST,
		KEY_PATH: _release_path(repo, tag, file_name),
		KEY_INTO: into,
		KEY_SELECT: selects,
	}]
	return _ok_spec("swappy", BASE_ENGINE, tag, clean, files)


## 提取顶层字面量赋值（含引号串与已定义标识符的拼接式、f-string）。[br][br]
## [param p_text] 脚本原文。[br]
## [return] 变量名 → 值
static func assignments(p_text: String) -> Dictionary[String, String]:
	var result: Dictionary[String, String] = {}
	for line: String in p_text.split("\n"):
		var trimmed: String = line.strip_edges()
		# 行首 # 是注释；比较行含 ==，会被同名变量污染取值
		if trimmed.begins_with("#") or trimmed.contains("=="):
			continue
		if trimmed.contains(">=") or trimmed.contains("<=") or trimmed.contains("!="):
			continue
		_assign_line(trimmed, result)
	return result


## 解析单行赋值。
static func _assign_line(p_line: String, p_result: Dictionary[String, String]) -> void:
	var equal_index: int = p_line.find("=")
	if equal_index <= 0:
		return
	var name: String = p_line.substr(0, equal_index).strip_edges()
	if not name.is_valid_identifier():
		return
	var value_text: String = p_line.substr(equal_index + 1).split("#", false)[0].strip_edges()
	if value_text.is_empty() or value_text.begins_with("["):
		return
	var full_value: String = _eval_tokens(value_text, p_result)
	if not full_value.is_empty():
		p_result[name] = full_value


## 求拼接式字符串值；含未定义标识符时返回空串。
static func _eval_tokens(p_expression: String, p_known: Dictionary[String, String]) -> String:
	var expression: String = p_expression
	var is_fstring: bool = false
	for prefix: String in ["f\"", "f'", "rf\"", "Rf\"", "rb\"", "b\""]:
		if expression.begins_with(prefix) and (prefix.ends_with("\"") or prefix.ends_with("'")):
			is_fstring = prefix.length() > 2
			expression = expression.substr(prefix.length() - 1)
			break
	if not expression.begins_with("\"") and not expression.begins_with("'"):
		return ""
	var parts: PackedStringArray = PackedStringArray()
	for match_result: RegExMatch in _regex(TOKEN_PATTERN).search_all(expression):
		var literal: String = match_result.get_string(1)
		if match_result.get_start(1) >= 0:
			parts.append(_expand_fstring(literal, p_known) if is_fstring else literal)
			continue
		var identifier: String = match_result.get_string(2)
		if not p_known.has(identifier):
			return ""
		parts.append(p_known[identifier])
	return "".join(parts)


## f-string 里的 {name} 展开（仅简单标识符；取不到即留空并报错由调用方兜住）。
static func _expand_fstring(p_literal: String, p_known: Dictionary[String, String]) -> String:
	var result: String = p_literal
	while true:
		var brace_start: int = result.find("{")
		if brace_start < 0:
			break
		var brace_end: int = result.find("}", brace_start)
		if brace_end < 0:
			break
		var key: String = result.substr(brace_start + 1, brace_end - brace_start - 1)
		key = key.split(":")[0].split("!")[0].strip_edges()
		var replacement: String = p_known[key] if p_known.has(key) else ""
		result = result.substr(0, brace_start) + replacement + result.substr(brace_end + 1)
	return result


## 取列表变量项；支持 `名字 = [` 与 `for 名字 in [` 两种上游写法。
static func _list_values(p_text: String, p_name: String) -> PackedStringArray:
	var def_regex: RegEx = _regex(LIST_DEF_PATTERN)
	var def_match: RegExMatch = def_regex.search(p_text)
	while def_match != null:
		var found_name: String = def_match.get_string(1)
		if found_name.is_empty():
			found_name = def_match.get_string(2)
		if found_name != p_name:
			def_match = def_regex.search(p_text, def_match.get_end())
			continue
		var bracket_end: int = p_text.find("]", def_match.get_end() - 1)
		if bracket_end < 0:
			return PackedStringArray()
		var block: String = p_text.substr(def_match.get_end(), bracket_end - def_match.get_end())
		var result: PackedStringArray = PackedStringArray()
		for item: RegExMatch in _regex(LIST_ITEM_PATTERN).search_all(block):
			result.append(item.get_string(1))
		return result
	return PackedStringArray()


## 扫描脚本原文，提取首个 GitHub Release 下载 URL 的 owner/repo，
## 并核对 URL 里的版本占位符是否就是期望的常量名，防止上游换 URL 后取错仓库。[br][br]
## [param p_text] 脚本原文。[param p_version_var] 期望的版本常量名（用于核对占位符）。[br]
## [return] {repo: "owner/repo", tag_var: "版本占位符名", error: String}
static func _repo_from_text(p_text: String, p_script: String,
		p_version_var: String) -> Dictionary:
	var match_result: RegExMatch = _regex(RELEASE_URL_PATTERN).search(p_text)
	if match_result == null:
		push_warning("%s 原文里扫不到 GitHub Release 下载 URL（上游改版？）" % p_script)
		return {PARSED_REPO: "", KEY_ERROR: "%s 解析不到 Release 仓库名" % p_script}
	var repo: String = "%s/%s" % [match_result.get_string(1), match_result.get_string(2)]
	# 核对版本占位符：URL 里的 {xxx} 若存在且与期望常量名不符，说明上游换了变量，报错
	var tag_segment: String = match_result.get_string(3)
	var var_match: RegExMatch = _regex(URL_VAR_PATTERN).search(tag_segment)
	var found_var: String = var_match.get_string(1) if var_match != null else ""
	if not found_var.is_empty() and p_version_var != "" and found_var != p_version_var:
		push_warning("%s 的 Release URL 版本占位符是 {%s}，与期望常量 %s 不符" % [
				p_script, found_var, p_version_var])
		return {PARSED_REPO: "", KEY_ERROR: "%s 的 Release URL 版本占位符与常量名不符（上游改版）" % p_script}
	return {PARSED_REPO: repo, KEY_ERROR: "", "tag_var": found_var}


## 从脚本原文提取 Release 仓库名；失败返回空串由调用方组装错误。
static func _repo_or_fail(p_text: String, p_script: String, p_version_var: String) -> String:
	var parsed: Dictionary = _repo_from_text(p_text, p_script, p_version_var)
	if not str(parsed.get(KEY_ERROR, "")).is_empty():
		return ""
	return str(parsed[PARSED_REPO])


## 构造 Release 下载路径：tag 里的 / 转义，否则路径段错位导致 404。
static func _release_path(p_repo: String, p_tag: String, p_file_name: String) -> String:
	return RELEASE_PATH_FORMAT % [p_repo, p_tag.replace(TAG_SLASH, TAG_SLASH_ESCAPED),
			p_file_name]


## 组装成功规格。
static func _ok_spec(p_id: String, p_base: String, p_tag: String,
		p_clean: PackedStringArray, p_files: Array) -> Dictionary:
	return {KEY_ERROR: "", KEY_SPEC: {
		KEY_ID: p_id, KEY_BASE: p_base, KEY_TAG: p_tag,
		KEY_CLEAN: p_clean, KEY_FILES: p_files,
	}}


## 收集全部文件项的 into 目录作清理清单。
static func _dirs_of(p_files: Array) -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	for file: Dictionary in p_files:
		var into: String = str(file.get(KEY_INTO, ""))
		if not into.is_empty() and not result.has(into):
			result.append(into)
	return result


## 必需常量；缺失返回空串并由调用方组装错误。
static func _need(p_values: Dictionary[String, String], p_name: String,
		p_script: String) -> String:
	if not p_values.has(p_name):
		push_warning("%s 里找不到顶层常量 %s（上游脚本改版？）" % [p_script, p_name])
		return ""
	return p_values[p_name]


## 正则懒编译缓存；编译失败返回永不匹配的空正则，调用方不判空也不会崩。
static func _regex(p_pattern: String) -> RegEx:
	if not _regex_cache.has(p_pattern):
		var regex: RegEx = RegEx.new()
		if regex.compile(p_pattern) != OK:
			push_error("正则编译失败：%s" % p_pattern)
			var fallback: RegEx = RegEx.new()
			fallback.compile("(?!)")
			_regex_cache[p_pattern] = fallback
		else:
			_regex_cache[p_pattern] = regex
	return _regex_cache[p_pattern]
