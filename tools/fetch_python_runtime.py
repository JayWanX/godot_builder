#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""CI 专用：按 python_runtime_manifest.json 下载并裁剪嵌入式 Python 运行时与 SCons 到 python/。

`python/` 是生成物、不入库（见 .gitignore）。导出预设要求打包 `python/*`，故 CI 在
导出前跑一次本脚本；无参数、无交互，三平台一次备齐。

    python tools/fetch_python_runtime.py

产物一律用清单里固定的官方 sha256 校验（摘要只信清单，不信来源自身），只走上游
GitHub / PyPI。裁剪规则不在本脚本内，全部读 python_runtime_manifest.json，与
addons/godot_builder_export/export_trimmer.gd 共用同一份清单、同一套语义。
"""
from __future__ import annotations

import hashlib
import json
import os
import platform as platform_std
import posixpath
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from dataclasses import dataclass
from typing import Callable, Iterator

# ── 路径 ────────────────────────────────────────────────────────────────────
TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
# 项目根：作为 CI 钩子运行时由执行器给出（bundle 会把脚本复制到 scripts/ 下，
# __file__ 的相对位置随之失效）；本地直跑时回退到 tools/ 的上一级。
PROJECT_DIR = os.environ.get("GODOT_HOOK_PROJECT_ROOT") or os.path.dirname(TOOLS_DIR)
MANIFEST_PATH = os.path.join(PROJECT_DIR, "python_runtime_manifest.json")
# 运行时根：平台运行时与站点包直接平铺其下（python/windows、python/site-packages），
# 与安装位置 user://python/<平台> 对应，中间不再分层
PYTHON_RUNTIME_ROOT = os.path.join(PROJECT_DIR, "python")
SITE_PACKAGES_ROOT = os.path.join(PYTHON_RUNTIME_ROOT, "site-packages")
# 下载归档的临时目录（main 里建、结束时删）
_temp_dir = ""

# ── 常量 ────────────────────────────────────────────────────────────────────
MB = 1024 * 1024
CHUNK_SIZE = 1 << 20
PROGRESS_STEP_BYTES = 8 * MB
HTTP_TIMEOUT_SECONDS = 180
USER_AGENT = "godot-builder-fetch/1.0"

SEP = "/"
PYCACHE_DIR_NAME = "__pycache__"
PYC_SUFFIX = ".pyc"
PY_SUFFIX = ".py"
URL_PBS_UPSTREAM = "pbs_upstream"
URL_PYPI_UPSTREAM = "pypi_upstream"
# 归档顶层目录层数（PBS 为 python/，剥一层对齐运行时根）
ARCHIVE_STRIP_LEVEL = 1
# 归档内解释器相对路径（PBS 三平台统一，Windows 由顶层 python.exe 承担）
INTERPRETER_REL_PATH = "bin/python3"
# 解释器可执行位（解包后 exec 位丢失会让 Linux/macOS 运行时无法启动）
EXECUTABLE_MODE = 0o755
DEFAULT_FILE_MODE = 0o644
ALL_PLATFORMS = ("windows", "linux", "macos")

SYSTEM_TO_PLATFORM = {"Windows": "windows", "Linux": "linux", "Darwin": "macos"}
ARCH_ALIASES = {"amd64": "x64", "x86_64": "x64", "arm64": "arm64", "aarch64": "arm64"}
# macOS 两架构合并为 universal 运行时，需同时取两份归档
MACOS_ASSET_PREFIX = "macos_"
MACOS_ASSETS = {"arm64": "macos_arm64", "x64": "macos_x86_64"}
DEFAULT_MACOS_ARCH = "arm64"

# 自检覆盖：解释器启动链 + SCons 主链 + 裁剪面最大的扩展。
# 只列清单保留集内确实存在的模块：探针要求导出一个已被裁掉的模块，等于自检自己失败。
SELFTEST_IMPORTS = [
    "SCons.Script", "SCons.Environment", "SCons.Errors", "SCons.Variables", "SCons.Platform.win32",
    "SCons.Platform.posix", "SCons.Tool.MSCommon", "SCons.Tool.ninja_tool",
    "ctypes", "bz2", "lzma", "socket", "hashlib", "uuid", "queue", "platform",
    "sysconfig", "subprocess", "shutil", "tempfile", "zipfile", "json", "logging", "pathlib",
    "re", "typing", "dataclasses", "ast", "inspect", "difflib", "gettext", "glob", "fnmatch",
    "tokenize", "linecache", "pprint", "random", "struct", "textwrap", "threading", "optparse",
    "cmd", "dis", "copy", "base64", "datetime", "enum", "contextlib", "warnings", "weakref",
]
SELFTEST_WINDOWS_ONLY = ["_wmi", "compression.zstd", "encodings._win_cp_codecs"]
# 探针只做「编码可用性」断言：查表即可，不用非 ASCII 字符（latin_1 等本就无法编码中文）
ENCODINGS_PROBE = ["utf_8", "gbk", "cp936", "latin_1", "utf_16", "cp1252", "ascii", "utf_32",
                   "big5", "shift_jis", "euc_jp"]
# oem 走 Windows 专属的 MultiByteToWideChar，非 Windows 上 encodings.oem 必然 ImportError
ENCODINGS_WINDOWS_ONLY = ["oem"]
# encodings.aliases 的归一化目标数，裁剪过度会让别名表残缺
ALIAS_MIN_TARGETS = 90
# 失败诊断保留的尾部长度（子进程输出前面多是无关的启动噪声）
FAILURE_TAIL_CHARS = 1200
# 摘要不符报错里显示的十六进制前缀长度
ERROR_DIGEST_CHARS = 12
# lipo 错误信息保留长度
LIPO_ERROR_CHARS = 150
# zip 外部属性到权限位的位移（PKZIP 规范：高 16 位为 Unix mode）
ZIP_MODE_SHIFT = 16

SELFTEST_CODE = r"""
import codecs
import importlib
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    cfg = json.load(fh)
if cfg["site_packages"]:
    sys.path.insert(0, cfg["site_packages"])

