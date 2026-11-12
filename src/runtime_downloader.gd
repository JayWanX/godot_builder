class_name RuntimeDownloader
extends RefCounted
## 运行时归档下载器：HTTPClient 逐帧轮询，边下边算 sha256 边落盘，不阻塞主线程。
##
## 用 HTTPClient 而非 HTTPRequest：后者会把响应整体经内部缓冲搬运，且本工具导出模板
## 已在裁剪配置中禁用该类。两条实测约束决定实现形态：
## 1) read_chunk_size 默认为 0，不设则 read_response_body_chunk() 永远返回空、整包驻留内存；
## 2) 重定向响应没有 body，必须在响应结束时按状态码判定，而不是等 STATUS_BODY。

## 单次读取分块大小（同时作为摘要与写盘的粒度）
const CHUNK_SIZE: int = 65536
## 单个源建立连接的超时（秒）
const CONNECT_TIMEOUT_SECONDS: float = 20.0
## 单次下载在无进展时的超时（秒）；有数据到达即重新计时
const STALL_TIMEOUT_SECONDS: float = 60.0
## 连续空轮询上限（超过判定为卡死并换源）
const IDLE_POLL_LIMIT: int = 600
## 单个源的最大尝试次数
const MAX_ATTEMPTS_PER_HOST: int = 2
## 重定向状态码区间与跟随上限
const REDIRECT_LOW: int = 300
const REDIRECT_HIGH: int = 399
const MAX_REDIRECTS: int = 5
## 服务端临时故障状态码下限（可在同源重试）
const SERVER_ERROR_LOW: int = 500
## 毫秒每秒（超时按真实时间计）
const MILLIS_PER_SECOND: float = 1000.0
## 请求头（GDScript 不接受 const PackedStringArray([...]) 构造，发送时再转换）
const REQUEST_HEADERS: Array[String] = [
	"User-Agent: GodotBuilder",
	"Accept: */*",
	"Accept-Encoding: identity",
]
## 结果字典键
const KEY_OK: String = "ok"
const KEY_REASON: String = "reason"
const KEY_BYTES: String = "bytes"
const KEY_HOST: String = "host"
const KEY_SHA256: String = "sha256"
const KEY_LOCATION: String = "location"
const KEY_NEED_REDIRECT: String = "need_redirect"
## 源与响应的键
const HEADER_LOCATION: String = "Location"
const SOURCE_HOST: String = "host"
const SOURCE_PORT: String = "port"
const SOURCE_TLS: String = "tls"
const SOURCE_PATH: String = "path"
## 摘要格式
const HEX_BYTE_FORMAT: String = "%02x"
const DIGEST_PREFIX_LENGTH: int = 12
## scheme 与端口
const SCHEME_HTTPS: String = "https://"
const SCHEME_HTTP: String = "http://"
const PORT_HTTPS: int = 443
const PORT_HTTP: int = 80

## 源候选，每项含键：host(String)、port(int)、tls(bool)、path(String)
var _sources: Array[Dictionary] = []
## 预期摘要（小写十六进制；为空则只下载不判定）
var _expected_sha: String = ""
## 活动连接与落盘文件
var _client: HTTPClient = null
var _file: FileAccess = null
var _hasher: HashingContext = null
## 计数与状态
var _received_bytes: int = 0
var _expected_bytes: int = -1
var _idle_polls: int = 0
## 本阶段最后一次有进展的时刻（毫秒，Time.get_ticks_msec）
var _last_progress_msec: int = 0
var _response_code: int = 0
var _location: String = ""
## 进度回调 f(已下载字节, 总字节)
var _progress: Callable = Callable()
## 阶段回调 f(说明文本)，用于连接与等待阶段给出可见反馈
var _stage: Callable = Callable()


## 配置源候选（按顺序尝试）。[br][br]
## [param p_sources] 每项含键：host(String)、port(int)、tls(bool)、path(String)
func configure(p_sources: Array[Dictionary]) -> void:
	_sources = []
	for source: Dictionary in p_sources:
		if str(source.get(SOURCE_HOST, "")).is_empty():
			continue
		_sources.append(source)


