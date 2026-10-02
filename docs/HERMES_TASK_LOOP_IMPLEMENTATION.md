# Hermes task loop — local review build

Baseline: `52013086570f87a0f645602972feb06ef0a5d8f4`; branch `hermes-task-loop`.
First implementation commit: `d4300e240b84207bf6aa363f736debeef1137227`; follow-up commit contains durable input delivery and correctness checks.
No production processes, credentials, device permissions, APK installs or remote Git writes were changed.

## Implemented product behavior

- SQLite tasks separate from conversation messages and worker sessions; source message, prompt/goal, constraints, completion boundary, task authorization snapshot and worker session/native turn remain linked.
- Persistent task events and transactional terminal outbox. Unique conversation receipt key prevents duplicates after crash/retry. Worker completion means execution finished, pending acceptance.
- Approval requires explicit task authorization. Android refresh never approves. Cards display directory, prompt and sandbox. Same-directory tasks serialize; unknown execution blocks another launch.
- Durable task input queue: accepted → queued → sending → delivered / worker_queued / failed / unsupported / unknown / blocked. SQLite claims happen before transmission; restart after claim yields unknown without replay. Duplicate request IDs return the existing delivery state. Worker-queued acknowledgements require a correlated delivery observation; absence for 120 seconds becomes unknown, never an endless silent queue.
- Codex adapter preserves `expectedTurnId`, checks returned `turnId`, records delivery to that turn separately from actual effect/acceptance. Existing runtime adapters and manual work pages are retained. Terminal events and final results are scoped by native turn; tool/reasoning deltas are excluded.
- MCP structured `read_only` and project-relative `forbid_path` restrictions automatically join the durable queue within existing task authorization. Arbitrary note text becomes `blocked_authorization`, with a visible reason. A model cannot turn notes into execution permission. Explicit UI instructions use the existing task scope; delivery text reiterates no permission expansion, publication, deletion or external messaging.
- Pi existing tmux/TUI adapter explicitly marks steer `unsupported` and records that it was NOT delivered. This does not claim the installed Pi RPC lacks steer; the current project has no RPC transport connection to those TUI sessions. No real worker was launched or migrated.
- Task-specific Pi completion now waits for `agent_settled`; `agent_end` alone cannot finish a task. New event extension captures settled/queue events. Manual Pi page status behavior remains unchanged.
- Cancel stays pending until worker reports interrupted. Worker/status failure produces unknown rather than false cancellation/completion. Unknown runs require reconciliation; no restart replay.
- Android activity ledger uses task IDs, not parent message grouping; two tasks from one message remain distinct. Parent linkage falls back through message_id / parent_message_id / origin_message_id. Unknown/future/ended states explicitly require verification, interrupted is stopped, completion remains pending acceptance. Details show events, complete result text and execution-session link. Cached controls require fresh connection.
- Voice submission success text now says “已交给助理 / 尚未收到实际账本回执”, including countdown and send phase. message_id is a conversation receipt, never proof of a financial transaction.
- Real Hermes transport receives source IDs and bounded task/input/result context on the next turn. No paid summarization or alternate agent hierarchy was introduced.

## Pi interface inspection (read-only, on this Mac)

Installed package `/usr/local/lib/node_modules/@earendil-works/pi-coding-agent`, version **0.99.2**:
`docs/rpc.md`, `docs/rpc-commands.md`, `docs/json.md` and extension type declarations were inspected.
RPC `steer` successful disposition `queued` means accepted/queued; delivery occurs before the next LLM call after current tool calls. RPC `abort` waits for idle before responding. `agent_settled` is final automatic-work settlement; `agent_end` is only a low-level run boundary.
Current Runtime.create uses `--approve` plus extensions and tmux, without `--mode rpc` or RPC stdin/stdout. Therefore this adapter cannot issue a supported RPC steer to existing sessions. Queue transitions to visible unsupported instead of silently waiting.
Default PATH Node v20.11.1 cannot load Pi 0.99.2 (package requires Node >=22.19.0). Read-only invocation with existing `/opt/homebrew/bin/node` v25.9.0 successfully returned Pi version 0.99.2. No global environment was changed.
The default Codex wrapper's `--version` fails because its configured native binary is absent. Native adapter semantics are mock-verified, not live-worker verified.

## Verification

Isolated Python 3.12 venv, temporary databases and fake workers only:

- Full repository backend suite: **52 passed**, one upstream Starlette/httpx deprecation warning.
- Existing regression suite alone (exclude new task test modules and new approval safety case): **34 passed**, one deselected. The earlier 37 result was the FULL suite at that point (34 existing + 3 new), not a selected subset.
- Current additions: 18 test cases covering A/B/updateA/idle conversation fixed tool decisions; parent linkage; authorization blocking; native turn/scope; MCP safe automatic restrictions; queue acknowledgement versus delivery; unsupported transport; rejection/timeout; repeated command; restart before/after claim; scoped completion/final text; cancel pending versus stopped; idempotent crash outbox receipts.
- `python -m compileall -q backend`, `git diff --check`: passed.
- New Kotlin unit status test and Android instrumented parent-link test are provided but **not executed**.

`./gradlew testDebugUnitTest assembleDebug` was attempted twice and fails before Gradle because no Java Runtime is available. Read-only search checked standard Android Studio/JBR locations in /Applications and user Applications, JAVA_HOME/ANDROID_HOME/ANDROID_SDK_ROOT, system/user JavaVirtualMachines, Homebrew/local JDK/Caskroom locations, SDKMAN/asdf/mise candidates, local tool directories and the project local.properties. System JavaVirtualMachines is empty; no Studio/JBR/JDK/adb was found. The production local.properties points to `/opt/homebrew/share/android-commandlinetools`, which does not exist. `~/Library/Android/sdk` is also absent. No global setup or tool installation was performed.

Thus Android compilation, existing JVM tests, instrumented tests, narrow/expanded rendering, offline/reconnect/repeated-click/back-navigation and physical-device regression are still unverified. Static review/diff checks are not compilation.

## Explicit remaining boundaries

- Model language understanding is unverified: fixed tool-call mock scenarios test product transitions only. No paid-model routing, real Pi/Codex work, adapter cancellation or device acceptance was authorized/performed.
- Pi RPC integration for NEW isolated task sessions remains separate work; existing TUI sessions clearly report unsupported steer. This follow-up does not silently replace manual worker transport.
- A structured model restriction is automatically delivered only to an already authorized, known running task on a supported transport. Arbitrary new-action notes are blocked; the user can explicitly submit a scoped instruction in task details. Delivery does not prove the model complied.
- Worker result is actual final assistant event text; missing text yields an explicit missing-result notice with session navigation. No independent acceptance validator runs.
- Startup unknown execution needs operator reconciliation. Old unlinked accepted proposals become unknown and do not resume. Main conversation receives local task receipts immediately; Hermes sees ledger context on its next turn.
- Phone calendar remains permission-page event count, not main-conversation calendar context. Standard and Active both enable important notifications; differentiated proactive scheduling is not implemented. No real calendar or finance integration was expanded.

## Minimal next steps requiring separate setup/production authorization

1. Make an existing approved JDK and Android SDK available, or authorize their installation; use per-command JAVA_HOME/SDK paths, compile and execute JVM/device tests at narrow and expanded widths.
2. In a nonproduction instance, authorize scoped native worker/model adapter tests; verify real Codex response/event versions and Pi cancellation/settlement. If desired, separately implement Pi RPC transport for new task sessions.
3. Review local commits and permission boundaries; separately authorize push/PR/deploy and APK installation. No such action has happened.
