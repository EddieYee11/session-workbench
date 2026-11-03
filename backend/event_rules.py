"""事件规则表（11-02，借鉴 rules.json）：哪类事件怎么处理，改 event_rules.json 一行即可，无需重启。

文件改坏时继续用上一份能用的，并记下错误；启动前可跑 `python event_rules.py` 检查。
敏感内容、过期、空批次是代码里的硬闸门（evals.gate），规则表放不开。
"""
import json, re, sys
from pathlib import Path

PATH = Path(__file__).with_name('event_rules.json')


def validate(data):
    if not isinstance(data, dict) or not isinstance(data.get('rules'), list) or not data['rules']:
        raise ValueError('rules 不能为空')
    defaults = data.get('defaults') or {}
    if int(defaults.get('parallel', 1)) < 1 or float(defaults.get('cooldown_minutes', 0)) < 0:
        raise ValueError('defaults 取值不合法')
    for rule in data['rules']:
        when = rule.get('when')
        if not rule.get('name') or not isinstance(when, dict) or rule.get('then') not in ('filter', 'judge'):
            raise ValueError(f'规则不完整：{rule}')
        if rule['then'] == 'filter' and not rule.get('reason'):
            raise ValueError(f"filter 规则要写 reason：{rule['name']}")
        if set(when) - {'sources', 'actor', 'text'}:
            raise ValueError(f"未知条件：{rule['name']}")
        for key in ('actor', 'text'):
            if key in when:
                re.compile(when[key])
    if data['rules'][-1]['when']:
        raise ValueError('最后一条必须是兜底规则（when 为空）')
    conversation = data.get('conversation') or {}
    if 'deep_work' in conversation:
        re.compile(conversation['deep_work'])
    return data


class EventRules:
    def __init__(self, path=PATH):
        self.path, self.stamp, self.data, self.error = Path(path), None, None, ''
        self.refresh()
        if self.data is None:
            raise ValueError(f'事件规则表不可用：{self.error}')

    def refresh(self):
        """文件变了才重读；改坏时保留上一份能用的。"""
        try:
            stamp = self.path.stat().st_mtime_ns
            if stamp != self.stamp:
                self.stamp = stamp
                self.data, self.error = validate(json.loads(self.path.read_text())), ''
        except (OSError, ValueError, TypeError, re.error) as error:
            self.error = f'{type(error).__name__}: {error}'[:300]
        return self.data

    def match(self, source, actor='', summary=''):
        """第一条命中的规则生效。"""
        for rule in self.refresh()['rules']:
            when = rule['when']
            if 'sources' in when and source not in when['sources']:
                continue
            if 'actor' in when and not re.search(when['actor'], actor or '', re.I):
                continue
            if 'text' in when and not re.search(when['text'], summary or '', re.I):
                continue
            return rule
        return self.data['rules'][-1]

    def setting(self, rule, key):
        return rule.get(key, (self.refresh().get('defaults') or {}).get(key))

    def mandate_allowed(self, source):
        """只看来源的规则决定能不能备草稿，不受发件人或正文影响。"""
        for rule in self.refresh()['rules']:
            if source in rule['when'].get('sources', ()):
                return bool(rule.get('mandate'))
        return False

    def conversation(self):
        return self.refresh().get('conversation') or {}


rules = EventRules()


if __name__ == '__main__':
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else PATH
    validate(json.loads(target.read_text()))
    print(f'规则表可用：{target}')
