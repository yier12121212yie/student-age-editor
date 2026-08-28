// 图片生成配置（openai-image-api）与 AiSettings 序列化测试。
import 'package:flutter_test/flutter_test.dart';
import 'package:student_age_editor/features/settings/settings_page.dart';

void main() {
  test('图片配置留空时自动复用对话配置（fallback）', () {
    final s = AiSettings(
      provider: 'openai_compatible',
      baseUrl: 'https://gateway.example.com/v1',
      apiKey: 'chat-key',
      model: 'gpt-4o',
    );
    expect(s.effectiveImageApiKey, 'chat-key');
    expect(s.effectiveImageBaseUrl, 'https://gateway.example.com/v1');
    expect(s.effectiveImageModel, 'gpt-4o');
  });

  test('图片配置优先于对话配置', () {
    final s = AiSettings(
      baseUrl: 'https://gateway.example.com/v1',
      apiKey: 'chat-key',
      model: 'gpt-4o',
      imageModel: 'gpt-image-1',
      imageApiKey: 'img-key',
      imageBaseUrl: 'https://api.openai.com/v1',
    );
    expect(s.effectiveImageApiKey, 'img-key');
    expect(s.effectiveImageBaseUrl, 'https://api.openai.com/v1');
    expect(s.effectiveImageModel, 'gpt-image-1');
  });

  test('全部留空时使用官方默认图片服务', () {
    final s = AiSettings();
    expect(s.effectiveImageApiKey, '');
    expect(s.effectiveImageBaseUrl, 'https://api.openai.com/v1');
    expect(s.effectiveImageModel, 'gpt-image-2');
  });

  test('新旧设置 JSON 往返兼容（缺失图片字段不报错）', () {
    // 旧版持久化数据没有 image* 字段
    final old = AiSettings.fromJson({
      'provider': 'openai_compatible',
      'baseUrl': 'https://x/v1',
      'apiKey': 'k',
      'model': 'm',
      'temperature': 0.3,
    });
    expect(old.imageModel, '');
    expect(old.imageApiKey, '');
    expect(old.imageBaseUrl, '');
    expect(old.effectiveImageApiKey, 'k');

    // 新版完整往返
    final s = AiSettings(
      imageModel: 'dall-e-3',
      imageApiKey: 'ik',
      imageBaseUrl: 'https://y/v1',
    );
    final restored = AiSettings.fromJson(s.toJson());
    expect(restored.imageModel, 'dall-e-3');
    expect(restored.imageApiKey, 'ik');
    expect(restored.imageBaseUrl, 'https://y/v1');
  });
}
