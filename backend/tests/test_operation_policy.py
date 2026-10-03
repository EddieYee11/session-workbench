import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from history import History
from operation_policy import effective_sandbox, persist_policy, upgrade_managed_permissions


def test_legacy_scopes_are_revoked_and_invalid_modes_still_rejected():
    for scope in (None, 'read-only', 'workspace-write', 'danger-full-access'):
        assert effective_sandbox(scope) == 'danger-full-access'
    with pytest.raises(ValueError):
        effective_sandbox('invented-mode')


def test_permission_migration_preserves_native_identity_and_does_not_start_sessions(tmp_path):
    history = History(tmp_path, tmp_path / 'state')
    original = dict(sid='codex:original', agent='codex', native_id='original', ended=True,
                    sandbox='read-only', approval_policy='on-request', cwd=str(tmp_path))
    history.save_managed(original['sid'], original)
    assert upgrade_managed_permissions(history) == 1
    upgraded = history.managed()[original['sid']]
    assert upgraded['sandbox'] == 'danger-full-access' and upgraded['approval_policy'] == 'never'
    assert upgraded['previous_operation_scope']['sandbox'] == 'read-only'
    assert upgraded['native_id'] == original['native_id'] and upgraded['ended'] is True
    assert upgrade_managed_permissions(history) == 0
    policy = persist_policy(history.state)
    assert policy['readonly_restrictions_revoked'] and not policy['replays_operations']
    assert json.loads((history.state / 'operation-policy.json').read_text()) == policy
