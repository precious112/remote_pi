# Status de turno — hooks dos harnesses

Como o Cockpit sabe que um agente numa aba está trabalhando, terminou o turno ou
precisa de uma ação do usuário (spinner, badge, chime, notificação do SO).

Suportados hoje: **Claude Code**, **Codex CLI** (0.147+) e **OpenCode** (via plugin).

## Como funciona

1. No boot, `bootstrapper.dart` roda os `HookInstaller` de cada harness. Eles
   materializam a CLI interna em `~/.cockpit/bin/cockpit` e registram
   `<cli> hook` nos eventos de ciclo de vida da config do harness.
2. A cada evento, o harness executa `cockpit hook` passando um JSON pelo stdin.
3. `cli/src/hook.rs` traduz o evento num status (`working` / `waiting` / `idle`)
   e manda pro app por socket Unix (TCP + token no Windows).
4. O roteamento é pela env `COCKPIT_PANE_ID`, que o app injeta na PTY da aba.
   Sessão de agente aberta **fora** do Cockpit não tem essa env, então o hook é
   no-op. É o gate natural: nada a configurar, nada a desligar.

Por que socket e não OSC na PTY: os harnesses rodam hooks sem terminal
controlador, e escrever em `/dev/tty` falha com `ENXIO`.

## Onde cada um instala

