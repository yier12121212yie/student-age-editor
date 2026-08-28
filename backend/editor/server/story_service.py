# -*- coding: utf-8 -*-
"""故事剧本文本 与 配置表 双向转换服务。

导入（文本 -> TalkCfg）：剥离自友商 services/story_importer.py 的 ScriptParser。
导出（配置表 -> 剧本文本）：剥离自友商 services/story_exporter.py 的 StoryExporterDialog。
无 GUI 依赖，供 HTTP API 层复用。
"""
import json
import re
from collections import deque

# ---------------- 导出所需常量（复制自 story_exporter.py） ----------------

EXPRESSION_MAP = {
    "0": "默认", "1": "开心", "2": "生气", "3": "伤心", "4": "害羞",
    "5": "喜欢", "6": "认真", "7": "疑惑", "8": "惊讶", "9": "得意",
    "10": "微笑", "11": "坏笑", "12": "担心", "13": "害怕", "14": "难过",
    "15": "咆哮", "16": "窘迫", "17": "不满", "18": "冷笑", "19": "无语",
    "20": "苦笑", "21": "挫败", "22": "尴尬", "23": "迷茫", "24": "嫌弃",
    "25": "俏皮", "26": "尴尬",
}

EVENT_TYPE_MAP = {
    0: "回合开始触发", 1: "独立按钮(不弹窗)", 2: "社交事件", 3: "回合结束触发", 4: "行动触发",
    10: "强制触发(不弹窗)", 11: "约会事件",
    12: "篮球主线-自动", 13: "篮球主线-被动", 14: "羽毛球主线-自动", 15: "羽毛球主线-被动",
    20: "关系任务", 21: "打招呼", 22: "话题", 30: "点击场景物品",
    36: "漫展", 37: "生日派对", 40: "考试", 41: "查看成绩", 50: "通知", 51: "流程",
    60: "状态", 61: "路人", 62: "点击物品", 63: "路人检查",
    70: "玩家打电话", 71: "玩家接电话", 80: "新闻", 90: "节日",
    101: "独立按钮(强制)", 102: "精力低事件", 104: "捣蛋事件", 110: "送礼", 200: "人生轨迹",
    500: "高考", 520: "表白事件", 521: "情侣电影", 522: "恋爱社交", 523: "生日礼物", 750: "学习",
    801: "回家触发", 802: "教学楼触发", 803: "操场触发", 804: "小卖部触发", 805: "游戏厅触发",
    806: "书店触发", 807: "商场触发", 808: "电影院触发", 811: "游乐园触发", 817: "双子峰触发",
    901: "回家触发", 902: "教学楼触发", 903: "操场触发", 904: "小卖部触发", 905: "游戏厅触发",
    906: "书店触发", 907: "商场触发", 908: "电影院触发", 911: "游乐园触发", 917: "双子峰触发",
}

RELATION_LEVEL_MAP = {
    1: "熟人", 2: "朋友", 3: "好友", 4: "密友", 5: "挚友", 6: "至交", 520: "恋人",
}

# ---------------- 导入：表达式词表 + 脚本解析器（复制自 story_importer.py） ----------------

