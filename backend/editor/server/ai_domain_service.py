# -*- coding: utf-8 -*-
"""AI 细分领域服务：把配置表按「剧情 / 背景 / 人物 / 社交 / 恋爱…」等创作领域组织，
提供领域级条目的 列表 / 读取 / 修改 / 新建 / 删除，替代让 AI 直接整文件读写的粗粒度方式。

设计（对比友商「若心知」编辑器的手工可视化分页：基础配置 / 内容创作 / 官方生态）：
    - 每个领域 = 一组配置表 + 中文名 + 说明，AI 只需说「改剧情 / 改背景」，工具层自动落到对应表；
    - 条目主键 = 配置表 JSON 对象中的记录 key（与 /api/cfg 的 {key: record} 结构一致）；
    - 修改为「字段级合并（patch）」语义：AI 只需给出要改的字段，其余字段保持不变；
    - patch 按 GAME_SCHEMA 做类型规整，未知字段拒绝，避免 AI 写入 schema 外字段；
    - 写操作前自动备份原表到 <表名>.json.bak（滚动 1 份），可手工回滚；
    - 仅操作「当前模组」Cfgs/zh-cn 下的配置表（与 /api/cfg 同一沙箱）。

模块不依赖 HTTP，可直接被 selftest / 其他服务调用。
"""
import json
import os
import re

from editor.server import fs_tools
from editor.server import cfg_store
from editor.server.fs_tools import SandboxError

try:
    from editor.core.game_schema import GAME_SCHEMA
except Exception:
    GAME_SCHEMA = {}


# ---------------------------------------------------------------------------
# 领域定义：id -> {name, desc, tables: {cfg: 中文名}}
# ---------------------------------------------------------------------------

def _cfg_names(*names):
    """把 (cfg, 中文名) 交替参数转成 {cfg: 中文名}。"""
    out = {}
    for i in range(0, len(names), 2):
        out[names[i]] = names[i + 1]
    return out


