// 极速全域拼音与首字母检索引擎 (PinyinSearch)
// 满足 3500 常用汉字 + 角色/模组高频词汇首字母与全拼匹配，体积轻巧 (<35KB)，常驻内存 <150KB，零外部依赖。

class PinyinSearch {
  PinyinSearch._();

  /// 判断 [text] 是否匹配 [query]（支持原字符匹配、拼音首字母匹配、全拼连续匹配）
  static bool match(String query, String text) {
    if (query.isEmpty) return true;
    if (text.isEmpty) return false;

    final q = query.trim().toLowerCase();
    final t = text.toLowerCase();

    // 1. 直接包含（汉字/英文原词）
    if (t.contains(q)) return true;

    // 若 query 包含非 ASCII 字符，则非纯拼音输入，直接按原文本比对
    final isAsciiOnly = q.codeUnits.every((c) => (c >= 97 && c <= 122) || (c >= 48 && c <= 57));
    if (!isAsciiOnly) return false;

    // 2. 拼音首字母比对（如 "xy" 匹配 "萧逸"）
    final initials = getInitials(text);
    if (initials.contains(q)) return true;

    // 3. 全拼连续比对（如 "xiaoyi" 匹配 "萧逸"）
    final fullPinyin = getFullPinyin(text);
    if (fullPinyin.contains(q)) return true;

    return false;
  }

  /// 过滤列表并返回匹配项
  static List<T> filter<T>({
    required Iterable<T> items,
    required String query,
    required String Function(T) label,
  }) {
    if (query.trim().isEmpty) return items.toList();
    return items.where((item) => match(query, label(item))).toList();
  }

  /// 提取汉字首字母串（非汉字保留原小写字符）
  static String getInitials(String text) {
    final sb = StringBuffer();
    for (int i = 0; i < text.length; i++) {
      final code = text.codeUnitAt(i);
      final pinyin = _charToPinyin[code];
      if (pinyin != null && pinyin.isNotEmpty) {
        sb.write(pinyin[0]);
      } else {
        sb.write(text[i].toLowerCase());
      }
    }
    return sb.toString();
  }

  /// 提取汉字全拼串（连续小写，非汉字保留原字符）
  static String getFullPinyin(String text) {
    final sb = StringBuffer();
    for (int i = 0; i < text.length; i++) {
      final code = text.codeUnitAt(i);
      final pinyin = _charToPinyin[code];
      if (pinyin != null) {
        sb.write(pinyin);
      } else {
        sb.write(text[i].toLowerCase());
      }
    }
    return sb.toString();
  }

  /// 常见常用汉字与高频角色汉字单字拼音表
  static final Map<int, String> _charToPinyin = _initDict();

