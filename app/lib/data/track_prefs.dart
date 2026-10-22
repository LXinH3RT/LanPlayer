/// 按语言偏好挑选默认音轨/字幕轨。
///
/// 为什么要单独抽出来：内核里现在用的是 `av_find_best_stream`，它只会挑
/// 「第一条」音轨、字幕也是「第一条」，完全不看语言。多音轨的片子（国语 +
/// 粤语 + 英语评论）默认经常落在英文上，用户报的就是这个。
///
/// 偏好模型：每个媒体类型（音频 / 字幕）各有「首选语言」和「次选语言」，
/// 用户可以在设置里改。匹配顺序：
///   1. 首选语言
///   2. 次选语言
///   3. 容器自己的默认标记（`disposition.default`）—— 发行方通常标对了
///   4. 第一条可用轨道
///
/// 语言一律按 ISO 639-2/B 三字母码比较（FFmpeg 的 `metadata.language` 就是
/// 这个），但用户写的可能是 `zh`、`zh-CN`、`chi`、`中文`，所以先归一化。
library;

/// 一个可选的轨道（音频或字幕）。
class TrackChoice {
  const TrackChoice({
    required this.index,
    this.lang = '',
    this.title = '',
    this.isDefault = false,
    this.external = false,
  });

  /// 流索引（字幕可能是外挂轨道的序号）。
  final int index;

  /// 容器里的语言标签，可能是 `zh` / `chi` / `zh-CN` / 空。
  final String lang;

  /// 轨道标题，比如「国语」「English 5.1」「评论音轨」。
  final String title;

  /// 容器认为的默认轨（`AV_DISPOSITION_DEFAULT`）。
  final bool isDefault;

  /// 外挂字幕。
  final bool external;

  @override
  String toString() =>
      'TrackChoice($index, lang=$lang, title=$title, default=$isDefault)';
}

/// 语言偏好的持久化形态：`auto` 表示「不指定，交给容器默认」。
class TrackPreference {
  const TrackPreference({
    this.primary = 'auto',
    this.secondary = 'auto',
  });

  /// 首选语言：`auto` / `zh` / `en` / `ja` …
  final String primary;

  /// 次选语言；`auto` 表示不设次选。
  final String secondary;

  TrackPreference copyWith({String? primary, String? secondary}) =>
      TrackPreference(
        primary: primary ?? this.primary,
        secondary: secondary ?? this.secondary,
      );

  Map<String, dynamic> toJson() => {
        'primary': primary,
        'secondary': secondary,
      };

  factory TrackPreference.fromJson(Map<String, dynamic>? j) => TrackPreference(
        primary: j?['primary'] as String? ?? 'auto',
        secondary: j?['secondary'] as String? ?? 'auto',
      );
}

/// 界面上可选的语言（设置页下拉用）。
///
/// 只用常见几种，避免做一个几百项的下拉。`auto` 排最前并有明确说明。
class LanguageOption {
  const LanguageOption(this.code, this.label);
  final String code;
  final String label;
}

const List<LanguageOption> kLanguageOptions = [
  LanguageOption('auto', '自动（跟随文件默认）'),
  LanguageOption('zh', '中文'),
  LanguageOption('en', '英语'),
  LanguageOption('ja', '日语'),
  LanguageOption('ko', '韩语'),
  LanguageOption('yue', '粤语'),
  LanguageOption('fr', '法语'),
  LanguageOption('de', '德语'),
  LanguageOption('es', '西班牙语'),
  LanguageOption('ru', '俄语'),
];

