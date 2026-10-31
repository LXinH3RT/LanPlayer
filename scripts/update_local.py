#!/usr/bin/env python3
"""把本机装着的 LanPlayer 换成当前这棵树编出来的版本。

用户的要求（2026-10-31）：**每次代码更新后，都把本机软件更新到最新版，
用本地版本号**。所以这个脚本要能被随手跑，不需要记四条命令、也不该
让人去想版本号该写多少。

它把 `scripts/` 里已有的三个步骤串起来：

1. `build_windows.py`          —— 编 C 内核（没改内核时也很快，增量）
2. `build_windows_desktop.py`  —— 编 Flutter 桌面端，把版本号当 dart-define 注入
3. `build_windows_installer.py`—— 打包成 NSIS 安装包
4. `install_local_windows.py`  —— 装到本机并核对

版本号按 `AgentsReadMe.md` §8.0 的规矩走：**正式版本号只在发 GitHub 时动**，
平时的构建用本地号 `<pubspec 版本>-local.<N>`，N 从 `dist/` 里已用过的最大
值往后加一。这样设置页「关于」里一眼就能看出装的是哪次构建，而 pubspec
保持不动。
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))

import lpscript as lp  # noqa: E402


def next_local_version(base: str) -> str:
    """`0.1.7` -> `0.1.7-local.8`，按 dist/ 里已有的包往后接。

    只看本地产物名，不看 pubspec 也不看 git tag —— 本号码的意义就是
    「这台机器上第几次构建」，跟发布版本无关。
    """
    used = [
        int(m.group(1))
        for p in lp.DIST.glob("LanPlayer-*-local.*-windows-x64-setup.exe")
        if (m := re.search(r"-local\.(\d+)-", p.name))
    ]
    return f"{base}-local.{max(used, default=0) + 1}"


def run(cmd: list[str]) -> None:
    print(f"\n$ {' '.join(cmd)}", flush=True)
    result = subprocess.run(cmd, cwd=lp.ROOT)
    if result.returncode != 0:
        raise lp.ScriptError(f"{cmd[0]} exited {result.returncode}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Rebuild this checkout and install it over the local copy.")
    parser.add_argument("--version", default="",
                        help="用指定的本地版本号（默认自动接上一个）")
    parser.add_argument("--out-dir", default=r"D:\LanPlayer",
                        help="安装到哪个目录")
    parser.add_argument("--skip-kernel", action="store_true",
                        help="跳过 build_windows.py（只改了 Dart 时能省几秒）")
    args = parser.parse_args()

    # 用当前解释器跑后续步骤：这套脚本必须用 .tools/python 那份（没有 pip、
    # 但有 Pillow 之外的依赖都在标准库里），换成别人启动的 python 会缺模块。
    py = sys.executable
    base = lp.pubspec_version().split("+", 1)[0]
    version = args.version or next_local_version(base)
    print(f"local version: {version}  (pubspec stays {lp.pubspec_version()})")

    if not args.skip_kernel:
        run([py, str(lp.ROOT / "scripts/build_windows.py")])
    run([py, str(lp.ROOT / "scripts/build_windows_desktop.py"), "--version", version])
    run([py, str(lp.ROOT / "scripts/build_windows_installer.py"), "--version", version])

    setup = lp.DIST / f"LanPlayer-{version}-windows-x64-setup.exe"
    if not setup.exists():
        raise lp.ScriptError(f"installer was not produced: {setup}")
    run([py, str(lp.ROOT / "scripts/install_local_windows.py"),
         "--setup", str(setup), "--out-dir", args.out_dir])

    print(f"\ndone: {version} installed to {args.out_dir}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except lp.ScriptError as exc:
        print(f"!! {exc}")
        sys.exit(1)
