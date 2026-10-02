# Hermes task loop

## 2026-10-02: executable main-chat task loop

This update applies to the live `会话工作台` source imported from mini's dot build (`3f3080b`). The older local-review record below remains historical evidence; its statements about unperformed native-worker testing do not describe this follow-up.

### Main conversation and independent work

- `create_task` sends a fixed authenticated `/personal/tasks/create` request. The backend verifies the source is an actual user message, its request ID belongs to that message, its Hermes session is the main conversation, and `source_quote` occurs verbatim in that message. A narrow direct-assignment check rejects feelings, vague wishes and consequential operations. The model remains responsible for interpreting which task the user meant; the backend does not continuously scan conversation text or invent tasks.
- Automatic work supports Codex `read-only`, or `workspace-write` for explicit code changes, in an existing project under `AI_Work_System`. Pi full access, deletion, publishing, external messaging, deployment and authentication changes keep the concrete approval-proposal path. The task stores the original source quote, task goal, completion condition, directory and authorization snapshot. Native sandbox and approvals remain the execution boundary; prompt restrictions are not a filesystem sandbox.
- Creation persists `queued` and returns `task_id` immediately. A separate task loop starts isolated native workers, with a limit of two active tasks. Same-directory writers serialize; two readers may run together. Unknown runs block conflicting work. A queued task survives restart; a claimed dispatch becomes unknown rather than being replayed.
- Main chat receives bounded recent task context, delivery states, results, project root and executor capabilities. Active work is prioritized, avoiding the old newest-task omission after 30 records. `recent_work_sessions` now includes the actual working directory.
- `update_task_constraints` supports `read_only`, `forbid_path` and `preserve_style`. Restrictions received while queued or awaiting approval remain `pending_start`, join the initial prompt and become `delivered` only after a confirmed native turn is returned. Restrictions on an active Codex turn use the original `expectedTurnId`. Arbitrary model notes remain blocked and do not enter the executable constraint list. Existing Pi tmux sessions explicitly report unsupported steer.
- `get_task_status` reads the ledger. `cancel_task` references a real user stop request and the exact existing task ID. A queued task can be cancelled before starting. Active Codex cancellation targets the original native turn, rather than the newest turn in that session. The task stays `cancel_requested` until an actual interrupted event; uncertain cancellation remains uncertain on retry.
- Native waiting events and failures are persisted. Final results use the last completed assistant record; tools, reasoning, streaming deltas and unrelated turns are excluded. Failure text includes the native turn error rather than an unexplained missing-result notice. Execution finished still requires acceptance; input delivery still does not prove compliance.

### Mini runtime inspection and required deployment

Read-only checks on mini confirmed:

- `work.eddie.sessions` runs `~/.session-workbench/venv/bin/python -m uvicorn app:app` on `127.0.0.1:8650`; its `WorkingDirectory` is the synchronized project `backend/`.
- Hermes `ai.hermes.com-personal` runs the isolated `com-personal` gateway profile; its API health on `8649` reports Hermes `0.21.5`. The profile starts this project's `backend/hermes_mcp.py` as a real stdio MCP process.
- Before this follow-up's production restart, `/personal/tasks` returned 404 and `tasks.sqlite` was absent: source presence or an APK build alone did not mean the backend was loaded.
- The dedicated profile MCP allowlist initially exposed only `personal_overview`, `recent_work_sessions`, `propose_work`, `work_proposal_status`. Deployment must append `personal_tasks`, `update_task_constraints`, `create_task`, `get_task_status`, `cancel_task` to `mcp_servers.com_workbench.tools.include`, preserving the other fields and credentials.
- After synchronized source hashes match, restart only `work.eddie.sessions` and `ai.hermes.com-personal`, then verify health, the protected tasks API and a fresh Hermes tool list. No global authentication configuration or triage profile needs changing. Deployment and phone acceptance are coordinated by the main agent; this backend follow-up did not restart production services.

### Current verification

