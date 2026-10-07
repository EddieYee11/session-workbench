"""The actual model-facing schema must require a structured restriction choice.

MCP runs in the Hermes environment. This contract is also run there when the
workbench test environment does not include that optional runtime dependency.
"""
import asyncio
import sys
from pathlib import Path
import pytest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))


def test_constraint_tool_requires_explicit_enum_without_authorizing_notes():
    pytest.importorskip('mcp')
    import hermes_mcp
    tools=asyncio.run(hermes_mcp.mcp.list_tools())
    tool=next(t for t in tools if t.name=='update_task_constraints')
    schema=tool.inputSchema
    assert 'constraint_type' in schema['required']
    kind=schema['properties']['constraint_type']
    assert set(kind['enum'])=={'read_only','preserve_style','forbid_path','note'}
    assert 'default' not in kind
    assert 'note' in tool.description and '回执不代表' in tool.description


def test_delegation_schema_defaults_to_full_access_but_keeps_real_source_required():
    pytest.importorskip('mcp')
    import hermes_mcp
    tools=asyncio.run(hermes_mcp.mcp.list_tools())
    for name in ('create_task','task_submit'):
        tool=next(t for t in tools if t.name==name)
        schema=tool.inputSchema
        assert schema['properties']['sandbox']['default']=='danger-full-access'
        assert 'sandbox' not in schema['required']
        assert 'source_quote' in schema['required']
        assert not {'origin_message_id','origin_request_id','origin_session_id'} & set(schema['properties'])
        # Wire validation remains stricter than the advertised model schema.
        fields=hermes_mcp.mcp._tool_manager.get_tool(name).fn_metadata.arg_model.model_fields
        assert all(fields[k].is_required() for k in ('origin_message_id','origin_request_id','origin_session_id'))
        assert '受理不' in tool.description
        assert tool.annotations.readOnlyHint is False
    merge=next(t for t in tools if t.name=='task_merge')
    assert '历史工作副本' in merge.description and '不需要合并' in merge.description
