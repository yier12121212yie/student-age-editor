# -*- coding: utf-8 -*-
"""flow_assets 单测：CG 图片判定（分辨率硬底线/分组否决与直通/宽高比）、
音乐判定（bgm bundle 直通 / AudioCfg type=1 / 角色语音与 TTS 配音排除）、
以及 aa_index v3 缓存的 texmeta 往返（保存/加载/版本失效）。

运行方式（在 backend 目录下）：
    python -m unittest editor.server.test_flow_assets -v
"""
import json
import os
import tempfile
import unittest

from editor.server.flow_assets import (
    is_cg_image, is_music, music_url_basenames, _tex_group)
from editor.services import unityfs_res as ur


def _b(name):
    """构造 bundle 路径样本。"""
    return os.path.join("aa", "StandaloneWindows64", name + ".bundle")

_H = "f87ec3045d163e9e53db51ff51763468"  # 伪打包 hash 段


class CgImageTest(unittest.TestCase):
    def test_resolution_floor(self):
        # 低于 1280x720 一律不是 CG（即使在 cg 组）
        self.assertFalse(is_cg_image("cg_001", _b("textures_assets_cg"), 1279, 720))
        self.assertFalse(is_cg_image("cg_002", _b("textures_assets_cg"), 1280, 719))
        self.assertFalse(is_cg_image("cg_003", _b("textures_assets_cg"), 800, 600))
        # 恰好达标 + cg 组直通
        self.assertTrue(is_cg_image("cg_004", _b("textures_assets_cg"), 1280, 720))

    def test_no_size(self):
        self.assertFalse(is_cg_image("cg_x", _b("textures_assets_cg"), 0, 0))
        self.assertFalse(is_cg_image("cg_y", _b("textures_assets_cg"), None, None))

    def test_group_pass(self):
        for tag in ("textures_assets_cg", "textures_assets_cg2",
                    "textures_assets_big", "textures_assets_comic"):
            self.assertTrue(is_cg_image("art", _b(tag), 1920, 1080), tag)

    def test_group_reject_despite_size(self):
        # 图标/头像/立绘组即使尺寸达标也否决
        for tag in ("textures_assets_icon", "textures_assets_kzone-head",
                    "textures_assets_role", "fonts_assets"):
            self.assertFalse(is_cg_image("big_one", _b(tag), 2048, 2048), tag)

    def test_aspect_heuristic_general_bundle(self):
        # 通用纹理包：16:9 通过；长条拼接与竖幅大图为非 CG
        self.assertTrue(is_cg_image("bg_room", _b("textures_assets_bg"), 1280, 720))
        self.assertFalse(is_cg_image("strip", _b("textures_assets_"), 4096, 720))
        self.assertFalse(is_cg_image("tall", _b("textures_assets_v177"), 1280, 2400))

    def test_flat_pack_name_reject(self):
        # 无 bundle 分组信息（资源包平铺文件）：靠尺寸+宽高比+命名兜底
        self.assertTrue(is_cg_image("cg_prom", "pack/tex/cg_prom.webp", 1280, 720))
        self.assertFalse(is_cg_image("ui_panel_bg", "pack/tex/ui_panel_bg.webp", 1920, 1080))
        self.assertFalse(is_cg_image("player_head", "pack/tex/player_head.webp", 1600, 900))

    def test_real_world_noise_rejected(self):
        # 实测索引中发现的噪声源：朋友圈大 bundle / paint / 图集页 / 本地化 / 杂包
        self.assertFalse(is_cg_image("k1", _b("kzone_min_" + _H), 1280, 720))
        self.assertFalse(is_cg_image("img_a", _b("textures_assets_paint_" + _H), 1280, 720))
        self.assertFalse(is_cg_image(
            "sactx-0-2048x1024-dxt5-role-77468c2a",
            _b("textures_assets_" + _H), 2048, 1024))
        self.assertFalse(is_cg_image(
            "1-1", _b("localization-assets-chinese(simplified)(zh-hans)_assets_all"),
            2048, 1152))
        self.assertFalse(is_cg_image("img_map", _b("common4_" + _H), 2560, 1440))
        self.assertFalse(is_cg_image("img_tree", _b("main_" + _H), 1476, 1246))

    def test_dlc_and_bg_groups_pass_with_ratio(self):
        # DLC v1xx 混合包与主包：分辨率 + 宽高比通过
        self.assertTrue(is_cg_image("1-1", _b("textures_assets_v182_" + _H), 2048, 1152))
        self.assertTrue(is_cg_image("bg_class", _b("textures_assets_big_" + _H), 2048, 1197))