| Harness | Arquivo | Formato |
|---|---|---|
| Claude Code | `~/.claude/settings.json` | `hooks.<Evento>[]`, cada item `{matcher, hooks:[{type, command}]}` |
| Codex CLI | `~/.codex/hooks.json` | mesma forma; **mais** um bloco de trust no `~/.codex/config.toml` |
| OpenCode | `~/.config/opencode/plugins/cockpit-status.ts` | plugin próprio: o OpenCode não tem arquivo de hooks (ver [OpenCode](#opencode-plugin)) |

Os dois instaladores fazem **append idempotente** de um entry marcado
(`_cockpit: v1`): re-rodar remove o entry antigo nosso e re-adiciona, sem nunca
reescrever a lista (hooks do usuário, de plugins ou do iTerm2 sobrevivem).

## Mapeamento de eventos

| Evento | Claude | Codex | Status |
|---|:--:|:--:|---|
| `UserPromptSubmit` | ✓ | ✓ | `working` (início de turno) |
| `PreToolUse` | ✓ | ✓ | `working` — exceto ferramenta bloqueante do Claude (ver abaixo) |
| `PostToolUse` | ✓ | ✓ | `working` |
| `Notification` | ✓ | — | `waiting` / `idle` (heurística sobre o texto) |
| `PermissionRequest` | — | ✓ | `waiting` |
| `Stop` | ✓ | ✓ | `idle` |
| `SessionStart` / `SessionEnd` | ✓ | ✓ | `idle` |
| `SubagentStart` / `SubagentStop`, `PreCompact` / `PostCompact` | — | ✓ | **ignorados**: não são o turno da aba |

Duas assimetrias que importam:

- **Claude**: ferramentas que bloqueiam esperando o usuário (`AskUserQuestion`,
  `ExitPlanMode`) não emitem `Notification`. O último hook antes do bloqueio é o
  `PreToolUse`, então ele vira `waiting` para essas duas — senão a aba fica com
  spinner eterno, sem chime.
- **Codex**: a aprovação tem evento próprio (`PermissionRequest`), então não há
  heurística de texto nem desvio no `PreToolUse`. O desvio do Claude continua no
  código e é inerte aqui (aquelas ferramentas não existem no Codex).

O envelope é praticamente o mesmo nos dois (`hook_event_name`, `session_id`,
`transcript_path`, `cwd`, `tool_name`, `tool_input`, `permission_mode`). O Codex
manda um `turn_id` a mais, que o helper repassa como `tid`.

## Retomar a sessão (quem é o dono do session-id)

O app persiste no layout o `session_id` que veio pelo hook, e no restore da aba
digita o comando que reata a conversa. **O id sozinho não diz de qual harness
é**, e os comandos diferem:

| Harness | Comando de resume |
|---|---|
| Claude Code | `claude --resume <id>` |
| Codex CLI | `codex resume <id>` |
| OpenCode | `opencode --session <id>` |

Por isso o instalador registra o comando do hook com `--harness <nome>`
(`cockpit hook --harness codex`), o helper carimba o payload com `hn`, e o
layout guarda `harness` ao lado de `claude_sid`. Sem a flag, o helper assume
`claude` — é o que os entries instalados por versões anteriores passam, e todos
eles eram do Claude.

Foi exatamente esse o bug do primeiro E2E: o app restaurou uma aba de Codex com
`claude --resume <id do codex>` e o Claude respondeu "No conversation found with
session ID".

## O gate de confiança do Codex

O Codex **só executa hook confiado**. Sem trust ele ignora o hook **em
silêncio** — nenhum aviso, nenhum log. O trust vive no `~/.codex/config.toml`:

```toml
[hooks.state."/Users/você/.codex/hooks.json:session_start:0:0"]
enabled = true
trusted_hash = "sha256:…"
```

- **Chave**: `"<caminho do hooks.json>:<evento_snake>:<índice do grupo>:<índice do handler>"`.
- **Hash**: `sha256` (hex, prefixado `sha256:`) do **JSON canônico** — chaves
  ordenadas, sem espaços — da identidade normalizada do handler:

  ```json
  {"event_name":"session_start","hooks":[{"async":false,"command":"…","timeout":600,"type":"command"}]}
  ```

  O `timeout` é o **normalizado**: 600s para todos os eventos, exceto
  `SessionEnd`, que tem default 1s (teto 3s). Campos ausentes (`matcher`,
  `commandWindows`, `statusMessage`, `additionalContextLimit`) não entram.
  Campos extras no arquivo — como o nosso marcador `_cockpit` — são ignorados
  na desserialização e **não** afetam o hash.

Como o hash deriva da config e não do binário, o Cockpit computa e grava o trust
junto com a instalação: o usuário não precisa aprovar nada na mão. É o mesmo
grau de confiança que já assumimos ao escrever no `settings.json` do Claude —
instalamos o nosso helper, e só ele. O bloco fica entre delimitadores
(`# >>> cockpit hooks` … `# <<< cockpit hooks`) e é regerado a cada boot;
o resto do `config.toml` nunca é tocado.

Referência no fonte do Codex: `codex-rs/hooks/src/engine/discovery.rs`
(`hook_hash`, `hook_key`) e `codex-rs/config/src/fingerprint.rs`
(`version_for_toml`).

### Limitações conhecidas

- **Índice do grupo faz parte da chave.** Se o usuário adicionar um hook próprio
  *antes* do nosso no mesmo evento, nosso índice muda e o trust deixa de bater —
  o hook para de rodar, em silêncio. O instalador corrige no boot seguinte,
  porque recalcula os índices a partir do arquivo final.
- **Editar o `hooks.json` na mão** entre boots tem o mesmo efeito, e a mesma
  correção.
- Se o Codex mudar o algoritmo do hash, o teste de golden em
  `test/data/codex_hook_installer_test.dart` quebra — os valores lá foram
  capturados de uma sessão real que executou os hooks sem
  `--dangerously-bypass-hook-trust`.

## OpenCode (plugin)

O OpenCode não lê um arquivo de hooks: ele carrega **plugins** (JS/TS) de
`~/.config/opencode/plugins/` ao iniciar. O `OpenCodeHookInstallerImpl` grava
**um arquivo só, nosso** (`cockpit-status.ts`, marcado `cockpit-managed v1` e
reescrito só quando o conteúdo muda); plugins do usuário nunca são tocados.

O plugin traduz os eventos do OpenCode para os **mesmos nomes** que o Codex já
manda e chama `cockpit hook --harness opencode` com o JSON no stdin. Por isso o
`hook.rs` e o app não mudam:

| Evento do OpenCode | Enviado como | Status |
|---|---|---|
| `session.status` = `busy` | `UserPromptSubmit` | `working` |
| hook `tool.execute.before` | `PreToolUse` | `working` |
| `permission.asked` / `permission.updated`, `question.asked` | `PermissionRequest` | `waiting` |
| `permission.replied`, `question.replied` / `question.rejected` | `PostToolUse` | `working` |
| `session.idle`, `session.status` = `idle`, `session.error` | `Stop` | `idle` |
| `session.created` (sessão principal), `tui.session.select` | `SessionStart` | `idle` (leva o session-id) |
| `session.deleted` (a da aba), `server.instance.disposed`, `global.disposed`, hook `dispose` | `SessionEnd` | `idle` |

- Sessões com `parentID` (subagentes) são **ignoradas**, pela mesma razão de
  `SubagentStart`/`SubagentStop` no Codex.
- Fora do Cockpit (sem `COCKPIT_TAB_ID`) o plugin não faz nada.
- Status repetido não é reenviado (um processo `cockpit hook` a menos por
  ferramenta).
- Se a CLI empacotada for a legada (`cockpit-hook`, sem o subcomando `hook`),
  o instalador não grava o plugin.

## Estrutura no código

```
cli/src/hook.rs                                   # tradução evento → status (agnóstico de harness)
lib/app/cockpit/domain/contracts/hook_installer.dart
lib/app/cockpit/data/hooks/hook_installer_base.dart      # CLI + comando (comum)
lib/app/cockpit/data/hooks/claude_hook_installer_impl.dart
lib/app/cockpit/data/hooks/codex_hook_installer_impl.dart
lib/app/cockpit/data/hooks/opencode_hook_installer_impl.dart
lib/app/cockpit/data/hooks/opencode_plugin_source.dart    # fonte do plugin do OpenCode
lib/app/bootstrapper.dart                         # roda os três no boot, não-fatal
```