## 依次尝试各源下载并写入文件，边写边算 sha256。[br][br]
## [param p_dest_path] 目标文件绝对路径。[br]
## [param p_expected_sha256] 期望摘要（小写十六进制）。[br]
## [param p_progress] 进度回调 f(已下载字节, 总字节)。[br]
## [param p_stage] 阶段回调 f(说明文本)，连接与等待阶段也会回调。[br]
## [return] 含键：ok(bool)、reason(String)、bytes(int)、host(String)、sha256(String)
func download(p_dest_path: String, p_expected_sha256: String = "",
		p_progress: Callable = Callable(), p_stage: Callable = Callable()) -> Dictionary:
	_progress = p_progress
	_stage = p_stage
	_expected_sha = p_expected_sha256.to_lower()
	if _sources.is_empty():
		return _fail("没有可用的下载源")
	var last_reason: String = "没有可用的下载源"
	var last_host: String = ""
	for source_index: int in _sources.size():
		var source: Dictionary = _sources[source_index]
		var host: String = str(source.get(SOURCE_HOST, ""))
		last_host = host
		for attempt: int in MAX_ATTEMPTS_PER_HOST:
			_notify_stage("连接 %s（第 %d 次）" % [host, attempt + 1])
			var outcome: Dictionary = await _run_source(source, host, p_dest_path)
			if bool(outcome.get(KEY_OK, false)):
				return outcome
			last_reason = str(outcome.get(KEY_REASON, "失败"))
			_notify_stage("%s 失败：%s" % [host, last_reason])
			# 内容类与服务端故障值得同源重试；握手与连接失败立刻换源
			if not _is_worth_retry(last_reason):
				break
	return _fail("%s（最后源 %s）" % [last_reason, last_host])


## 在单个源上完成一次下载，含必要的重定向跟随。
func _run_source(p_source: Dictionary, p_host: String, p_dest_path: String) -> Dictionary:
	var current: Dictionary = p_source
	var current_host: String = p_host
	for hop: int in MAX_REDIRECTS + 1:
		var fetch: Dictionary = await _fetch(current, p_dest_path)
		if not bool(fetch.get(KEY_OK, false)):
			_close_all()
			DirAccess.remove_absolute(p_dest_path)
			return _fail(str(fetch.get(KEY_REASON, "失败")))
		var need_redirect: bool = bool(fetch.get(KEY_NEED_REDIRECT, false))
		var location: String = str(fetch.get(KEY_LOCATION, ""))
		_close_all()
		if not need_redirect:
			return _verify_and_finish(p_dest_path, current_host)
		if hop >= MAX_REDIRECTS or location.is_empty():
			DirAccess.remove_absolute(p_dest_path)
			return _fail("重定向不可用（Location=%s，已跟随 %d 次）" % [location, hop])
		var resolved: Dictionary = _resolve_location(current_host, location,
				str(current.get(SOURCE_PATH, "/")))
		if resolved.is_empty():
			DirAccess.remove_absolute(p_dest_path)
			return _fail("无法解析重定向目标：%s" % location)
		current = resolved
		current_host = str(resolved.get(SOURCE_HOST, ""))
	DirAccess.remove_absolute(p_dest_path)
	return _fail("重定向次数超过 %d 次上限" % MAX_REDIRECTS)


## 连接、请求并收流。响应结束时把状态码与 Location 一并带回，不在这里收尾。
func _fetch(p_source: Dictionary, p_dest_path: String) -> Dictionary:
	_client = HTTPClient.new()
	# 必须显式设置：默认 0 会让 read_response_body_chunk() 只在整包到齐后返回数据
	_client.read_chunk_size = CHUNK_SIZE
	_received_bytes = 0
	_expected_bytes = -1
	_idle_polls = 0
	_last_progress_msec = Time.get_ticks_msec()
	_response_code = 0
	_location = ""
	_hasher = HashingContext.new()
	if _hasher.start(HashingContext.HASH_SHA256) != OK:
		return {KEY_OK: false, KEY_REASON: "摘要上下文初始化失败"}
	var is_tls: bool = bool(p_source.get(SOURCE_TLS, true))
	var tls_options: TLSOptions = TLSOptions.client() if is_tls else null
	if is_tls and tls_options == null:
		return {KEY_OK: false, KEY_REASON: "本引擎构建未包含 TLS 后端或缺少内置根证书，无法安全下载"}
	var port: int = int(p_source.get(SOURCE_PORT, PORT_HTTPS if is_tls else PORT_HTTP))
	if _client.connect_to_host(str(p_source.get(SOURCE_HOST, "")), port, tls_options) != OK:
		return {KEY_OK: false, KEY_REASON: "无法发起连接"}
	var wait_reason: String = await _wait_until_connected()
	if not wait_reason.is_empty():
		return {KEY_OK: false, KEY_REASON: wait_reason}
	# 先建目标文件再发请求：让下载过程有可见落盘，失败时由调用方删除
	if not _open_target(p_dest_path):
		return {KEY_OK: false, KEY_REASON: "无法写入 %s（%s）" % [
			p_dest_path, error_string(FileAccess.get_open_error())]}
	if _client.request(HTTPClient.METHOD_GET, str(p_source.get(SOURCE_PATH, "/")),
			PackedStringArray(REQUEST_HEADERS)) != OK:
		return {KEY_OK: false, KEY_REASON: "无法发起请求"}
	_last_progress_msec = Time.get_ticks_msec()
	_notify_stage("已连接 %s，等待响应" % str(p_source.get(SOURCE_HOST, "")))
	return await _pump()


