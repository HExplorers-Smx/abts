import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/lyric_line.dart';

/// 百度智能云「音频文件转写」（录音文件识别/长音频）。
///
/// 官方接口（文档：百度智能云 SPEECH - 音频文件转写API）：
/// - 获取 token：GET  https://aip.baidubce.com/oauth/2.0/token
/// - 创建任务：  POST https://aip.baidubce.com/rpc/2.0/aasr/v1/create
///   body 支持 speech_data（本地音频 base64 直传），无需公网 URL
/// - 查询结果：  POST https://aip.baidubce.com/rpc/2.0/aasr/v1/query
///
/// 密钥由用户在「设置 → 语音转写（百度）」自行填写保存，不内置。
class BaiduAsr {
  BaiduAsr._();

  static const _tokenUrl = 'https://aip.baidubce.com/oauth/2.0/token';
  static const _createUrl = 'https://aip.baidubce.com/rpc/2.0/aasr/v1/create';
  static const _queryUrl = 'https://aip.baidubce.com/rpc/2.0/aasr/v1/query';

  static const _prefsAppId = 'baidu_asr_appid';

  /// 最近一次转写失败原因（供 UI 展示，替代静默失败）
  static String? lastError;
  static const _prefsApiKey = 'baidu_asr_api_key';
  static const _prefsSecretKey = 'baidu_asr_secret_key';
  static const _prefsEnabled = 'baidu_asr_enabled';
  static const _prefsLang = 'baidu_asr_lang';

  // ---------- 配置 ----------

  static Future<BaiduAsrConfig> loadConfig() async {
    final p = await SharedPreferences.getInstance();
    return BaiduAsrConfig(
      appId: p.getString(_prefsAppId) ?? '',
      apiKey: p.getString(_prefsApiKey) ?? '',
      secretKey: p.getString(_prefsSecretKey) ?? '',
      enabled: p.getBool(_prefsEnabled) ?? false,
      lang: p.getString(_prefsLang) ?? 'zh',
    );
  }