- Full backend suite: **62 passed**, one upstream Starlette/httpx deprecation warning. New cases cover verified human source, rejected wish/small-talk/consequential authorization, two tasks and a restriction without a third task, main-chat submission while dispatch is waiting, HTTP pairing/idempotency, restrictions before approval, queued restart/cancel, exact-turn cancellation, uncertain retry, recent context and expired proposal synchronization.
- Python compile check and `git diff --check`: passed. The real Hermes Python environment successfully lists all nine MCP tools from the updated source.
- Real mini Codex validation ran two `read-only` native threads/turns in an isolated synthetic fixture. A reported **2 ordinary files**, B reported **0 first-level directories**; both reached `execution_finished`. A received a real native `turn/steer` acknowledgement for its original turn and ledger delivery became `delivered`. A further conversational message was accepted; only two tasks existed; the fixture still contained only `alpha.txt` and `beta.txt`.
- Successful native evidence is at `~/.session-workbench/task-loop-validation-20261002-1790926987/verification.json` on mini, with native event logs in the same directory. Task interpretation was supplied deterministically; this is a real adapter/worker test, not verification of Hermes' natural-language routing.
- The first native attempt exposed a stale CLI-config model alias rejected by the ChatGPT account. Task workers now select the account's advertised `model/list` default, with its default effort, rather than hardcoding or changing global model configuration. The second native attempt completed successfully.

### Completed production and phone checks

The production services were restarted after synchronized hashes matched. The dedicated gateway allowlist now includes all nine tools. Real natural main-chat assignments created two independent Codex workers; the final pair returned 2 ordinary files and 0 first-level directories. The phone task page displayed their live ledger, and work finished after the phone returned to its launcher. Task receipts reached the same persistent main conversation.

A follow-up read-only restriction targeted the original task ID and reached `delivered`; small talk stayed in conversation and created no extra task. The first natural test exposed a schema ambiguity: the model put `read_only` in `text` and omitted the restriction kind. `constraint_type` is now a required Literal enum with concrete tool descriptions and transport examples; the repeated natural test succeeded. Arbitrary notes still cannot grant execution authority. User-facing task receipts now use Chinese state labels.

A separate actual native cancellation reached `cancelled` only after the native interrupted event. The original turn ID stayed associated with that request. Evidence is saved on mini at `~/.session-workbench/com15-live-acceptance/verification-final.json` and `verification-cancel.json`. These are real model/runtime checks, distinct from the historical mock tests below.

Android 1.5.0 was installed on the Xiaomi phone with its existing local signing key. Main chat, real task details, floating Com2 navigation and direct local calendar reading were inspected; the four current events were shown and an event opened the actual system calendar. Current navigation tests passed seven checks at both narrow and wide emulator sizes. See `com-1.5.0.md` for the latest release record.

Existing Pi RPC steer, automatic acceptance validation and recovery of unknown executions remain unimplemented boundaries. Physical fold/unfold and genuine user speech remain separate handheld acceptance paths.

## Historical local-review build

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
- Android final command: `testDebugUnitTest assembleDebug assembleDebugAndroidTest lintDebug` — **BUILD SUCCESSFUL**.
- Android active JVM unit suite: **19 passed**, zero failures/errors/skips (18 existing active cases + new ledger status case). Six obsolete `VoiceSheetGestureTest` cases were removed: baseline commit `c370e52` replaced the expanding voice sheet with a floating expense window and deleted both tested helpers, while leaving their tests behind. Dead production helpers were not reintroduced merely to satisfy obsolete tests.
- Main Kotlin and instrumented-test Kotlin compile; both main and AndroidTest APKs generated. Instrumented tests **compiled, not executed**.
- Android Lint: **0 errors, 13 warnings**. Actual build discovery also fixed the baseline PhonePermissions location checks with an explicit permission guard and SecurityException handling, plus API-30 guard for notification detail settings. No permissions added; Manifest remains identical to the baseline.
- APK signature verification passed (v2), one signer.

### Authorized local toolchain setup

After explicit user authorization, installed into the task workspace, with per-command environment variables only:

