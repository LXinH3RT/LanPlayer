/// 外挂字幕与视频的配对规则。
///
/// 真实的片源目录里，字幕名和视频名很少逐字相同：同一个文件可能带发布组
/// 标签、压制参数、集数、语言后缀，甚至只写英文名而视频是中文名。这里把
/// 「怎样算同一个片」的判断集中到一处，列表分组（[DirectoryListing]）和
/// 内核的自动挂载都用同一套思路，免得两边各说各话。
///
/// 判定分三级，从严到宽：
///
/// 1. **主干相同**，或字幕主干以「视频主干 + 分隔符」开头。
///    `电影.mkv` + `电影.srt`、`电影.mkv` + `电影.zh-CN.srt`。
/// 2. **集数一致**。两边都能认出集数（`S01E02`、`第2集`、`001`…）且相等时，
///    后面的片名长短不再重要：`S10E01.mkv` 对得上
///    `54-S10E01 The Mystery of the Blue Train 蓝色列车之谜.srt`。
///    集数不同则直接判否，`悠哉日常大王013.ass` 不会挂到 `…001.mkv` 上。
/// 3. **去掉噪声词后仍能对上**。发布组、分辨率、编码、语言标签这类词先剔除，
///    剩下的主体若包含或近似，就认为是同一条。
///
/// 反例同样是规则的一部分：`电影2.srt` 不能挂到 `电影.mkv` 上 —— 主干前缀
/// 之后多出来的若是裸数字，说明是另一个片子（续集、另一集），不是语言后缀。
library;

/// 噪声词：发布组、封装/编码/分辨率、音轨格式、常见片源站标签。
///
/// 这些词出现在谁身上都不影响「是不是同一个片子」，所以比较前先摘掉。
const Set<String> _noiseTokens = {
  // 分辨率
  '2160p', '1080p', '1080i', '720p', '576p', '480p', '4k', '8k', 'uhd', 'hd',
  'sd',
  // 片源
  'bluray', 'blu', 'ray', 'bdrip', 'brrip', 'bd', 'remux', 'webrip', 'webdl',
  'web', 'dl', 'hdtv', 'dvdrip', 'dvd', 'hdrip', 'cam', 'ts', 'tc',
  // 编码
  'x264', 'x265', 'h264', 'h265', 'avc', 'hevc', 'av1', 'vp9', '10bit', '8bit',
  '10bits', 'hi10p', 'main10',
  // 音频
  'aac', 'ac3', 'eac3', 'dts', 'dtshd', 'flac', 'truehd', 'atmos', 'ddp', 'dd',
  'ddp5', 'dd5', 'mp3', 'opus',
  // 其它
  'proper', 'repack', 'extended', 'uncut', 'unrated', 'directors', 'cut',
  'hdr', 'hdr10', 'dovi', 'sdr', 'yify', 'yts', 'mx', 'nf', 'amzn', 'itv',
  'dsnp', 'hmax', 'atvp', 'multi', 'dual', 'subs', 'sub', 'chs', 'cht',
};

/// 语言/字幕类型标签：出现在主干之后属于「同一条字幕的不同语言版本」。
const Set<String> _languageTokens = {
  'zh', 'zhcn', 'zhtw', 'zhhk', 'chs', 'cht', 'chn', 'chi', 'zho',
  // `cn`/`tw`/`hk`/`hans`/`hant` 是最常见的一批写法，早先漏了，
  // `Movie.2024.1080p.mkv` 配 `Movie.2024.zh-CN.srt` 会被判否。
  // 与内核 `native/src/core/submatch.c` 的 `kLang[]` 对齐。
  'cn', 'tw', 'hk', 'hans', 'hant',
  'en', 'eng', 'english', 'jp', 'jpn', 'japanese', 'kr', 'kor', 'korean',
  'sc', 'tc', 'gb', 'big5', '简体', '繁体', '简中', '繁中', '中文', '英文',
  '中英', '英中', '双语', '中日', '日文', '粤语', '国语',
  'ass', 'srt', 'ssa', 'vtt', 'sub', 'forced', 'sdh', 'cc', 'hi',
  '蓝光版', '蓝光版本', '特效', '字幕', '版',
};

