import 'package:flutter/services.dart';

/// 播放页与浏览页里所有「能自定义的键盘动作」。
///
/// 为什么要有这份目录：改动前快捷键是散在 `player_screen.dart` 的
/// `_isPlayerKey` / `_handleKey` 两个函数里的 if 链，键写死在代码里，
/// 用户既看不到有哪些，也改不了。现在把「动作」抽成数据，界面按这份
/// 目录列出来，播放页按键时也按这份目录查表，两边不会漂移。
enum ShortcutAction {
  playPause('play_pause', '播放 / 暂停', ShortcutGroup.playback,
      LogicalKeyboardKey.space),
  seekBack(
      'seek_back', '快退', ShortcutGroup.playback, LogicalKeyboardKey.arrowLeft),
  seekForward('seek_forward', '快进', ShortcutGroup.playback,
      LogicalKeyboardKey.arrowRight),
  volumeUp(
      'volume_up', '音量增大', ShortcutGroup.audio, LogicalKeyboardKey.arrowUp),
  volumeDown(
      'volume_down', '音量减小', ShortcutGroup.audio, LogicalKeyboardKey.arrowDown),
  mute('mute', '静音 / 取消静音', ShortcutGroup.audio, LogicalKeyboardKey.keyM),
  speedUp('speed_up', '加速一档', ShortcutGroup.playback, null),
  speedDown('speed_down', '减速一档', ShortcutGroup.playback, null),
  speedReset('speed_reset', '恢复 1.0 倍速', ShortcutGroup.playback, null),
  fullscreen(
      'fullscreen', '全屏 / 退出全屏', ShortcutGroup.window, LogicalKeyboardKey.keyF),
  escape(
      'escape', '退出全屏，否则返回', ShortcutGroup.window, LogicalKeyboardKey.escape),
  subtitleEarlier('subtitle_earlier', '字幕提前 0.1 秒', ShortcutGroup.subtitle,
      LogicalKeyboardKey.bracketLeft),
  subtitleLater('subtitle_later', '字幕延后 0.1 秒', ShortcutGroup.subtitle,
      LogicalKeyboardKey.bracketRight),
  stats('stats', '显示 / 隐藏解码统计', ShortcutGroup.debug, LogicalKeyboardKey.keyS),
  back(
      'back', '返回上一级（浏览页）', ShortcutGroup.window, LogicalKeyboardKey.backspace);

  const ShortcutAction(this.id, this.label, this.group, this.defaultKey);

  /// 存进 `settings.json` 用的稳定标识。**不要**改成枚举名 —— 那是重构就
  /// 会变的东西，用户的绑定会一起丢。
  final String id;
  final String label;
  final ShortcutGroup group;

  /// 默认键。`null` = 出厂不绑定，等用户自己指定。
  final LogicalKeyboardKey? defaultKey;

  static ShortcutAction? byId(String id) {
    for (final a in ShortcutAction.values) {
      if (a.id == id) return a;
    }
    return null;
  }
}

/// 分组只影响设置页的分节标题。
enum ShortcutGroup {
  playback('播放'),
  audio('音量'),
  subtitle('字幕'),
  window('窗口与导航'),
  debug('调试');

  const ShortcutGroup(this.title);
  final String title;
}

/// 用户改过之后的一份绑定表。
///
/// 只存「与默认不同」的项，这样以后给某个动作换默认键时，没动过的用户
/// 能自动拿到新默认值。`null` 表示「明确解绑」，与「没配置」是两回事 ——
/// 没有这个区别就没法表达「我就是要把它空着」。
class ShortcutBindings {
  final Map<ShortcutAction, LogicalKeyboardKey?> _overrides;

  const ShortcutBindings._(this._overrides);

  static const ShortcutBindings empty = ShortcutBindings._({});

  factory ShortcutBindings.fromJson(Object? raw) {
    final map = <ShortcutAction, LogicalKeyboardKey?>{};
    if (raw is Map) {
      raw.forEach((key, value) {
        final action = ShortcutAction.byId(key.toString());
        if (action == null) return; // 老版本留下的动作名，直接忽略
        if (value == null) {
          map[action] = null;
          return;
        }
        final id = value is num ? value.toInt() : null;
        if (id == null) return;
        map[action] = keyFromId(id);
      });
    }
    return ShortcutBindings._(map);
  }

  Map<String, dynamic> toJson() => {
        for (final e in _overrides.entries) e.key.id: e.value?.keyId,
      };

  /// 这个动作当前生效的键；`null` 表示没绑。
  LogicalKeyboardKey? keyFor(ShortcutAction action) =>
      _overrides.containsKey(action) ? _overrides[action] : action.defaultKey;

  bool get isDefault => _overrides.isEmpty;

