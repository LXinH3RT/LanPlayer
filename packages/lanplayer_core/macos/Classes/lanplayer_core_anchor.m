// lanplayer_core（macOS）的锚点编译单元。
//
// 它没有任何运行时逻辑，唯一作用是让 CocoaPods 有一个真正可编译的 .m 文件，
// 从而在 pod 构建阶段就验证 HEADER_SEARCH_PATHS 是否指对了 native/include。
// 如果这里报 "lanplayer/lp_player.h file not found"，说明 podspec 里的路径算错了，
// 不用等到链接 app 才发现。
//
// 真正的实现全在 native/third_party/lanplayer/apple/lib/liblanplayer.a 里。

#import <Foundation/Foundation.h>

#include "lanplayer/lp_player.h"

// 导出给 app 一个常量，方便在 Xcode 里确认这个 pod 真的进了二进制。
// 不用它也没关系，符号会被静态链接器剔除。
NSString *const LanPlayerCorePodMarker = @"lanplayer_core-macos";
