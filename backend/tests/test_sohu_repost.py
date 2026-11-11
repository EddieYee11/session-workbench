import json
from pathlib import Path

from sohu_repost import SohuRepostService, parse_copy_angles


def test_parse_copy_angles():
    raw = (
        "【角度 A：判断】这身手真利落，平时没少练吧[赞]\n"
        "[推荐理由]：口语自然\n"
        "【角度 B：互动】@泡饭-climbing 你们馆也有这条线吗？[吃瓜]\n"
    )
    angles = parse_copy_angles(raw)
    assert len(angles) == 2
    assert "[赞]" in angles[0]
    assert "@泡饭-climbing" in angles[1]


def test_sohu_repost_service_status_and_actions(tmp_path: Path):
    bot = tmp_path / "sohu-repost-bot"
    (bot / "logs").mkdir(parents=True)
    (bot / "config.json").write_text(
        json.dumps(
            {
                "quota": {"dailyTotal": 10, "perCreatorDaily": 3, "nonOutdoorDaily": 1, "nonOutdoorMinIntervalHours": 8},
                "sohu": {"myUid": "376622042"},
            }
        ),
        encoding="utf-8",
    )
    (bot / "state.json").write_text(
        json.dumps(
            {
                "bootstrapped": True,
                "processedIds": {"id-1": "published", "id-2": "pending_review"},
                "daily": {},
                "consecutiveNetFailures": 0,
                "updatedAt": "2026-11-07T07:20:00Z",
            }
        ),
        encoding="utf-8",
    )
    (bot / "monitor_state.json").write_text(json.dumps({"lastReconcileAt": 1793954712189}), encoding="utf-8")
    (bot / "crash_streak.txt").write_text("0", encoding="utf-8")
    (bot / "logs" / "pipeline.log").write_text(
        "[2026-11-07T05:48:44.674Z] queue fetched: 445 items\n"
        "[2026-11-07T05:48:44.674Z] published: [#大有可攀] [耀阳环游记] @泡饭-climbing 这油箱口，是不是有啥特别的？[吃瓜]\n"
        "[2026-11-07T05:50:25.447Z] run done, published=1\n",
        encoding="utf-8",
    )
    (bot / "logs" / "monitor.log").write_text(
        "[2026-11-07T06:45:44.098Z] [monitor] nas heartbeat ok (0.17h)\n"
        "[2026-11-07T06:45:45.730Z] [monitor] login check: ok\n",
        encoding="utf-8",
    )
    (bot / "review_queue.jsonl").write_text(
        json.dumps(
            {
                "status": "pending",
                "ts": "2026-11-06T15:45:20.728Z",
                "item": {
                    "id": "rev-1",
                    "uid": "261499995",
                    "creatorName": "Eating爱自由",
                    "theme": "朝圣之旅第二天",
                    "link": "https://tv.sohu.com/v/abc.html",
                    "copy": "法线起点小镇的风景真好，难怪那么多人选择这里。\n开启朝圣之旅的第二天，这个小镇就是法线第一站。",
                    "copy_confidence": None,
                },
            },
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )

    svc = SohuRepostService(bot_dir=bot)
    svc._nas_cache_at = 9999999999.0  # skip ssh in unit test
    snap = svc.status()
    assert snap["available"] is True
    assert snap["health"]["login_ok"] is True
    assert snap["health"]["queue_total"] == 445
    assert len(snap["review_queue"]) == 1
    assert snap["review_queue"][0]["creator_name"] == "Eating爱自由"
    assert len(snap["recent"]) == 1
    assert snap["recent"][0]["category"] == "topic_dayoukepan"
    assert "@泡饭-climbing" in snap["recent"][0]["mentions"]
    assert "[吃瓜]" in snap["recent"][0]["emojis"]

    res = svc.act("approve", item_id="rev-1", angle_index=1)
    assert res["ok"] is True
    assert len(res["snapshot"]["review_queue"]) == 0
    saved = json.loads((bot / "review_queue.jsonl").read_text(encoding="utf-8").strip())
    assert saved["status"] == "approved"
    assert saved["chosenIdx"] == 1