## 流式收取响应主体直到结束。
func _pump() -> Dictionary:
	while true:
		_client.poll()
		var status: int = _client.get_status()
		if status == HTTPClient.STATUS_BODY:
			# 先读响应元信息：重定向响应没有 body，等首个数据块会永远等不到
			if _response_code == 0:
				_read_response_meta()
				if _response_code >= REDIRECT_LOW and _response_code <= REDIRECT_HIGH:
					return _redirect_result()
			var chunk: PackedByteArray = _client.read_response_body_chunk()
			if chunk.is_empty():
				_idle_polls += 1
				if _idle_polls > IDLE_POLL_LIMIT:
					return {KEY_OK: false, KEY_REASON: "响应长时间无数据"}
			else:
				_idle_polls = 0
				_last_progress_msec = Time.get_ticks_msec()
				_file.store_buffer(chunk)
				_hasher.update(chunk)
				_received_bytes += chunk.size()
				if _progress.is_valid():
					_progress.call(_received_bytes, _expected_bytes)
		elif status == HTTPClient.STATUS_CONNECTED:
			return _response_result()
		elif status in [HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING,
				HTTPClient.STATUS_REQUESTING]:
			pass
		else:
			return {KEY_OK: false, KEY_REASON: _describe_status(status)}
		# 用真实时间计时：帧率随负载变化，按帧累加会让超时上限形同虚设
		if _seconds_since_progress() > STALL_TIMEOUT_SECONDS:
			return {KEY_OK: false, KEY_REASON: "下载停滞（%.0f 秒无数据）" % STALL_TIMEOUT_SECONDS}
		await _next_frame()
	return {KEY_OK: false, KEY_REASON: "读取循环意外退出"}


## 首帧读取响应元信息（状态码与正文长度）。
func _read_response_meta() -> void:
	_response_code = _client.get_response_code()
	_expected_bytes = _client.get_response_body_length()


## 30x 响应：取 Location 交回调用方。
func _redirect_result() -> Dictionary:
	if not _location.is_empty():
		return {KEY_OK: true, KEY_NEED_REDIRECT: true, KEY_LOCATION: _location}
	var headers: Dictionary = _client.get_response_headers_as_dictionary()
	_location = str(headers.get(HEADER_LOCATION, headers.get(HEADER_LOCATION.to_lower(), "")))
	return {KEY_OK: true, KEY_NEED_REDIRECT: true, KEY_LOCATION: _location,
			KEY_BYTES: _received_bytes}


## 响应结束（无 body 或 body 读完）：判定状态码。
func _response_result() -> Dictionary:
	if _response_code == 0:
		_response_code = _client.get_response_code()
	if _response_code >= REDIRECT_LOW and _response_code <= REDIRECT_HIGH:
		return _redirect_result()
	if _response_code >= SERVER_ERROR_LOW:
		return {KEY_OK: false, KEY_REASON: "服务端错误 HTTP %d" % _response_code}
	if _response_code >= 400:
		return {KEY_OK: false, KEY_REASON: "HTTP %d" % _response_code}
	return {KEY_OK: true, KEY_NEED_REDIRECT: false, KEY_BYTES: _received_bytes}


## 校验摘要并组装最终结果（文件已关闭后调用）。
func _verify_and_finish(p_dest_path: String, p_host: String) -> Dictionary:
	var hex_text: String = _finish_hex()
	if _received_bytes <= 0:
		DirAccess.remove_absolute(p_dest_path)
		return _fail("下载内容为空")
	if not _expected_sha.is_empty() and hex_text != _expected_sha:
		DirAccess.remove_absolute(p_dest_path)
		return _fail("摘要不符（期望 %s…，实得 %s…）" % [
			_expected_sha.substr(0, DIGEST_PREFIX_LENGTH),
			hex_text.substr(0, DIGEST_PREFIX_LENGTH)])
	return {
		KEY_OK: true, KEY_REASON: "", KEY_BYTES: _received_bytes,
		KEY_SHA256: hex_text, KEY_HOST: p_host,
	}


