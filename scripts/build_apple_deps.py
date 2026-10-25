#!/usr/bin/env python3
"""Build FFmpeg + libsmb2 + the LanPlayer C core for iOS (device + simulator)
and macOS into native/third_party/, matching the layout from docs/build.md.

    python scripts/build_apple_deps.py            # macOS (the usual desktop build)
    SLICES=iphoneos python scripts/build_apple_deps.py
    SLICES="iphoneos iphonesimulator" python scripts/build_apple_deps.py
    ARCHS=x86_64 python scripts/build_apple_deps.py   # Intel Mac
    FORCE=1 python scripts/build_apple_deps.py        # ignore the FFmpeg cache

Output layout - one directory per platform family, so macOS and iOS archives can
coexist in one working copy:

    native/third_party/ffmpeg/apple/<family>/{include,lib}   libav*.a, libsw*.a
    native/third_party/libsmb2/apple/<family>/{include,lib}  libsmb2.a
    native/third_party/lanplayer/apple/<family>/lib          liblanplayer.a

where <family> is macosx / iphoneos / iphonesimulator.  A copy of the family
built last also lands in the old flat apple/lib path (with an apple/lib/.family
marker) so a checkout that never ran this script for its own family still
links, and so one-shot CI jobs keep working.

The core is built here (rather than by CocoaPods) on purpose: this script
already has to run on the Mac for FFmpeg and libsmb2, and a plain `ar` of our
own translation units is far easier to debug than a pod that globs sources from
outside its own directory.
"""
from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tool"))
import lpscript as lp  # noqa: E402

FFMPEG_LIBS = ["avformat", "avcodec", "avutil", "swresample", "swscale", "avfilter"]

# Only the platform-independent core plus the Apple adapters.  platform/android
# and platform/win32 need their own system headers, and platform/stub would
# clash with the symbols platform/apple defines.
CORE_SOURCES = [
    "native/src/util/lp_str.c",
    "native/src/util/lp_log.c",
    "native/src/core/queue.c",
    "native/src/core/audio_ring.c",
    "native/src/core/nal.c",
    "native/src/core/demux.c",
    "native/src/core/video.c",
    "native/src/core/audio.c",
    "native/src/core/subtitle.c",
    "native/src/core/thumb.c",
    "native/src/core/player.c",
    "native/src/source/url.c",
    "native/src/source/io.c",
    "native/src/source/smb.c",
    "native/src/source/file.c",
    "native/src/platform/apple/videotoolbox_decoder.c",
    "native/src/platform/apple/coreaudio_sink.c",
    "native/src/platform/apple/apple_texture.c",
]


def jobs() -> str:
    return lp.output(["sysctl", "-n", "hw.ncpu"]) or str(os.cpu_count() or 4)


def curl(url: str, dest: Path) -> bool:
    dest.parent.mkdir(parents=True, exist_ok=True)
    result = lp.run(["curl", "-fsSL", "--retry", "5", "--retry-delay", "5",
                     "--retry-all-errors", url, "-o", str(dest)], check=False, capture=True)
    if result.returncode != 0:
        lp.warn(f"curl failed for {url} ({(result.stderr or '').strip()[-200:]})")
        return False
    return True


def fetch_ffmpeg(work: Path, version: str) -> Path:
    tree = work / f"ffmpeg-{version}"
    if tree.is_dir():
        return tree

    tarball = work / "ffmpeg.tar.xz"
    if curl(f"https://ffmpeg.org/releases/ffmpeg-{version}.tar.xz", tarball):
        lp.run(["tar", "xf", str(tarball), "-C", str(work)])
        return tree

    # ffmpeg.org is unreachable from the hosted runners often enough to be a
    # nuisance ("Could not resolve host: ffmpeg.org"), so fall back to the
    # GitHub mirror of the same release tag.  GitHub names the archive
    # directory after the tag (FFmpeg-n6.1.1), hence the rename.
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


def slice_spec(slice_name: str, min_ios: str, min_macos: str) -> dict:
    """SDK, sysroot, deployment target and the -m…version-min flag for a slice."""
    if slice_name not in ("iphoneos", "iphonesimulator", "macosx"):
        raise lp.ScriptError(f"unknown slice {slice_name}")
    sdk = slice_name
    sysroot = lp.output(["xcrun", "--sdk", sdk, "--show-sdk-path"])
    if not sysroot:
        raise lp.ScriptError(f"xcrun cannot find the {sdk} SDK")
    ios = sdk.startswith("iphone")
    deploy = min_ios if ios else min_macos
    if sdk == "iphonesimulator":
        # 模拟器必须用 -mios-simulator-version-min；用 -miphoneos-version-min 会在
        # clang 里触发 "overriding deployment target" 警告，个别 Xcode 版本会把它
        # 升级成错误。
        flag = f"-mios-simulator-version-min={deploy}"
    elif ios:
        flag = f"-miphoneos-version-min={deploy}"
    else:
        flag = f"-mmacosx-version-min={deploy}"
    return {"sdk": sdk, "sysroot": sysroot, "deploy": deploy, "flag": flag}


