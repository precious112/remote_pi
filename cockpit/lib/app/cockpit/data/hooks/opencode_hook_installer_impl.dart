import 'dart:io';

import 'package:cockpit/app/cockpit/data/hooks/hook_installer_base.dart';
import 'package:cockpit/app/cockpit/data/hooks/opencode_plugin_source.dart';
import 'package:flutter/foundation.dart';

/// Installs Cockpit's turn-status reporting into **OpenCode**.
///
/// OpenCode has no hooks file: it loads plugins from
/// `~/.config/opencode/plugins/`. So instead of editing a config, this writes
/// one plugin file of our own ([fileName]) that forwards OpenCode's events to
/// `cockpit hook --harness opencode`. See [openCodePluginSource].
///
/// Same rules as the Claude and Codex installers:
/// - idempotent: the file is only rewritten when its content changes;
/// - only ever touches its own file, never the user's other plugins;
/// - the plugin is a no-op outside a Cockpit tab (no `COCKPIT_TAB_ID`).
class OpenCodeHookInstallerImpl extends HookInstallerBase {
  const OpenCodeHookInstallerImpl();

  @override
  String get harnessName => 'opencode';

  /// Our plugin's file name inside OpenCode's plugins folder.
  static const String fileName = 'cockpit-status.ts';

  @override
  Future<void> writeConfig({
    required String home,
    required String command,
  }) async {
    // The plugin needs the Rust CLI's `hook --harness`. If the base class fell
    // back to the legacy `cockpit-hook` binary, skip rather than install a
    // plugin that can't report.
    final argv = hookArgv(command);
    if (argv == null) return;

    final dir = Directory('$home/.config/opencode/plugins');
    await dir.create(recursive: true);
    final file = File('${dir.path}/$fileName');
    final content = openCodePluginSource(argv);
    if (await file.exists() && await file.readAsString() == content) return;
    await file.writeAsString(content);
    if (kDebugMode) {
      debugPrint('[opencode-hook] plugin installed at ${file.path}');
    }
  }

  /// Turns the base class's shell command (`<cli> hook`, with the path quoted
  /// when it has spaces) into an argument list the plugin can spawn without a
  /// shell. `null` when [command] is not the Rust CLI's `hook` subcommand.
  @visibleForTesting
  static List<String>? hookArgv(String command) {
    const suffix = ' hook';
    if (!command.endsWith(suffix)) return null;
    var cli = command.substring(0, command.length - suffix.length);
    if (cli.length >= 2 && cli.startsWith('"') && cli.endsWith('"')) {
      cli = cli.substring(1, cli.length - 1);
    }
    return <String>[cli, 'hook', '--harness', 'opencode'];
  }
}