  static Future<void> saveConfig(
      {required String appId,
      required String apiKey,
      required String secretKey,
      required bool enabled,
      String lang = 'zh'}) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefsAppId, appId.trim());
    await p.setString(_prefsApiKey, apiKey.trim());
    await p.setString(_prefsSecretKey, secretKey.trim());
    await p.setBool(_prefsEnabled, enabled);
    await p.setString(_prefsLang, lang == 'en' ? 'en' : 'zh');
  }

  static Future<void> clearConfig() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_prefsAppId);
    await p.remove(_prefsApiKey);
    await p.remove(_prefsSecretKey);
    await p.setBool(_prefsEnabled, false);
  }

  // ---------- 转写 ----------

  static Future<String?> _accessToken(
      String apiKey, String secretKey) async {
    final r = await Dio(BaseOptions(connectTimeout: const Duration(seconds: 12)))
        .get(
      _tokenUrl,
      queryParameters: {
        'grant_type': 'client_credentials',
        'client_id': apiKey,
        'client_secret': secretKey,
      },
    );
    final t = ((r.data as Map?)?['access_token'] as String?)?.trim();
    if (t == null || t.isEmpty) return null;
    return t;
  }

  /// 转写本地音频 → 带时间轴的歌词行列表。
  ///
  /// [onStage] 上报阶段进度（提交任务 / 识别中…），供 UI 提示；
  /// 任一环节失败返回 null（不抛异常，由调用方决定提示）。
  static Future<List<LyricLine>?> transcribe(
    File audio, {
    required String apiKey,
    required String secretKey,
    void Function(String stage)? onStage,
    int timeoutSeconds = 900,
  }) async {
    try {
      final token = await _accessToken(apiKey, secretKey);
      if (token == null) {
        lastError = '授权失败：请检查 API Key / Secret Key 是否与控制台一致（32 位）';
        return null;
      }
      onStage?.call('正在获取识别授权…');
      final bytes = await audio.readAsBytes();
      if (bytes.isEmpty) return null;
      final b64 = base64Encode(bytes);
      final ext = audio.path.split('.').last.toLowerCase();
      final format = switch (ext) {
        'wav' => 'wav',
        'm4a' => 'm4a',
        'aac' => 'aac',
        'ogg' => 'ogg',
        'flac' => 'flac',
        _ => 'mp3',
      };
      final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 15)));

      onStage?.call('正在提交转写任务…');
      final lang = (await loadConfig()).lang;
      final pid = lang == 'en' ? 1737 : 80006; // 中文音视频字幕模型(词级) / 英文模型
      final create = await dio.post(
        '$_createUrl?access_token=$token',
        data: {
          'speech_data': b64,
          'format': format,
          'sample_rate': 16000,
          'pid': pid,
          'role_num': 1,
          // 词级时间戳开关（部分账号/模型支持；多余字段如被忽略不影响主流程）
          'enable_word_time': true,
          'enable_words': true,
        },
      );
      final cd = create.data as Map? ?? {};
      if ((cd['error_code'] as num?)?.toInt() != 0) {
        lastError = '提交失败：${cd['error_code']} ${cd['error_msg']}';
        debugPrint('[BaiduAsr] create 失败: ${cd['error_msg']}');
        return null;
      }
      final taskId = (((cd['result'] as Map?)?['task_id']) ??
              ((cd['result'] as Map?)?['session_id']))
          as String?;
      if (taskId == null || taskId.isEmpty) return null;

      // 轮询识别结果（异步任务，通常几十秒到几分钟）
      final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds));
      var waited = 0;
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 5));
        waited += 5;
        onStage?.call('正在识别…（${waited}s）');
        final q = await dio.post(
          '$_queryUrl?access_token=$token',
          data: {'task_ids': [taskId]},
        );
        final info = ((q.data as Map?)?['tasks_info'] as List?)
            ?.firstOrNull as Map?;
        final status = '${info?['task_status'] ?? ''}';
        if (status == 'success') {
          final lines = _linesFromResult(
              (info?['task_result'] as Map?)?['detailed_result'] as List?,
              (info?['task_result'] as Map?)?['result'] as String?,
              ((info?['task_result'] as Map?)?['audio_duration'] as num?)
                  ?.toDouble());
          return lines == null || lines.isEmpty ? null : lines;
        }
        if (status == 'error' || status == 'failed' || status == 'cancel') {
          lastError = '识别失败：$status'
              '（${info?['error_code'] ?? ''} ${info?['error_msg'] ?? ''}）';
          debugPrint('[BaiduAsr] 任务失败: $status');
          return null;
        }
      }
      debugPrint('[BaiduAsr] 转写超时');
      lastError = '识别超时（${timeoutSeconds}s）';
      return null;
    } catch (e) {
      debugPrint('[BaiduAsr] 转写异常: $e');
      lastError = '转写异常：$e';
      return null;
    }
  }

  /// 识别结果 → 歌词行。优先用带时间轴的分段结果；没有分段时退化为
  /// 整段文本 + 音频总时长（歌词视图仍可逐字扫字）。
  static List<LyricLine>? _linesFromResult(
      List? detailed, String? whole, double? audioDurationMs) {
    final lines = <LyricLine>[];
    for (final seg in detailed ?? const []) {
      final s = seg as Map?;
      final begin = ((s?['begin_time'] as num?)?.toDouble() ?? 0) / 1000;
      final end = ((s?['end_time'] as num?)?.toDouble() ?? 0) / 1000;
      final res = s?['res'];
      final text = res is List ? res.map((e) => '$e').join('') : '${res ?? ''}';
      if (text.trim().isEmpty) continue;

      // 词级时间戳：words_info 每项 {word, start_time, end_time}(毫秒)
      // 识别结果按字切分时即为字级，随文本顺序排列。
      List<LyricWord>? words;
      final wi = s?['words_info'] as List?;
      if (wi != null && wi.isNotEmpty) {
        final parsed = <LyricWord>[];
        for (final w in wi) {
          final m = w as Map?;
          final wd = '${m?['word'] ?? ''}';
          if (wd.trim().isEmpty) continue;
          parsed.add(LyricWord(
            word: wd,
            start: ((m?['start_time'] as num?)?.toDouble() ?? 0) / 1000,
            end: ((m?['end_time'] as num?)?.toDouble() ?? 0) / 1000,
          ));
        }
        // 词文本拼接与句子文本一致时才采用，否则丢弃避免错位
        final joined = parsed.map((e) => e.word).join();
        if (joined.replaceAll(' ', '') == text.replaceAll(' ', '') &&
            parsed.isNotEmpty) {
          words = parsed;
        }
      }

      lines.add(LyricLine(
        start: begin,
        end: end > begin ? end : begin + 1,
        text: text.trim(),
        words: words,
      ));
    }
    if (lines.isEmpty && whole != null && whole.trim().isNotEmpty) {
      final totalSec = (audioDurationMs ?? 0) / 1000;
      lines.add(LyricLine(
        start: 0,
        end: totalSec > 1 ? totalSec : 60,
        text: whole.trim(),
      ));
    }
    return lines;
  }
}

/// 百度语音转写配置（设置页读写）
class BaiduAsrConfig {
  final String appId;
  final String apiKey;
  final String secretKey;
  final bool enabled;

  /// 转写语言：'zh' = 中文音视频字幕模型（词级时间戳）；'en' = 英文模型
  final String lang;

  const BaiduAsrConfig({
    required this.appId,
    required this.apiKey,
    required this.secretKey,
    required this.enabled,
    this.lang = 'zh',
  });

  bool get isConfigured =>
      appId.isNotEmpty && apiKey.isNotEmpty && secretKey.isNotEmpty;
}