/// 把各种写法归一成 ISO 639-2/B 三字母码；认不出的返回小写原值。
///
/// 覆盖：二字母（`zh`）、三字母 B/T（`chi`/`zho`）、带地区（`zh-CN`、
/// `zh_Hans`）、中文名（`中文`、`简体`）。
String normalizeLanguage(String raw) {
  var s = raw.trim().toLowerCase();
  if (s.isEmpty) return '';
  // 去掉地区/脚本后缀：zh-cn / zh_hans / pt-br
  for (final sep in ['-', '_']) {
    final i = s.indexOf(sep);
    if (i > 0) {
      s = s.substring(0, i);
    }
  }
  switch (s) {
    // 中文：二字母 zh，三字母 chi(B)/zho(T)，以及常见中文写法
    case 'zh':
    case 'chi':
    case 'zho':
    case '中文':
    case '汉语':
    case '普通话':
    case '简体':
    case 'chs':
    case 'cht':
      return 'chi';
    case 'en':
    case 'eng':
    case 'english':
    case '英语':
    case '英文':
      return 'eng';
    case 'ja':
    case 'jpn':
    case 'japanese':
    case '日语':
    case '日文':
      return 'jpn';
    case 'ko':
    case 'kor':
    case 'korean':
    case '韩语':
    case '韩文':
      return 'kor';
    case 'yue':
    case 'cantonese':
      return 'yue';
    case 'fr':
    case 'fre':
    case 'fra':
    case 'french':
      return 'fre';
    case 'de':
    case 'ger':
    case 'deu':
    case 'german':
      return 'ger';
    case 'es':
    case 'spa':
    case 'spanish':
      return 'spa';
    case 'ru':
    case 'rus':
    case 'russian':
      return 'rus';
    default:
      return s;
  }
}

/// 两个语言标签是否指同一种语言。
bool sameLanguage(String a, String b) {
  final na = normalizeLanguage(a);
  final nb = normalizeLanguage(b);
  return na.isNotEmpty && na == nb;
}

/// 从轨道里挑一条。
///
/// 返回被选中轨道的 `index`；没有任何轨道时返回 `null`。
/// [allowNull] 为 true 且偏好是 `auto`、且没有默认标记时，返回第一条。
int? pickTrack(
  List<TrackChoice> tracks,
  TrackPreference pref, {
  bool preferExternalLast = true,
}) {
  if (tracks.isEmpty) return null;

  // 排列顺序：内嵌在前、外挂在后（外挂字幕只是补充，不该抢默认）。
  //
  // 必须把 index 作为第二排序键：Dart 的 List.sort 不保证稳定，比较函数
  // 在相等时返回 0 会让同组轨道的相对顺序变得不可预测。
  final ordered = List<TrackChoice>.from(tracks);
  if (preferExternalLast) {
    ordered.sort((a, b) {
      final ea = a.external ? 1 : 0;
      final eb = b.external ? 1 : 0;
      if (ea != eb) return ea - eb;
      return a.index.compareTo(b.index);
    });
  }

  // 1. 首选语言
  if (pref.primary.isNotEmpty && pref.primary != 'auto') {
    for (final t in ordered) {
      if (sameLanguage(t.lang, pref.primary)) return t.index;
    }
    // 语言标签缺失时退回标题：很多中文片把「国语」写在 title 里而不是 lang。
    for (final t in ordered) {
      if (titleHintsLanguage(t.title, pref.primary)) return t.index;
    }
  }

  // 2. 次选语言
  if (pref.secondary.isNotEmpty && pref.secondary != 'auto') {
    for (final t in ordered) {
      if (sameLanguage(t.lang, pref.secondary)) return t.index;
    }
    for (final t in ordered) {
      if (titleHintsLanguage(t.title, pref.secondary)) return t.index;
    }
  }

  // 3. 容器默认标记
  for (final t in ordered) {
    if (t.isDefault) return t.index;
  }

  // 4. 第一条
  return ordered.first.index;
}

/// 轨道标题里是否提到某种语言（兜底：容器没写 `language` 标签时）。
bool titleHintsLanguage(String title, String lang) {
  if (title.isEmpty) return false;
  final target = normalizeLanguage(lang);
  if (target.isEmpty || target == 'auto') return false;
  final t = title.toLowerCase();
  switch (target) {
    case 'chi':
      return t.contains('中文') ||
          t.contains('国语') ||
          t.contains('汉语') ||
          t.contains('普通话') ||
          t.contains('简体') ||
          t.contains('繁体') ||
          t.contains('粤') ||
          t.contains('chi') ||
          t.contains('zho') ||
          t.contains('mandarin') ||
          t.contains('cantonese');
    case 'eng':
      return t.contains('english') || t.contains('eng') || t.contains('英文');
    case 'jpn':
      return t.contains('japanese') || t.contains('jpn') || t.contains('日语');
    case 'kor':
      return t.contains('korean') || t.contains('kor') || t.contains('韩语');
    default:
      return t.contains(target);
  }
}
