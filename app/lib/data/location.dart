import 'models.dart';

/// Where a browser session points at: an SMB share or a local directory.
/// Keeping this separate from [ServerProfile] lets module 5 (local playback)
/// reuse the exact same browsing and playback UI.
class MediaLocation {
  const MediaLocation({
    required this.label,
    required this.rootUrl,
    required this.options,
    this.profile,
    this.isLocal = false,
  });

  final String label;
  final String rootUrl;
  final Map<String, dynamic> options;
  final ServerProfile? profile;
  final bool isLocal;

  factory MediaLocation.fromProfile(ServerProfile p) => MediaLocation(
        label: p.displayName,
        rootUrl: p.rootUrl,
        options: p.transportOptions(),
        profile: p,
      );

  factory MediaLocation.local(String label, String path) => MediaLocation(
        label: label,
        rootUrl: 'file://$path',
        options: const {},
        isLocal: true,
      );

  /// Adds credentials back into a URL produced by the native listing (which
  /// never returns them), so playback can open the file directly.
  String credentialized(String path) {
    final p = profile;
    if (p == null || isLocal) return path;
    const marker = 'smb://';
    if (!path.startsWith(marker)) return path;
    final rest = path.substring(marker.length);
    if (rest.contains('@')) return path;
    final user = Uri.encodeComponent(p.user);
    final pass = Uri.encodeComponent(p.password);
    return 'smb://$user:$pass@$rest';
  }

  /// Options handed to lp_player_open: credentials + user preferences are merged
  /// by the caller.
  Map<String, dynamic> get openOptions => {
        ...options,
      };
}