def build_smart_expression_map():
    raw_map = {
        0:  ["默认", "平静", "正常", "淡定", "发呆", "面无表情", "恢复"],
        1:  ["开心", "高兴", "快乐", "喜悦", "兴奋", "乐", "嘻嘻", "哈哈", "愉悦", "欣喜", "雀跃", "笑逐颜开", "捧腹", "乐呵呵", "好耶"],
        2:  ["生气", "愤怒", "恼火", "怒", "暴怒", "气愤", "愤慨", "不爽", "恼怒", "发火", "怒视", "气呼呼", "咬牙"],
        3:  ["伤心", "哭", "哭泣", "落泪", "悲伤", "呜呜", "啜泣", "悲痛", "哀伤", "泪流满面", "痛哭", "抽泣", "泪崩"],
        4:  ["害羞", "脸红", "羞涩", "不好意思", "腼腆", "羞答答", "扭捏"],
        5:  ["喜欢", "爱慕", "花痴", "心动", "眼冒爱心", "陶醉"],
        6:  ["认真", "严肃", "凝重", "神色凝重", "郑重", "沉重", "专注", "仔细", "一丝不苟", "正经"],
        7:  ["疑惑", "疑问", "不解", "纳闷", "奇怪", "呃", "问号", "困惑", "迷糊", "不懂"],
        8:  ["惊讶", "震惊", "惊吓", "吓", "呆住", "愣住", "错愕", "难以置信", "目瞪口呆", "惊愕", "意外", "吃惊"],
        9:  ["得意", "骄傲", "炫耀", "哼", "傲娇", "翘尾巴", "洋洋得意", "自豪", "显摆"],
        10: ["微笑", "莞尔", "浅笑", "嘴角上扬", "含笑", "笑意", "轻笑", "笑吟吟"],
        11: ["坏笑", "阴险", "狡黠", "嘿嘿", "邪笑", "阴笑", "不怀好意"],
        12: ["担心", "担忧", "忧虑", "牵挂", "紧张", "不安", "悬着心"],
        13: ["害怕", "恐惧", "发抖", "哆嗦", "惊恐", "畏惧", "胆怯", "瑟瑟发抖", "惊慌"],
        14: ["难过", "失落", "沮丧", "郁闷", "消沉", "灰心", "低落", "惆怅"],
        15: ["咆哮", "大吼", "怒吼", "吼叫", "歇斯底里", "大叫"],
        16: ["窘迫", "局促", "不自在"],
        17: ["不满", "抱怨", "牢骚", "抗议", "撇嘴", "啧"],
        18: ["冷笑", "嗤之以鼻", "不屑", "嘲讽", "讥讽", "呵呵"],
        19: ["无语", "汗", "汗颜", "黑线", "...", "……", "沉默"],
        20: ["苦笑", "无奈", "勉强笑"],
        21: ["挫败", "灰头土脸", "打击"],
        22: ["尴尬", "尬住", "僵硬"],
        23: ["迷茫", "呆滞", "空洞", "懵", "懵逼", "发愣"],
        24: ["嫌弃", "鄙视", "恶心", "厌恶", "皱眉", "白眼"],
        25: ["俏皮", "吐舌", "鬼脸", "调皮", "眨眼", "wink"],
    }
    flat_map = {}
    for eid, keywords in raw_map.items():
        for kw in keywords:
            flat_map[kw] = eid
    return flat_map


SMART_EXPR_MAP = build_smart_expression_map()


