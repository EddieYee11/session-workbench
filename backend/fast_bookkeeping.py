"""确定性记账快通道：明确记账意图不过大模型，直接写账本并回读。

主聊天消息在交给 Hermes 之前先过这里。parse() 返回 None 表示这条不该走快通道
（意图不明、金额缺失或有歧义、分类拿不准），原样交回 Hermes；只有返回计划时才由
本路径独占这次写入。授权判据复用 policy 的 bookkeeping_intent / bookkeeping_details，
和 Hermes 工具面（agent_tools.authorize_tool）是同一套，不新增更宽的授权。
分类与账户关键词表沿用 Siri 快通道（mini ~/.hermes/scripts/siri_fastpath.py），
保证两个入口对同一句话的记账口径一致。
"""
import re

from policy import (
    BOOK_BLOCK,
    _money_matches,
    bookkeeping_details,
    bookkeeping_intent,
    bookkeeping_query,
    money_amounts,
    quote_free,
)

DEFAULT_ACCOUNT = '招商银行储蓄卡'
INCOME_CATEGORIES = ('工资', '奖金', '报销', '其他收入')
MAX_AMOUNT = 200000

CATEGORY_KEYWORDS = (
    ('餐饮外卖', '早饭 早餐 午饭 午餐 晚饭 晚餐 夜宵 外卖 咖啡 奶茶 饮料 饮品 可乐 啤酒 饭 餐 吃 喝 面 粉 火锅 烧烤 瑞幸 星巴克 麦当劳 肯德基 便利店 水果 零食 超市 买菜'),
    ('出行交通', '打车 滴滴 地铁 公交 高铁 火车 机票 飞机 油 加油 停车 高速 过路 骑行 单车 出租'),
    ('汽车摩托', '摩托 机油 保养 车险 洗车 轮胎 头盔'),
    ('居住房租', '房租 水电 燃气 物业 电费 水费'),
    ('通讯话费', '话费 流量 宽带'),
    ('App订阅', '订阅 会员 Claude ChatGPT Kimi iCloud Netflix Spotify Apple'),
    ('健康医疗', '药 医院 挂号 体检 牙 诊所'),
    ('个护美容', '理发 剪发 剪头 头发 洗澡 护肤 洗衣'),
    ('娱乐休闲', '电影 攀岩 岩馆 游戏 KTV 门票 演出 健身 泳'),
    ('学习成长', '书 课 课程 培训 学费'),
    ('人情社交', '红包 礼物 请客 份子 送礼'),
    ('数码电子', '数码 耳机 键盘 鼠标 手机 电脑 充电 线 相机 镜头'),
    ('宠物', '猫 狗 宠物 猫粮 狗粮'),
    ('购物消费', '买 衣服 鞋 裤 淘宝 京东 拼多多 购物 包'),
)
INCOME_KEYWORDS = (
    ('工资', '工资 薪水'),
    ('奖金', '奖金 年终'),
    ('报销', '报销'),
    ('其他收入', '收入 到账 转账 退款 收到 得'),
)
ACCOUNT_KEYWORDS = (
    ('现金', '现金'),
    ('花呗', '花呗'),
    ('京东白条', '白条'),
    ('信用卡-招商', '信用卡 招商信用卡'),
    ('信用卡-中信visa', '中信'),
    ('信用卡-招商万事达', '万事达'),
    ('工商银行', '工行 工商'),
)

# 记账动词/花费词：出现在句首或句中，都不该进备注。
BOOK_WORDS = '记账|记一笔|记一下|记下|记录|花了|花费|消费|支出|用了|付了|到账|收入|收到'
PREFIX = re.compile(r'^(?:' + BOOK_WORDS + r')了?\s*[:：,，]?\s*')
VERB = re.compile(r'(?:' + BOOK_WORDS + r')了?')
POLITE = re.compile(r'^(?:(?:能不能|可不可以|可以|请|麻烦|帮我|给我|替我|我要|我想|我需要)\s*)+')


def _keyword(text, table):
    lowered = text.lower()
    for name, keywords in table:
        for word in keywords.split():
            if word.lower() in lowered:
                return name
    return None