def build_ffmpeg(src: Path, work: Path, slice_name: str, spec: dict,
                 primary_arch: str, force: bool) -> Path:
    prefix = work / f"ff-{slice_name}"
    if (prefix / "lib" / "libavcodec.a").exists() and not force:
        # FFmpeg takes a long time to build and most reruns fail on a later
        # step, so an existing archive is reused unless FORCE=1.
        lp.note(f"== FFmpeg {slice_name} (cached)")
        return prefix

    lp.step(f"FFmpeg {slice_name}")
    build = work / f"ffbuild-{slice_name}"
    shutil.rmtree(build, ignore_errors=True)
    build.mkdir(parents=True)

    cc = ["xcrun", "-sdk", spec["sdk"], "clang", "-arch", primary_arch, spec["flag"]]
    configure = [
        str(src / "configure"),
        f"--prefix={prefix}", "--target-os=darwin", f"--arch={primary_arch}",
        "--enable-cross-compile", f"--sysroot={spec['sysroot']}",
        f"--cc={' '.join(cc)}", "--pkg-config=/usr/bin/false",
        "--enable-static", "--disable-shared", "--disable-programs", "--disable-doc",
        "--disable-avdevice", "--disable-postproc",
        "--enable-videotoolbox", "--enable-audiotoolbox",
        "--extra-cflags=-Wno-error=unguarded-availability-new",
        "--disable-filters",
        "--enable-filter=abuffer,abuffersink,buffer,buffersink,atempo,yadif,scale,format,aresample",
        "--enable-demuxer=matroska,mov,avi,mpegts,flv,mp3,aac,flac,wav,ogg,ass,srt,webvtt",
        "--enable-decoder=h264,hevc,vp8,vp9,av1,mpeg4,mpeg2video,aac,mp3,ac3,eac3,dts,flac,opus,vorbis,ass,subrip,webvtt",
        "--enable-protocol=file,http,https,tcp,tls",
    ]
    lp.run(configure, cwd=build)
    lp.run(["make", f"-j{jobs()}"], cwd=build)
    lp.run(["make", "install"], cwd=build)
    return prefix


def build_libsmb2(src: Path, work: Path, slice_name: str, spec: dict,
                  primary_arch: str) -> Path:
    """libsmb2 as a static archive; returns its build directory."""
    lp.step(f"libsmb2 {slice_name}")
    build = work / f"smb-{slice_name}"
    shutil.rmtree(build, ignore_errors=True)
    out = work / f"smb-out-{slice_name}"
    ios = spec["sdk"].startswith("iphone")

    # Why GSSAPI and OpenSSL must be disabled:
    #   libsmb2's CMakeLists unconditionally finds both.  macOS ships
    #   libgssapi_krb5 and gssapi/gssapi.h, so HAVE_LIBKRB5 gets defined and
    #   lib/krb5-wrapper.c starts using gss_const_OID,
    #   gss_acquire_cred_with_password, gss_set_neg_mechs,
    #   gss_inquire_sec_context_by_oid, GSS_C_INQ_SSPI_SESSION_KEY and
    #   gss_release_buffer_set - extensions of MIT/Heimdal krb5 that Apple's
    #   GSS.framework does not have; Xcode 15 and later make implicit function
    #   declarations hard errors, so that is 18 errors at once.  With Homebrew
    #   installed OpenSSL is found too, leaving libcrypto symbols in the static
    #   archive that the app never links.
    #   Only NTLM (user + password) is needed, no Kerberos and no SMB3
    #   transport encryption, so both probes are switched off and libsmb2 uses
    #   its own AES/MD4/HMAC implementation.
    #   CMAKE_DISABLE_FIND_PACKAGE_<pkg> is a standard cache variable that makes
    #   the matching find_package fail (not fatally), which is more reliable
    #   than -DGSSAPI_FOUND=FALSE.
    # CMAKE_POLICY_VERSION_MINIMUM=3.5: libsmb2 v4.0.0 asks for
    # cmake_minimum_required 3.2, and CMake 4.x (what Homebrew installs now)
    # dropped compatibility below 3.5, so configuring fails with
    # "Compatibility with CMake < 3.5 has been removed".  The variable exists
    # since CMake 3.31; older CMake only warns "Manually-specified variables
    # were not used", so passing it unconditionally is safe.
    lp.run([
        "cmake", "-S", str(src), "-B", str(build),
        f"-DCMAKE_SYSTEM_NAME={'iOS' if ios else 'Darwin'}",
        f"-DCMAKE_OSX_SYSROOT={spec['sdk']}",
        f"-DCMAKE_OSX_ARCHITECTURES={primary_arch}",
        f"-DCMAKE_OSX_DEPLOYMENT_TARGET={spec['deploy']}",
        f"-DCMAKE_INSTALL_PREFIX={out}",
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
        "-DCMAKE_DISABLE_FIND_PACKAGE_GSSAPI=TRUE",
        "-DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=TRUE",
        "-DBUILD_SHARED_LIBS=OFF", "-DCMAKE_BUILD_TYPE=Release",
    ])
    lp.run(["cmake", "--build", str(build), f"-j{jobs()}"])
    lp.run(["cmake", "--install", str(build)])
    return build