class ScriptParser:
    """把「角色名：台词（动作标注）」格式的剧本文本解析为 TalkCfg 数据。"""

    def __init__(self, start_id, name_to_id_map, start_idx=1):
        self.base_id = int(start_id) * 1000
        self.current_idx = start_idx
        self.name_to_id = name_to_id_map

    def get_next_id(self):
        return self.base_id + self.current_idx

    def parse_natural_action(self, action_text, speaker_id):
        action_text = action_text.strip().replace("[", "").replace("]", "")
        if not action_text:
            return None

        if re.match(r"^[\d,\s-]+$", action_text):
            try:
                code_str = action_text.replace("，", ",")
                parsed = [int(x) for x in code_str.split(",")]
                if parsed[0] == -1 and not (len(parsed) >= 2 and 4000 <= parsed[1] < 6000):
                    return None
                return parsed
            except Exception:
                pass

        target_id = speaker_id
        sorted_names = sorted(self.name_to_id.keys(), key=len, reverse=True)
        for name in sorted_names:
            if name in action_text:
                target_id = self.name_to_id[name]
                break

        if "一段时间" in action_text or "延时" in action_text:
            return [4006]
        if "震动" in action_text or "抖动" in action_text:
            nums = re.findall(r"\d+", action_text)
            val = int(nums[0]) if nums else 1
            if "屏幕" in action_text:
                return [4001, val]
            if target_id == -1:
                return None
            return [target_id, 3002]
        if "跳一跳" in action_text or "微动" in action_text:
            if target_id == -1:
                return None
            return [target_id, 3001]
        if "模糊" in action_text:
            return [4002]
        if "陈旧" in action_text or "做旧" in action_text:
            return [4009]
        if "反色" in action_text:
            return [4010]
        if "清空" in action_text and ("特效" in action_text or "效果" in action_text):
            return [4003]
        if "挂电话" in action_text or "挂断" in action_text:
            return [4008]
        if "闭眼" in action_text:
            return [4011, 1]
        if "睁眼" in action_text:
            return [4011, 0]
        if "闪白" in action_text:
            nums = re.findall(r"\d+", action_text)
            return [4012, int(nums[0])] if nums else [4012, 1]
        if "结束CG" in action_text or "关闭CG" in action_text:
            return [4017]
        if "道具" in action_text:
            nums = re.findall(r"\d+", action_text)
            return [4004, int(nums[0])] if nums else [4004, 0]
        if "纸条" in action_text:
            nums = re.findall(r"\d+", action_text)
            return [0, 5001, int(nums[0]) if nums else 0]

        for kw, eid in SMART_EXPR_MAP.items():
            if kw in action_text:
                if target_id == -1:
                    return None
                return [target_id, 3000, eid]

        enter_type = None
        if "直接" in action_text and ("入场" in action_text or "出现" in action_text):
            enter_type = 1002
        elif "底部" in action_text and ("入场" in action_text or "出现" in action_text):
            enter_type = 1003
        elif "滑动" in action_text or "入场" in action_text:
            enter_type = 1001

        if enter_type:
            if target_id == -1:
                return None
            pos = 3
            if "左" in action_text:
                pos = 1
            elif "右" in action_text:
                pos = 2
            return [target_id, enter_type, 1, pos]

        if "退场" in action_text or "消失" in action_text:
            if target_id == -1:
                return None
            leave_type = 2001
            if "直接" in action_text:
                leave_type = 2002
            return [target_id, leave_type]

        if "移动" in action_text:
            if target_id == -1:
                return None
            nums = re.findall(r"-?\d+", action_text)
            val = int(nums[0]) if nums else 0
            if "左" in action_text and val > 0:
                val = -val
            if "下" in action_text and val > 0:
                val = -val
            move_type = 3004
            if "上" in action_text or "下" in action_text:
                move_type = 3008
            return [target_id, move_type, val]

        if "镜像" in action_text:
            if target_id == -1:
                return None
            return [target_id, 3007]
        if "转身" in action_text:
            if target_id == -1:
                return None
            return [target_id, 3005]
        if "换装" in action_text or "衣服" in action_text:
            if target_id == -1:
                return None
            nums = re.findall(r"\d+", action_text)
            return [target_id, 3006, int(nums[0]) if nums else 0]
        if "emoji" in action_text.lower() or "气泡" in action_text:
            if target_id == -1:
                return None
            nums = re.findall(r"\d+", action_text)
            return [target_id, 3009, int(nums[0]) if nums else 0]

        return None

    def process_block(self, speaker_name, raw_content):
        if not raw_content.strip():
            return None

        speaker_id = -1
        if speaker_name and speaker_name in self.name_to_id:
            speaker_id = self.name_to_id[speaker_name]

        lstripped_content = raw_content.lstrip(" \t")
        custom_role_name = None
        roleName_match = re.match(r"^[\(（]([^)）\n]+)[\)）]", lstripped_content)

        if roleName_match:
            custom_role_name = roleName_match.group(1).strip()
            raw_text = lstripped_content[roleName_match.end():].strip()
        else:
            raw_text = raw_content.strip()

        if raw_text.startswith(":") or raw_text.startswith("："):
            raw_text = raw_text[1:].strip()

        current_data = {
            "id": self.get_next_id(), "roleIds": [speaker_id] if speaker_id != -1 else [],
            "content": "", "bg": 0, "audio": 0, "roles": [], "effect": [], "miniGame": [],
            "screenEffect": [], "check": [], "nextTalk": [], "nextTalk2": [], "option": [],
            "replace": [], "showTxt": None, "time": 0, "vocals": [], "roleName": None,
            "effect2": [], "highlights": [],
        }

        if custom_role_name:
            current_data["roleName"] = custom_role_name
        elif speaker_id == -1 and speaker_name != "旁白":
            current_data["roleName"] = speaker_name

        eff_match = re.search(r"(?:触发效果|effect|(?<!屏幕)效果)[:：\s]*(\[.*?\]|[\d,，;；\s]+)(?:[。.\n]|$)", raw_text, re.IGNORECASE)
        if eff_match:
            val_str = eff_match.group(1).strip()
            try:
                parsed = json.loads(val_str)
                if isinstance(parsed, list):
                    if all(isinstance(x, list) for x in parsed):
                        current_data["effect"].extend(parsed)
                    else:
                        current_data["effect"].append(parsed)
            except Exception:
                val_str = val_str.replace("[", "").replace("]", "")
                eff_groups = re.split(r"[;；]", val_str)
                for eg in eff_groups:
                    if not eg.strip():
                        continue
                    nums = [int(x) for x in re.findall(r"\d+", eg)]
                    if nums:
                        current_data["effect"].append(nums)
            raw_text = raw_text.replace(eff_match.group(0).strip(), "")

        bg_match = re.search(r"(?:bg|背景)[:：\s]*(\d+)", raw_text, re.IGNORECASE)
        if bg_match:
            current_data["bg"] = int(bg_match.group(1))
            raw_text = raw_text.replace(bg_match.group(0), "")

        bgm_match = re.search(r"(?:bgm|music|音乐)[:：\s]*(\d+)", raw_text, re.IGNORECASE)
        if bgm_match:
            current_data["audio"] = int(bgm_match.group(1))
            raw_text = raw_text.replace(bgm_match.group(0), "")

        full_act_text = ""
        act_matches = re.finditer(r"(?:动作|action|roles|屏幕效果|screenEffect)[:：\s]+(.*?)(?=\n|$)", raw_text, re.IGNORECASE)
        for match in act_matches:
            full_act_text += match.group(1) + ";"
            raw_text = raw_text.replace(match.group(0), "")

        brackets = re.findall(r"[（\(\[](.*?)[）\)\]]", raw_text)
        for b_text in brackets:
            if not any(x in b_text for x in ["系统", "前提判定", "条件"]):
                sub_acts = re.split(r"[;；、]", b_text)
                valid_found = False
                for sub_act in sub_acts:
                    if self.parse_natural_action(sub_act, speaker_id):
                        full_act_text += sub_act + ";"
                        valid_found = True
                if valid_found:
                    raw_text = raw_text.replace("[%s]" % b_text, "").replace("(%s)" % b_text, "").replace("（%s）" % b_text, "")

        if full_act_text:
            acts = re.split(r"[;；、]", full_act_text)
            for act in acts:
                parsed_code = self.parse_natural_action(act, speaker_id)
                if parsed_code:
                    code_id = parsed_code[0]
                    if 4000 <= code_id < 5000:
                        current_data["screenEffect"] = parsed_code
                    elif parsed_code[0] == 0 and len(parsed_code) >= 2 and parsed_code[1] == 5001:
                        current_data["roles"].append(parsed_code)
                    else:
                        if parsed_code[0] != -1:
                            current_data["roles"].append(parsed_code)

        clean_content = re.sub(r"^[:：\s]+", "", raw_text)
        clean_content = re.sub(r"\s*bgm?\s*", "", clean_content, flags=re.IGNORECASE)
        current_data["content"] = clean_content.strip()

        current_data["nextTalk"] = [self.base_id + self.current_idx + 1]
        self.current_idx += 1
        return current_data

    def run(self, full_text):
        sorted_names = sorted(self.name_to_id.keys(), key=len, reverse=True)
        names_pattern = "|".join([re.escape(n) for n in sorted_names])
        regex = re.compile(r"(?:^|\n)\s*(" + names_pattern + r")(?=[:：\s\t\(\)（）\[\]]|$)", re.MULTILINE)

        matches = list(regex.finditer(full_text))
        processed_list = []

        if not matches:
            if full_text.strip():
                data = self.process_block("旁白", full_text)
                if data:
                    processed_list.append(data)
        else:
            if matches[0].start() > 0:
                pre_text = full_text[:matches[0].start()]
                if pre_text.strip():
                    data = self.process_block("旁白", pre_text)
                    if data:
                        processed_list.append(data)

            for i in range(len(matches)):
                current_match = matches[i]
                current_name = current_match.group(1)
                content_start = current_match.end()
                content_end = matches[i + 1].start() if i < len(matches) - 1 else len(full_text)
                block_content = full_text[content_start:content_end]
                data = self.process_block(current_name, block_content)
                if data:
                    processed_list.append(data)

        final_processed_list = []
        pending_resets = set()
        for item in processed_list:
            existing_expr_users = set()
            for action in item["roles"]:
                if len(action) >= 2 and action[1] == 3000:
                    existing_expr_users.add(action[0])
            for uid in pending_resets:
                if uid not in existing_expr_users and uid != -1:
                    item["roles"].insert(0, [uid, 3000, 0])

            pending_resets.clear()
            for action in item["roles"]:
                if len(action) >= 3 and action[1] == 3000 and action[2] != 0 and action[0] != -1:
                    pending_resets.add(action[0])

            expr_dict = {}
            other_acts = []

            for act in item["roles"]:
                if not isinstance(act, list) or len(act) < 2:
                    continue
                uid = act[0]
                act_type = act[1]
                if act_type == 3000:
                    expr_dict[uid] = act
                else:
                    if act not in other_acts:
                        other_acts.append(act)

            item["roles"] = list(expr_dict.values()) + other_acts
            final_processed_list.append(item)

        if final_processed_list:
            final_processed_list[-1]["nextTalk"] = []

        json_output = {}
        for item in final_processed_list:
            json_output[str(item["id"])] = item
        return json_output


