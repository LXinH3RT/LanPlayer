/*
 * 这个头文件的唯一作用，是给 CocoaPods 一个真实存在的源文件锚点。
 *
 * lanplayer_core.podspec 的 s.source_files 指向 Classes/**\/*.h，但本 pod 真正
 * 要分发的是 native/ 下预编译好的 liblanplayer.a 与 lanplayer/*.h（见
 * s.preserve_paths 与 s.user_target_xcconfig）。CocoaPods 要求 source_files
 * 至少匹配到一个文件，否则部分版本会报 "The `lanplayer_core` pod failed to
 * validate" 并中止 pod install。
 *
 * 不要往这里放任何被编译的代码：C 源码的编译入口是
 * scripts/build_apple_deps.py。
 */
#ifndef LANPLAYER_CORE_POD_ANCHOR_H
#define LANPLAYER_CORE_POD_ANCHOR_H

#endif /* LANPLAYER_CORE_POD_ANCHOR_H */
