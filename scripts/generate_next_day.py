import json
from copy import deepcopy
from datetime import datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STATE_PATH = ROOT / "data" / "world-state.json"
OUT_PATH = ROOT / "data" / "world-state.next.json"


PLANS = {
    "repair_power": {
        "title": "修复发电机后的第二天",
        "brief": "老王把旧车线圈接进发电系统，温室重新亮起保温灯。北面废墟的机械声暂时远了。",
        "impact": {"power": 18, "morale": 4, "threat": -2},
        "history": "投票选择修发电机，营地电力恢复了一截。",
    },
    "scavenge_north": {
        "title": "北面搜寻后的第二天",
        "brief": "老张带队摸到北面废墟，带回了罐头和药品，也确认那里有人活动过。",
        "impact": {"food": 10, "medicine": 5, "threat": 8, "morale": 2},
        "history": "投票选择北面搜寻，营地获得补给，也暴露了踪迹。",
    },
    "tend_wounded": {
        "title": "照顾伤员后的第二天",
        "brief": "小李把医疗站重新整理了一遍，伤员退烧了。药品更少，但营地安静了许多。",
        "impact": {"medicine": -5, "morale": 14, "threat": -1},
        "history": "投票选择照顾伤员，营地士气明显回升。",
    },
}


def clamp(value, low=0, high=100):
    return max(low, min(high, int(value)))


def apply_impact(state, impact):
    resources = state["world"]["resources"]
    for key, delta in impact.items():
        if key == "threat":
            state["world"]["threat"] = clamp(state["world"].get("threat", 0) + delta)
        else:
            resources[key] = clamp(resources.get(key, 0) + delta)


def rotate_schedule(state):
    for character in state["characters"]:
        for item in character["schedule"]:
            if item.get("time") == 6:
                item["text"] = f"{character['name']}在检查昨天留下的变化。"
            elif item.get("time") == 21:
                item["text"] = f"{character['name']}把今天的事记了下来。"


def main():
    state = json.loads(STATE_PATH.read_text(encoding="utf-8"))
    next_state = deepcopy(state)
    next_state["day"] = int(state.get("day", 1)) + 1

    selected = state.get("last_vote") or "repair_power"
    plan = PLANS.get(selected, PLANS["repair_power"])
    next_state["title"] = plan["title"]
    next_state["world"]["daily_brief"] = plan["brief"]
    apply_impact(next_state, plan["impact"])
    rotate_schedule(next_state)
    next_state.setdefault("history", []).append(f"第 {next_state['day']} 天：{plan['history']}")
    next_state["generated_at"] = datetime.utcnow().isoformat(timespec="seconds") + "Z"

    OUT_PATH.write_text(json.dumps(next_state, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"wrote {OUT_PATH}")


if __name__ == "__main__":
    main()
