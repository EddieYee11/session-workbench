import asyncio, json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from runsheet import RunSheets

DATA = {'focus': [{'project': '大有可攀', 'venue': '北顶', 'date': '2026-10-25', 'days_left': 1}, {'project': '远的', 'date': '2026-11-30', 'days_left': 36}],
        'wechat': [{'chat': '大有可攀筹备群', 'project': '大有可攀', 'recent': ['24日20:00 小倩：明早7点进场搭建', '24日20:05 老马：计时牌我带']}],
        'calendar': [{'title': '大有可攀攀岩生活节', 'start': '10-25 09:00', 'location': '北顶'}],
        'board': [{'title': '大有可攀物料清单', 'due': '2026-10-24', 'next': '', 'project': ''}, {'title': '无关的事', 'due': '', 'next': '', 'project': ''}]}


def test_runsheet_is_generated_once_for_the_day_before_and_renders_stable_checkboxes(tmp_path):
    seen = []
    async def model(payload):
        seen.append(payload)
        return {'summary': '七点进场，九点开场', 'timeline': [{'time': '07:00', 'what': '进场搭建', 'who': '小倩', 'where': '北顶'}, {'what': ''}],
                'checklist': [{'text': '计时牌', 'who': '老马'}], 'contacts': [{'name': '小倩', 'role': '现场总控'}], 'risks': ['降温'], 'evil': '<script>'}
    sheets = RunSheets(tmp_path / 'state', tmp_path, model, clock=lambda: 1792900000)
    (tmp_path / 'state').mkdir()
    made = asyncio.run(sheets.ensure(DATA))
    assert len(made) == 1 and made[0]['path'] == 'work/航程产出/2026-10-25-大有可攀-当日流程.html'
    assert [t['title'] for t in seen[0]['todos']] == ['大有可攀物料清单'] and len(seen[0]['events']) == 1
    page = (tmp_path / made[0]['path']).read_text()
    assert '07:00　进场搭建' in page and 'type="checkbox" id="c-' in page and '<script>' not in page and '待定' not in page.split('<footer>')[0].replace('「待定」', '')
    assert asyncio.run(sheets.ensure(DATA)) == [], '同一天不重复生成'
    assert sheets.get('大有可攀', '2026-10-25')['counts'] == {'timeline': 1, 'checklist': 1}


def test_runsheet_refuses_empty_output(tmp_path):
    async def model(payload):
        return {'summary': 'x'}
    sheets = RunSheets(tmp_path, tmp_path, model)
    try:
        asyncio.run(sheets.generate(DATA['focus'][0], DATA))
        assert False
    except ValueError:
        pass
    assert sheets.index() == {}