def build_core(root: Path, work: Path, slice_name: str, spec: dict,
               primary_arch: str) -> Path:
    lp.step(f"LanPlayer core {slice_name}")
    build = work / f"lp-{slice_name}"
    shutil.rmtree(build, ignore_errors=True)
    build.mkdir(parents=True)

    common = [
        "xcrun", "-sdk", spec["sdk"], "clang",
        "-arch", primary_arch, spec["flag"],
        "-std=gnu11", "-O2", "-fPIC", "-fblocks",
        "-DNDEBUG",
        "-DLP_PLATFORM_APPLE=1",
        "-DLP_HAVE_ICONV=1",
        "-DLP_HAVE_SMB2=1",
        "-DLP_ENABLE_HTTP=1",
        "-D_FILE_OFFSET_BITS=64",
        "-D_GNU_SOURCE",
        f"-I{root / 'native' / 'include'}",
        f"-I{root / 'native' / 'src'}",
        f"-I{root / 'native' / 'src' / 'source'}",
        f"-I{work / f'ff-{slice_name}' / 'include'}",
        f"-I{work / 'libsmb2' / 'include'}",
    ]
    objects: list[str] = []
    for relative in CORE_SOURCES:
        obj = build / (Path(relative).stem + ".o")
        lp.run([*common, "-c", str(root / relative), "-o", str(obj)])
        objects.append(str(obj))

    lp.run(["xcrun", "--sdk", spec["sdk"], "libtool", "-static",
            "-o", str(build / "liblanplayer.a"), *objects])
    print(f"== ar liblanplayer.a ({slice_name}) <- {len(objects)} object(s)")
    return build / "liblanplayer.a"


def lipo_one(name: str, inputs: list[Path], outdir: Path) -> None:
    if not inputs:
        lp.warn(f"lib{name}.a not found, skipped")
        return
    outdir.mkdir(parents=True, exist_ok=True)
    lp.run(["lipo", "-create", *[str(p) for p in inputs],
            "-output", str(outdir / f"lib{name}.a")])
    print(f"== lipo lib{name}.a <- {len(inputs)} slice(s)")


