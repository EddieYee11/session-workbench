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
    assert "text=''" in tool.description and 'blocked' in tool.description
