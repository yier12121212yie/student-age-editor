// 「从源码启动」纯逻辑单测：源码后端探测与搜索根推导（backend_launcher.dart）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/core/backend_launcher.dart';

void main() {
  group('resolveSourceBackend', () {
    String? find(List<String> roots, Set<String> files,
            {String sep = '/', String exe = 'backend'}) =>
        BackendLauncher.resolveSourceBackend(
            roots: roots, fileExists: files.contains, separator: sep, exeName: exe);

    test('命中仓库根布局 native/build/bin/backend', () {
      expect(
        find(['/repo'], {'/repo/native/build/bin/backend'}),
        '/repo/native/build/bin/backend',
      );
    });

    test('命中备用布局 build-native/bin/backend', () {
      expect(
        find(['/repo'], {'/repo/build-native/bin/backend'}),
        '/repo/build-native/bin/backend',
      );
    });

    test('Windows 反斜杠分隔与 .exe 后缀', () {
      expect(
        find([r'D:\repo'], {r'D:\repo\native\build\bin\backend.exe'},
            sep: r'\', exe: 'backend.exe'),
        r'D:\repo\native\build\bin\backend.exe',
      );
    });

    test('找不到返回 null', () {
      expect(find(['/repo', '/other'], {}), isNull);
    });

    test('按搜索根顺序取第一个命中（native/build 优先于同根 build-native）', () {
      final files = {
        '/repo/build-native/bin/backend',
        '/repo/native/build/bin/backend',
      };
      expect(find(['/repo'], files), '/repo/native/build/bin/backend');
    });
  });

  group('sourceSearchRoots', () {
    test('从 cwd 与 exeDir 分别向上走，去重保序', () {
      final roots = BackendLauncher.sourceSearchRoots(
        cwd: '/repo/frontend',
        exeDir: '/repo/frontend/build/windows/x64/runner/Debug',
        separator: '/',
      );
      // 首个种子原样在列，且向上能到仓库根
      expect(roots.first, '/repo/frontend');
      expect(roots, contains('/repo'));
      expect(roots.length, roots.toSet().length, reason: '共享前缀应去重');
      // exeDir 自身也在列
      expect(roots, contains('/repo/frontend/build/windows/x64/runner/Debug'));
    });

    test('向上不超过 maxUp 级', () {
      final roots = BackendLauncher.sourceSearchRoots(
        cwd: '/a/b/c/d/e',
        exeDir: '/a/b/c/d/e',
        separator: '/',
        maxUp: 2,
      );
      expect(roots, ['/a/b/c/d/e', '/a/b/c/d', '/a/b/c']);
    });

    test('Windows 盘根正确终止', () {
      final roots = BackendLauncher.sourceSearchRoots(
        cwd: r'D:\repo\frontend',
        exeDir: r'D:\repo\frontend',
        separator: r'\',
        maxUp: 10,
      );
      expect(roots, contains(r'D:\repo'));
      expect(roots, contains(r'D:\'));
      expect(roots.last, r'D:\');
    });

    test('POSIX 根目录正确终止', () {
      final roots = BackendLauncher.sourceSearchRoots(
        cwd: '/x',
        exeDir: '/x',
        separator: '/',
        maxUp: 10,
      );
      expect(roots, ['/x', '/']);
    });
  });

  group('真实仓库探测', () {
    test('flutter test（debug、cwd=frontend）下能发现源码构建的 backend', () {
      final path = BackendLauncher.instance.sourceBackendPath();
      // CI 上 native 未构建时不算失败;本地构建过则必须命中。
      if (path == null) {
        markTestSkipped('native 后端未构建（native/build/bin 无产物）');
        return;
      }
      expect(File(path).existsSync(), isTrue);
      final normalized = path.replaceAll(r'\', '/');
      expect(
        normalized.contains('native/build/bin/backend') ||
            normalized.contains('build-native/bin/backend'),
        isTrue,
        reason: '探测结果应落在仓库源码构建目录: $path',
      );
    });
  });
}
