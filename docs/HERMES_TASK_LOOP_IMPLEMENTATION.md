# Hermes task loop — local review build

Baseline: `52013086570f87a0f645602972feb06ef0a5d8f4`, branch `hermes-task-loop`.
No production processes, credentials, device permissions, APK installs or remote Git writes were changed.

## Implemented

- SQLite task records separate from conversation messages and worker sessions; source message, prompt/goal, constraints, completion boundary, authorization snapshot and worker session/native turn are preserved.
- Append-only events and transactional terminal outbox. Conversation receipt has a unique request key; crash between insert and outbox acknowledgement cannot duplicate the receipt. Worker completion is explicitly “execution finished, pending acceptance”.
- Existing approval route now requires explicit task authorization. Android refresh no longer approves proposals. Proposal card shows the directory, prompt and sandbox before the explicit approval action. Same-directory tasks serialize; unknown runs block another launch.
- Existing worker adapters retained. Codex uses `turn/steer` with `expectedTurnId`; cancellation only becomes cancelled after runtime reports interrupted. Pi constraints are accepted pending delivery because the existing terminal transport has no safe running-turn steer.
- Restart recovers active tasks to unknown, never resends worker commands. Duplicate command keys do not steer or cancel twice. Uncertain deliveries remain visible in events.
- `/personal/tasks`, task input and cancel routes; activity ledger uses these task records instead of treating Hermes conversational runs as tasks. Cached task records remain visible offline; controls require a fresh connection. Results and real event text are visible in the task timeline; execution-session navigation remains.
- Hermes real transport receives source IDs and bounded task/result context on the next conversational turn. MCP adds durable task listing and constraint update without creating another task or granting execution permission. Ambiguous references require clarification in the tool/transport instructions.

## Verification

On this Mac, isolated Python 3.12 virtual environment and temporary test databases:
`python -m pytest backend/tests -q`: **37 passed**, one upstream Starlette/httpx deprecation warning.
`python -m compileall -q backend`, `git diff --check`: passed.

New tests cover two tasks, updating A without task C, conversational submission without dispatch, duplicate steer/cancel, cancellation pending vs confirmed, restart unknown/no replay, terminal outbox redelivery after acknowledgement loss, source linkage and rejection of refresh-only approval.
Existing approval dispatch tests use fake create/input adapters; no real worker launched. Existing runtime/API/voice/history tests pass.

Android `./gradlew testDebugUnitTest assembleDebug` was attempted and failed before Gradle execution because no Java Runtime is installed. The production local.properties points to `/opt/homebrew/share/android-commandlinetools`, which is absent here. No narrow/expanded rendering, emulator or physical-device checks were possible. Kotlin changes require compilation and UI verification before release.

## Remaining boundaries

- Natural-language routing uses existing Hermes with tool instructions, not a deterministic local parser. Paid-model A/B/constraint/ambiguous-reference behavior is unverified. Fake tests exercise product state transitions, not language understanding.
- MCP constraints are recorded as accepted pending delivery, not automatically steered; Android explicit input can steer Codex. Pi running-turn input is deliberately pending. A durable queued-input delivery worker is still needed for automatic safe delivery, including task-level permission checking of changed instructions.
- Startup unknown runs need operator reconciliation; no automatic replay. Runtime stop confirmation depends on real interrupted events, which needs authorized adapter verification. A missing terminal event keeps a task active/unknown rather than claiming cancellation.
- Worker result comes from persisted assistant events. No assistant body yields an explicit missing-result notice with a session link. This is not independent task acceptance or validation.
- Tasks created by an older build without ledger linkage become unknown; they do not automatically resume. Rejected and expired cards remain inspectable.
- Task completion reaches the local main conversation immediately; Hermes model sees the bounded ledger context on its next turn. No extra paid-model summarization is invoked.
- Existing manual Pi/Codex pages and adapters were retained; physical-device regression remains unverified.

## Minimal next release steps (separate authorization)

1. Provision/locate JDK and Android SDK; compile tests/debug build and verify offline/reconnect/repeated clicks/back navigation at narrow and expanded widths.
2. In a nonproduction service instance, authorize scoped native Codex/Pi adapter tests and model routing tests; reconcile native cancellation and result events, implement/review queued constraint delivery.
3. Review permission boundaries and code, then separately authorize push/PR/deployment and APK installation. This checkout is a reviewable intermediate implementation, not a production-ready release.
