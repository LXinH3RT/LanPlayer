/// 视频纹理桥在 app 侧的入口。
///
/// 实现住在 `packages/lanplayer_video`：那里的 `lib/src/channel.dart` 定义通道
/// 名、方法名与参数键，`lib/src/bridge.dart` 给出调用封装。这里只做转发，让
/// `player_screen.dart` 与其它调用点保持 `import 'video_texture.dart';` 不变，
/// 同时保证「通道叫什么」在整个仓库里只有一处定义。
library;

export 'package:lanplayer_video/lanplayer_video.dart';
