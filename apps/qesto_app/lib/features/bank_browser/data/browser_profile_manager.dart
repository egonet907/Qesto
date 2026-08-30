import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../domain/bank_browser_models.dart';

class BrowserProfileManager {
  BrowserProfileManager({Directory? rootDirectory})
    : rootDirectory = rootDirectory ?? _defaultRoot();

  final Directory rootDirectory;

  Directory profileDirectory(String profileId) =>
      Directory('${rootDirectory.path}${Platform.pathSeparator}$profileId');

  Directory cefDataDirectory(String profileId) => Directory(
    '${profileDirectory(profileId).path}${Platform.pathSeparator}cef',
  );

  Future<BankProfile> createProfile(BankConnectorConfig bank) async {
    await rootDirectory.create(recursive: true);
    final now = DateTime.now();
    final random = Random.secure().nextInt(0x7fffffff).toRadixString(16);
    final id = '${bank.bankId}-${now.microsecondsSinceEpoch}-$random';
    final profile = BankProfile(
      id: id,
      bankId: bank.bankId,
      displayName: bank.displayName,
      createdAt: now,
      lastOpenedAt: now,
      lastKnownUrl: bank.startUrl,
    );
    await cefDataDirectory(id).create(recursive: true);
    await _writeProfile(profile);
    return profile;
  }

  Future<BankProfile?> getProfile(String id) async {
    if (!_validId(id)) return null;
    final file = _metadataFile(id);
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      return BankProfile.fromJson((decoded as Map).cast<String, Object?>());
    } on Object {
      return null;
    }
  }

  Future<List<BankProfile>> listProfiles() async {
    if (!await rootDirectory.exists()) return const [];
    final profiles = <BankProfile>[];
    await for (final entity in rootDirectory.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final id = entity.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .last;
      final profile = await getProfile(id);
      if (profile != null) profiles.add(profile);
    }
    profiles.sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt));
    return profiles;
  }

  Future<bool> profileExists(String id) async =>
      _validId(id) && await _metadataFile(id).exists();

  Future<BankProfile> openProfile(BankProfile profile) async {
    final updated = profile.copyWith(lastOpenedAt: DateTime.now());
    await _writeProfile(updated);
    return updated;
  }

  Future<BankProfile> updateLastKnownUrl(
    BankProfile profile,
    Uri sanitizedUrl,
  ) async {
    final updated = profile.copyWith(lastKnownUrl: sanitizedUrl);
    await _writeProfile(updated);
    return updated;
  }

  Future<BankProfile> updateLastSync(
    BankProfile profile,
    DateTime syncedAt,
  ) async {
    final updated = profile.copyWith(lastSyncAt: syncedAt);
    await _writeProfile(updated);
    return updated;
  }

  /// Call only after the CEF browser and its RequestContext have closed.
  Future<void> deleteProfile(String id) async {
    if (!_validId(id)) throw ArgumentError.value(id, 'id');
    final directory = profileDirectory(id);
    if (!await directory.exists()) return;
    _assertInsideRoot(directory);
    Object? lastError;
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        await directory.delete(recursive: true);
        return;
      } on Object catch (error) {
        lastError = error;
        await Future<void>.delayed(Duration(milliseconds: 150 << attempt));
      }
    }
    throw FileSystemException(
      'Не удалось удалить локальный профиль браузера',
      directory.path,
      lastError is OSError ? lastError : null,
    );
  }

  Future<void> clearAllProfiles() async {
    final profiles = await listProfiles();
    for (final profile in profiles) {
      await deleteProfile(profile.id);
    }
  }

  File _metadataFile(String id) =>
      File('${profileDirectory(id).path}${Platform.pathSeparator}profile.json');

  Future<void> _writeProfile(BankProfile profile) async {
    if (!_validId(profile.id)) throw ArgumentError.value(profile.id, 'id');
    final directory = profileDirectory(profile.id);
    _assertInsideRoot(directory);
    await directory.create(recursive: true);
    final target = _metadataFile(profile.id);
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(jsonEncode(profile.toJson()), flush: true);
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }

  void _assertInsideRoot(Directory directory) {
    final root = rootDirectory.absolute.path.toLowerCase();
    final candidate = directory.absolute.path.toLowerCase();
    final prefix = root.endsWith(Platform.pathSeparator)
        ? root
        : '$root${Platform.pathSeparator}';
    if (!candidate.startsWith(prefix) || candidate == root) {
      throw StateError('Browser profile path escaped its local root');
    }
  }

  bool _validId(String value) =>
      RegExp(r'^[a-z0-9][a-z0-9_-]{2,127}$').hasMatch(value);

  static Directory _defaultRoot() {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.trim().isEmpty) {
      return Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}Qesto${Platform.pathSeparator}BankBrowser',
      );
    }
    return Directory(
      '$localAppData${Platform.pathSeparator}Qesto${Platform.pathSeparator}BankBrowser',
    );
  }
}