  /// 把 [action] 绑到 [key]；[key] 传 `null` 表示解绑。
  ///
  /// 同一个键被别的动作占着时，**把那个动作解绑**并返回它，让界面能提示
  /// 「快退已改绑到 ←」。两个动作抢一个键只会让其中一个永远不触发，比
  /// 直接覆盖更让人困惑。
  ShortcutBindings bind(ShortcutAction action, LogicalKeyboardKey? key) {
    final next = Map<ShortcutAction, LogicalKeyboardKey?>.from(_overrides);
    if (key != null) {
      for (final other in ShortcutAction.values) {
        if (other == action) continue;
        if (keyFor(other) != key) continue;
        next[other] = null;
        break;
      }
    }
    next[action] = key;
    return ShortcutBindings._(next);
  }

  /// [key] 当前被哪个**别的**动作占着（用于改键时提示「会抢走谁」）。
  ShortcutAction? conflictFor(ShortcutAction action, LogicalKeyboardKey key) {
    for (final other in ShortcutAction.values) {
      if (other == action) continue;
      if (keyFor(other) == key) return other;
    }
    return null;
  }

  ShortcutBindings resetAll() => empty;

  ShortcutBindings resetOne(ShortcutAction action) {
    final next = Map<ShortcutAction, LogicalKeyboardKey?>.from(_overrides)
      ..remove(action);
    return ShortcutBindings._(next);
  }

  /// 播放页用这个判断「这一颗键要不要自己处理」。
  ///
  /// 顺带把 ESC 之外的 `escape` 等价处理留给调用方 —— 这里只回答「是不是
  /// 某个动作的键」，具体做哪个动作由 [actionForKey] 查。
  bool ownsKey(LogicalKeyboardKey key) => actionForKey(key) != null;

  ShortcutAction? actionForKey(LogicalKeyboardKey key) {
    for (final action in ShortcutAction.values) {
      if (keyFor(action) == key) return action;
    }
    return null;
  }

  /// 键的显示名。空格、方向键这类 `keyLabel` 是空的，得自己给。
  ///
  /// 方向键的 `keyLabel` 其实是 `ARROW LEFT` 这种全大写串，所以必须先判
  /// 特殊键，不能先看 `keyLabel` 非空就返回 —— 否则界面上会冒出
  /// 「ARROW LEFT」这种半截英文。
  static String label(LogicalKeyboardKey key) {
    switch (key) {
      case LogicalKeyboardKey.space:
        return '空格';
      case LogicalKeyboardKey.arrowLeft:
        return '←';
      case LogicalKeyboardKey.arrowRight:
        return '→';
      case LogicalKeyboardKey.arrowUp:
        return '↑';
      case LogicalKeyboardKey.arrowDown:
        return '↓';
      case LogicalKeyboardKey.escape:
        return 'Esc';
      case LogicalKeyboardKey.backspace:
        return '退格';
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        return '回车';
      case LogicalKeyboardKey.tab:
        return 'Tab';
    }
    final label = key.keyLabel.trim();
    if (label.isNotEmpty) return label.toUpperCase();
    final name = key.debugName;
    if (name != null && name.isNotEmpty) return name;
    return '#${key.keyId}';
  }

  /// 把存下来的整数还原成键。
  ///
  /// 先用预定义表查（能拿到 `keyLabel`/`debugName`，显示名才好看），查不到
  /// 再按原始 id 构造 —— 用户绑了一颗小众媒体键时不能因此整份配置读不动。
  static LogicalKeyboardKey? keyFromId(int id) =>
      LogicalKeyboardKey.findKeyByKeyId(id) ?? LogicalKeyboardKey(id);
}

/// 鼠标侧的手势说明。这些不是「键」，改不了绑定，但用户要求把它们列出来，
/// 否则界面上看不见、也不知道双击左右三分之一是快进退。
class PointerGesture {
  const PointerGesture(this.gesture, this.effect);
  final String gesture;
  final String effect;

  static const List<PointerGesture> all = [
    PointerGesture('单击画面', '显示 / 隐藏控制条'),
    PointerGesture('双击画面左侧三分之一', '快退（步长见「进度」段）'),
    PointerGesture('双击画面中间三分之一', '播放 / 暂停'),
    PointerGesture('双击画面右侧三分之一', '快进（步长见「进度」段）'),
    PointerGesture('长按画面', '临时 2.0 倍速，松手恢复'),
    PointerGesture('左半边上下拖动', '调节亮度'),
    PointerGesture('右半边上下拖动', '调节音量'),
    PointerGesture('滚轮', '调节音量'),
    PointerGesture('点击底栏音量数字', '静音 / 取消静音'),
    PointerGesture('长按底栏音量数字', '打开音量面板'),
    PointerGesture('单击「画面」按钮', '全屏 / 退出全屏'),
    PointerGesture('长按「画面」按钮', '打开画面设置面板'),
  ];
}
