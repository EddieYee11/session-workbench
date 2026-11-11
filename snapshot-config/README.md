# Com pre-rework snapshot - 2026-11-12

Snapshot of the Com project (session-workbench) taken before the big
OpenMausBot-style rework, so the pre-rework state can be restored.

Branch: snapshot/20261112-pre-rework
Based on: com-superagent-events at e1d4f37b7dd790e87db9acabed68f8f065cc0f7f,
plus the uncommitted working-tree state at snapshot time.
Taken: 2026-11-12, overnight safety snapshot run.

Contents:
- backend/ : live backend as of snapshot time (incl. send_message.py, evolution work)
- ios/ : iOS app source as of snapshot time
- docs/ : docs as of snapshot time
- snapshot-config/superagent-flags.json : live superagent flags from mini (send_message on)
- snapshot-config/hermes-config-sanitized.yaml : Hermes com-personal config, secrets removed

Excluded on purpose: sqlite and db files, env files, keys, tokens, credentials,
chat records, DerivedData, build outputs, app bundles, Pods, node_modules,
backend backup copies, _archive, _bak, scratchpad, records, android, web.

Rollback:
  git checkout snapshot/20261112-pre-rework
  Then restart the backend services on mini as before.
  The flags file here is a copy; restore it by hand if needed.