AI_DOMAINS = [
    {
        "id": "story",
        "name": "剧情",
        "desc": "事件、对话、选项、行动等剧情内容",
        "tables": _cfg_names(
            "EvtCfg", "事件", "TalkCfg", "对话", "OptionCfg", "选项",
            "EvtTypeCfg", "事件类型", "TalkAnimeCfg", "对话立绘动画",
            "ActionCfg", "行动", "ActionEvtCfg", "行动事件", "ActionTalkCfg", "行动对话",
            "ActionTypeCfg", "行动类型", "ClassTalkCfg", "课堂对话", "BargainTalkCfg", "砍价对话",
        ),
    },
    {
        "id": "character",
        "name": "人物",
        "desc": "人物基础、成长、属性、性格、姓名、称号、外观等",
        "tables": _cfg_names(
            "PersonCfg", "人物", "PersonGrowCfg", "人物成长", "PersonAttrCfg", "人物属性",
            "PersonHobbyCfg", "人物爱好", "PersonStateCfg", "人物状态", "PersonFaceCfg", "人物表情",
            "PersonConstCfg", "人物常量", "PersonalityTypeCfg", "性格类型", "PersonalityTestCfg", "性格测试",
            "PersonalityInfluenceCfg", "性格影响", "PersonalityLevelCfg", "性格等级", "TraitsCfg", "特质",
            "NameCfg", "名字", "NicknameCfg", "昵称", "MottoCfg", "座右铭", "MottoLVCfg", "座右铭等级",
            "RelationCfg", "关系", "OtherRelationCfg", "其他关系", "AcquaintancesNumberCfg", "熟人数量",
            "InitialSettingCfg", "初始设置", "SpecializationCfg", "专长", "ModFaceCfg", "捏脸",
            "ClothTypeCfg", "服装", "HairTypeCfg", "发型",
        ),
    },
    {
        "id": "background",
        "name": "背景与场景",
        "desc": "背景图、地图、音乐音效、CG、画面特效",
        "tables": _cfg_names(
            "BgCfg", "背景图", "MapCfg", "地图", "AudioCfg", "音乐音效",
            "CGCfg", "CG", "ShaderCfg", "画面特效", "ColorCfg", "颜色",
            "AnimeConCfg", "动画条件", "AnimeConExpCfg", "动画条件经验", "AnimeKzoneContentCfg", "动画空间动态", "AnimeMarkCntCfg", "动画标记数",
        ),
    },
    {
        "id": "social",
        "name": "社交",
        "desc": "空间动态、短信、闲聊、新闻、好友",
        "tables": _cfg_names(
            "KZoneContentCfg", "空间动态", "KZoneCommentCfg", "空间评论", "KZoneAvatarCfg", "空间头像",
            "KZoneColorCfg", "空间颜色", "KZoneFontCfg", "空间字体", "KZoneMessageBoardCfg", "空间留言板",
            "KZoneProfileCfg", "空间装扮", "PhoneMsgCfg", "手机短信", "InteractCfg", "闲聊",
            "FriendRequestCfg", "好友申请", "NewsCfg", "新闻", "NewsCommentCfg", "新闻评论",
            "NewsTypeCfg", "新闻类型", "ThanksNameCfg", "感谢称呼", "Review2Cfg", "回评",
        ),
    },
    {
        "id": "love",
        "name": "恋爱与结局",
        "desc": "送礼、恋爱约会、生日、结局、家庭",
        "tables": _cfg_names(
            "GiftEvtCfg", "送礼事件", "LoveActionCfg", "恋爱行动", "LoveBadmintonCfg", "恋爱羽毛球",
            "LoveBreakfastCfg", "爱心早餐", "LoveDrawCfg", "恋爱绘画", "LoveGreetingCfg", "恋爱问候",
            "LovePhotoboothCfg", "恋爱拍照", "LoveRibbonCfg", "恋爱缎带", "LoveVindicateCfg", "恋爱辩解",
            "LoveVindicateRateCfg", "恋爱辩解概率", "BirthdayLvCfg", "生日等级", "BirthdayPaintCfg", "生日涂鸦",
            "BirthdayPaintGuessCfg", "生日涂鸦猜谜", "BirthdayRewardCfg", "生日奖励", "BirthdayScoreCfg", "生日分数",
            "EndingDatingCfg", "结局约会", "EndingOptionCfg", "结局选项", "EndingPartCfg", "结局章节",
            "MomPowerCfg", "妈妈力", "NpcChunSupportCfg", "春支持", "NpcJunChaosCfg", "君巢",
        ),
    },
    {
        "id": "item",
        "name": "物品与商店",
        "desc": "物品、商店、书籍、试卷、道具",
        "tables": _cfg_names(
            "ItemCfg", "物品", "ItemTagCfg", "物品标签", "ItemTypeCfg", "物品类型",
            "ShopCfg", "商店", "HonorShopCfg", "荣誉商店", "FightItemCfg", "战斗道具",
            "BookCfg", "书籍", "BookThemeCfg", "书籍主题", "PaperCfg", "试卷",
            "WishCfg", "许愿", "DivinationCfg", "占卜", "FishCfg", "鱼",
            "FishBaitCfg", "鱼饵", "FishDiffCfg", "钓鱼难度", "FishTypeCfg", "鱼类型",
        ),
    },
    {
        "id": "achievement",
        "name": "成就与称号",
        "desc": "成就、称号、荣誉排行",
        "tables": _cfg_names(
            "AchievementCfg", "成就", "AchEffectCfg", "成就效果", "AchIncreaseCfg", "成就提升",
            "AchRankCfg", "成就排行", "AchRefreshCfg", "成就刷新", "GlobalAchCfg", "全局成就",
            "SocialAchievementCfg", "社交成就", "HonorRankCfg", "荣誉排行", "RankCfg", "排行",
        ),
    },
    {
        "id": "study",
        "name": "学习与考试",
        "desc": "课程、作业、考试、学习方法、知识、成绩",
        "tables": _cfg_names(
            "LessonCfg", "课程", "HomeworkCfg", "作业", "ExamBrickCfg", "考试砖块",
            "ExamLevelCfg", "考试等级", "ExamStepCfg", "考试步骤", "FinalExamScoreCfg", "期末考试分数",
            "StudyMethodCfg", "学习方法", "StudyMethodIncresseCfg", "学习方法提升", "StudyPressureCfg", "学习压力",
            "StudyStrategyCfg", "学习策略", "StudyStrategyCostCfg", "学习策略消耗", "StudySummaryCfg", "学习总结",
            "StudySummaryRewardCfg", "学习总结奖励", "KnowledgeCfg", "知识", "KnowledgeQuestionsCfg", "知识问答",
            "KnowledgeTalkTextCfg", "知识对话文本", "KnowledgeTreeCfg", "知识树", "TestPaperCfg", "测试卷",
            "ScoreCfg", "成绩", "ScoreFormulaCfg", "成绩公式", "ScoreParmCfg", "成绩参数", "ScoreRankCfg", "成绩排行",
            "GradeCfg", "年级", "EducationCfg", "教育", "UnivercityCfg", "大学", "UnivercityRankCfg", "大学排行",
            "ReadBookCostCfg", "读书消耗", "MotiveCfg", "动机", "IntrospectionCardCfg", "内省卡",
            "IntrospectionFrequencyCfg", "内省频率", "IntrospectionProgressCfg", "内省进度", "IntrospectionSlotCfg", "内省槽",
        ),
    },
    {
        "id": "club",
        "name": "社团与活动",
        "desc": "社团、日常活动、季节、出游、展会",
        "tables": _cfg_names(
            "ClubActivityCfg", "社团活动", "ClubDailyCfg", "社团日常", "ClubDepartmentCfg", "社团部门",
            "ClubFundsCfg", "社团资金", "ClubMemberCfg", "社团成员", "ClubMemeberCntCfg", "社团人数",
            "ActivityCfg", "活动", "NpcActivityCfg", "NPC活动", "SeasonCfg", "季节", "SeasonTypeCfg", "季节类型",
            "SiteWeightCfg", "地点权重", "TripEffectCfg", "出游效果", "TripLevelCfg", "出游等级",
            "TripSpotCfg", "出游地点", "TripTypeCfg", "出游类型", "ExpoAttrCfg", "展会属性",
            "ExpoEvtCfg", "展会事件", "ExpoSiteCfg", "展会展位", "GoBtnCfg", "按钮",
        ),
    },
    {
        "id": "minigame",
        "name": "小游戏",
        "desc": "各类小游戏的题目、关卡、配置",
        "tables": _cfg_names(
            "MinigameCfg", "小游戏", "MinigameActionCfg", "小游戏行动", "BrickMinigameCfg", "砖块小游戏",
            "CrosswordMinigameCfg", "填字小游戏", "DrawingMinigameCfg", "绘画小游戏", "HandicraftMiniGameCfg", "手工小游戏",
            "HongbaoMiniGameCfg", "红包小游戏", "LineMatchMinigameCfg", "连线小游戏", "MusicMinigameCfg", "音乐小游戏",
            "PianoCfg", "钢琴", "PianoKeyCfg", "钢琴键", "PuzzleMinigameCfg", "拼图小游戏",
            "Qte3MinigameCfg", "QTE小游戏", "SentenceMiniGameCfg", "造句小游戏", "StudyCardMiniGameCfg", "学习卡小游戏",
            "StudyCardRateMiniGameCfg", "学习卡概率", "TalkInputMinigameCfg", "打字小游戏", "WeavingMinigameCfg", "编织小游戏",
            "VoteTurntableCfg", "投票转盘", "QuizAICfg", "问答AI", "QuizCardCfg", "问答卡",
            "QuizCompetitionCfg", "问答竞赛", "QuizPlayerReduceCfg", "问答减员", "QuizTypeCfg", "问答类型",
        ),
    },
    {
        "id": "battle",
        "name": "运动与对战",
        "desc": "篮球、羽毛球、谈判、DND 等玩法数值",
        "tables": _cfg_names(
            "Basketball1On1Cfg", "篮球单挑", "BasketballPlayerCfg", "篮球球员", "BasketballSkinCfg", "篮球皮肤",
            "BadmintonLevelCfg", "羽毛球等级", "BadmintonModelCfg", "羽毛球模型",
            "NegotiationCfg", "谈判", "NegotiationBuffCfg", "谈判增益", "NegotiationChatCfg", "谈判对话",
            "NegotiationInvolvedCfg", "谈判参与", "NegotiationMiniGameCfg", "谈判小游戏", "NegotiationMiniGameCardCfg", "谈判卡牌",
            "NegotiationMiniGameCardTypeCfg", "谈判卡牌类型", "NegotiationPlayerCfg", "谈判玩家", "NegotiationSkillCfg", "谈判技能",
            "NegotiationTalkCfg", "谈判对话文本", "NegotiationTeamCfg", "谈判队伍", "NegotiationTeammateCfg", "谈判队友",
            "NegotiationTopicCfg", "谈判话题", "NegotiationUniqueCardCfg", "谈判特殊卡", "FightPlayerCfg", "战斗玩家",
            "SportConstCfg", "运动常量",
        ),
    },
    {
        "id": "job",
        "name": "职业与兼职",
        "desc": "职业、兼职需求、NPC 教学",
        "tables": _cfg_names(
            "JobCfg", "职业", "JobUnlockCfg", "职业解锁", "IntDemandCfg", "兼职需求", "TeachNpcCfg", "NPC教学",
        ),
    },
    {
        "id": "world",
        "name": "世界观与文案",
        "desc": "世界观、描述、文本、编年史、影视、写作",
        "tables": _cfg_names(
            "WorldviewCfg", "世界观", "DescriptionCfg", "描述", "TextCfg", "文本", "LoadingTxtCfg", "加载文本",
            "ChronologyCfg", "编年史", "WikiCfg", "百科", "TVCfg", "电视", "MovieCfg", "电影",
            "MuseumNameCfg", "博物馆名", "WritingCfg", "写作", "WritingEffectCfg", "写作效果", "WritingRankCfg", "写作排行",
            "RenshengguanMemoryCfg", "人生馆记忆", "RenshengguanSkillCfg", "人生馆技能", "RenshengguanTypeCfg", "人生馆类型",
            "InfluenceCfg", "影响",
        ),
    },
    {
        "id": "function",
        "name": "功能与系统",
        "desc": "功能开关、引导、快捷键、红点、游戏全局参数",
        "tables": _cfg_names(
            "FuncCfg", "功能", "FuncTypeCfg", "功能类型", "GuideCfg", "引导", "GuideGroupCfg", "引导组",
            "GuideImgCfg", "引导图", "GuideNegotiationCfg", "引导谈判", "GuideStateCfg", "引导状态",
            "HotKeyCfg", "快捷键", "InputActionCfg", "输入动作", "ConsoleCodeCfg", "控制台代码",
            "RedpointCfg", "红点", "ToggleCfg", "开关", "LocalizeAssetCfg", "本地化资源",
            "GameCfg", "游戏参数", "GameDiffCfg", "游戏难度", "GamePlatformCfg", "游戏平台", "GameTypeCfg", "游戏类型",
            "EffectConstCfg", "效果常量", "EffectTypeCfg", "效果类型", "ConditionTypeCfg", "条件类型",
            "OtherAttrCfg", "其他属性", "ValueviewCfg", "数值视图", "ValueviewEffectCfg", "数值视图效果",
            "ValueviewGraphCfg", "数值视图图表", "AttrUnitCfg", "属性单位", "AttrUnitCondCfg", "属性单位条件",
        ),
    },
]