bad = []
for name in cfg["imports"]:
    try:
        importlib.import_module(name)
    except Exception as exc:
        bad.append("%s: %s: %s" % (name, type(exc).__name__, exc))
for enc in cfg["encodings"]:
    try:
        codecs.lookup(enc)
    except Exception as exc:
        bad.append("encodings.%s: %s" % (enc, type(exc).__name__))

import encodings.aliases
targets = set(encodings.aliases.aliases.values())
if len(targets) < cfg["alias_min_targets"]:
    bad.append("aliases 表异常小: %d" % len(targets))

print("FAIL|" + "; ".join(bad) if bad else "OK")
"""


# ── 输出与主机识别 ──────────────────────────────────────────────────────────
def log(p_message: str) -> None:
    print(p_message, flush=True)


def die(p_message: str, p_code: int = 1) -> None:
    """打印 GitHub Actions 注解并终止；调用点之后无需再 return。"""
    print("::error::" + p_message, file=sys.stderr)
    raise SystemExit(p_code)


def megabytes(p_size: int) -> str:
    """字节数 → 带单位的显示串（0 视为未知长度）。"""
    return f"{p_size / MB:.1f} MB" if p_size else "?"


def host_platform() -> str:
    """宿主平台；未知系统按 windows 处理（本工具只在三平台发布）。"""
    return SYSTEM_TO_PLATFORM.get(platform_std.system(), "windows")


def host_arch() -> str:
    """宿主架构；识别不了直接报错，猜一个会裁出跑不起来的运行时。"""
    machine = platform_std.machine().lower()
    arch = ARCH_ALIASES.get(machine)
    if arch is None:
        die(f"无法识别宿主架构：{machine}")
    return arch


def platform_dir(p_platform: str) -> str:
    """平台运行时的落盘目录（python/<平台>）。"""
    return os.path.join(PYTHON_RUNTIME_ROOT, p_platform)


def interpreter_path(p_platform: str) -> str:
    """宿主平台的解释器绝对路径。"""
    if p_platform == "windows":
        return os.path.join(platform_dir("windows"), "python.exe")
    return os.path.join(platform_dir(p_platform), "bin", "python3")


# ── 下载 ────────────────────────────────────────────────────────────────────
def sha256_file(p_path: str) -> str:
    digest = hashlib.sha256()
    with open(p_path, "rb") as fh:
        for chunk in iter(lambda: fh.read(CHUNK_SIZE), b""):
            digest.update(chunk)
    return digest.hexdigest()


def http_download(p_url: str, p_dest: str) -> None:
    """流式下载到 p_dest，边下边打印进度。"""
    request = urllib.request.Request(p_url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response, \
            open(p_dest, "wb") as out:
        total = int(response.headers.get("Content-Length") or 0)
        done = 0
        next_mark = PROGRESS_STEP_BYTES
        while True:
            chunk = response.read(CHUNK_SIZE)
            if not chunk:
                break
            out.write(chunk)
            done += len(chunk)
            if done >= next_mark:
                log(f"    {megabytes(done)} / {megabytes(total)}")
                next_mark = done + PROGRESS_STEP_BYTES


def download_checked(p_url: str, p_dest: str, p_sha256: str) -> str:
    """下载到 p_dest 并用清单摘要校验；摘要是唯一可信来源，不符即报错。"""
    if not p_url:
        die(f"清单缺少 URL，无法下载 {os.path.basename(p_dest)}")
    log(f"  下载 {p_url}")
    http_download(p_url, p_dest)
    got = sha256_file(p_dest)
    if got != p_sha256:
        os.remove(p_dest)
        die(f"{os.path.basename(p_dest)} 摘要不符："
            f"期望 {p_sha256[:ERROR_DIGEST_CHARS]}…，实得 {got[:ERROR_DIGEST_CHARS]}…")
    log(f"  校验通过 {megabytes(os.path.getsize(p_dest))}")
    return p_dest


# ── 保留规则 ────────────────────────────────────────────────────────────────
def _string_set(p_value: object, p_lower: bool = False) -> frozenset[str]:
    """JSON 数组 → 字符串集合（JSON 边界在此收敛，判定侧不再判类型）。"""
    if not isinstance(p_value, list):
        return frozenset()
    if p_lower:
        return frozenset(str(item).lower() for item in p_value)
    return frozenset(str(item) for item in p_value)


@dataclass(frozen=True)
class RuntimeRules:
    """单平台运行时的保留判定；集合预建，逐文件判定 O(1)。"""

    platform: str
    stdlib_parts: tuple[str, ...]
    top_allow: frozenset[str]
    top_drop: frozenset[str]
    bin_allow: frozenset[str]
    dlls_allow: frozenset[str]
    allow_files: frozenset[str]

    def keeps(self, p_rel: str) -> bool:
        """相对路径（已剥归档顶层目录、正斜杠）是否保留。"""
        segments = p_rel.split(SEP)
        if PYCACHE_DIR_NAME in segments or p_rel.endswith(PYC_SUFFIX):
            return False
        if len(segments) == 1:
            return p_rel.lower() not in self.top_drop
        first = segments[0]
        if first not in self.top_allow:
            return False
        if self.platform == "windows" and first == "DLLs":
            return segments[-1] in self.dlls_allow
        if first == "bin":
            return segments[-1] in self.bin_allow
        # stdlib 之外的 lib/ 子目录（如 lib-dynload）一律不保留
        if self.platform != "windows" and first == self.stdlib_parts[0] \
                and len(segments) > 1 and segments[1] != self.stdlib_parts[1]:
            return False
        if self._under_stdlib(segments):
            # stdlib 内部按文件级精确白名单判定：单位级会把整包带入（如 email 30 文件）
            return p_rel.lower() in self.allow_files
        return True

    def _under_stdlib(self, p_segments: list[str]) -> bool:
        depth = len(self.stdlib_parts)
        if len(p_segments) <= depth:
            return False
        return tuple(p_segments[:depth]) == self.stdlib_parts


@dataclass(frozen=True)
class SiteRules:
    """站点包保留判定：只留 SCons 树内、顶层单位在白名单内的 .py。"""

    root: str
    py_only: bool
    units: frozenset[str]

    def keeps(self, p_rel: str) -> bool:
        prefix = self.root + SEP
        if not p_rel.startswith(prefix):
            return False
        if p_rel.endswith(PYC_SUFFIX) or PYCACHE_DIR_NAME in p_rel.split(SEP):
            return False
        if self.py_only and not p_rel.endswith(PY_SUFFIX):
            return False
        unit = p_rel[len(prefix):].split(SEP)[0]
        return unit.removesuffix(PY_SUFFIX) in self.units


class Manifest:
    """python_runtime_manifest.json 的类型化视图：资产、URL 模板与保留规则。"""

    REQUIRED_KEYS = ("pbs_tag", "assets", "urls", "scons", "platforms", "site_packages")

    def __init__(self, p_data: dict) -> None:
        self._data = p_data
        self._runtime_rules: dict[str, RuntimeRules] = {}

    @classmethod
    def load(cls, p_path: str = MANIFEST_PATH) -> "Manifest":
        with open(p_path, encoding="utf-8") as fh:
            data = json.load(fh)
        missing = [key for key in cls.REQUIRED_KEYS if key not in data]
        if missing:
            die(f"清单缺少字段：{'、'.join(missing)}")
        return cls(data)

    @property
    def pbs_tag(self) -> str:
        return str(self._data["pbs_tag"])

    def assets(self) -> dict:
        return self._data["assets"]

    def asset(self, p_key: str) -> dict:
        """单个下载资产；字段不完整时直接报错，避免下游拿到空摘要。"""
        item = self.assets().get(p_key)
        if not isinstance(item, dict):
            die(f"清单缺少资产 {p_key}")
        return self._require_fields(item, ("file", "sha256"), f"资产 {p_key}")

    def scons(self) -> dict:
        return self._require_fields(self._data["scons"], ("file", "path", "sha256"), "scons 段")

    @staticmethod
    def _require_fields(p_item: dict, p_names: tuple[str, ...], p_label: str) -> dict:
        for name in p_names:
            if not p_item.get(name):
                die(f"清单{p_label}缺少字段 {name}")
        return p_item

    def build_url(self, p_url_key: str, p_file: str = "", p_path: str = "") -> str:
        """展开 {tag}/{file}/{path} 占位；模板缺失时返回空串由调用方报错。"""
        template = str(self._data["urls"].get(p_url_key, ""))
        if not template:
            return ""
        return (template.replace("{tag}", self.pbs_tag)
                .replace("{file}", p_file)
                .replace("{path}", p_path))

    def platform_report(self, p_platform: str) -> dict:
        """清单里供日志展示的统计字段。"""
        return self._data["platforms"].get(p_platform) or {}

    def site_report(self) -> dict:
        return self._data["site_packages"]

    def runtime_rules(self, p_platform: str) -> RuntimeRules:
        cached = self._runtime_rules.get(p_platform)
        if cached is not None:
            return cached
        raw = self.platform_report(p_platform)
        if not raw:
            die(f"清单里没有平台 {p_platform}")
        stdlib_dir = str(raw.get("stdlib_dir", ""))
        if not stdlib_dir:
            die(f"清单平台 {p_platform} 缺少 stdlib_dir")
        rules = RuntimeRules(
            platform=p_platform,
            stdlib_parts=tuple(stdlib_dir.split(SEP)),
            top_allow=_string_set(raw.get("top_allow")),
            top_drop=_string_set(raw.get("top_file_drop"), p_lower=True),
            bin_allow=_string_set(raw.get("bin_allow")),
            dlls_allow=_string_set(raw.get("dlls_allow")),
            allow_files=_string_set(raw.get("stdlib_allow_files"), p_lower=True),
        )
        self._runtime_rules[p_platform] = rules
        return rules

    def site_rules(self) -> SiteRules:
        raw = self.site_report()
        return SiteRules(
            root=str(raw.get("root", "SCons")),
            py_only=bool(raw.get("py_only", True)),
            units=_string_set(raw.get("top_allow")),
        )


# ── 归档读取 ────────────────────────────────────────────────────────────────
def _strip_segments(p_name: str, p_strip_level: int) -> str:
    """去掉 p_strip_level 层顶层目录；层级不足（顶层壳）返回空串。"""
    parts = [part for part in p_name.split(SEP) if part not in ("", ".")]
    if len(parts) <= p_strip_level:
        return ""
    return SEP.join(parts[p_strip_level:])


class ArchiveSource:
    """归档的只读视图（鸭子类型协议）：支持 with 语句、paths()、read()。

    paths() 返回剥过顶层目录的相对路径（正斜杠）；read() 返回 (字节, 权限位)，
    权限位取不到时为 None。实现见 TarSource / ZipSource。
    """

    def paths(self) -> Iterator[str]:
        raise NotImplementedError

    def read(self, p_rel: str) -> tuple[bytes, int | None]:
        raise NotImplementedError


class TarSource(ArchiveSource):
    """tar.gz 读取：剥顶层目录；符号/硬链接解到实体（等价于解包后按内容复制）。"""

    MAX_LINK_DEPTH = 8

    def __init__(self, p_archive: str, p_strip_level: int = ARCHIVE_STRIP_LEVEL) -> None:
        self._archive = p_archive
        self._strip_level = p_strip_level
        self._tar: tarfile.TarFile | None = None
        self._by_name: dict[str, tarfile.TarInfo] = {}
        self._by_rel: dict[str, tarfile.TarInfo] = {}

    def __enter__(self) -> "TarSource":
        self._tar = tarfile.open(self._archive, "r:gz")
        for member in self._tar.getmembers():
            self._by_name[member.name] = member
            rel = _strip_segments(member.name, self._strip_level)
            if not rel or member.isdir():
                continue
            if member.isreg() or member.issym() or member.islnk():
                self._by_rel[rel] = member
        return self

    def __exit__(self, p_exc_type, p_exc, p_traceback) -> bool:
        if self._tar is not None:
            self._tar.close()
            self._tar = None
        return False

    def paths(self) -> Iterator[str]:
        return iter(self._by_rel)

    def read(self, p_rel: str) -> tuple[bytes, int | None]:
        member = self._resolve(p_rel)
        handle = self._tar.extractfile(member) if self._tar is not None else None
        if handle is None:
            raise ValueError(f"归档条目不可读：{p_rel}")
        with handle:
            return handle.read(), member.mode

    def _resolve(self, p_rel: str) -> tarfile.TarInfo:
        """把链接链解到普通文件；成环、越界、悬空一律报错而不是静默跳过。"""
        member = self._by_rel[p_rel]
        seen: set[str] = set()
        while member.issym() or member.islnk():
            if member.name in seen or len(seen) >= self.MAX_LINK_DEPTH:
                raise ValueError(f"符号链接异常（成环或层数过多）：{p_rel}")
            seen.add(member.name)
            target = member.linkname
            if member.issym():
                target = posixpath.join(posixpath.dirname(member.name), target)
            target = posixpath.normpath(target)
            if target.startswith("..") or target.startswith(SEP):
                raise ValueError(f"链接指向归档外：{member.name} → {member.linkname}")
            resolved = self._by_name.get(target)
            if resolved is None:
                raise ValueError(f"链接目标缺失：{member.name} → {target}")
            member = resolved
        if not member.isreg():
            raise ValueError(f"归档条目不是普通文件：{p_rel}")
        return member


class ZipSource(ArchiveSource):
    """zip 读取（wheel 顶层即 SCons/ 与 dist-info，不剥层）。"""

    def __init__(self, p_archive: str, p_strip_level: int = 0) -> None:
        self._archive = p_archive
        self._strip_level = p_strip_level
        self._zip: zipfile.ZipFile | None = None
        self._by_rel: dict[str, zipfile.ZipInfo] = {}

    def __enter__(self) -> "ZipSource":
        self._zip = zipfile.ZipFile(self._archive)
        for info in self._zip.infolist():
            if info.is_dir():
                continue
            rel = _strip_segments(info.filename, self._strip_level)
            if rel:
                self._by_rel[rel] = info
        return self

    def __exit__(self, p_exc_type, p_exc, p_traceback) -> bool:
        if self._zip is not None:
            self._zip.close()
            self._zip = None
        return False

    def paths(self) -> Iterator[str]:
        return iter(self._by_rel)

    def read(self, p_rel: str) -> tuple[bytes, int | None]:
        if self._zip is None:
            raise ValueError(f"归档未打开：{self._archive}")
        info = self._by_rel.get(p_rel)
        if info is None:
            raise ValueError(f"归档条目缺失：{p_rel}")
        mode = (info.external_attr >> ZIP_MODE_SHIFT) & 0o777
        return self._zip.read(info), (mode or None)


# ── 落盘 ────────────────────────────────────────────────────────────────────
def replace_dir(p_stage: str, p_target: str) -> None:
    """用暂存目录整体替换目标目录；跨卷无法 rename 时退化为复制（与 GDScript 侧同构）。"""
    shutil.rmtree(p_target, ignore_errors=True)
    os.makedirs(os.path.dirname(p_target) or ".", exist_ok=True)
    try:
        os.replace(p_stage, p_target)
    except OSError:
        shutil.copytree(p_stage, p_target)
        shutil.rmtree(p_stage, ignore_errors=True)


def _permissions(p_mode: int | None) -> int:
    """归档权限位保留可执行性（跨卷复制/解包后丢掉 exec 位会让 Linux/macOS 无法启动）。"""
    return EXECUTABLE_MODE if p_mode and p_mode & 0o111 else DEFAULT_FILE_MODE


def materialize(p_source: ArchiveSource, p_target: str,
                p_keeps: Callable[[str], bool]) -> tuple[int, int]:
    """把源里保留的条目写到 p_target：先写暂存目录再整体替换，失败不留半成品。"""
    stage = p_target + ".tmp"
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(stage)
    count = 0
    size = 0
    try:
        for rel in p_source.paths():
            if not p_keeps(rel):
                continue
            data, mode = p_source.read(rel)
            destination = os.path.join(stage, rel.replace(SEP, os.sep))
            os.makedirs(os.path.dirname(destination), exist_ok=True)
            with open(destination, "wb") as fh:
                fh.write(data)
            os.chmod(destination, _permissions(mode))
            count += 1
            size += len(data)
        replace_dir(stage, p_target)
    except BaseException:
        shutil.rmtree(stage, ignore_errors=True)
        raise
    return count, size


# ── 准备 ────────────────────────────────────────────────────────────────────
def download_pbs_asset(p_manifest: Manifest, p_key: str) -> str:
    """下载 PBS 归档到临时文件，返回路径；调用方用完负责删除。"""
    item = p_manifest.asset(p_key)
    url = p_manifest.build_url(URL_PBS_UPSTREAM, p_file=item["file"])
    return download_checked(url, os.path.join(_temp_dir, item["file"]), item["sha256"])


def download_scons_wheel(p_manifest: Manifest) -> str:
    """下载 SCons wheel（清单固定 path 含内容哈希）；调用方用完负责删除。"""
    item = p_manifest.scons()
    url = p_manifest.build_url(URL_PYPI_UPSTREAM, p_path=item["path"])
    return download_checked(url, os.path.join(_temp_dir, item["file"]), item["sha256"])


def prepare_runtime(p_manifest: Manifest, p_platform: str) -> None:
    rules = p_manifest.runtime_rules(p_platform)
    raw = p_manifest.platform_report(p_platform)
    log(f"── {p_platform} 运行时（stdlib 保留 {len(raw.get('stdlib_top_allow') or [])}"
        f"/{raw.get('stdlib_top_total', '?')} 顶层单位，"
        f"全量 {raw.get('files_total', '?')} 文件）")
    if p_platform == "macos":
        prepare_macos_runtime(p_manifest, rules)
        return
    archive = download_pbs_asset(p_manifest, p_platform)
    try:
        with TarSource(archive) as source:
            count, size = materialize(source, platform_dir(p_platform), rules.keeps)
    finally:
        os.remove(archive)
    log(f"  {p_platform}：{count} 文件 {megabytes(size)}")


def prepare_macos_runtime(p_manifest: Manifest, p_rules: RuntimeRules) -> None:
    """两架构归档：主架构落全树，第二架构只补解释器（lipo 只能在 macOS 上做）。"""
    primary_arch = host_arch() if host_platform() == "macos" else DEFAULT_MACOS_ARCH
    secondary_arch = "x64" if primary_arch == "arm64" else "arm64"

    primary = download_pbs_asset(p_manifest, MACOS_ASSETS[primary_arch])
    try:
        with TarSource(primary) as source:
            count, size = materialize(source, platform_dir("macos"), p_rules.keeps)
    finally:
        os.remove(primary)

    secondary_key = MACOS_ASSETS[secondary_arch]
    secondary = download_pbs_asset(p_manifest, secondary_key)
    try:
        note = merge_secondary_interpreter(secondary, platform_dir("macos"), secondary_key)
    finally:
        os.remove(secondary)
    log(f"  macOS：{count} 文件 {megabytes(size)}，{note}")


def merge_secondary_interpreter(p_archive: str, p_target_root: str,
                                p_asset_key: str) -> str:
    """第二架构解释器落到 bin/python3.<arch>；能 lipo 就合并为 universal。

    后缀取自清单资产键（macos_x86_64 → x86_64），与 GDScript 侧
    runtime_provisioner._merge_secondary_runtime 的命名保持一字不差。
    """
    with TarSource(p_archive) as source:
        if INTERPRETER_REL_PATH not in set(source.paths()):
            return "无第二架构解释器"
        data, _mode = source.read(INTERPRETER_REL_PATH)
    suffix = p_asset_key.removeprefix(MACOS_ASSET_PREFIX)
    bin_dir = os.path.join(p_target_root, "bin")
    os.makedirs(bin_dir, exist_ok=True)
    other = os.path.join(bin_dir, "python3." + suffix)
    with open(other, "wb") as fh:
        fh.write(data)
    os.chmod(other, EXECUTABLE_MODE)
    return lipo_interpreters(os.path.join(bin_dir, "python3"), other)


def lipo_interpreters(p_main: str, p_other: str) -> str:
    """在 macOS 主机上把两份单架构解释器合成 universal；否则保留两份待后续合并。"""
    if platform_std.system() != "Darwin" or shutil.which("lipo") is None:
        return "非 macOS 主机：第二架构解释器已就位待合并"
    merged = p_main + ".universal"
    result = subprocess.run(["lipo", "-create", p_main, p_other, "-output", merged],
                            capture_output=True, text=True, check=False)
    if result.returncode:
        return f"lipo 失败：{result.stderr.strip()[:LIPO_ERROR_CHARS]}"
    os.replace(merged, p_main)
    os.remove(p_other)
    return "解释器已 lipo 合并为 universal"


def prepare_site_packages(p_manifest: Manifest) -> None:
    raw = p_manifest.site_report()
    log(f"── SCons {p_manifest.scons().get('version', '?')}"
        f"（保留 {len(raw.get('top_allow') or [])}/{raw.get('top_total', '?')} 顶层单位）")
    wheel = download_scons_wheel(p_manifest)
    try:
        with ZipSource(wheel) as source:
            count, size = materialize(source, SITE_PACKAGES_ROOT,
                                      p_manifest.site_rules().keeps)
    finally:
        os.remove(wheel)
    log(f"  site-packages：{count} 文件 {megabytes(size)}"
        f"（wheel 内 SCons 树 {raw.get('files_total', '?')} 文件，"
        f"排除数据文件 {raw.get('data_files_dropped', '?')} 个）")


# ── 自检 ────────────────────────────────────────────────────────────────────
def selftest_config(p_platform: str) -> dict:
    """自检配置：按平台裁剪导入与编码探针（oem 编码只在 Windows 可用）。"""
    imports = list(SELFTEST_IMPORTS)
    encodings = list(ENCODINGS_PROBE)
    if p_platform == "windows":
        imports += SELFTEST_WINDOWS_ONLY
        encodings += ENCODINGS_WINDOWS_ONLY
    return {
        "imports": imports,
        "encodings": encodings,
        "site_packages": SITE_PACKAGES_ROOT,
        "alias_min_targets": ALIAS_MIN_TARGETS,
    }


def selftest_env() -> dict:
    """隔离子进程环境：UTF-8 输出、不读宿主 site-packages、不写字节码。

    最后一项是必需的：自检直接跑刚裁剪出的 python/ 树，写进去的 __pycache__
    会留在生成物里被打包进 PCK。
    """
    return dict(os.environ, PYTHONUTF8="1", PYTHONIOENCODING="utf-8",
                PYTHONNOUSERSITE="1", PYTHONDONTWRITEBYTECODE="1")


def run_probe(p_python: str, p_config: dict) -> tuple[bool, str]:
    """跑导入/编码探针；配置走临时 JSON，避开命令行长度上限。"""
    handle, config_path = tempfile.mkstemp(prefix="selftest_", suffix=".json")
    os.close(handle)
    try:
        with open(config_path, "w", encoding="utf-8") as fh:
            json.dump(p_config, fh)
        result = subprocess.run([p_python, "-c", SELFTEST_CODE, config_path],
                                capture_output=True, text=True, env=selftest_env(),
                                cwd=PROJECT_DIR, check=False)
    finally:
        os.remove(config_path)
    output = ((result.stdout or "") + (result.stderr or "")).strip()
    return (not result.returncode and output.startswith("OK")), output


def run_scons_version(p_python: str) -> tuple[bool, str]:
    """以 SCons 自己的入口跑 --version，验证站点包能被真正加载。"""
    boot = ("import sys; sys.path.insert(0, r'%s'); "
            "import SCons.Script; SCons.Script.main()" % SITE_PACKAGES_ROOT)
    result = subprocess.run([p_python, "-c", boot, "--version"],
                            capture_output=True, text=True, env=selftest_env(),
                            cwd=PROJECT_DIR, check=False)
    output = (result.stdout or "") + (result.stderr or "")
    return (not result.returncode and "SCons: v" in output), output


def describe_failure(p_output: str, p_fallback: str) -> str:
    return p_output[-FAILURE_TAIL_CHARS:] if p_output else p_fallback


def verify_all_platforms(p_manifest: "Manifest") -> None:
    """逐个平台核对保留集声明的文件是否都已落盘（不执行二进制，故可跨平台）。

    宿主平台由 verify() 实际运行验证；其余平台无法在本机执行，但「清单声明要保留的
    文件是否真的在」是纯文件检查，可在任意宿主完成——这是清单漏项 / 归档变动的
    唯一跨平台防线。

    取清单**原文**而非 RuntimeRules.allow_files：后者为大小写不敏感判定做了小写化，
    用它拼落盘路径会在大小写敏感的文件系统上误报（如 Lib/ → lib/）。
    """
    for platform in ALL_PLATFORMS:
        declared = p_manifest.platform_report(platform).get("stdlib_allow_files") or []
        base = platform_dir(platform)
        if not os.path.isdir(base):
            die(f"完整性检查失败：{platform} 运行时目录缺失 {base}")
        missing = [rel for rel in declared
                   if not os.path.isfile(os.path.join(base, str(rel).replace(SEP, os.sep)))]
        if missing:
            die(f"完整性检查失败（{platform}）：清单声明保留但未落盘 {len(missing)} 个文件，"
                f"前 5 个：{missing[:5]}")
        log(f"  {platform}：清单声明的 {len(declared)} 个文件全部就位")


def verify() -> None:
    """在宿主平台实跑自检；其余平台做文件完整性核对。"""
    platform = host_platform()
    python = interpreter_path(platform)
    if not os.path.isfile(python):
        die(f"自检失败：解释器缺失 {python}")

    config = selftest_config(platform)
    ok, output = run_probe(python, config)
    if not ok:
        die("自检失败（探针模块不在保留集，或裁剪过度）：\n"
            + describe_failure(output, "解释器未输出任何内容"))

    ok, output = run_scons_version(python)
    if not ok:
        die("自检失败（scons --version）：\n" + describe_failure(output, "SCons 未输出任何内容"))

    log(f"  自检通过：{len(config['imports'])} 个模块可导入，"
        f"{len(config['encodings'])} 种编码可查表，scons --version 正常，aliases 表完整")


# ── 入口 ────────────────────────────────────────────────────────────────────
def main() -> int:
    global _temp_dir
    manifest = Manifest.load()
    # 归档只解不改，下完即弃：CI 每次都是干净环境，留缓存没有意义
    _temp_dir = tempfile.mkdtemp(prefix="fetch_python_runtime_")
    try:
        for platform in ALL_PLATFORMS:
            prepare_runtime(manifest, platform)
        prepare_site_packages(manifest)
    finally:
        shutil.rmtree(_temp_dir, ignore_errors=True)
    # 先做全平台文件核对（纯 I/O，能跨平台），再在宿主平台实跑自检
    verify_all_platforms(manifest)
    verify()
    log("完成。python/ 是生成物、不入库；规则只改 python_runtime_manifest.json。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