def parse_script(start_id, text, name_to_id_map, start_idx=1):
    """解析剧本文本为 TalkCfg 数据（id 从 start_id*1000+start_idx 起）。"""
    parser = ScriptParser(start_id, name_to_id_map, start_idx=start_idx)
    return parser.run(text or "")


# ---------------- 导出（复制自 story_exporter.py，UI 选项参数化） ----------------

class _ExportOptions(object):
    """导出选项（对应友商对话框的复选框，默认全开）。"""

    def __init__(self, pure=False, show_id=True, show_type=True, show_cond=True,
                 show_expr=True, show_action=True, show_bg=True, show_audio=True,
                 show_minigame=True, show_effect=True):
        self.pure = pure
        self.show_id = show_id
        self.show_type = show_type
        self.show_cond = show_cond
        self.show_expr = show_expr
        self.show_action = show_action
        self.show_bg = show_bg
        self.show_audio = show_audio
        self.show_minigame = show_minigame
        self.show_effect = show_effect


def _clean_floats(data):
    if isinstance(data, list):
        return [_clean_floats(x) for x in data]
    if isinstance(data, dict):
        return {k: _clean_floats(v) for k, v in data.items()}
    if isinstance(data, float):
        return int(data) if data.is_integer() else data
    if isinstance(data, str) and data.endswith(".0") and data[:-2].lstrip("-").isdigit():
        return int(data[:-2])
    return data


