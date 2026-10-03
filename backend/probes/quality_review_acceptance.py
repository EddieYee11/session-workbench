"""Real isolated Pi Judge: reject missing deliverable, accept matching file evidence."""
import argparse
import asyncio
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from quality_judge import review


async def run():
    with tempfile.TemporaryDirectory(prefix='com-quality-review-') as folder:
        state = Path(folder)
        first = state / 'first.txt'
        second = state / 'second.txt'
        first.write_text('first deliverable\n')
        task = {'id': 'judge-acceptance', 'title': '交付两个文本文件', 'status': 'execution_finished',
                'cwd': folder, 'run_id': 'missing-evidence',
                'authorization': {'source_quote': '创建 first.txt 和 second.txt 两个文本文件，分别写入 first deliverable 和 second deliverable。'},
                'completion_condition': '两个文件存在且内容符合原要求',
                'acceptance_criteria': [{'id': 'first', 'description': 'first.txt 内容含 first deliverable'},
                                        {'id': 'second', 'description': 'second.txt 内容含 second deliverable'}],
                'result': '我已经把两个文件全部完成', 'constraints': []}
        evidence = [{'reference': str(first), 'check': 'file_contains', 'criterion_id': 'first', 'passed': True}]
        negative = await review(task, evidence, state)
        assert negative['verdict'] in {'revise', 'unknown'}, negative
        second.write_text('second deliverable\n')
        evidence.append({'reference': str(second), 'check': 'file_contains', 'criterion_id': 'second', 'passed': True})
        task['run_id'] = 'complete-evidence'
        positive = await review(task, evidence, state)
        assert positive['verdict'] == 'pass', positive
        return {'no_production_state': True, 'reviewer_tools': False,
                'missing_artifact': negative, 'complete_artifacts': positive}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output')
    args = parser.parse_args()
    report = asyncio.run(run())
    if args.output:
        target = Path(args.output)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(report, ensure_ascii=False, indent=2))
        target.chmod(0o600)
    print(json.dumps(report, ensure_ascii=False))