// 配对规则里用到的正则全部在文件级编译一次。
//
// 这些模式此前分散在 `_episodeKey`/`_core`/`_isHashLike`/`_onlyDecoration`
// 里，每调用一次就新建 14 个 `RegExp`。列目录时对每个「视频×字幕」组合都要
// 走一遍判定，`RegExp` 的编译开销会按组合数放大；建表改成分桶后判定次数降
// 下来了，但「每个名字只解析一次」的前提下，编译仍然应该只发生一次。

/// `s01e02` / `S01.E02`。
final RegExp _reSeasonEpisode = RegExp(r's(\d{1,2})[\s._-]*e(\d{1,4})');

/// `1x02`。
final RegExp _reSeasonXEpisode =
    RegExp(r'(?<![0-9a-z])(\d{1,2})x(\d{1,3})(?![0-9])');

/// `第02集` / `第 2 话`。
final RegExp _reCjkEpisode = RegExp(r'第\s*(\d{1,4})\s*[集话話]');

/// 只有集号的 `e02`。
final RegExp _reEpisodeOnly = RegExp(r'(?<![a-z0-9])e(\d{1,4})(?![0-9])');

/// 被分隔符包起来的独立 2–3 位数字。
final RegExp _reLooseEpisode = RegExp(r'(?<![0-9a-z])(\d{2,3})(?![0-9a-z])');

/// 结尾的 2–4 位数字。
final RegExp _reTrailingNumber = RegExp(r'(\d{2,4})$');

/// 方括号整段：发布组、站点标签。
final RegExp _reBracketGroup = RegExp(r'\[[^\]]*\]');

/// 圆括号整段。
final RegExp _reParenGroup = RegExp(r'\([^)]*\)');

/// 花括号整段。
final RegExp _reBraceGroup = RegExp(r'\{[^}]*\}');

/// 非「字母/数字/汉字」的字符，统一折成空格。
///
/// `_core` 与 `_onlyDecoration` 用的是同一个模式，共用一个实例。
final RegExp _reNonWord = RegExp(r'[^0-9a-z\u4e00-\u9fff]+');

/// 8 位十六进制。
final RegExp _reCrcHex = RegExp(r'^[0-9a-f]{8}$');

/// 是否含数字。
final RegExp _reDigit = RegExp(r'[0-9]');

/// `v2` / `v3` 这类版本号。
final RegExp _reVersionSuffix = RegExp(r'^v\d+$');

/// 判断 [subName] 这份字幕是否属于 [videoName] 这个视频。
bool subtitleBelongsTo(String videoName, String subName) {
  final a = _stem(videoName);
  final b = _stem(subName);
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;

  // 第一级：主干前缀 + 分隔符（老规则，保留）。
  if (b.length > a.length && b.startsWith(a) && _isSeparator(b[a.length])) {
    return true;
  }

  // 第二级：集数。两边都认得出来时，以集数为准。
  final ka = _episodeKey(a);
  final kb = _episodeKey(b);
  if (ka != null && kb != null && ka != kb) return false;

  final ca = _core(a);
  final cb = _core(b);
  if (ca.isEmpty || cb.isEmpty) return false;

  if (ka != null && kb != null) {
    // 同一集：片名写法不同也认，`S10E01` 这类只有集数的名字直接放行。
    return true;
  }

  if (ca == cb) return true;

  // 第三级：一方是另一方的前缀时，多出来的部分必须只是语言/噪声标签。
  // 裸数字说明是续集或另一集（`电影2.srt` 之于 `电影.mkv`），一律判否。
  if (cb.startsWith(ca)) {
    return _onlyDecoration(cb.substring(ca.length));
  }
  if (ca.startsWith(cb)) {
    return _onlyDecoration(ca.substring(cb.length));
  }

  // 都不是前缀关系：退到字符二元组相似度。同名片源跨语言（中文名 vs
  // 英文名）在这里对不上，那是翻译问题，字符相似度解决不了，也不该硬凑。
  return _dice(ca, cb) >= 0.86;
}

/// 去掉最后一个扩展名并转小写。`movie.zh-CN.srt` → `movie.zh-cn`。
String _stem(String name) {
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  return base.toLowerCase().trim();
}

