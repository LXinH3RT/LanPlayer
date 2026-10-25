#!/usr/bin/env python3
"""Cross-compile FFmpeg and libsmb2 for Android into native/third_party/.

    ANDROID_NDK_HOME=<ndk> python scripts/build_android_deps.py [abi...]

Default ABIs: arm64-v8a armeabi-v7a.  The output layout matches what
native/CMakeLists.txt expects (see docs/build.md).
"""
from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))
import lpscript as lp  # noqa: E402

FFMPEG_ABIS = {
    "arm64-v8a": ("arm64", "armv8-a", "aarch64-linux-android"),
    "armeabi-v7a": ("arm", "armv7-a", "armv7a-linux-androideabi"),
    "x86_64": ("x86_64", "x86-64", "x86_64-linux-android"),
}


def jobs() -> str:
    return str(os.cpu_count() or 4)


def curl(url: str, dest: Path) -> bool:
    """Download with retries; False when curl gives up."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    result = lp.run(["curl", "-fsSL", "--retry", "5", "--retry-delay", "5",
                     "--retry-all-errors", url, "-o", str(dest)], check=False, capture=True)
    if result.returncode != 0:
        lp.warn(f"curl failed for {url} ({(result.stderr or '').strip()[-200:]})")
        return False
    return True


def fetch(url: str, dest: Path) -> None:
    if dest.exists():
        return
    lp.step(f"fetching {url}")
    if not curl(url, dest):
        raise lp.ScriptError(f"cannot download {url}")


def fetch_ffmpeg(work: Path, version: str) -> Path:
    """The extracted FFmpeg source tree, from ffmpeg.org or the GitHub mirror."""
    tree = work / f"ffmpeg-{version}"
    if tree.is_dir():
        return tree

    tarball = work / "ffmpeg.tar.xz"
    if curl(f"https://ffmpeg.org/releases/ffmpeg-{version}.tar.xz", tarball):
        lp.run(["tar", "xf", str(tarball), "-C", str(work)])
        return tree

    # ffmpeg.org has been flaky from CI runners ("Could not resolve host"), so
    # fall back to the GitHub mirror of the same release tag.  GitHub names the
    # archive directory after the tag (FFmpeg-n6.1.1), hence the rename.
    lp.warn("ffmpeg.org unreachable, falling back to the GitHub mirror")
    archive = work / "ffmpeg.tar.gz"
    if not curl(f"https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/tags/n{version}", archive):
        raise lp.ScriptError("cannot download FFmpeg from either source")
    lp.run(["tar", "xf", str(archive), "-C", str(work)])
    candidates = sorted(p for p in work.glob("FFmpeg-*") if p.is_dir())
    if not candidates:
        raise lp.ScriptError("ffmpeg tarball extracted nowhere")
    candidates[0].rename(tree)
    return tree


def build_ffmpeg(src: Path, work: Path, out: Path, abi: str, api: str,
                 toolchain: Path) -> Path:
    arch, cpu, triple = FFMPEG_ABIS[abi]
    cc = toolchain / "bin" / f"{triple}{api}-clang"
    cxx = toolchain / "bin" / f"{triple}{api}-clang++"
    prefix = out / "ffmpeg" / "android" / f"x-{abi}"

    lp.step(f"FFmpeg for {abi}")
    build = work / f"ffbuild-{abi}"
    shutil.rmtree(build, ignore_errors=True)
    build.mkdir(parents=True)

    configure = [
        str(src / "configure"),
        f"--prefix={prefix}", "--target-os=android", f"--arch={arch}", f"--cpu={cpu}",
        "--enable-cross-compile", f"--sysroot={toolchain / 'sysroot'}",
        f"--cc={cc}", f"--cxx={cxx}",
        f"--ar={toolchain / 'bin' / 'llvm-ar'}",
        f"--nm={toolchain / 'bin' / 'llvm-nm'}",
        f"--strip={toolchain / 'bin' / 'llvm-strip'}",
        f"--ranlib={toolchain / 'bin' / 'llvm-ranlib'}",
        "--enable-shared", "--disable-static", "--disable-programs", "--disable-doc",
        "--disable-avdevice", "--disable-postproc", "--disable-swscale-alpha",
        "--enable-jni", "--enable-mediacodec",
        "--enable-filter=atempo,yadif,scale,format,aresample",
        "--enable-demuxer=matroska,mov,avi,mpegts,flv,mp3,aac,flac,wav,ogg,ass,srt,webvtt",
        "--enable-decoder=h264,hevc,vp8,vp9,av1,mpeg4,mpeg2video,aac,mp3,ac3,eac3,dts,flac,opus,vorbis,ass,subrip,webvtt",
        "--enable-parser=h264,hevc,vp9,av1,mpegaudio,aac",
        "--enable-protocol=file,http,https,tcp,tls",
        "--enable-small",
    ]
    lp.run(configure, cwd=build)
    lp.run(["make", f"-j{jobs()}"], cwd=build)
    lp.run(["make", "install"], cwd=build)
    return prefix


def build_libsmb2(src: Path, ndk: Path, work: Path, out: Path, abi: str, api: str) -> Path:
    lp.step(f"libsmb2 for {abi}")
    build = work / f"smb-{abi}"
    shutil.rmtree(build, ignore_errors=True)
    # libsmb2's CMake probes for OpenSSL and GSSAPI; the NDK sysroot has
    # neither, so find_package() leaves OPENSSL_INCLUDE_DIR as NOTFOUND and the
    # generate step dies.  Only plain SMB2/SMB3 is needed, so both probes are
    # turned off explicitly.  CMAKE_POLICY_VERSION_MINIMUM covers libsmb2's
    # cmake_minimum_required(2.8.12) being rejected by CMake >= 4.
    lp.run([
        "cmake", "-S", str(src), "-B", str(build),
        f"-DCMAKE_TOOLCHAIN_FILE={ndk / 'build' / 'cmake' / 'android.toolchain.cmake'}",
        f"-DANDROID_ABI={abi}", f"-DANDROID_PLATFORM=android-{api}",
        f"-DCMAKE_INSTALL_PREFIX={out / 'libsmb2' / 'android'}",
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
        "-DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=TRUE",
        "-DCMAKE_DISABLE_FIND_PACKAGE_GSSAPI=TRUE",
        "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=ON",
    ])
    lp.run(["cmake", "--build", str(build), f"-j{jobs()}"])
    return build


def stage(prefix: Path, smb_build: Path, smb_src: Path, out: Path, abi: str) -> None:
    """Copy the built libraries into the layout CMake and Gradle expect."""
    # Layout expected by CMake: <root>/android/<abi>/lib/<abi>/*.so + include/
    ffabi = out / "ffmpeg" / "android" / abi
    (ffabi / "lib" / abi).mkdir(parents=True, exist_ok=True)
    for so in sorted((prefix / "lib").glob("*.so*")):
        shutil.copy2(so, ffabi / "lib" / abi / so.name)
    shutil.copytree(prefix / "include", ffabi / "include", dirs_exist_ok=True)

    # libsmb2's install puts everything in one prefix, so copy per ABI.
    (out / "libsmb2" / "android" / "lib" / abi).mkdir(parents=True, exist_ok=True)
    for so in sorted(smb_build.rglob("libsmb2*.so*")):
        shutil.copy2(so, out / "libsmb2" / "android" / "lib" / abi / so.name)
    # Headers come from the source clone, not the build tree.
    shutil.copytree(smb_src / "include", out / "libsmb2" / "android" / "include",
                    dirs_exist_ok=True)

    # Gradle only packages libraries that live in a jniLibs directory, and the
    # CMake IMPORTED targets are not copied into the APK by AGP.  Stage a
    # jniLibs-friendly tree (<root>/<abi>/*.so) for app/build.gradle.kts.
    jni = out / "jniLibs" / abi
    jni.mkdir(parents=True, exist_ok=True)
    for so in sorted((prefix / "lib").glob("*.so*")):
        shutil.copy2(so, jni / so.name)
    for so in sorted(smb_build.rglob("libsmb2*.so*")):
        shutil.copy2(so, jni / so.name)


def main() -> int:
    ndk = os.environ.get("ANDROID_NDK_HOME") or os.environ.get("ANDROID_NDK_ROOT") or ""
    if not ndk:
        raise lp.ScriptError("ANDROID_NDK_HOME is not set")
    ndk_path = Path(ndk)

    out = lp.ROOT / "native" / "third_party"
    work = Path(os.environ.get("WORK", str(lp.ROOT / "build" / "deps")))
    api = os.environ.get("API", "26")
    ffmpeg_version = os.environ.get("FFMPEG_VERSION", "6.1.1")
    smb2_version = os.environ.get("LIBSMB2_VERSION", "v4.0.0")

    import platform
    host_tag = "darwin-x86_64" if platform.system() == "Darwin" else "linux-x86_64"
    toolchain = ndk_path / "toolchains" / "llvm" / "prebuilt" / host_tag
    if not toolchain.is_dir():
        raise lp.ScriptError(f"NDK toolchain not found at {toolchain}")

    abis = sys.argv[1:] or ["arm64-v8a", "armeabi-v7a"]
    for abi in abis:
        if abi not in FFMPEG_ABIS:
            raise lp.ScriptError(f"unsupported ABI {abi} (choose from {', '.join(FFMPEG_ABIS)})")

    for directory in (work, out / "ffmpeg" / "android", out / "libsmb2" / "android"):
        directory.mkdir(parents=True, exist_ok=True)

    ffmpeg_src = fetch_ffmpeg(work, ffmpeg_version)

    smb_src = work / "libsmb2"
    if not smb_src.is_dir():
        lp.run(["git", "clone", "--depth", "1", "--branch", smb2_version,
                "https://github.com/sahlberg/libsmb2", str(smb_src)])

    for abi in abis:
        prefix = build_ffmpeg(ffmpeg_src, work, out, abi, api, toolchain)
        smb_build = build_libsmb2(smb_src, ndk_path, work, out, abi, api)
        stage(prefix, smb_build, smb_src, out, abi)

    print(f"done: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(lp.main(main))