def _parse_condition_item(cond, role_dict):
    cond = _clean_floats(cond)
    if not cond or len(cond) < 2:
        return "未知条件"
    c_type = cond[0]
    c_code = cond[1]
    p1 = cond[2] if len(cond) > 2 else 0
    p2 = cond[3] if len(cond) > 3 else 0
    p3 = cond[4] if len(cond) > 4 else 0

    def role_name(rid):
        return role_dict.get(str(rid), str(rid))

    if c_type == 7:
        r_name = role_name(p1)
        if c_code == 0:
            return "%s是你的%s" % (r_name, RELATION_LEVEL_MAP.get(p2, "关系%s" % p2))
        if c_code == 1:
            return "%s的好感>=%s" % (r_name, p2)
        if c_code == -1:
            return "%s的好感<%s" % (r_name, p2)
        if c_code == 10:
            return "与父母成功交涉%s次" % p2
        if c_code == 7:
            return "社交%s次" % p1
        if c_code == 9:
            return "有认识的人"
        if c_code == 5:
            return "%s(及以上)人数>=%s" % (RELATION_LEVEL_MAP.get(p1, str(p1)), p2)
        if c_code == 50:
            return "%s关系异性人数>=%s" % (RELATION_LEVEL_MAP.get(p1, str(p1)), p2)
        if c_code == 8:
            return "提升关系%s次" % p1
        if c_code == 22:
            return "%s是好感最高的异性" % r_name
    elif c_type == 1:
        if c_code == 1:
            return "年龄>=%s" % p1
        if c_code == 2:
            return "年龄<=%s" % p1
        if c_code == 3:
            return "%s<=年龄<=%s" % (p1, p2)
        if c_code == 0:
            return "%s岁%s月" % (p1, p2)
        if c_code == 12:
            if p1 == 0:
                return "年级=%s" % p2
            if p1 == 1:
                return "年级>=%s" % p2
            if p1 == -1:
                return "年级<=%s" % p2
            if p1 == 101:
                return "%s<=年级<=%s" % (p2, p3)
        if c_code == 99:
            return "性别为%s" % ("男" if p1 == 1 else ("女" if p1 == 2 else str(p1)))
        if c_code == 98:
            return "%s生" % ("文科" if p1 == 1 else "理科")
        if c_code == -98:
            return "非%s生" % ("文科" if p1 == 1 else "理科")
        if c_code == 97:
            return "%s文理分班" % ("已" if p1 == 1 else "未")
        if c_code == 20:
            return "小学毕业之前" if p1 == 1 else "小学毕业之后"
    elif c_type == 2:
        if c_code == 0:
            return "当前第%s回合" % p1
        if c_code == 100:
            return "第%s回合及以后" % p1
        if c_code == -100:
            return "未到第%s回合" % p1
        if c_code == 1:
            return "当前%s月" % p1
        if c_code == 4:
            return "当前%s季" % p1
        if c_code == 10:
            return "当前%s年" % p1
        if c_code == 20:
            return "%s-%s年" % (p1, p2)
        if c_code == 11:
            return "当前%s年%s月" % (p1, p2)
        if c_code == 110:
            return "当前%s年%s月及以后" % (p1, p2)
        if c_code == 12:
            return "当前是偶数年"
        if c_code == 101:
            return "当前是主角生日"
        if c_code == 3:
            return "当前%s年%s季" % (p1, p2)
        if c_code == 30:
            return "当前%s年%s季及以后" % (p1, p2)
        if c_code == 8:
            return "当前是寒暑假" if p1 == 1 else "当前不是寒暑假"
    elif c_type == 3:
        if c_code == 1:
            return "事件%s已发生" % p1
        if c_code == 2:
            return "选项%s已激活" % p1
        if c_code == -1:
            return "事件%s未发生" % p1
        if c_code == -2:
            return "选项%s未激活" % p1
        if c_code == 3:
            return "对话%s已激活" % p1
        if c_code == -3:
            return "对话%s未激活" % p1
        if c_code == 4:
            return "价值观%s已激活" % p1
        if c_code == -4:
            return "价值观%s未激活" % p1
        if c_code == 5:
            return "短信%s已发出" % p1
        if c_code == -5:
            return "短信%s未发出" % p1
        if c_code == 30:
            return "本回合已发生对话%s" % p1
        if c_code == -30:
            return "本回合未发生对话%s" % p1
        if c_code == 6:
            return "跑团对话%s已触发" % p1
    return "未知条件%s" % cond