/// 视频主干与字幕附加部分之间的分隔符。
bool _isSeparator(String ch) {
  return ch == '.' || ch == '_' || ch == '-' || ch == ' ' || ch == '(';
}

/// 认集数。返回归一化后的键，认不出返回 null。
///
/// 只认有明确形状的写法：`S01E02`、`1x02`、`第02集`、`E02`，以及
/// **两位以上**的纯数字尾巴（`悠哉日常大王001`、`白箱101`、`101.mp4`）。
/// 一位数字不当集数，否则 `电影2` 这种续集会被当成第 2 集。
String? _episodeKey(String stem) {
  var m = _reSeasonEpisode.firstMatch(stem);
  if (m != null) {
    return 's${int.parse(m.group(1)!)}e${int.parse(m.group(2)!)}';
  }
  m = _reSeasonXEpisode.firstMatch(stem);
  if (m != null) {
    return 's${int.parse(m.group(1)!)}e${int.parse(m.group(2)!)}';
  }
  m = _reCjkEpisode.firstMatch(stem);
  if (m != null) return 'e${int.parse(m.group(1)!)}';
  m = _reEpisodeOnly.firstMatch(stem);
  if (m != null) return 'e${int.parse(m.group(1)!)}';
  // 被分隔符包起来的独立 2–3 位数字，取最后一个。
  //
  // 发布组最常见的写法就是这种：`[Group] Show Name - 01 [1080p].mkv` 与
  // `[Group] Show Name - 02.chs.ass`。数字后面跟的是 `]` 或 `.` 而不是行尾，
  // 下面那条「纯数字结尾」够不着，两边都认不出集数，于是掉进 Dice 近似判定
  // ——`show name 01` 与 `show name 02` 相似度约 0.909，整季字幕会被判成
  // 同一片挂到每一集上。
  //
  // 只收 2–3 位：`2049` 这种四位数是年份或片名里的数字，收进来会让
  // `Blade.Runner.2049.mkv` 与 `Blade.Runner.2049.2017.zh.srt` 判成两集。
  final loose = _reLooseEpisode.allMatches(stem).toList();
  if (loose.isNotEmpty) {
    return 'e${int.parse(loose.last.group(1)!)}';
  }
  m = _reTrailingNumber.firstMatch(stem);
  if (m != null) {
    // 纯数字文件名（`101.mp4`）与「片名 + 数字」都算，但要求数字前不是字母，
    // 避免把 `x264`、`h264` 之类的编码名当集数。
    final start = m.start;
    if (start == 0 || !_isAsciiLetter(stem.codeUnitAt(start - 1))) {
      return 'e${int.parse(m.group(1)!)}';
    }
  }
  return null;
}

bool _isAsciiLetter(int c) =>
    (c >= 0x61 && c <= 0x7a) || (c >= 0x41 && c <= 0x5a);

/// 摘掉发布组/质量/语言标签后的主体，只留片名与本集编号。
String _core(String stem) {
  var s = stem;
  // 方括号、圆括号里的通常是发布组和站点标签，整段丢掉。
  s = s.replaceAll(_reBracketGroup, ' ');
  s = s.replaceAll(_reParenGroup, ' ');
  s = s.replaceAll(_reBraceGroup, ' ');
  // 标点统一成空格，中英文都按空格切。
  s = s.replaceAll(_reNonWord, ' ');
  final out = <String>[];
  for (final t in s.split(' ')) {
    if (t.isEmpty) continue;
    if (_noiseTokens.contains(t)) continue;
    if (_languageTokens.contains(t)) continue;
    if (_isHashLike(t)) continue;
    out.add(t);
  }
  return out.join(' ');
}

/// 8 位十六进制、且带数字的串，基本是发布组算出来的 CRC（`D12B2CA8`）。
bool _isHashLike(String t) {
  if (t.length != 8) return false;
  if (!_reCrcHex.hasMatch(t)) return false;
  return t.contains(_reDigit);
}

/// [rest] 是否只是语言标签、噪声词或纯分隔符。
bool _onlyDecoration(String rest) {
  final s = rest.replaceAll(_reNonWord, ' ').trim();
  if (s.isEmpty) return true;
  for (final t in s.split(' ')) {
    if (t.isEmpty) continue;
    if (_languageTokens.contains(t)) continue;
    if (_noiseTokens.contains(t)) continue;
    if (_reVersionSuffix.hasMatch(t)) continue; // v2 / v3 版本号
    return false;
  }
  return true;
}