# 通用兜底领域：其余所有配置表
TABLE_FALLBACK_DOMAIN = "table"
_TABLE_CN = {}  # cfg -> 中文名（领域定义内累积）


def _accumulate_table_cn():
    for dom in AI_DOMAINS:
        for cfg, cn in dom["tables"].items():
            _TABLE_CN.setdefault(cfg, cn)


_accumulate_table_cn()


def _split_camel(name):
    """EvtCfg -> evt；PersonGrowCfg -> person grow。"""
    parts = re.findall(r"[A-Z][a-z0-9]*|[a-z0-9]+", name)
    return " ".join(parts).strip().lower()


def _auto_cn(cfg_name):
    """未手工命名的表，用驼峰拆词生成中文名（保留原文避免误导）。"""
    base = cfg_name
    for suffix in ("Cfg", "Define"):
        if base.endswith(suffix) and len(base) > len(suffix):
            base = base[: -len(suffix)]
    return "%s配置" % _split_camel(base) if base else cfg_name


def get_domains():
    """领域清单（含每领域下的表与中文名）。"""
    out = []
    for dom in AI_DOMAINS:
        out.append({
            "id": dom["id"],
            "name": dom["name"],
            "desc": dom["desc"],
            "tables": {cfg: _TABLE_CN.get(cfg, _auto_cn(cfg)) for cfg in sorted(dom["tables"])},
        })
    assigned = set()
    for dom in AI_DOMAINS:
        assigned.update(dom["tables"])
    remaining = sorted(set(GAME_SCHEMA) - assigned)
    out.append({
        "id": TABLE_FALLBACK_DOMAIN,
        "name": "通用配置",
        "desc": "未归入上述领域的其他配置表（兜底）",
        "tables": {cfg: _TABLE_CN.get(cfg, _auto_cn(cfg)) for cfg in remaining},
    })
    return out