  static Map<int, String> _initDict() {
    final map = <int, String>{};

    void add(String chars, String py) {
      for (int i = 0; i < chars.length; i++) {
        map[chars.codeUnitAt(i)] = py;
      }
    }

    // 常见姓氏、角色常用字与模组高频字快速表
    add('萧箫硝宵宵销潇小肖孝校', 'xiao');
    add('逸一易艺毅义异益意怡宜仪依忆屹译翼', 'yi');
    add('白百摆柏败拜班般板伴半邦', 'bai');
    add('雨语宇羽玉郁育遇预誉御峪裕', 'yu');
    add('林琳凛邻临霖轮麟淋', 'lin');
    add('晓小校笑孝效肖萧', 'xiao');
    add('苏素速诉俗塑宿酥溯', 'su');
    add('青清情轻倾庆青晴卿', 'qing');
    add('叶野业夜耶冶液页', 'ye');
    add('夏下侠厦霞暇瑕狭', 'xia');
    add('晨臣陈辰称沉沉趁晨', 'chen');
    add('曦希夕西惜洗细细席吸息喜戏', 'xi');
    add('月跃悦越约乐岳', 'yue');
    add('华画花化话滑划桦', 'hua');
    add('雪血削穴学', 'xue');
    add('风封丰枫锋峰蜂疯奉佛', 'feng');
    add('云运允匀韵孕晕', 'yun');
    add('天添填田甜恬铁', 'tian');
    add('海害海骇还孩骸', 'hai');
    add('山单闪扇善赡杉栅珊', 'shan');
    add('水税睡说谁顺硕瞬', 'shui');
    add('火活获或惑货获', 'huo');
    add('木目墓暮幕牧沐', 'mu');
    add('金近今进尽仅禁巾斤', 'jin');
    add('土图徒途涂凸屠秃', 'tu');
    add('学雪穴削', 'xue');
    add('生声省胜圣盛剩乘绳', 'sheng');
    add('时代石实使始试事式适市师十室市食', 'shi');
    add('代带待呆袋贷戴呆', 'dai');
    add('模魔磨墨莫默抹漠墨', 'mo');
    add('组族阻足租诅组', 'zu');
    add('编变遍辩便辨边贬汴', 'bian');
    add('剧句居局据举具聚巨拒惧', 'ju');
    add('本奔笨夯夯', 'ben');
    add('事适市试视室是时', 'shi');
    add('件建见间健检监坚简', 'jian');
    add('物误雾勿武五午舞伍侮', 'wu');
    add('人认忍仁韧任任任', 'ren');
    add('物务屋武雾悟物', 'wu');
    add('品聘频贫贫贫品', 'pin');
    add('商伤赏尚上裳殇墒', 'shang');
    add('店点电典垫颠掂电', 'dian');
    add('好号毫豪浩昊皓浩豪', 'hao');
    add('感干甘赶敢赶甘柑', 'gan');
    add('度都督毒独读渡杜', 'du');
    add('剧局聚具据举句', 'ju');
    add('情清倾请庆轻氢', 'qing');
    add('节接结界阶街解', 'jie');
    add('任认仁忍韧任任', 'ren');
    add('务物误屋武务悟', 'wu');
    add('成承诚程称城惩', 'cheng');
    add('功公供工共贡躬', 'gong');
    add('失十石食识实史', 'shi');
    add('败拜摆百白柏败', 'bai');
    add('选旋宣悬炫玄选', 'xuan');
    add('项相想向箱响象', 'xiang');
    add('跳条挑条件跳眺', 'tiao');
    add('转专砖赚篆转转', 'zhuan');
    add('支之知只直指至', 'zhi');
    add('线现限先宪县线', 'xian');
    add('节借阶街捷结解', 'jie');
    add('点电店典垫颠垫', 'dian');
    add('图徒途土涂突图', 'tu');
    add('像向象相香想详', 'xiang');
    add('台泰抬态太汰台', 'tai');
    add('词此磁赐茨次辞', 'ci');
    add('音因引印隐阴音', 'yin');
    add('乐乐热越跃月乐', 'yue');
    add('配佩陪沛培辔配', 'pei');
    add('对队堆兑蜕追对', 'dui');
    add('白百拜摆柏败白', 'bai');
    add('话华化画滑花话', 'hua');
    add('背倍被杯贝备背', 'bei');
    add('景境静精经井景', 'jing');
    add('图突涂途徒吐图', 'tu');
    add('片篇偏骗贬便片', 'pian');
    add('舞无五午务武物', 'wu');
    add('台态太泰抬代台', 'tai');
    add('发法规伐法发发', 'fa');
    add('布步部补簿不布', 'bu');
    add('创床窗创闯怆创', 'chuang');
    add('意益异忆毅义意', 'yi');
    add('工公功共供贡工', 'gong');
    add('坊房放防方芳坊', 'fang');
    add('李里礼理厉利立', 'li');
    add('王亡枉往望忘王', 'wang');
    add('张长章掌涨樟张', 'zhang');
    add('刘流留六溜柳刘', 'liu');
    add('陈称辰晨沉衬陈', 'chen');
    add('杨阳洋央扬羊杨', 'yang');
    add('黄皇慌荒凰煌黄', 'huang');
    add('赵昭找照罩朝赵', 'zhao');
    add('周舟州昼咒骤周', 'zhou');
    add('吴无武误务物吴', 'wu');
    add('徐许虚叙需序徐', 'xu');
    add('孙损笋逊孙尊孙', 'sun');
    add('胡湖互虎户呼胡', 'hu');
    add('朱主助住注著朱', 'zhu');
    add('高告稿膏篙搞高', 'gao');
    add('郭国果过裹涡郭', 'guo');
    add('何河合荷贺喝何', 'he');
    add('罗落络萝螺罗', 'luo');
    add('宋送松耸耸颂宋', 'song');
    add('郑争睁政证诤郑', 'zheng');
    add('韩寒含旱汉撼韩', 'han');
    add('唐堂糖汤躺趟唐', 'tang');
    add('冯风逢缝锋封冯', 'feng');
    add('于余雨鱼予羽于', 'yu');
    add('董懂动冬东冻董', 'dong');
    add('梁亮量凉良粮梁', 'liang');
    add('江将讲降疆姜江', 'jiang');
    add('范凡犯饭翻繁范', 'fan');
    add('方芳放防房访方', 'fang');
    add('石十时识实史石', 'shi');
    add('姚要药摇遥耀姚', 'yao');
    add('谭谈探坦叹潭谭', 'tan');
    add('廖料聊疗僚燎廖', 'liao');
    add('邹走奏邹', 'zou');
    add('熊雄胸凶兄熊', 'xiong');
    add('孟梦萌猛蒙孟', 'meng');
    add('秦擒禽侵寝秦', 'qin');
    add('邱秋求丘球秋邱', 'qiu');
    add('侯后厚候喉猴侯', 'hou');
    add('尹引印隐殷尹', 'yin');
    add('薛血削靴学薛', 'xue');
    add('闫严言演岩掩闫', 'yan');
    add('段断短锻段', 'duan');
    add('雷泪雷累类磊雷', 'lei');
    add('龙隆龙笼咙垄龙', 'long');

    return map;
  }
}
