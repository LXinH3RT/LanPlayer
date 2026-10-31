#!/usr/bin/env python3
"""解析 native/sources.cmake，给构建脚本一份和 CMake 完全一致的源文件清单。

设计动机：内核的源文件清单以前被抄在三个地方（native/CMakeLists.txt、
scripts/build_windows.py、scripts/build_apple_deps.py）。新增一个 .c 要改三处，
漏掉哪一处都会变成「本地编得过、CI 里符号找不到」。现在清单只在
native/sources.cmake 里写一次，CMake 直接 include 它，两个构建脚本用这里的
解析函数读同一份文本 —— 是同一个来源，不是第二次抄写。

用法::

    from native_sources import load_sources
    groups = load_sources()               # {"LP_CORE_SOURCES": [...], ...}
    core = groups["LP_CORE_SOURCES"]      # ["src/util/lp_str.c", ...]
    core_abs = groups.resolve("LP_CORE_SOURCES")   # 绝对路径

路径一律相对 native/，与 CMake 的 set() 写法一致，两个脚本各自拼前缀即可。
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = ROOT / "native" / "sources.cmake"

# set(LP_FOO_SOURCES <条目...>)，条目可以带行内注释，也可以跨行。
_SET = re.compile(r"\bset\(\s*(LP_[A-Z0-9_]+)\s+(.*?)\)", re.S)
_COMMENT = re.compile(r"#[^\n]*")


class SourceManifest:
    """一份解析好的 CLI 清单：组名 -> 相对 native/ 的源文件列表。"""

    def __init__(self, groups: dict[str, list[str]], path: Path):
        self._groups = groups
        self.path = path

    def __getitem__(self, name: str) -> list[str]:
        try:
            return list(self._groups[name])
        except KeyError:
            known = ", ".join(sorted(self._groups))
            raise KeyError(f"{self.path.name} has no group '{name}' (known: {known})") from None

    def get(self, name: str, default: list[str] | None = None) -> list[str]:
        value = self._groups.get(name)
        return list(default or []) if value is None else list(value)

    def resolve(self, name: str) -> list[Path]:
        base = self.path.parent
        return [base / rel for rel in self[name]]

    def names(self) -> list[str]:
        return sorted(self._groups)

    def all_sources(self) -> list[str]:
        seen: list[str] = []
        for group in self._groups.values():
            for rel in group:
                if rel not in seen:
                    seen.append(rel)
        return seen


def load_sources(path: Path | None = None) -> SourceManifest:
    """读清单。文件缺失或某个 set() 一条源文件都没有都算错误。"""
    manifest = path or DEFAULT_MANIFEST
    if not manifest.is_file():
        raise FileNotFoundError(f"native source manifest not found: {manifest}")
    text = _COMMENT.sub("", manifest.read_text(encoding="utf-8"))
    groups: dict[str, list[str]] = {}
    for match in _SET.finditer(text):
        name, body = match.group(1), match.group(2)
        entries = [tok for tok in re.split(r"[\s;]+", body) if tok]
        # 只认源文件：set() 里也可能出现 CMake 变量，那些以 ${ 开头。
        groups[name] = [e for e in entries if not e.startswith("${")]
    if not groups:
        raise ValueError(f"{manifest.name} defines no LP_*_SOURCES group")
    empty = [name for name, entries in groups.items() if not entries]
    if empty:
        raise ValueError(f"{manifest.name}: empty group(s) {', '.join(empty)}")
    return SourceManifest(groups, manifest)


def _main() -> int:
    """`python tool/native_sources.py` 打印分组，方便人工核对。"""
    manifest = load_sources()
    print(f"{manifest.path.relative_to(ROOT)}")
    for name in manifest.names():
        entries = manifest[name]
        print(f"  {name} ({len(entries)})")
        for rel in entries:
            print(f"    {rel}")
    print(f"unique sources: {len(manifest.all_sources())}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
