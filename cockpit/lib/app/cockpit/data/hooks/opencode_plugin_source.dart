import 'dart:convert';

/// Source of the OpenCode plugin that `OpenCodeHookInstallerImpl` writes to
/// `~/.config/opencode/plugins/`.
///
/// OpenCode has no hooks file like Claude Code or Codex: it is extended by
/// plugins, JS/TS files it loads at startup. This plugin translates OpenCode's
/// events into the same Claude-style event names the other harnesses already
/// send (`UserPromptSubmit`, `Stop`, ...) and pipes them into
/// `cockpit hook --harness opencode`, so `hook.rs` and the app handle OpenCode
/// with no changes on their side.
///
/// [argv] is the command to spawn, e.g.
/// `["/Users/me/.cockpit/bin/cockpit", "hook", "--harness", "opencode"]`.
/// It is embedded as a JSON array, which is also a valid TypeScript literal,
/// with any special characters in the path escaped.
String openCodePluginSource(List<String> argv) =>
    _template.replaceFirst('__HOOK_CMD__', jsonEncode(argv));

// Raw string: the `$` signs below are TypeScript, not Dart interpolation.
const String _template = r'''
// cockpit-managed v1: written by Cockpit on every launch; edits will be overwritten.
// Reports OpenCode's turn status (working / waiting / idle) to the Cockpit tab
// it runs in, through `cockpit hook`. Does nothing outside Cockpit.

declare const Bun: any;

// Filled in by Cockpit with the absolute path of its CLI.
const HOOK_CMD: string[] = __HOOK_CMD__;

// What each event means to Cockpit (mirrors status_for in cli/src/hook.rs),
// used to skip sending the same status twice in a row.
const STATUS: Record<string, string> = {
  UserPromptSubmit: "working",
  PreToolUse: "working",
  PostToolUse: "working",
  PermissionRequest: "waiting",
  Stop: "idle",
  SessionStart: "idle",
  SessionEnd: "idle",
};

export const CockpitStatus = async () => {
  // Cockpit sets this in every tab it opens. Missing: not a Cockpit tab.
  const tabId = process.env.COCKPIT_TAB_ID ?? process.env.COCKPIT_PANE_ID;
  if (!tabId) return {};

  // Subagent sessions: their events must not move the tab's status.
  const childSessions = new Set<string>();
  // Last status sent, to avoid repeats.
  let lastStatus = "";
  // The session the tab is showing (for resume and for "session ended").
  let mainSession = "";

  const report = (event: string, sessionID?: string) => {
    if (sessionID && childSessions.has(sessionID)) return;
    if (sessionID) mainSession = sessionID;
    // SessionStart always goes through: it may carry a new session id.
    if (STATUS[event] === lastStatus && event !== "SessionStart") return;
    lastStatus = STATUS[event];
    try {
      const proc = Bun.spawn(HOOK_CMD, {
        stdin: "pipe",
        stdout: "ignore",
        stderr: "ignore",
      });
      proc.stdin.write(
        JSON.stringify({
          hook_event_name: event,
          session_id: sessionID ?? "",
          cwd: process.cwd(),
        }),
      );
      proc.stdin.end();
    } catch {
      // Cockpit's CLI missing or broken: stay silent, never break OpenCode.
    }
  };

  return {
    event: async ({ event }: any) => {
      const p = event.properties ?? {};
      switch (event.type) {
        case "session.created":
          // A parent id means a subagent: remember it and ignore it.
          if (p.info?.parentID) childSessions.add(p.info.id);
          else report("SessionStart", p.info?.id);
          return;
        case "session.status":
          if (p.status?.type === "busy") report("UserPromptSubmit", p.sessionID);
          else if (p.status?.type === "idle") report("Stop", p.sessionID);
          // "retry" is still the same turn.
          return;
        case "session.idle":
          report("Stop", p.sessionID);
          return;
        // The turn failed or was cancelled: it is over.
        case "session.error":
          report("Stop", p.sessionID);
          return;
        // Waiting for the user (old and new event names).
        case "permission.asked":
        case "permission.updated":
        case "question.asked":
          report("PermissionRequest", p.sessionID);
          return;
        // The user answered: working again.
        case "permission.replied":
        case "question.replied":
        case "question.rejected":
          report("PostToolUse", p.sessionID);
          return;
        // Switched sessions in the TUI: resume must reopen this one.
        case "tui.session.select":
          report("SessionStart", p.sessionID);
          return;
        case "session.deleted":
          if (p.sessionID === mainSession) report("SessionEnd", p.sessionID);
          return;
        // OpenCode is shutting down (old and new event names).
        case "server.instance.disposed":
        case "global.disposed":
          report("SessionEnd", mainSession);
          return;
      }
    },
    // Activity during long turns.
    "tool.execute.before": async (input: any) => {
      report("PreToolUse", input.sessionID);
    },
    // Quitting mid-turn must not leave the tab spinning.
    dispose: async () => {
      report("SessionEnd", mainSession);
    },
  };
};
''';
