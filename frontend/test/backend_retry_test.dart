// 后端断线自愈包装的纯逻辑单测：连接级失败识别 + 重试/重抛语义。
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:student_age_editor/core/backend_retry.dart';

void main() {
  group('isBackendConnectionError', () {
    test('http.ClientException（桌面 SocketException / Web 传输失败）算连接级', () {
      expect(isBackendConnectionError(http.ClientException('boom')), isTrue);
    });

    test('字符串形态的 SocketException / refused 算连接级', () {
      expect(
        isBackendConnectionError(Exception('SocketException: refused')),
        isTrue,
      );
      expect(isBackendConnectionError(Exception('Connection refused')), isTrue);
    });

    test('业务错误（4xx/5xx 普通异常）不算连接级', () {
      expect(
        isBackendConnectionError(Exception('HTTP 400: bad request')),
        isFalse,
      );
      expect(isBackendConnectionError(StateError('x')), isFalse);
    });
  });

  group('withBackendRetry', () {
    test('首次连接失败 → 调 ensureBackend 后重试成功', () async {
      var calls = 0;
      var ensured = 0;
      final out = await withBackendRetry(
        () async {
          calls++;
          if (calls == 1) throw http.ClientException('connection refused');
          return 'ok';
        },
        ensureBackend: () async {
          ensured++;
          return true;
        },
      );
      expect(out, 'ok');
      expect(calls, 2);
      expect(ensured, 1);
    });

    test('业务错误不重试、原样抛出', () async {
      var calls = 0;
      var ensured = 0;
      await expectLater(
        withBackendRetry(
          () async {
            calls++;
            throw Exception('HTTP 400: bad request');
          },
          ensureBackend: () async {
            ensured++;
            return true;
          },
        ),
        throwsA(isA<Exception>()),
      );
      expect(calls, 1);
      expect(ensured, 0);
    });

    test('持续连接失败：用完 attempts 后抛出最后一次错误', () async {
      var calls = 0;
      var ensured = 0;
      await expectLater(
        withBackendRetry(
          () async {
            calls++;
            throw http.ClientException('still down');
          },
          ensureBackend: () async {
            ensured++;
            return false;
          },
        ),
        throwsA(isA<http.ClientException>()),
      );
      expect(calls, 2);
      expect(ensured, 1); // 仅最后一次之前恢复一次
    });
  });
}