def get_domain(domain_id):
    for dom in get_domains():
        if dom["id"] == domain_id:
            return dom
    raise SandboxError("未知领域: %s（可用领域见 /api/ai/domains）" % domain_id)


def _cfg_in_domain(domain_id, cfg):
    if domain_id == TABLE_FALLBACK_DOMAIN:
        assigned = set()
        for dom in AI_DOMAINS:
            assigned.update(dom["tables"])
        return cfg in set(GAME_SCHEMA) - assigned
    dom = get_domain(domain_id)
    return cfg in dom["tables"]


# ---------------------------------------------------------------------------
# 配置表读写（沙箱 + 备份 + 原子写）
# ---------------------------------------------------------------------------

# 离线模式注入点：CLI/TUI（无 HTTP server）设置当前模组的 Cfgs/zh-cn 目录。
# 默认 None 表示走 STATE；一旦设置，所有领域工具即离线可用（selftest 同理）。
_offline_cfg_dir = None


def set_offline_cfg_dir(cfg_dir):
    """离线复用入口：传入当前模组 Cfgs/zh-cn 目录，传 None 恢复由 STATE 提供。"""
    global _offline_cfg_dir
    _offline_cfg_dir = str(cfg_dir) if cfg_dir else None


def _cfg_dir():
    """当前模组的 Cfgs/zh-cn 目录（优先离线注入，否则由 STATE 提供）。"""
    if _offline_cfg_dir:
        return _offline_cfg_dir
    from editor.server.api import STATE
    return STATE._cfg_dir()


