import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:qesto/features/bank_browser/config/bank_connector_registry.dart';
import 'package:qesto/features/bank_browser/data/browser_profile_manager.dart';

void main() {
  late Directory root;
  late BrowserProfileManager manager;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('qesto-bank-profile-test-');
    manager = BrowserProfileManager(rootDirectory: root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('creates isolated persistent profile metadata and CEF folder', () async {
    final first = await manager.createProfile(BankConnectorRegistry.sber);
    final second = await manager.createProfile(BankConnectorRegistry.sber);

    expect(first.id, isNot(second.id));
    expect(await manager.profileExists(first.id), isTrue);
    expect(await manager.cefDataDirectory(first.id).exists(), isTrue);
    expect(await manager.cefDataDirectory(second.id).exists(), isTrue);

    final restored = await manager.getProfile(first.id);
    expect(restored?.bankId, 'sber');
    expect(restored?.lastKnownUrl, BankConnectorRegistry.sber.startUrl);
  });

  test('updates safe last URL and lists most recently opened first', () async {
    final first = await manager.createProfile(BankConnectorRegistry.sber);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final second = await manager.createProfile(BankConnectorRegistry.sber);
    await manager.updateLastKnownUrl(
      first,
      Uri.parse('https://online.sberbank.ru/main'),
    );

    final listed = await manager.listProfiles();
    expect(listed.first.id, second.id);
    expect(
      (await manager.getProfile(first.id))?.lastKnownUrl.toString(),
      'https://online.sberbank.ru/main',
    );
  });

  test('deleting profile wipes browser website data with metadata', () async {
    final profile = await manager.createProfile(BankConnectorRegistry.sber);
    final cookieMarker = File(
      '${manager.cefDataDirectory(profile.id).path}${Platform.pathSeparator}cookie-marker',
    );
    await cookieMarker.writeAsString('sensitive local data');

    await manager.deleteProfile(profile.id);

    expect(await manager.profileDirectory(profile.id).exists(), isFalse);
    expect(await manager.profileExists(profile.id), isFalse);
  });

  test('rejects traversal identifiers', () async {
    expect(
      () => manager.deleteProfile('../outside'),
      throwsA(isA<ArgumentError>()),
    );
  });
}