class _StoryExporter(object):
    def __init__(self, evt_cfg, talk_cfg, opt_cfg, role_dict, opts=None):
        self.evt_cfg = evt_cfg or {}
        self.talk_cfg = talk_cfg or {}
        self.opt_cfg = opt_cfg or {}
        self.role_dict = role_dict or {}
        self.opts = opts if opts is not None else _ExportOptions()
        self.all_starts = set()
        for e_info in self.evt_cfg.values():
            if not isinstance(e_info, dict):
                continue
            start_id = e_info.get("talkId")
            if isinstance(start_id, list):
                for sid in start_id:
                    self.all_starts.add(str(sid))
            elif start_id:
                self.all_starts.add(str(start_id))

    def get_role_name(self, rid):
        return self.role_dict.get(str(rid), str(rid))

    def parse_all_conditions(self, cond_list):
        if not cond_list:
            return ""
        return "并且".join(self._parse_condition_item(c) for c in cond_list)

    def _parse_condition_item(self, cond):
        return _parse_condition_item(cond, self.role_dict)

    def format_event_header(self, evt_id, evt_data):
        title = evt_data.get("title", "未命名_%s" % evt_id)
        type_str = ""
        if self.opts.show_type:
            t_id = evt_data.get("type", -1)
            t_name = EVENT_TYPE_MAP.get(t_id, "类型%s" % t_id)
            type_str = "%s：" % t_name

        parens_parts = []
        npc_id = evt_data.get("npc", 0)
        if npc_id and npc_id != 0:
            parens_parts.append("%s专属事件" % self.get_role_name(npc_id))

        if self.opts.show_cond:
            cond_data = _clean_floats(evt_data.get("condition", []))
            if cond_data:
                parens_parts.append("触发条件为：%s" % self.parse_all_conditions(cond_data))

        parens_str = "（%s）" % "，".join(parens_parts) if parens_parts else ""
        id_str = " 事件id：%s" % evt_id if self.opts.show_id else ""
        return "%s%s%s%s" % (type_str, title, parens_str, id_str)

    def parse_roles_and_effects(self, talk_entry):
        actions = []
        expressions = []
        roles_data = _clean_floats(talk_entry.get("roles", []))
        if not roles_data:
            return "", ""

        for item in roles_data:
            if not isinstance(item, list) or len(item) < 2:
                continue
            role_id = str(item[0])
            type_id = int(item[1])
            params = item[2:]
            role_name = self.get_role_name(role_id)

            if type_id == 3000:
                if self.opts.show_expr:
                    expr_id = str(params[0]) if params else "0"
                    expressions.append("%s%s" % (role_name, EXPRESSION_MAP.get(expr_id, expr_id)))
                continue

            if not self.opts.show_action:
                continue
            action_desc = ""
            if type_id in [1001, 1002, 1003]:
                pos = params[1] if len(params) > 1 else 1
                pos_map = {1: "左", 2: "右", 3: "中"}
                m_map = {1001: "滑动", 1002: "直接", 1003: "底部"}
                action_desc = "%s%s入场到%s侧" % (role_name, m_map[type_id], pos_map.get(pos, "?"))
            elif type_id == 2001:
                action_desc = "%s滑动退场" % role_name
            elif type_id == 2002:
                action_desc = "%s直接退场" % role_name
            elif type_id == 3004:
                action_desc = "%s移动%s" % (role_name, params[0] if params else 0)
            elif type_id == 4001:
                action_desc = "屏幕抖动"
            elif type_id == 4015:
                action_desc = "播放CG:%s" % (params[0] if params else "?")
            else:
                action_desc = "[%s]" % ",".join(map(str, item))
            if action_desc:
                actions.append(action_desc)
        return ";".join(expressions), ";".join(actions)

    def print_talk_entry(self, output_list, talk_entry, processed_set):
        tid = str(talk_entry.get("id"))
        if tid in processed_set:
            output_list.append("   >>> (剧情汇合/跳转至已读剧情 ID: %s)" % tid)
            return False

        processed_set.add(tid)

        content = talk_entry.get("content")
        if content is None or not isinstance(content, str):
            content = ""
        content = content.strip()

        role_ids = talk_entry.get("roleIds", [])
        npc_id = talk_entry.get("npcId")
        if role_ids and isinstance(role_ids, list) and len(role_ids) > 0:
            speaker = "和".join([self.get_role_name(r) for r in role_ids])
        elif npc_id is not None:
            speaker = self.get_role_name(npc_id)
        else:
            speaker = "旁白"

        if talk_entry.get("roleName"):
            if speaker != "旁白":
                speaker = "%s(%s)" % (speaker, talk_entry["roleName"])
            else:
                speaker = talk_entry["roleName"]

        if self.opts.pure:
            if content:
                output_list.append("%s：%s" % (speaker, content))
                output_list.append("")
            return True

        info_tags = []
        if self.opts.show_bg and talk_entry.get("bg"):
            info_tags.append("背景：%s" % talk_entry["bg"])
        if self.opts.show_audio and talk_entry.get("audio"):
            info_tags.append("BGM：%s" % talk_entry["audio"])
        if self.opts.show_minigame and talk_entry.get("miniGame"):
            info_tags.append("小游戏：%s" % _clean_floats(talk_entry["miniGame"]))
        if self.opts.show_effect and talk_entry.get("effect"):
            info_tags.append("效果：%s" % json.dumps(_clean_floats(talk_entry["effect"]), ensure_ascii=False))

        expr, act = self.parse_roles_and_effects(talk_entry)

        line = []
        if content or expr or act:
            line.append(speaker)
        if expr:
            line.append("[%s]" % expr)
        if info_tags:
            line.extend(info_tags)
        if act:
            line.append("动作：%s" % act)

        if line or content:
            if line:
                output_list.append("   ".join(line))
            if content:
                output_list.append(content)
            output_list.append("")

        return True

    def process_options(self, talk, output, processed_set, start_tids):
        options = talk.get("option", [])
        valid_options = [oid for oid in options if str(oid) in self.opt_cfg] if self.opt_cfg else []
        if not valid_options:
            return False
        for idx, oid in enumerate(valid_options, 1):
            cfg = self.opt_cfg.get(str(oid), {})
            output.append("——————")

            opt_content = cfg.get("content", "未命名选项")
            if self.opts.show_effect and cfg.get("effect"):
                cleaned_eff = _clean_floats(cfg.get("effect"))
                opt_content += "   效果：%s" % json.dumps(cleaned_eff, ensure_ascii=False)

            output.append("决定%s：%s" % (idx, opt_content))
            output.append("——————")
            branch_ids = [str(x) for x in (cfg.get("talkId") or []) + (cfg.get("talkId2") or []) if x]
            self.process_sequence(output, processed_set, branch_ids, start_tids)
        output.append("——————")
        return True

    def process_sequence(self, output, processed_set, start_tids, all_start_ids):
        if not start_tids:
            return
        queue = deque([str(x) for x in start_tids if x])

        while queue:
            tid = queue.popleft()
            talk = self.talk_cfg.get(tid)
            if not talk:
                continue

            is_new_content = self.print_talk_entry(output, talk, processed_set)
            if not is_new_content:
                continue

            check = talk.get("check", [])
            ns, nf = talk.get("nextTalk", []), talk.get("nextTalk2", [])
            if check and ns and nf:
                c_str = str(_clean_floats(check[0]))
                output.append("--- 检定成功 (%s) ---" % c_str)
                self.process_sequence(output, processed_set, ns, all_start_ids)
                output.append("--- 检定失败 ---")
                self.process_sequence(output, processed_set, nf, all_start_ids)
                continue

            if self.process_options(talk, output, processed_set, start_tids):
                continue

            next_ids = [str(x) for x in talk.get("nextTalk", []) if x]
            valid = [n for n in next_ids if n not in all_start_ids or n in [str(x) for x in start_tids]]
            queue.extend(valid)

    def export_events(self, evt_ids, dual_choice="both"):
        """导出指定事件（按列表顺序）。dual_choice: both|male|female（双起始线时）。"""
        output = []
        for eid in evt_ids:
            eid = str(eid)
            event = self.evt_cfg.get(eid, {})
            if not isinstance(event, dict):
                continue

            current_processed = set()
            current_event_buffer = []
            current_event_buffer.append(self.format_event_header(eid, event))
            current_event_buffer.append("")

            starts = [str(x) for x in event.get("talkId", []) if x]
            if len(starts) == 2:
                if dual_choice == "male":
                    starts = [starts[0]]
                elif dual_choice == "female":
                    starts = [starts[1]]

            self.process_sequence(current_event_buffer, current_processed, starts, self.all_starts)

            current_event_buffer.append("----- END -----")
            current_event_buffer.append("")
            current_event_buffer.append("")
            output.extend(current_event_buffer)
        return "\n".join(output)


_VALID_EXPORT_OPTS = frozenset({
    "pure", "show_id", "show_type", "show_cond", "show_expr", "show_action",
    "show_bg", "show_audio", "show_minigame", "show_effect",
})


def export_story(evt_cfg, talk_cfg, opt_cfg, role_dict, evt_ids, opts=None, dual_choice="both"):
    """导出事件剧本文本。opts 为 dict 或 _ExportOptions；evt_ids 为事件 ID 列表。"""
    if isinstance(opts, dict):
        o = _ExportOptions(**{k: v for k, v in opts.items() if k in _VALID_EXPORT_OPTS})
    else:
        o = opts if opts is not None else _ExportOptions()
    exporter = _StoryExporter(evt_cfg, talk_cfg, opt_cfg, role_dict, opts=o)
    return exporter.export_events(evt_ids, dual_choice=dual_choice)