- Eclipse Temurin JDK **17.0.20.1**, official Adoptium release/API; SHA-256 verified.
- Google Mac ARM command-line tools **22.0**; official SHA-256 verified.
- Android Platform **35** (revision 2), Build Tools **35.0.0**, Platform Tools **37.0.1**. Build Tools is pinned to 35.0.0 to stay within the approved component scope.
- Gradle **8.11.1**, repository-fixed official distribution.

Explicitly accepted **Android Software Development Kit License Agreement**, SDK package license ID `android-sdk-license`, for these components only. Official agreement/download page: https://developer.android.com/studio#command-tools . The sdkmanager component prompt displayed the January 16, 2019 package text under that license ID; the approved official download page displays the current agreement. Only the single required SDK license prompt was accepted; no blanket `yes sdkmanager --licenses`, emulator images or unrelated agreements.

Initial Java Maven TLS connections intermittently failed. Official Google/Maven Central artifacts were downloaded with curl and checked against official published checksums; a task-local initialization script exclusively routes two affected dependency versions (`androidx.test:runner:1.6.2`, `org.jetbrains.kotlin:kotlin-reflect:1.6.10`) to those verified local files. All other dependencies retain the repository's configured official sources. TLS/certificate validation and system safety settings were not relaxed. Final build uses this temporary local workaround; it is not committed as a repository mirror configuration.

Local evidence under `/Users/eddiegao/Documents/Codex/2026-10-02/task-2/`:

- `toolchains/build_android.sh`: per-command environment wrapper.
- `toolchains/android-build-final.log`: successful full Android build.
- `toolchains/backend-test.log`: 52 backend tests passed.
- `deliverables/verification.json`: exact JVM counts, lint counts, APK hashes and unexecuted-device flags.
- `repo/android/app/build/reports/lint-results-debug.html` and `repo/android/app/build/reports/tests/testDebugUnitTest/index.html`: generated reports.

APK deliverables (local only):

- `deliverables/com-hermes-task-loop-debug.apk` (69,671,769 bytes), SHA-256 `3a6ed51a6bbd371ae7a6fab81e5f4972ee137b591e9559ed1204634b32b338d1`.
- `deliverables/com-hermes-task-loop-androidTest.apk` (2,323,823 bytes), SHA-256 `ff385512b08400c036ff09aa93adcabbf196442d54846d9c8c58f2b2fc9eefc1`.

No APK was installed on a phone. No emulator image was approved or installed. Thus actual narrow/expanded rendering, instrumented parent-link/navigation tests, offline/reconnect/repeated-click/back-navigation and physical-device regression remain unverified; compilation and Lint are not visual acceptance.

## Explicit remaining boundaries

- Model language understanding is unverified: fixed tool-call mock scenarios test product transitions only. No paid-model routing, real Pi/Codex work, adapter cancellation or device acceptance was authorized/performed.
- Pi RPC integration for NEW isolated task sessions remains separate work; existing TUI sessions clearly report unsupported steer. This follow-up does not silently replace manual worker transport.
- A structured model restriction is automatically delivered only to an already authorized, known running task on a supported transport. Arbitrary new-action notes are blocked; the user can explicitly submit a scoped instruction in task details. Delivery does not prove the model complied.
- Worker result is actual final assistant event text; missing text yields an explicit missing-result notice with session navigation. No independent acceptance validator runs.
- Startup unknown execution needs operator reconciliation. Old unlinked accepted proposals become unknown and do not resume. Main conversation receives local task receipts immediately; Hermes sees ledger context on its next turn.
- Phone calendar remains permission-page event count, not main-conversation calendar context. Standard and Active both enable important notifications; differentiated proactive scheduling is not implemented. No real calendar or finance integration was expanded.

## Minimal next steps requiring separate setup/production authorization

1. Toolchain, APK compilation, JVM tests and Lint are complete. Separately authorize an emulator image or test-device installation to execute instrumented UI tests and verify narrow/expanded widths, offline/reconnect/back behavior.
2. In a nonproduction instance, authorize scoped native worker/model adapter tests; verify real Codex response/event versions and Pi cancellation/settlement. If desired, separately implement Pi RPC transport for new task sessions.
3. Review local commits and permission boundaries; separately authorize push/PR/deploy and APK installation. No such action has happened.
