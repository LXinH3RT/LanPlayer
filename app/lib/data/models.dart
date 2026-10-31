/// Data model facade.
///
/// Callers keep importing this one file; the models themselves live in four
/// files grouped by responsibility:
///
///   * `playback_settings.dart` — player state and the persisted preferences
///     (speed, volume, seek step, tracks, shortcuts).
///   * `media_models.dart` — server profile, directory entries, stream and
///     media info, plus the subtitle-track helpers that read them.
///   * `directory_view.dart` — `DirectoryListing` and the derived views the
///     browser renders (videos, folders, sidecar grouping, browsable rows).
///   * `subtitle_models.dart` — the parsed subtitle cue tree and its styling.
library;

export 'scheme.dart';
export 'shortcuts.dart';
export 'subtitle_match.dart';
export 'track_prefs.dart';

export 'directory_view.dart';
export 'media_models.dart';
export 'playback_settings.dart';
export 'subtitle_models.dart';