def _cfg_path(cfg_name):
    d = _cfg_dir()
    if not d:
        raise SandboxError("未选择模组")
    rel = fs_tools._norm(cfg_name + ".json")
    return os.path.join(d, rel)


def load_cfg(cfg_name):
    """读取配置表（磁盘 → {key: record}），失败抛 SandboxError。"""
    path = _cfg_path(cfg_name)
    if not os.path.isfile(path):
        raise SandboxError("配置表不存在: %s.json" % cfg_name)
    try:
        with open(path, "r", encoding="utf-8-sig") as fp:
            data = json.load(fp)
    except (ValueError, OSError) as e:
        raise SandboxError("配置表 %s 读取失败: %s" % (cfg_name, e))
    if not isinstance(data, dict):
        raise SandboxError("配置表 %s 结构异常：顶层应为 JSON 对象" % cfg_name)
    return data


def cfg_exists(cfg):
    """配置表文件是否存在（未选模组时照常抛 SandboxError）。"""
    return os.path.isfile(_cfg_path(cfg))


def _missing_cfg_error(cfg):
    """表不存在时的可执行提示：让 AI 知道如何继续，而不是裸报「配置表不存在」。"""
    return SandboxError(
        "当前模组还没有 %s 配置表（%s.json 不存在，通常是因为还没有创建过任何条目）。"
        "如需新建条目请用 create_domain_item（会自动创建该表）；"
        "如需确认已有条目可先用 list_domain_items 查看。" % (cfg, cfg))


def _backup_path(cfg_name):
    return _cfg_path(cfg_name) + ".bak"


def save_cfg(cfg_name, data, backup=True):
    """原子写回配置表；写前把当前内容备份为 <表>.json.bak（滚动 1 份）。

    落盘统一走 cfg_store.write_cfg（覆盖前另留 .editor_history 历史快照，
    与 GUI / CLI 写入链路一致）；.bak 作为双保险保留。
    """
    path = _cfg_path(cfg_name)
    if backup and os.path.isfile(path):
        try:
            with open(path, "rb") as src, open(_backup_path(cfg_name), "wb") as dst:
                dst.write(src.read())
        except OSError:
            pass  # 备份失败不阻塞写入
    result = cfg_store.write_cfg(path, data, snapshot=True)
    if not result.get("ok"):
        raise OSError(result.get("error") or "配置表写入失败")


# ---------------------------------------------------------------------------
# 条目级操作
# ---------------------------------------------------------------------------

_FIELD_CN = {}


def _load_field_cn():
    """字段中文名：优先用 data_dicts 的键名映射，其次从领域表内嵌字段名提取。"""
    try:
        from editor.core import data_dicts
        for m in (data_dicts.DEFAULT_EVT_KEY_MAP, data_dicts.DEFAULT_TALK_KEY_MAP,
                  data_dicts.DEFAULT_OPT_KEY_MAP, data_dicts.DEFAULT_PERSON_KEY_MAP,
                  data_dicts.DEFAULT_GROW_KEY_MAP, data_dicts.DEFAULT_KZONE_KEY_MAP,
                  data_dicts.DEFAULT_PHONE_KEY_MAP, data_dicts.DEFAULT_GIFT_KEY_MAP,
                  data_dicts.DEFAULT_INTERACT_KEY_MAP):
            for k, v in m.items():
                _FIELD_CN.setdefault(k, v)
    except Exception:
        pass


_load_field_cn()


def _field_cn(cfg, field):
    if field in _FIELD_CN:
        return _FIELD_CN[field]
    schema = GAME_SCHEMA.get(cfg, {})
    return schema.get(field, field)


