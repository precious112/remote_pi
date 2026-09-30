import 'dart:io';

import 'package:cockpit/app/cockpit/data/hooks/opencode_hook_installer_impl.dart';
import 'package:flutter_test/flutter_test.dart';

/// Installer with the CLI copy short-circuited: these tests exercise the plugin
/// file (where the rules are), not the binary copy, which needs the app bundle.
class _FakeInstaller extends OpenCodeHookInstallerImpl {
  const _FakeInstaller(this.command);

  final String command;

  @override
  Future<String?> ensureCli() async => '/fake/cockpit';

  @override
  Future<String?> resolveHookCommand(String? cliPath) async => command;
}

void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('opencode-hook-test');
  });

  tearDown(() async {
    if (await home.exists()) await home.delete(recursive: true);
  });

  File plugin() => File(
    '${home.path}/.config/opencode/plugins/${OpenCodeHookInstallerImpl.fileName}',
  );

  group('writeConfig', () {
    test('writes the plugin with the CLI path and --harness opencode', () async {
      const installer = _FakeInstaller('/bin/cockpit hook');
      await installer.writeConfig(home: home.path, command: '/bin/cockpit hook');

      final content = plugin().readAsStringSync();
      expect(
        content,
        contains(
          'const HOOK_CMD: string[] = ["/bin/cockpit","hook","--harness","opencode"];',
        ),
      );
      expect(content, isNot(contains('__HOOK_CMD__')));
      expect(content, startsWith('// cockpit-managed v1'));
    });

    test('creates the plugins folder when OpenCode has none yet', () async {
      expect(Directory('${home.path}/.config').existsSync(), isFalse);
      const installer = _FakeInstaller('/bin/cockpit hook');
      await installer.writeConfig(home: home.path, command: '/bin/cockpit hook');
      expect(plugin().existsSync(), isTrue);
    });

    test('running again does not rewrite an up-to-date file', () async {
      const installer = _FakeInstaller('/bin/cockpit hook');
      await installer.writeConfig(home: home.path, command: '/bin/cockpit hook');
      final before = plugin().lastModifiedSync();
      final content = plugin().readAsStringSync();

      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await installer.writeConfig(home: home.path, command: '/bin/cockpit hook');

      expect(plugin().readAsStringSync(), content);
      expect(plugin().lastModifiedSync(), before);
    });

    test('replaces an outdated copy of our own plugin', () async {
      await plugin().parent.create(recursive: true);
      plugin().writeAsStringSync('// old version');

      const installer = _FakeInstaller('/bin/cockpit hook');
      await installer.writeConfig(home: home.path, command: '/bin/cockpit hook');

      expect(plugin().readAsStringSync(), contains('cockpit-managed v1'));
    });

    test("leaves the user's other plugins alone", () async {
      final dir = await Directory(
        '${home.path}/.config/opencode/plugins',
      ).create(recursive: true);
      final mine = File('${dir.path}/my-plugin.ts')
        ..writeAsStringSync('export const Mine = async () => ({});');

      const installer = _FakeInstaller('/bin/cockpit hook');
      await installer.writeConfig(home: home.path, command: '/bin/cockpit hook');

      expect(mine.readAsStringSync(), 'export const Mine = async () => ({});');
      expect(dir.listSync().length, 2);
    });

    test('skips the legacy cockpit-hook binary (no hook subcommand)', () async {
      const installer = _FakeInstaller('/bin/cockpit-hook');
      await installer.writeConfig(home: home.path, command: '/bin/cockpit-hook');
      expect(plugin().existsSync(), isFalse);
    });
  });

  group('hookArgv', () {
    test('splits the plain command', () {
      expect(OpenCodeHookInstallerImpl.hookArgv('/bin/cockpit hook'), [
        '/bin/cockpit',
        'hook',
        '--harness',
        'opencode',
      ]);
    });

    test('unquotes a path with spaces', () {
      expect(
        OpenCodeHookInstallerImpl.hookArgv(
          '"/Users/John Smith/.cockpit/bin/cockpit" hook',
        ),
        ['/Users/John Smith/.cockpit/bin/cockpit', 'hook', '--harness', 'opencode'],
      );
    });

    test('escapes the path safely inside the plugin', () async {
      const command = '"/Users/O\'Neil "Q"/.cockpit/bin/cockpit" hook';
      const installer = _FakeInstaller(command);
      await installer.writeConfig(home: home.path, command: command);
      expect(
        plugin().readAsStringSync(),
        contains(r'["/Users/O' "'" r'Neil \"Q\"/.cockpit/bin/cockpit",'),
      );
    });

    test('returns null for anything that is not the hook subcommand', () {
      expect(OpenCodeHookInstallerImpl.hookArgv('/bin/cockpit-hook'), isNull);
      expect(OpenCodeHookInstallerImpl.hookArgv(''), isNull);
    });
  });
}