def main() -> int:
    if sys.platform != "darwin":
        raise lp.ScriptError("Apple dependency builds need macOS")

    root = lp.ROOT
    out = root / "native" / "third_party"
    work = Path(os.environ.get("WORK", str(root / "build" / "deps")))
    ffmpeg_version = os.environ.get("FFMPEG_VERSION", "6.1.1")
    smb2_version = os.environ.get("LIBSMB2_VERSION", "v4.0.0")
    slices = os.environ.get("SLICES", "macosx").split()
    archs = os.environ.get("ARCHS", "arm64").split()
    min_ios = os.environ.get("MIN_IOS", "15.0")
    min_macos = os.environ.get("MIN_MACOS", "12.0")
    force = os.environ.get("FORCE", "0") == "1"
    # One platform family per output directory.  On Apple silicon iphoneos,
    # iphonesimulator and macosx are all arm64, and lipo refuses to pack two
    # slices with the same architecture into one fat archive ("have the same
    # architectures (arm64)").  Each family therefore gets its own directory.
    family = slices[0]
    primary_arch = archs[0]

    for directory in (work, out / "ffmpeg" / "apple", out / "libsmb2" / "apple"):
        directory.mkdir(parents=True, exist_ok=True)

    ffmpeg_src = fetch_ffmpeg(work, ffmpeg_version)
    smb_src = work / "libsmb2"
    if not smb_src.is_dir():
        lp.run(["git", "clone", "--depth", "1", "--branch", smb2_version,
                "https://github.com/sahlberg/libsmb2", str(smb_src)])

    core_archives: list[Path] = []
    for slice_name in slices:
        spec = slice_spec(slice_name, min_ios, min_macos)
        build_ffmpeg(ffmpeg_src, work, slice_name, spec, primary_arch, force)
        build_libsmb2(smb_src, work, slice_name, spec, primary_arch)
        core_archives.append(build_core(root, work, slice_name, spec, primary_arch))

    # Merge the slices: lipo every static library into one archive per family.
    ff_out = out / "ffmpeg" / "apple" / family / "lib"
    smb_out = out / "libsmb2" / "apple" / family / "lib"
    lp_out = out / "lanplayer" / "apple" / family / "lib"
    for directory in (ff_out, smb_out, lp_out):
        directory.mkdir(parents=True, exist_ok=True)

    for name in FFMPEG_LIBS:
        inputs = [work / f"ff-{s}" / "lib" / f"lib{name}.a" for s in slices]
        lipo_one(name, [p for p in inputs if p.exists()], ff_out)
    smb_inputs = [work / f"smb-out-{s}" / "lib" / "libsmb2.a" for s in slices]
    lipo_one("smb2", [p for p in smb_inputs if p.exists()], smb_out)

    # Our own core: one archive per slice, merged the same way but arch-deduped,
    # so iphoneos arm64 wins over iphonesimulator arm64.
    seen: set[str] = set()
    unique: list[Path] = []
    for archive in core_archives:
        if not archive.exists():
            continue
        arch = lp.output(["lipo", "-archs", str(archive)]).split()
        if arch and arch[0] in seen:
            lp.note(f"== lipo liblanplayer.a: skipping {archive.parent.name} "
                    f"(duplicate {arch[0]})")
            continue
        if arch:
            seen.add(arch[0])
        unique.append(archive)
    if len(unique) == 1:
        shutil.copy2(unique[0], lp_out / "liblanplayer.a")
        print("== copy liblanplayer.a <- 1 slice")
    elif unique:
        lipo_one("lanplayer", unique, lp_out)
    else:
        lp.warn("liblanplayer.a not built, skipped")

    # Backfill the old flat path: the three podspecs still list apple/lib in
    # LIBRARY_SEARCH_PATHS, which keeps one-shot CI jobs and stale checkouts
    # working.  The podspecs prefer the family directory when it exists.
    for library, source in (("ffmpeg", ff_out), ("libsmb2", smb_out),
                            ("lanplayer", lp_out)):
        target = out / library / "apple" / "lib"
        target.mkdir(parents=True, exist_ok=True)
        for archive in sorted(source.glob("*.a")):
            shutil.copy2(archive, target / archive.name)
        (target / ".family").write_text(family + "\n", encoding="utf-8")
    print(f"== staged {family} archives into {out}/*/apple/{family}/lib (+ apple/lib mirror)")

    # Headers: identical across slices, take the first.  Prefer the installed
    # headers (smb-out-*/include) over the source tree's include/: the latter
    # also holds asprintf.h, libsmb2-private.h, Makefile.am, msvc/… which are
    # only needed while building libsmb2 itself, and the app side only wants
    # <smb2/libsmb2.h>.
    first = slices[0]
    for library in ("ffmpeg", "libsmb2"):
        shutil.rmtree(out / library / "apple" / "include", ignore_errors=True)
        (out / library / "apple" / "include").mkdir(parents=True, exist_ok=True)
    shutil.copytree(work / f"ff-{first}" / "include",
                    out / "ffmpeg" / "apple" / "include", dirs_exist_ok=True)
    smb_headers = work / f"smb-out-{first}" / "include"
    shutil.copytree(smb_headers if smb_headers.is_dir() else smb_src / "include",
                    out / "libsmb2" / "apple" / "include", dirs_exist_ok=True)
    # Also keep a copy under the family so the podspec needs no second guess.
    for library in ("ffmpeg", "libsmb2"):
        shutil.rmtree(out / library / "apple" / family / "include", ignore_errors=True)
        shutil.copytree(out / library / "apple" / "include",
                        out / library / "apple" / family / "include", dirs_exist_ok=True)

    # lanplayer_core.podspec lists the seven FFmpeg libraries in its own order
    # and does not need libpostproc (configure has --disable-postproc); avdevice
    # is never referenced by the core either (checked with grep), so it must not
    # appear in the podspec.
    print(f"done: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(lp.main(main))