def _entry_summary(cfg, key, record):
    """条目摘要：名称 + 关键内容预览（供 list 用）。"""
    if not isinstance(record, dict):
        return {"cfg": cfg, "id": str(key), "name": str(record)[:60], "summary": ""}
    name = ""
    for nf in ("name", "title", "content", "desc", "girlTalk", "text", "boyTalk"):
        v = record.get(nf)
        if isinstance(v, str) and v.strip():
            name = v.strip()
            break
    summary = ""
    for sf in ("desc", "note", "content", "text", "talk"):
        v = record.get(sf)
        if isinstance(v, str) and v.strip():
            summary = v.strip().replace("\n", " ")[:120]
            break
    return {"cfg": cfg, "id": str(key), "name": name[:80], "summary": summary}


def list_domain_items(domain_id, q=None, limit=50, table=None):
    """列出领域内条目。q 为关键词（匹配 id / 名称 / 摘要），table 限定单表。"""
    dom = get_domain(domain_id)
    cfgs = [table] if table else list(dom["tables"])
    if table is not None and not _cfg_in_domain(domain_id, table):
        raise SandboxError("表 %s 不属于领域 %s" % (table, dom["name"]))
    out = []
    limit = max(1, min(int(limit or 50), 200))
    q = (q or "").strip().lower()
    for cfg in cfgs:
        try:
            data = load_cfg(cfg)
        except SandboxError:
            continue  # 表不存在时跳过（模组通常只带部分表）
        for key, record in data.items():
            item = _entry_summary(cfg, str(key), record)
            if q and not (
                q in item["id"].lower()
                or q in item["name"].lower()
                or q in item["summary"].lower()
                or (isinstance(record, dict) and any(
                    q in str(v).lower() for v in list(record.values())[:8]))
            ):
                continue
            out.append(item)
            if len(out) >= limit:
                return {"domain": dom["id"], "q": q, "items": out}
    return {"domain": dom["id"], "q": q, "items": out}


def get_domain_item(domain_id, cfg, key):
    """读取单个条目完整 JSON。"""
    if not _cfg_in_domain(domain_id, cfg):
        raise SandboxError("表 %s 不属于领域 %s" % (cfg, get_domain(domain_id)["name"]))
    if not cfg_exists(cfg):
        raise _missing_cfg_error(cfg)
    data = load_cfg(cfg)
    key = str(key)
    if key not in data:
        raise SandboxError("表 %s 中不存在 id=%s（可用 list_domain_items 查看）" % (cfg, key))
    record = data[key]
    return {
        "domain": domain_id,
        "cfg": cfg,
        "cfg_cn": _TABLE_CN.get(cfg, _auto_cn(cfg)),
        "id": key,
        "data": record,
        "fields": [_field_cn(cfg, k) for k in (record.keys() if isinstance(record, dict) else [])],
    }


def _coerce_patch(cfg, patch):
    """按 GAME_SCHEMA 规整 patch 字段类型；未知字段拒绝。

    Number: 接受 int/float/数字字符串；String: 接受标量（拒绝 bool/容器）转字符串；
    1D/2D Array: 接受 list（含 JSON 字符串解析）；未知字段直接报错。
    """
    schema = GAME_SCHEMA.get(cfg)
    if not schema:
        raise SandboxError(
            "表 %s 在游戏 schema 中无字段定义（%s），无法安全校验字段，请勿通过 AI 直接修改"
            % (cfg, "元数据/空表" if cfg.endswith(("Define", "Attribute")) else "全局配置表"))
    out = {}
    for k, v in patch.items():
        ftype = schema.get(k)
        if ftype is None:
            raise SandboxError("表 %s 的字段 %s 不在 schema 中（允许字段: %s）"
                               % (cfg, k, "、".join(sorted(schema)[:30]) or "无"))
        if ftype == "Number":
            if isinstance(v, bool) or not isinstance(v, (int, float, str)):
                raise SandboxError("字段 %s 应为数值，收到: %r" % (k, v))
            try:
                out[k] = float(v) if isinstance(v, str) else v
            except ValueError:
                raise SandboxError("字段 %s 应为数值，收到: %r" % (k, v))
        elif ftype == "String":
            if isinstance(v, (bool, dict, list)):
                raise SandboxError("字段 %s 应为字符串，收到: %r" % (k, v))
            out[k] = v
        elif "Array" in ftype:
            if isinstance(v, str):
                try:
                    v = json.loads(v)
                except ValueError:
                    raise SandboxError("字段 %s 应为数组（JSON），收到: %r" % (k, v))
            if not isinstance(v, list):
                raise SandboxError("字段 %s 应为数组，收到: %r" % (k, v))
            out[k] = v
        else:
            out[k] = v
    return out