def _comment(text):
    """备注：去掉金额、记账动词、账户词和客套前缀后的剩余内容。"""
    rest = text
    for start, end, _ in reversed(_money_matches(text)):
        rest = rest[:start] + ' ' + rest[end:]
    rest = PREFIX.sub('', rest.strip())
    rest = POLITE.sub('', rest)
    for _, keywords in ACCOUNT_KEYWORDS:
        for word in keywords.split():
            rest = rest.replace(word, ' ')
    rest = VERB.sub(' ', rest)
    rest = re.sub(r'\s+([，,。.：:？?])', r'\1', rest)
    return re.sub(r'\s+', ' ', rest).strip(' ，,。.：:·')


def parse(text):
    """返回 ezbookkeeping 的记账参数；返回 None 表示交回 Hermes（模糊回退）。"""
    external = quote_free(text)
    if not external or not bookkeeping_intent(external):
        return None
    amounts = {value for value in money_amounts(external)}
    if len(amounts) != 1:
        return None
    amount = amounts.pop()
    if not 0 < amount <= MAX_AMOUNT:
        return None
    permitted, _ = bookkeeping_details(external, float(amount))
    if not permitted:
        return None
    category = (_keyword(external, INCOME_KEYWORDS)
                or _keyword(external, CATEGORY_KEYWORDS)
                or ('其他收入' if '得' in external else None))
    if not category:
        # 关键词表认不出用途就交回 Hermes，宁可不快也不要落错分类。
        return None
    return {
        'amount': float(amount),
        'category': category,
        'account': _keyword(external, ACCOUNT_KEYWORDS) or DEFAULT_ACCOUNT,
        'comment': _comment(external),
    }


def parse_candidate(text):
    """模糊记账只产出待确认候选，绝不授权写入。

    parse() 已完成第一道筛选，这里兜住“含义足够清楚但没打中词表”的口语：
    单个金额、不是查询/否定/第三人口述，且金额外还留有可读用途。
    """
    external = quote_free(text)
    if not external or bookkeeping_query(external) or BOOK_BLOCK.search(external):
        return None
    if re.search(r"我(?:的)?(?:朋友|同事|家人)|(?:他|她|他们|她们)(?:买|花|消费|支出|付)", external):
        return None
    hits = _money_matches(external)
    if len(hits) != 1:
        return None
    # 金额词表可能被第二个裸数字替代，候选层仍需按真实数字数量拒绝多金额。
    # 中文金额没有阿拉伯数字；只有出现裸数字时才用它们识别多金额。
    separate_numbers = re.findall(r'\d+(?:\.\d+)?', external)
    if separate_numbers and (len(separate_numbers) != 1 or len(set(separate_numbers)) != 1):
        return None
    amount = hits[0][2]
    if not 0 < amount <= MAX_AMOUNT:
        return None
    # 去掉金额后的残留词表达真实用途；亮词/纯符号/只有常用客套语不算。
    remainder = external
    start, end, _ = hits[0]
    remainder = (remainder[:start] + ' ' + remainder[end:]).strip()
    if re.fullmatch(r'[\W\d\s_]*', remainder, re.I):
        return None
    if not re.search(r'[\u4e00-\u9fffA-Za-z]', remainder):
        return None
    # 金额、分类与账户只用于展示建议；只有用户确认后且 policy 校验通过才会写入。
    return {
        'amount': float(amount),
        'category': (_keyword(external, INCOME_KEYWORDS)
                     or _keyword(external, CATEGORY_KEYWORDS)
                     or ('其他收入' if '得' in external else '购物消费')),
        'account': DEFAULT_ACCOUNT,
        'comment': _comment(external),
    }
    # 模糊候选不带政策授权；确认时会重新走 bookkeeping_details。


def confirm_card(result):
    """把候选转成用户可点击/可回复的确认卡；正文必须触发澄清绑定。"""
    sign = '+' if result.get('category') in INCOME_CATEGORIES else '-'
    text = '记一笔 %s%g · %s' % (sign, float(result.get('amount', 0)), result.get('category', ''))
    if result.get('comment'):
        text += '·' + str(result['comment'])
    text += '（' + str(result.get('account') or DEFAULT_ACCOUNT) + '），记这笔账吗？确认金额后直接入账。'
    return text


def receipt(result):
    """已记 -35 餐饮外卖·午饭 —— 与 Siri 快通道同一句式。"""
    sign = '+' if result.get('category') in INCOME_CATEGORIES else '-'
    text = '已记 %s%g %s' % (sign, float(result.get('amount', 0)), result.get('category', ''))
    if result.get('comment'):
        text += '·' + str(result['comment'])
    if result.get('account') and result['account'] != DEFAULT_ACCOUNT:
        text += '（' + str(result['account']) + '）'
    return text
