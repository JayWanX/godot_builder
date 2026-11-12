@abstract
class_name EncryptionKey
extends Object
## PCK 加密编译密钥（ENCRYPTION_KEY）的生成与校验。[br][br]
## 生成使用 OS.get_entropy() 的加密级随机字节，不依赖被裁剪的 mbedtls 模块；
## CLI gen-key 与 GUI 设置共用本类，保证行为一致。

## 密钥字节数（Godot 引擎要求 32 字节 / 64 位十六进制）。
const KEY_BYTES: int = 32
## 十六进制字符数。
const HEX_LENGTH: int = KEY_BYTES * 2

## 生成一个新的加密密钥。[br][br]
## [return] 64 位小写十六进制字符串；系统熵不可用时返回空串。
static func generate() -> String:
	var entropy: PackedByteArray = OS.get_entropy(KEY_BYTES)
	if entropy.size() != KEY_BYTES:
		return ""
	return entropy.hex_encode()

## 校验密钥格式（长度与十六进制字符集）。[br][br]
## [param p_key] 待校验字符串。[br]
## [return] 符合 64 位十六进制时返回 true。
static func is_valid(p_key: String) -> bool:
	if p_key.length() != HEX_LENGTH:
		return false
	return p_key.is_valid_hex_number(false)