def _match_role_id_by_name(name):
    """按名字精确匹配角色 ID：优先内置角色字典（ROLE_DICT），其次当前模组 PersonCfg。

    返回原始 id（数字字符串可安全转 int 时转成 int，保持与既有数据一致），匹配不到返回 None。
    """
    name = (name or "").strip()
    if not name:
        return None
    try:
        from editor.core import data_dicts
        role_dict = getattr(data_dicts, "ROLE_DICT", {}) or {}
    except Exception:
        role_dict = {}
    candidates = {}
    for rid, rname in role_dict.items():
        candidates[str(rid)] = str(rname)
    try:
        if cfg_exists("PersonCfg"):
            for rid, rec in load_cfg("PersonCfg").items():
                if isinstance(rec, dict) and str(rec.get("name", "") or "").strip():
                    candidates[str(rid)] = str(rec["name"]).strip()
    except SandboxError:
        pass
    for rid, rname in candidates.items():
        if rname == name:
            return int(rid) if rid.isdigit() and str(int(rid)) == rid else rid
    return None


def _ensure_content_role(cfg, record):
    """有「内容归属角色」的条目写操作兜底：避免生成「有内容却没说话人/发送者」的坏数据。

    - TalkCfg（对白）：填了 roleName（自定义名字）但 roleIds（说话人群组）为空时，
      按名字自动匹配角色补 roleIds，匹配不到则报错；旁白（两者皆空）放行。
    - PhoneMsgCfg（短信）/ KZoneContentCfg（空间动态）/ KZoneCommentCfg（评论）：
      填了 content 却漏掉发送者/发布者 role（roles）时，报错引导补角色 ID。
    """
    if not isinstance(record, dict):
        return
    if cfg == "TalkCfg":
        role_name = (record.get("roleName") or "").strip()
        if not role_name or (record.get("roleIds") or []):
            return
        matched = _match_role_id_by_name(role_name)
        if matched is None:
            raise SandboxError(
                "对白（TalkCfg）的说话人群组 roleIds 为必填，不能只填 roleName（自定义名字）。"
                "你填的自定义名字「%s」不在角色字典中：请先用 get_game_dicts(name=roles, q=%s) "
                "查询该角色的 ID 并补上 roleIds=[ID]；若想新增角色请先创建 PersonCfg 条目，"
                "或用已有角色 ID 配合 roleName 显示自定义名字。" % (role_name, role_name))
        record["roleIds"] = [matched]
        return
    role_field = {"PhoneMsgCfg": "role", "KZoneContentCfg": "role",
                  "KZoneCommentCfg": "roles"}.get(cfg)
    if role_field is None:
        return
    has_content = bool(str(record.get("content") or "").strip())
    role_val = record.get(role_field)
    role_empty = (role_val is None or role_val == ""
                  or (isinstance(role_val, list) and len(role_val) == 0))
    if not has_content or not role_empty:
        return
    raise SandboxError(
        "条目（%s）的 %s（发送者/发布者角色）为必填，不能只填内容。"
        "请先用 get_game_dicts(name=roles, q=角色名) 查询发送角色的 ID，"
        "再补上 %s=ID。" % (cfg, role_field, role_field))


def update_domain_item(domain_id, cfg, key, patch):
    """字段级合并修改：只更新 patch 中的字段，其余保持不动。返回修改后的完整记录。"""
    if not isinstance(patch, dict) or not patch:
        raise SandboxError("patch 必须是非空对象")
    if not _cfg_in_domain(domain_id, cfg):
        raise SandboxError("表 %s 不属于领域 %s" % (cfg, get_domain(domain_id)["name"]))
    if not cfg_exists(cfg):
        raise _missing_cfg_error(cfg)
    data = load_cfg(cfg)
    key = str(key)
    if key not in data:
        raise SandboxError("表 %s 中不存在 id=%s" % (cfg, key))
    record = data[key]
    if not isinstance(record, dict):
        raise SandboxError("表 %s 的 id=%s 不是对象，无法字段级修改" % (cfg, key))
    coerced = _coerce_patch(cfg, patch)
    before = json.dumps(record, ensure_ascii=False, sort_keys=True)
    record.update(coerced)
    _ensure_content_role(cfg, record)
    after = json.dumps(record, ensure_ascii=False, sort_keys=True)
    if before == after:
        return {"domain": domain_id, "cfg": cfg, "id": key, "changed": False,
                "data": record, "note": "patch 与原内容一致，未写入"}
    save_cfg(cfg, data)
    return {"domain": domain_id, "cfg": cfg, "id": key, "changed": True,
            "patched_fields": sorted(coerced), "data": record}


