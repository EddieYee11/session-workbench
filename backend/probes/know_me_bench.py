"""20 题「懂我」量化基准集 (`know_me_bench.py`)。

用途：
- `--offline`：毫秒级离线评估 `context_builder.build` + `memory_truth` 真相层对 Eddie 20 项核心身份、业务规范、
  硬件拓扑与协作红线的上下文召回覆盖率（要求命中率 `>= 90%`，且 `SENSITIVE` 命中数为 0、`system_chars` 未膨胀）。
- `--live`：连接本地 Magpie 快模型网关或运行中的 Com API 评估端到端回答得分（不调用任何商业付费 Claude 模型）。
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

BACKEND_DIR = Path(__file__).resolve().parents[1]
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

import httpx  # noqa: E402

import context_builder  # noqa: E402
from hermes_prompt import SYSTEM_PROMPT  # noqa: E402
from memory import SENSITIVE  # noqa: E402
from memory_truth import ensure_truth_files  # noqa: E402

PASS_THRESHOLD = 0.90
LIVE_MAGPIE_URL = "http://127.0.0.1:3001/v1/chat/completions"
LIVE_MAGPIE_MODEL = "auto/gemini-3.8-flash"


@dataclass(frozen=True)
class KnowMeCase:
    id: str
    category: str
    question: str
    # 每个元素是一个「必命中语义组」：组内任意一个候选词命中即视为该语义点召回成功；所有组均命中才算本题通过
    expected_groups: tuple[tuple[str, ...], ...]
    forbidden_terms: tuple[str, ...] = ()


KNOW_ME_CASES: tuple[KnowMeCase, ...] = (
    KnowMeCase(
        id="q01_name_and_address",
        category="identity",
        question="在私聊里你应该怎么称呼我？我的本名叫什么？",
        expected_groups=(("Eddie",), ("高杰",)),
    ),
    KnowMeCase(
        id="q02_wechat_and_group_aliases",
        category="identity",
        question="我的微信昵称是什么？在工作群里同事一般怎么称呼我？",
        expected_groups=(("野望",), ("野哥", "小野")),
    ),
    KnowMeCase(
        id="q03_partner_and_cat",
        category="identity",
        question="我的伴侣叫什么？家里的猫叫什么名字？",
        expected_groups=(("Rui",), ("Logo",)),
    ),
    KnowMeCase(
        id="q04_sohu_role_and_account",
        category="work",
        question="我现在在哪家公司担任什么角色？主理哪个户外内容账号？",
        expected_groups=(("搜狐",), ("内容导演", "资深视频编辑"), ("搜狐户外",)),
    ),
    KnowMeCase(
        id="q05_climbing_guidebook_column",
        category="work",
        question="搜狐户外的核心攀岩栏目叫什么名字？评测原则接不接硬广？",
        expected_groups=(("全国岩馆路书",), ("真实评测", "不接硬广")),
    ),
    KnowMeCase(
        id="q06_compliance_and_colleague",
        category="work",
        question="搜狐户外文案有什么禁用词要求？合规审核与野生老马合同找哪位同事协同？",
        expected_groups=(("最",), ("于超然",)),
    ),
    KnowMeCase(
        id="q07_weekly_report_rule",
        category="work",
        question="帮我写聊天版周报时固定用什么标题标记？同事崔梦雨怎么简写？",
        expected_groups=(("【周报】",), ("梦雨",)),
    ),
    KnowMeCase(
        id="q08_sleep_commute_weekend",
        category="lifestyle",
        question="我日常大概几点起床入睡？周末会安排加班吗？",
        expected_groups=(("07:30",), ("23:30",), ("周末不加班",)),
    ),
    KnowMeCase(
        id="q09_evening_training",
        category="lifestyle",
        question="工作日晚间我一般什么时间段固定去运动？主要练什么？",
        expected_groups=(("19:30",), ("健身", "攀岩", "抱石")),
    ),
    KnowMeCase(
        id="q10_motorcycle_model",
        category="lifestyle",
        question="我平时骑行摩旅重点关注哪一款摩托车车源？",
        expected_groups=(("凯旋", "Scrambler 900"),),
    ),
    KnowMeCase(
        id="q11_calendar_title_format",
        category="lifestyle",
        question="帮我创建日历日程时，标题格式有什么统一规范？",
        expected_groups=(("【分类】标题",),),
    ),
    KnowMeCase(
        id="q12_bookkeeping_preferences",
        category="lifestyle",
        question="我的个人记账部署在什么服务上？默认刷哪张银行卡、酒店住宿归哪个分类？",
        expected_groups=(("ezbookkeeping",), ("招商银行",), ("居住房租",)),
    ),
    KnowMeCase(
        id="q13_dual_mac_and_port",
        category="hardware",
        question="我的两台 Mac 电脑怎么分工和同步？Com 后端常驻在哪个端口？",
        expected_groups=(("MacBook Pro", "Eddie-MBP"), ("Mac mini",), ("Syncthing",), ("8650",)),
    ),
    KnowMeCase(
        id="q14_primary_mobile_device",
        category="hardware",
        question="我现在随身使用的主力手机真机是什么？旧 Android 端还在用吗？",
        expected_groups=(("iPhone Duo",), ("Android",)),
    ),
    KnowMeCase(
        id="q15_agent_routing_rules",
        category="hardware",
        question="多 Agent 派活时禁用哪类付费模型？iOS、脚本盘点、写作审查分别派给谁？",
        expected_groups=(("Claude",), ("cursor",), ("pi",), ("agy",)),
    ),
    KnowMeCase(
        id="q16_soul_tone_and_conclusion",
        category="soul",
        question="你在手机上跟我对话应该保持怎样的语气和结论先后顺序？",
        expected_groups=(("先给结论",), ("口语", "朋友", "熟识")),
    ),
    KnowMeCase(
        id="q17_soul_multi_option_recommendation",
        category="soul",
        question="遇到多个技术或业务方案取舍时，你能只罗列优缺点让我自己猜吗？",
        expected_groups=(("倾向建议",), ("投入产出比",)),
    ),
    KnowMeCase(
        id="q18_soul_outbound_stop_before_button",
        category="soul",
        question="帮我发外部邮件、提搜狐 PR 劳务报销单或发视频号内容时，最后一步谁来点？",
        expected_groups=(("停在按钮前",), ("发送",), ("提交",), ("发布",)),
    ),
    KnowMeCase(
        id="q19_soul_wechat_context_only",
        category="soul",
        question="看到未读微信消息你会催我回别人微信吗？工作群重点提炼哪些点名？",
        expected_groups=(("绝不催回", "只作背景上下文"), ("@野望", "野望")),
    ),
    KnowMeCase(
        id="q20_soul_data_safety_and_freshness",
        category="soul",
        question="整理数据文件有什么删除红线？如果短信超 48 小时未更新或缺少定位怎么处理？",
        expected_groups=(("只转移不删除",), ("48",), ("绝不瞎编", "新鲜度")),
    ),
)


def _evaluate_text_against_case(text: str, case: KnowMeCase) -> tuple[bool, list[tuple[str, ...]], list[str]]:
    low = text.lower()
    missing: list[tuple[str, ...]] = []
    for group in case.expected_groups:
        if not any(cand.lower() in low for cand in group):
            missing.append(group)
    forbidden_hit = [term for term in case.forbidden_terms if term.lower() in low]
    passed = (len(missing) == 0) and (len(forbidden_hit) == 0)
    return passed, missing, forbidden_hit


def run_offline_benchmark(state_dir: Path | None = None) -> dict[str, Any]:
    """离线校验 20 道懂我基准题在 `context_builder.build` 中的真相召回覆盖率与安全不变量。"""
    assert len(KNOW_ME_CASES) == 20, f"基准题数量必须为 20，当前为 {len(KNOW_ME_CASES)}"
    started = time.perf_counter()

    def _run_with_dir(st_dir: Path) -> dict[str, Any]:
        ensure_truth_files(st_dir)
        details: list[dict[str, Any]] = []
        passed_count = 0
        sensitive_leaks = 0
        system_prompt_intact = True

        for case in KNOW_ME_CASES:
            t0 = time.perf_counter()
            ws = context_builder.build(st_dir, case.question, recall_fn=lambda _q: {"items": []})
            dt_ms = round((time.perf_counter() - t0) * 1000.0, 3)

            if ws.sizes.get("system_chars") != len(SYSTEM_PROMPT) or len(SYSTEM_PROMPT) >= 2200:
                system_prompt_intact = False
            # SYSTEM_PROMPT 自身含「不碰密码或隐私」字样，敏感词检查针对 SYSTEM_PROMPT 之外注入的真相与上下文层
            injected_tail = ws.instructions[len(SYSTEM_PROMPT) :] if ws.instructions.startswith(SYSTEM_PROMPT) else ws.instructions
            has_sensitive = bool(SENSITIVE.search(injected_tail))
            if has_sensitive:
                sensitive_leaks += 1

            ok, missing, forbidden_hit = _evaluate_text_against_case(ws.instructions, case)
            if ok and not has_sensitive:
                passed_count += 1

            details.append(
                {
                    "id": case.id,
                    "category": case.category,
                    "question": case.question,
                    "passed": bool(ok and not has_sensitive),
                    "truth_chars": ws.sizes.get("truth_chars", 0),
                    "latency_ms": dt_ms,
                    "missing_groups": [list(g) for g in missing],
                    "forbidden_hits": forbidden_hit,
                    "sensitive_leak": has_sensitive,
                }
            )

        total = len(KNOW_ME_CASES)
        hit_rate = passed_count / total if total else 0.0
        elapsed_ms = round((time.perf_counter() - started) * 1000.0, 2)
        return {
            "mode": "offline",
            "total": total,
            "passed": passed_count,
            "hit_rate": round(hit_rate, 4),
            "threshold": PASS_THRESHOLD,
            "ok": bool(hit_rate >= PASS_THRESHOLD and sensitive_leaks == 0 and system_prompt_intact),
            "sensitive_leaks": sensitive_leaks,
            "system_prompt_intact": system_prompt_intact,
            "elapsed_ms": elapsed_ms,
            "cases": details,
        }

    if state_dir is not None:
        return _run_with_dir(Path(state_dir))
    with tempfile.TemporaryDirectory(prefix="com-know-me-bench-") as tmp:
        return _run_with_dir(Path(tmp))


async def run_live_benchmark(
    *,
    magpie_url: str = LIVE_MAGPIE_URL,
    model: str = LIVE_MAGPIE_MODEL,
    state_dir: Path | None = None,
) -> dict[str, Any]:
    """在线调用本地 Magpie 快模型端到端回答 20 道懂我基准题并打分（零商业 Claude 调用）。"""
    if "claude" in model.lower():
        raise ValueError("禁止在 know_me_bench 中使用商业付费 Claude 模型")

    started = time.perf_counter()
    api_key = os.environ.get("MAGPIE_API_KEY", "local")

    async def _run_in_dir(st_dir: Path) -> dict[str, Any]:
        details: list[dict[str, Any]] = []
        passed_count = 0
        async with httpx.AsyncClient(timeout=15.0, trust_env=False) as client:
            for case in KNOW_ME_CASES:
                ws = context_builder.build(st_dir, case.question, recall_fn=lambda _q: {"items": []})
                t0 = time.perf_counter()
                answer = ""
                err = ""
                try:
                    resp = await client.post(
                        magpie_url,
                        headers={"Authorization": f"Bearer {api_key}"},
                        json={
                            "model": model,
                            "messages": [
                                {"role": "system", "content": ws.instructions},
                                {"role": "user", "content": case.question},
                            ],
                            "temperature": 0.0,
                        },
                    )
                    resp.raise_for_status()
                    payload = resp.json()
                    answer = str(((payload.get("choices") or [{}])[0].get("message") or {}).get("content") or "")
                except Exception as exc:
                    err = f"{type(exc).__name__}: {exc}"[:200]
                dt_ms = round((time.perf_counter() - t0) * 1000.0, 1)
                ok, missing, forbidden_hit = _evaluate_text_against_case(answer, case)
                if ok and not err:
                    passed_count += 1
                details.append(
                    {
                        "id": case.id,
                        "category": case.category,
                        "passed": bool(ok and not err),
                        "latency_ms": dt_ms,
                        "answer_preview": answer[:120],
                        "missing_groups": [list(g) for g in missing],
                        "error": err,
                    }
                )
        total = len(KNOW_ME_CASES)
        hit_rate = passed_count / total if total else 0.0
        return {
            "mode": "live",
            "model": model,
            "total": total,
            "passed": passed_count,
            "hit_rate": round(hit_rate, 4),
            "threshold": PASS_THRESHOLD,
            "ok": hit_rate >= PASS_THRESHOLD,
            "elapsed_ms": round((time.perf_counter() - started) * 1000.0, 1),
            "cases": details,
        }

    if state_dir is not None:
        return await _run_in_dir(Path(state_dir))
    with tempfile.TemporaryDirectory(prefix="com-know-me-live-") as tmp:
        return await _run_in_dir(Path(tmp))


def main() -> int:
    parser = argparse.ArgumentParser(description="Com! 20 题「懂我」量化基准集")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--offline", action="store_true", help="离线快速评估上下文召回覆盖率（默认）")
    mode.add_argument("--live", action="store_true", help="调用本地 Magpie 快模型端到端评分")
    parser.add_argument("--magpie-url", default=LIVE_MAGPIE_URL, help="本地 Magpie OpenAI 兼容接口地址")
    parser.add_argument("--model", default=LIVE_MAGPIE_MODEL, help="本地网关快模型名称（严禁 Claude）")
    parser.add_argument("--json", action="store_true", help="输出完整 JSON 报告")
    args = parser.parse_args()

    if args.live:
        report = asyncio.run(run_live_benchmark(magpie_url=args.magpie_url, model=args.model))
    else:
        report = run_offline_benchmark()

    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        status_str = "PASS" if report["ok"] else "FAIL"
        print(
            f"[{status_str}] Know-Me Benchmark ({report['mode']}): "
            f"{report['passed']}/{report['total']} ({report['hit_rate'] * 100:.1f}%, "
            f"threshold >= {report['threshold'] * 100:.0f}%, {report['elapsed_ms']} ms)"
        )
        for item in report["cases"]:
            if not item["passed"]:
                print(f"  - MISS {item['id']}: missing={item.get('missing_groups')} err={item.get('error', '')}")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