## 等待连接建立（必须逐帧 poll，HTTPClient 的状态由 poll 推进）。[br][br]
## [return] 失败原因；空串表示成功
func _wait_until_connected() -> String:
	var started_msec: int = Time.get_ticks_msec()
	while _client.get_status() != HTTPClient.STATUS_CONNECTED:
		_client.poll()
		var status: int = _client.get_status()
		if status == HTTPClient.STATUS_CONNECTED:
			break
		if status in [HTTPClient.STATUS_TLS_HANDSHAKE_ERROR, HTTPClient.STATUS_CONNECTION_ERROR,
				HTTPClient.STATUS_CANT_CONNECT, HTTPClient.STATUS_CANT_RESOLVE,
				HTTPClient.STATUS_DISCONNECTED]:
			return _describe_status(status)
		if _elapsed_since(started_msec) > CONNECT_TIMEOUT_SECONDS:
			return "连接超时（%.0f 秒未建立）" % CONNECT_TIMEOUT_SECONDS
		await _next_frame()
	return ""


## 距指定时刻的秒数（真实时间）。
func _elapsed_since(p_started_msec: int) -> float:
	return float(Time.get_ticks_msec() - p_started_msec) / MILLIS_PER_SECOND


## 距上次有进展的秒数。
func _seconds_since_progress() -> float:
	return _elapsed_since(_last_progress_msec)


## 上报阶段说明（无回调时忽略）。
func _notify_stage(p_text: String) -> void:
	if _stage.is_valid():
		_stage.call(p_text)


## 让出一帧（无场景树时同步返回）。
func _next_frame() -> void:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	await tree.process_frame


## 把 30x 的 Location 解析为下一次请求的源。
func _resolve_location(p_host: String, p_location: String, p_current_path: String) -> Dictionary:
	var location: String = p_location.strip_edges()
	if location.is_empty():
		return {}
	if location.begins_with(SCHEME_HTTPS) or location.begins_with(SCHEME_HTTP):
		var is_https: bool = location.begins_with(SCHEME_HTTPS)
		var rest: String = location.split("://", false)[1]
		var slash_index: int = rest.find("/")
		var host_part: String = rest if slash_index < 0 else rest.substr(0, slash_index)
		var path_part: String = "/" if slash_index < 0 else rest.substr(slash_index)
		var port: int = PORT_HTTPS if is_https else PORT_HTTP
		if host_part.contains(":"):
			var pieces: PackedStringArray = host_part.split(":")
			host_part = pieces[0]
			port = pieces[1].to_int() if pieces[1].is_valid_int() else port
		if host_part.is_empty():
			return {}
		return {
			SOURCE_HOST: host_part, SOURCE_PORT: port,
			SOURCE_TLS: is_https, SOURCE_PATH: path_part,
		}
	var fixed: String = location
	if not fixed.begins_with("/"):
		fixed = p_current_path.get_base_dir().path_join(fixed)
	return {SOURCE_HOST: p_host, SOURCE_PORT: PORT_HTTPS, SOURCE_TLS: true, SOURCE_PATH: fixed}


## 打开落盘文件。
func _open_target(p_path: String) -> bool:
	if _file != null:
		_file.close()
		_file = null
	_file = FileAccess.open(p_path, FileAccess.WRITE)
	return _file != null


## 关闭连接与文件。
func _close_all() -> void:
	if _file != null:
		_file.flush()
		_file.close()
		_file = null
	if _client != null:
		_client.close()
		_client = null


## 摘要十六进制（小写）。
func _finish_hex() -> String:
	var digest: PackedByteArray = _hasher.finish()
	var text: String = ""
	for byte_value: int in digest:
		text += HEX_BYTE_FORMAT % byte_value
	return text


## 失败结果。
func _fail(p_reason: String) -> Dictionary:
	return {KEY_OK: false, KEY_REASON: p_reason, KEY_BYTES: _received_bytes, KEY_HOST: ""}


## 该失败原因是否值得在同源重试。
func _is_worth_retry(p_reason: String) -> bool:
	return p_reason.contains("HTTP 5") or p_reason.contains("服务端错误") \
			or p_reason.contains("无数据") or p_reason.contains("超时")


## 状态码转中文原因。
func _describe_status(p_status: int) -> String:
	match p_status:
		HTTPClient.STATUS_CANT_RESOLVE:
			return "域名解析失败"
		HTTPClient.STATUS_CANT_CONNECT:
			return "无法连接主机"
		HTTPClient.STATUS_CONNECTION_ERROR:
			return "连接错误（该源在 Godot HTTPClient 下不可达）"
		HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
			return "TLS 握手失败（内置根证书不信任该站点）"
		HTTPClient.STATUS_DISCONNECTED:
			return "连接已关闭"
		_:
			return "未知连接状态 %d" % p_status