def create_domain_item(domain_id, cfg, key, data):
    """新建条目。key 缺省时自动分配（当前最大数值 id + 1，或 1）。"""
    if not isinstance(data, dict):
        raise SandboxError("data 必须是非空对象")
    if not _cfg_in_domain(domain_id, cfg):
        raise SandboxError("表 %s 不属于领域 %s" % (cfg, get_domain(domain_id)["name"]))
    # 表不存在时自动建空表：新建条目本身就该能建表（模组通常只带部分表）
    table = {} if not cfg_exists(cfg) else load_cfg(cfg)
    if key is None:
        # 优先采用 data 中的 id 字段作为记录 key，避免 key 与记录内 id 不一致
        key = data.get("id")
    if key is None:
        nums = [int(k) for k in table if str(k).isdigit()]
        key = str((max(nums) + 1) if nums else 1)
    key = str(key)
    if key in table:
        raise SandboxError("表 %s 已存在 id=%s，请用 update 修改或换一个 id" % (cfg, key))
    coerced = _coerce_patch(cfg, data)
    _ensure_content_role(cfg, coerced)
    table[key] = coerced
    save_cfg(cfg, table)
    return {"domain": domain_id, "cfg": cfg, "id": key, "created": True, "data": coerced}


def delete_domain_item(domain_id, cfg, key):
    """删除条目。返回被删除的记录。"""
    if not _cfg_in_domain(domain_id, cfg):
        raise SandboxError("表 %s 不属于领域 %s" % (cfg, get_domain(domain_id)["name"]))
    if not cfg_exists(cfg):
        raise _missing_cfg_error(cfg)
    table = load_cfg(cfg)
    key = str(key)
    if key not in table:
        raise SandboxError("表 %s 中不存在 id=%s" % (cfg, key))
    removed = table.pop(key)
    save_cfg(cfg, table)
    return {"domain": domain_id, "cfg": cfg, "id": key, "deleted": True, "data": removed}


# ---------------------------------------------------------------------------
# 游戏字典查询（AI 对话填 ID 时核对 id → 名称）
# ---------------------------------------------------------------------------

GAME_DICT_SOURCES = {
    "roles": ("角色", "ROLE_DICT"),
    "items": ("物品", "ITEM_DICT"),
    "maps": ("地点", "MAP_DICT"),
    "jobs": ("职业", "JOB_DICT"),
    "attrs": ("属性", "ATTR_DICT"),
    "relations": ("关系", "RELATION_DICT"),
    "bgs": ("背景", "BG_DICT"),
    "turns": ("回合", "TURN_DICT"),
    "evt_types": ("事件类型", "EVT_TYPE_DICT"),
    "badminton_models": ("羽毛球模型", "BADMINTON_MODELS"),
}


def list_dicts():
    """列出可查询的游戏字典及条目数。"""
    try:
        from editor.core import data_dicts
    except Exception:
        data_dicts = None
    out = []
    for k, (cn, attr) in GAME_DICT_SOURCES.items():
        try:
            count = len(getattr(data_dicts, attr, {}) or {})
        except Exception:
            count = 0
        out.append({"id": k, "name": cn, "count": count})
    return out


def get_dict(name, q=None, limit=30):
    """按关键词查询游戏字典，返回 [{id, name}]，供 AI 填写 ID 字段时核对名称。"""
    src = GAME_DICT_SOURCES.get((name or "").strip().lower())
    if src is None:
        raise SandboxError(
            "未知字典 %s（可用 get_game_dicts 不带参数查看可用字典列表）" % name)
    try:
        from editor.core import data_dicts
        d = getattr(data_dicts, src[1], {}) or {}
    except Exception:
        d = {}
    q = (q or "").strip().lower()
    items = []
    for k, v in d.items():
        label = str(v)
        if isinstance(v, (list, tuple)) and v:
            label = str(v[0])
        if q and q not in str(k).lower() and q not in label.lower():
            continue
        items.append({"id": str(k), "name": label})
    items.sort(key=lambda it: (
        (int(it["id"]) if it["id"].lstrip("-").isdigit() else 1 << 60),
        it["id"],
    ))
    try:
        cap = max(1, min(int(limit or 30), 100))
    except (TypeError, ValueError):
        cap = 30
    return {
        "name": (name or "").strip().lower(),
        "cn": src[0],
        "total": len(items),
        "items": items[:cap],
    }