class TexGroupTest(unittest.TestCase):
    def test_group_parse(self):
        self.assertEqual(_tex_group(_b("textures_assets_cg_" + _H)), "cg")
        self.assertEqual(_tex_group(_b("textures_assets_cg2_" + _H)), "cg2")
        self.assertEqual(_tex_group(_b("textures_assets_kzone-head_" + _H)),
                         "kzone-head")
        self.assertEqual(_tex_group(_b("textures_assets__" + _H)), "")
        self.assertEqual(_tex_group(_b("textures_assets_v182_" + _H)), "v182")
        self.assertIsNone(_tex_group(_b("kzone_min_" + _H)))
        self.assertIsNone(_tex_group("pack/tex/cg_prom.webp"))


class MusicTest(unittest.TestCase):
    def test_bgm_bundle_pass(self):
        self.assertTrue(is_music("bgm_theme", _b("audios_assets_bgm"), set()))

    def test_voice_and_tts_reject(self):
        # 角色语音/ogg 包/TTS 配音：即便 key 出现在 type=1 表集合里也排除？
        # —— 不：表登记优先于分组，仅 audio/tts 与 role/ogg 包被硬否决
        urls = {"bgm_theme", "song2"}
        self.assertFalse(is_music("vo_mei_01", _b("audios_assets_role"), urls))
        self.assertFalse(is_music("ogg_misc", _b("audios_assets_ogg"), urls))
        self.assertFalse(is_music("audio/tts/line001", "", urls))

    def test_table_url_hit(self):
        rows = {
            "1": {"id": 1, "url": "Audios/bgm_school", "type": 1},
            "2": {"id": 2, "url": "audio/tts/line1", "type": 0},
            "3": {"id": 3, "url": "se_door.ogg", "type": 2},
        }
        urls = music_url_basenames(rows)
        self.assertEqual(urls, {"bgm_school"})
        self.assertTrue(is_music("bgm_school", _b("audios_assets_"), urls))
        self.assertFalse(is_music("se_door", _b("audios_assets_"), urls))
        self.assertFalse(is_music("line1", "", urls))


class IndexTexmetaTest(unittest.TestCase):
    def test_save_load_roundtrip_and_version_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            idx = ur.UnityFsIndex([], cache_root=tmp, fingerprint="fp1")
            idx._tex = {"cg_01": ["aa/bundle/b1.bundle", 7]}
            idx._texmeta = {"cg_01": [1280, 720]}
            idx._bundle_set = {"aa/bundle/b1.bundle"}
            idx._save_index()

            with open(os.path.join(tmp, "aa_index.json"), encoding="utf-8") as rf:
                got = json.load(rf)
            self.assertEqual(got["v"], ur.CACHE_VERSION)
            self.assertEqual(got["texmeta"]["cg_01"], [1280, 720])

            back = ur.UnityFsIndex([], cache_root=tmp, fingerprint="fp1")
            self.assertTrue(back.try_load_cached())
            self.assertEqual(back.tex_meta("CG_01"), [1280, 720])
            self.assertTrue(back.has_texmeta())
            self.assertEqual(back.tex_bundle("cg_01"), "aa/bundle/b1.bundle")

            # 旧版本缓存（v2）必须失效，强制重扫补采 texmeta
            with open(os.path.join(tmp, "aa_index.json"), "w", encoding="utf-8") as f:
                json.dump({"v": 2, "fp": "fp1", "tex": idx._tex,
                           "aud": {}, "txt": {}, "cabs": {}, "bundles": []}, f)
            stale = ur.UnityFsIndex([], cache_root=tmp, fingerprint="fp1")
            self.assertFalse(stale.try_load_cached())

    def test_collect_env_records_meta(self):
        class FakeObj:
            def __init__(self, type_name, name, path_id, w=0, h=0):
                self.type = type("T", (), {"name": type_name})()
                self._name = name
                self.path_id = path_id
                self._w, self._h = w, h

            def peek_name(self):
                return self._name

            def read(self):
                return type("R", (), {"m_Width": self._w, "m_Height": self._h})()

        class FakeEnv:
            def __init__(self, objs):
                self.objects = objs

        env = FakeEnv([
            FakeObj("Texture2D", "cg_day.png", 1, 1280, 720),
            FakeObj("Sprite", "icon_a.png", 2, 64, 64),
            FakeObj("AudioClip", "bgm_x.ogg", 3),
        ])
        tex, aud, txt, meta = {}, {}, {}, {}
        ur._collect_env(env, "aa/textures_assets_cg.bundle", tex, aud, txt, meta)
        self.assertEqual(meta["cg_day"], [1280, 720])
        self.assertEqual(meta["icon_a"], [64, 64])  # 尺寸照采，判定在下游
        self.assertNotIn("bgm_x", tex)


if __name__ == "__main__":
    unittest.main()