/// 字符二元组 Dice 系数，给「不是前缀、但有重叠」的名字用。
double _dice(String a, String b) {
  final x = _bigrams(a);
  final y = _bigrams(b);
  if (x.isEmpty || y.isEmpty) return 0;
  var common = 0;
  final pool = <String, int>{};
  for (final g in y) {
    pool[g] = (pool[g] ?? 0) + 1;
  }
  for (final g in x) {
    final n = pool[g] ?? 0;
    if (n > 0) {
      common++;
      pool[g] = n - 1;
    }
  }
  return 2 * common / (x.length + y.length);
}

List<String> _bigrams(String s) {
  final r = <String>[];
  for (var i = 0; i + 1 < s.length; i++) {
    r.add(s.substring(i, i + 2));
  }
  return r;
}

/// 一个文件名在配对算法里的解析结果。
///
/// 列表分组要对「视频×字幕」的每个组合做判定，若每次都从文件名重新解析，
/// 同一个名字会被解析上百次。把解析结果缓存成 [SubtitleKey] 之后，判定
/// 退化成几次字符串比较；配对语义仍由 [subtitleBelongsTo] 单独拥有，
/// 这里只是它的展开形式。
///
/// 字段全部来自 [subtitleBelongsTo] 用到的中间量：
/// - [stem]、[core] 分别对应 `_stem(name)`、`_core(stem)`；
/// - [episode] 对应 `_episodeKey(stem)`。
class SubtitleKey {
  SubtitleKey._({
    required this.stem,
    required this.core,
    required this.episode,
    required this.bigrams,
  });

  /// 解析 [name]。空名字返回 `null`，与 [subtitleBelongsTo] 的空名判否一致。
  static SubtitleKey? parse(String name) {
    final stem = _stem(name);
    if (stem.isEmpty) return null;
    final core = _core(stem);
    return SubtitleKey._(
      stem: stem,
      core: core,
      episode: _episodeKey(stem),
      bigrams: core.isEmpty ? const [] : _bigrams(core),
    );
  }

  /// 去掉扩展名并转小写后的主干。
  final String stem;

  /// 摘掉发布组/质量/语言标签后的主体。
  final String core;

  /// 归一化后的集数键，认不出为 `null`。
  final String? episode;

  /// [core] 的字符二元组，供 Dice 相似度使用。
  final List<String> bigrams;

  /// 与 [subtitleBelongsTo] 逐级等价的判定，只是把已经算过的中间量复用起来。
  bool matches(SubtitleKey other) {
    final a = stem;
    final b = other.stem;
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;

    // 第一级：主干前缀 + 分隔符。
    if (b.length > a.length && b.startsWith(a) && _isSeparator(b[a.length])) {
      return true;
    }

    // 第二级：集数。两边都认得出来时以集数为准。
    final ka = episode;
    final kb = other.episode;
    if (ka != null && kb != null && ka != kb) return false;

    final ca = core;
    final cb = other.core;
    if (ca.isEmpty || cb.isEmpty) return false;

    if (ka != null && kb != null) return true;
    if (ca == cb) return true;

    // 第三级：一方是另一方的前缀时，多出来的部分必须只是语言/噪声标签。
    if (cb.startsWith(ca)) {
      return _onlyDecoration(cb.substring(ca.length));
    }
    if (ca.startsWith(cb)) {
      return _onlyDecoration(ca.substring(cb.length));
    }

    return _diceBigrams(bigrams, other.bigrams) >= 0.86;
  }
}

/// [SubtitleKey.bigrams] 版本的 Dice 系数，避免为判定再拆一遍二元组。
double _diceBigrams(List<String> x, List<String> y) {
  if (x.isEmpty || y.isEmpty) return 0;
  var common = 0;
  final pool = <String, int>{};
  for (final g in y) {
    pool[g] = (pool[g] ?? 0) + 1;
  }
  for (final g in x) {
    final n = pool[g] ?? 0;
    if (n > 0) {
      common++;
      pool[g] = n - 1;
    }
  }
  return 2 * common / (x.length + y.length);
}
