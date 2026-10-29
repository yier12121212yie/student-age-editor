import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:student_age_editor/core/texture_budget.dart';

/// 纹理预算守门测试 —— 「降 GPU 峰值占用」阶段 5。
///
/// ## 这个测试在守什么
///
/// 全库有三层自研图片缓存（`TexBytesCache` / `_BytesLru` / Live2D
/// `_renderCache`），但存的全是**压缩字节**，吃 Dart 堆、**不吃 GPU**。GPU 纹理的
/// 唯一来源是引擎的 `ImageCache`（解码后 RGBA 位图），而它此前**全库从未配置**，
/// 走 Flutter 默认 1000 条 / 100 MiB 且只进不出。
///
/// 所以这里断言四件事：
///   1. 预算确实被设置（且 `main()` 里真的调了 `apply()`）；
///   2. 解码档位函数的行为边界（吸档只向上、上限生效、不越界）；
///   3. Live2D 那层**唯一无上限**的缓存已经限容；
///   4. **每一个** `Image.memory` / `Image.network` 调用点都给了 `cacheWidth`。
///
/// 第 4 条是最重要的一条：仓库真实资源 `Tex2D/` 里有 3 张 **8192×8192** 的 SDF
/// 字体图集，按原尺寸解码单张就是 **256 MB** 位图。漏一个调用点，就是一次崩溃。
void main() {
  // ---------------- 4. 静态守门：所有图片调用点必须降采样 ----------------

  group('静态守门', () {
    /// 放行标记：在调用点同窗口内写 `// texture-budget-exempt` 可豁免
    /// （需要原图语义且已论证过上限时使用）。
    const exemptMarker = 'texture-budget-exempt';

    /// `cacheWidth` 可以写在调用点的后续若干行（多参调用逐行排版）。
    const lookaheadLines = 12;

    test('每个 Image.memory / Image.network 调用点都带 cacheWidth', () {
      final libDir = Directory('lib');
      expect(libDir.existsSync(), isTrue, reason: '请在 frontend/ 下运行');

      final callRe = RegExp(r'Image\.(?:memory|network)\(');
      final violations = <String>[];

      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final rel = entity.path
            .replaceAll(Platform.pathSeparator, '/')
            .replaceFirst('lib/', '');
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (!callRe.hasMatch(lines[i])) continue;
          final window = lines
              .sublist(i, (i + lookaheadLines).clamp(0, lines.length))
              .join('\n');
          if (window.contains('cacheWidth')) continue;
          if (window.contains(exemptMarker)) continue;
          violations.add('$rel:${i + 1}  ${lines[i].trim()}');
        }
      }

      expect(
        violations,
        isEmpty,
        reason: '漏 cacheWidth = 按原图解码。Tex2D/ 里有 8192×8192 的字体图集，'
            '单张解码就是 256 MB 位图。请改用\n'
            '  TextureBudget.decodeWidth(context, box.maxWidth, max: ...)\n'
            '确实需要原图语义时，在调用点附近写 `// $exemptMarker` 并论证上限。\n'
            '违规 ${violations.length} 处：\n  ${violations.join('\n  ')}',
      );
    });

    test('main() 里确实调用了 TextureBudget.apply()', () {
      final f = File('lib/main.dart');
      expect(f.existsSync(), isTrue);
      final src = f.readAsStringSync();
      expect(
        src.contains('TextureBudget.apply()'),
        isTrue,
        reason: '预算必须在任何图片开始解码前设置；删掉这一行等于回退到引擎默认 '
            '1000 条 / 100 MiB。',
      );
      expect(src.contains("import 'core/texture_budget.dart';"), isTrue);
    });

    test('Live2D 那层唯一的无上限缓存已限容', () {
      final f = File('lib/features/resources/live2d_preview_panel.dart');
      expect(f.existsSync(), isTrue);
      final src = f.readAsStringSync();
      expect(
        src.contains('final Map<String, Uint8List> _renderCache = {}'),
        isFalse,
        reason: '裸 Map 没有任何上限——切 20 个表达式就是 20 张数 MB 的位图常驻。'
            '必须换成 BoundedByteLru。',
      );
      expect(src.contains('BoundedByteLru('), isTrue);
    });

    test('解码宽计算只有 TextureBudget 一个来源', () {
      final libDir = Directory('lib');
      final dups = <String>[];
      // 手写「显示宽 × DPR」的旧写法：一律应上收到
      // TextureBudget.decodeWidth / decodeWidthFor。判据很直接——凡是
      // `cacheWidth` 附近还出现 `devicePixelRatio` 的，都是在本地算尺寸
      // （而不是问 TextureBudget 要一个档位）。
      final widthFromDprRe = RegExp(r'devicePixelRatio', caseSensitive: false);
      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final rel = entity.path
            .replaceAll(Platform.pathSeparator, '/')
            .replaceFirst('lib/', '');
        if (rel == 'core/texture_budget.dart') continue;
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final t = lines[i].trimLeft();
          if (t.startsWith('//') || t.startsWith('///')) continue;
          if (!RegExp(r'cacheWidth').hasMatch(lines[i])) continue;
          final window = lines
              .sublist(i, (i + 6).clamp(0, lines.length))
              .join('\n');
          if (widthFromDprRe.hasMatch(window)) {
            dups.add('$rel:${i + 1}');
          }
        }
      }
      expect(dups, isEmpty,
          reason: '解码宽计算散落各处 = 同一张图按多个尺寸各解一份位图。'
              '请改用 TextureBudget.decodeWidth(context, box.maxWidth, max: ...)。'
              '违规：\n  ${dups.join('\n  ')}');
    });

    test('全库不再手写 devicePixelRatio 参与解码尺寸', () {
      final libDir = Directory('lib');
      final offenders = <String>[];
      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final rel = entity.path
            .replaceAll(Platform.pathSeparator, '/')
            .replaceFirst('lib/', '');
        if (rel == 'core/texture_budget.dart') continue;
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final t = lines[i].trimLeft();
          if (t.startsWith('//') || t.startsWith('///')) continue;
          if (RegExp(r'devicepixelratio', caseSensitive: false)
              .hasMatch(lines[i])) {
            offenders.add('$rel:${i + 1}  ${lines[i].trim()}');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'DPR 只应在 core/texture_budget.dart 里读一次。'
              '违规：\n  ${offenders.join('\n  ')}');
    });
  });

  // ---------------- 2. 档位函数边界 ----------------

  group('decodeWidthFor', () {
    test('显示宽未知 → null（保持原图尺寸，交给宿主约束）', () {
      expect(TextureBudget.decodeWidthFor(null, 2), isNull);
      expect(TextureBudget.decodeWidthFor(double.infinity, 2), isNull);
      expect(TextureBudget.decodeWidthFor(0, 2), isNull);
      expect(TextureBudget.decodeWidthFor(-5, 2), isNull);
      expect(TextureBudget.decodeWidthFor(double.nan, 2), isNull);
    });

    test('吸档只向上，绝不下取（下取会让图变小、视觉变糊）', () {
      // 44 头像位：44 × 2 = 88 → 吸到 176 档
      expect(TextureBudget.decodeWidthFor(44, 2), 176);
      // 画廊格 172 × 1 = 172 → 176 档
      expect(TextureBudget.decodeWidthFor(172, 1), 176);
      // 画廊格 172 × 2 = 344 → 352 档
      expect(TextureBudget.decodeWidthFor(172, 2), 352);
      // 恰好落在档位上不动
      expect(TextureBudget.decodeWidthFor(176, 1), 176);
      expect(TextureBudget.decodeWidthFor(512, 2), 1024);
    });

    test('超过最大档时不吸档，原值交给 max 夹', () {
      // 画布 1200 × DPR2 = 2400，最大档 2048 —— 不能下取到 2048，
      // 要原样交给 max 决定（CG 的 4096 上限需要这个原值）。
      expect(TextureBudget.decodeWidthFor(1200, 2, max: 4096), 2400);
      // 同一场景按背景上限会被夹到 2048
      expect(
        TextureBudget.decodeWidthFor(1200, 2,
            max: TextureBudget.kBackgroundMaxDecodeWidth),
        2048,
      );
    });

    test('最大档 / 上限生效', () {
      // 8192 宽的字体图集：不设 cacheWidth 是 256 MB，这里必须被夹住。
      expect(TextureBudget.decodeWidthFor(8192, 1),
          TextureBudget.kMaxDecodeWidth); // 4096
      expect(
        TextureBudget.decodeWidthFor(8192, 1,
            max: TextureBudget.kFullViewMaxDecodeWidth),
        4096,
      );
      expect(
        TextureBudget.decodeWidthFor(8192, 1,
            max: TextureBudget.kLive2dMaxDecodeWidth),
        1536,
      );
      // max 小于最小档时按最小档兜底，不产生 0/负值
      expect(TextureBudget.decodeWidthFor(100, 1, max: 10),
          TextureBudget.kMinDecodeWidth);
    });

    test('factor 参与计算（BoxFit.cover 的 overscan 余量）', () {
      // 吸档会吃掉 factor 的细粒度差异，所以用 snapToTier:false 直接看原始值。
      const bgMax = TextureBudget.kBackgroundMaxDecodeWidth; // 2048
      // 背景此前 factor 2：1000 × 2 × 2 = 4000 → 被上限夹到 2048
      expect(
        TextureBudget.decodeWidthFor(1000, 2,
            factor: 2, max: bgMax, snapToTier: false),
        2048,
      );
      // 降到 1.5：1000 × 2 × 1.5 = 3000 → 仍被夹到 2048
      expect(
        TextureBudget.decodeWidthFor(1000, 2,
            factor: 1.5, max: bgMax, snapToTier: false),
        2048,
      );
      // DPR 1 上 factor 才真正省下来：1000 × 1 × 1.5 = 1500（省 500px / 少 ~2 MB）
      expect(
        TextureBudget.decodeWidthFor(1000, 1,
            factor: 1.5, max: bgMax, snapToTier: false),
        1500,
      );
      expect(
        TextureBudget.decodeWidthFor(1000, 1,
            factor: 2, max: bgMax, snapToTier: false),
        2000,
      );
      // 吸档打开后，上面两个都会被吸到 2048 档 —— 这正是「档位收敛」的代价
      // 与收益：少一个尺寸条目，换多解一点点。
      expect(
        TextureBudget.decodeWidthFor(1000, 1,
            factor: 1.5, max: bgMax),
        2048,
      );
    });

    test('非法 dpr / factor 回落到 1，不产生 NaN 宽度', () {
      expect(TextureBudget.decodeWidthFor(100, 0), 176);
      expect(TextureBudget.decodeWidthFor(100, -3), 176);
      expect(TextureBudget.decodeWidthFor(100, double.nan), 176);
      expect(TextureBudget.decodeWidthFor(100, 2, factor: 0), 352);
      expect(TextureBudget.decodeWidthFor(100, 2, factor: double.infinity), 352);
    });

    test('snapToTier: false 时保留精确值（只受 min/max 夹）', () {
      expect(TextureBudget.decodeWidthFor(90, 1, snapToTier: false), 90);
      expect(TextureBudget.decodeWidthFor(90, 2, snapToTier: false), 180);
      expect(TextureBudget.decodeWidthFor(10, 1, snapToTier: false),
          TextureBudget.kMinDecodeWidth);
    });

    test('snapUpToTier 单调不减', () {
      for (var px = 1; px <= 3000; px += 7) {
        expect(TextureBudget.snapUpToTier(px), greaterThanOrEqualTo(px));
      }
      expect(TextureBudget.snapUpToTier(1), TextureBudget.kDecodeTiers.first);
      expect(TextureBudget.snapUpToTier(4096), 4096); // 超最大档原样返回
    });

    test('A3 不变量：结果只能是档位 / 被 max 夹住的 max / 最大档之上的原值', () {
      // 「档位收敛」的核心保证：同一显示盒 → 同一解码宽 → 同一张图只解一份
      // 位图。所以返回值不许是「档位与档位之间的任意数」。
      //
      // 实现是 `px → 吸档 → 超 max 则夹到 max`，因此非档位结果只有两种合法
      // 来源（它们都不产生「同一盒子多个尺寸」）：
      //   1) 被 max 夹住：r == max。注意 kLive2dMaxDecodeWidth = 1536
      //      **本身不是档位**，所以 max 这一支必须单独放行；
      //   2) 源图实在太大（> 最大档）不吸档：r > lastTier，交给 max 夹
      //      （CG 的 4096 档走这条）。
      const lastTier = 2048;
      expect(TextureBudget.kDecodeTiers.last, lastTier);
      for (var w = 1; w <= 1600; w += 11) {
        for (final dpr in <double>[1, 1.25, 1.5, 2, 3]) {
          for (final factor in <double>[1, 1.5, 2]) {
            for (final max in <int>[
              TextureBudget.kBackgroundMaxDecodeWidth,
              TextureBudget.kLive2dMaxDecodeWidth,
              TextureBudget.kCgMaxDecodeWidth,
            ]) {
              final r = TextureBudget.decodeWidthFor(w.toDouble(), dpr,
                  factor: factor, max: max)!;
              expect(r, greaterThanOrEqualTo(TextureBudget.kMinDecodeWidth));
              expect(r, lessThanOrEqualTo(max));
              expect(
                TextureBudget.kDecodeTiers.contains(r) || r == max || r > lastTier,
                isTrue,
                reason: '解码宽 $r 既不是档位、又不是 max($max)、也不在最大档之上'
                    '（w=$w dpr=$dpr factor=$factor）——'
                    '说明有调用点绕开了档位表，同一张图会按多尺寸各解一份位图。',
              );
            }
          }
        }
      }
    });
  });

  // ---------------- 1. 预算确实被设置 ----------------

  group('ImageCache 预算', () {
    test('apply() 把两条上限都设进引擎', () {
      TestWidgetsFlutterBinding.ensureInitialized();
      final cache = PaintingBinding.instance.imageCache;

      // 先改成别的值，确保 apply() 真的在写（而不是碰巧相等）。
      cache.maximumSizeBytes = 1 << 20;
      cache.maximumSize = 7;

      TextureBudget.apply();

      expect(cache.maximumSizeBytes, TextureBudget.sizeBytes);
      expect(cache.maximumSize, TextureBudget.entryLimit);
      // 引擎默认是 1000 条 / 100 MiB；本方案的桌面预算是 48 MiB。
      expect(TextureBudget.sizeBytes, lessThan(100 << 20));
      expect(TextureBudget.entryLimit, lessThan(1000));
    });

    test('releaseScene() 可调用且不抛（清缓存表，不动存活位图）', () {
      TestWidgetsFlutterBinding.ensureInitialized();
      expect(TextureBudget.releaseScene, returnsNormally);
      expect(() => TextureBudget.releaseScene(), returnsNormally);
    });

    test('evictBytes() 对空/含 null 的输入是安全的', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await expectLater(TextureBudget.evictBytes(const <Uint8List?>[]),
          completes);
      await expectLater(
          TextureBudget.evictBytes(<Uint8List?>[null, null]), completes);
      await expectLater(
        TextureBudget.evictBytes(<Uint8List?>[Uint8List.fromList(<int>[1, 2, 3])]),
        completes,
      );
    });
  });

  // ---------------- 3. 有界字节 LRU ----------------

  group('BoundedByteLru', () {
    Uint8List payload(int n) => Uint8List.fromList(List<int>.filled(n, 7));

    test('按条数上限淘汰，并交出被淘汰的载荷', () {
      final lru = BoundedByteLru(maxEntries: 3, maxBytes: 1 << 20);
      expect(lru.put('a', payload(10)), isEmpty);
      expect(lru.put('b', payload(10)), isEmpty);
      expect(lru.put('c', payload(10)), isEmpty);
      expect(lru.length, 3);

      final dropped = lru.put('d', payload(10));
      expect(lru.length, 3);
      expect(dropped, hasLength(1), reason: '被淘汰的载荷必须交回来——调用方要拿它'
          '去引擎 ImageCache 里赶走对应的解码位图');
      expect(lru.containsKey('a'), isFalse, reason: '最旧的先出');
      expect(lru.containsKey('d'), isTrue);
    });

    test('按总字节上限淘汰', () {
      final lru = BoundedByteLru(maxEntries: 100, maxBytes: 100);
      lru.put('a', payload(40));
      lru.put('b', payload(40));
      expect(lru.bytes, 80);
      final dropped = lru.put('c', payload(40));
      expect(lru.bytes, lessThanOrEqualTo(100));
      expect(dropped, isNotEmpty);
      expect(lru.containsKey('c'), isTrue, reason: '刚写入的不该被自己挤掉');
    });

    test('命中即续命（LRU 序）', () {
      final lru = BoundedByteLru(maxEntries: 2, maxBytes: 1 << 20);
      lru.put('a', payload(1));
      lru.put('b', payload(1));
      expect(lru['a'], isNotNull); // 触碰 a → a 变成最新
      lru.put('c', payload(1)); // 应淘汰 b 而不是 a
      expect(lru.containsKey('a'), isTrue);
      expect(lru.containsKey('b'), isFalse);
    });

    test('同键覆写不重复计数', () {
      final lru = BoundedByteLru(maxEntries: 10, maxBytes: 1 << 20);
      lru.put('a', payload(100));
      lru.put('a', payload(30));
      expect(lru.length, 1);
      expect(lru.bytes, 30);
    });

    test('clear() 交出全部载荷并清零', () {
      final lru = BoundedByteLru(maxEntries: 10, maxBytes: 1 << 20);
      lru.put('a', payload(10));
      lru.put('b', payload(20));
      final all = lru.clear();
      expect(all, hasLength(2));
      expect(lru.length, 0);
      expect(lru.bytes, 0);
    });

    test('上限为 1 也不会死循环', () {
      final lru = BoundedByteLru(maxEntries: 1, maxBytes: 4);
      lru.put('a', payload(10));
      lru.put('b', payload(10));
      expect(lru.length, 1);
      expect(lru.containsKey('b'), isTrue);
    });
  });
}
