import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../core/app_meta.dart';
import '../core/network/api_config.dart';

/// 检查更新：数据源走 GitHub Releases
///
/// 发布后把下面两个常量改成你的仓库即可，例如：
/// ```dart
/// static const githubOwner = 'your-name';
/// static const githubRepo = 'abts';
/// ```
class UpdateResult {
  const UpdateResult({
    required this.configured,
    this.error,
    this.latestVersion,
    this.latestName,
    this.changelog,
    this.htmlUrl,
    this.apkUrl,
  });

  /// 是否已配置 GitHub 仓库（未配置时不会发起请求）
  final bool configured;
  final String? error;
  final String? latestVersion;
  final String? latestName;
  final String? changelog;
  final String? htmlUrl;
  final String? apkUrl;

  bool get hasNewer {
    if (!configured) return false;
    final v = latestVersion;
    if (v == null) return false;
    return _compareVersion(AppMeta.version, v) < 0;
  }
}

/// GitHub 语义化版本比较：等价返回 0，a 大返回 1，a 小返回 -1
int _compareVersion(String a, String b) {
  int toInt(String s) => int.tryParse(s.replaceAll(RegExp(r'\D'), '')) ?? 0;
  final pa = a.split('.');
  final pb = b.split('.');
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? toInt(pa[i]) : 0;
    final y = i < pb.length ? toInt(pb[i]) : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

class AppUpdate {
  AppUpdate._();

  /// GitHub 仓库（检查更新数据源）
  static const String githubOwner = 'HExplorers-Smx';
  static const String githubRepo = 'abts';

  static bool get configured => githubOwner.isNotEmpty && githubRepo.isNotEmpty;

  static String get _apiUrl =>
      'https://api.github.com/repos/$githubOwner/$githubRepo/releases/latest';

  static String get _downloadBase =>
      'https://github.com/$githubOwner/$githubRepo/releases/latest';

  /// 检查最新版本。
  ///
  /// 未配置仓库时直接返回 [configured=false]，不发起网络请求。
  static Future<UpdateResult> check() async {
    if (!configured) {
      return const UpdateResult(configured: false);
    }
    try {
      final resp = await Dio().get(
        _apiUrl,
        options: Options(
          headers: {'Accept': 'application/vnd.github+json'},
          responseType: ResponseType.json,
        ),
      );
      final data = resp.data as Map? ?? {};
      String? apkUrl;
      final assets = data['assets'] as List? ?? const [];
      for (final a in assets) {
        final m = a as Map?;
        final name = '${m?['name'] ?? ''}';
        if (name.endsWith('.apk')) {
          apkUrl = '${m?['browser_download_url'] ?? ''}';
          break;
        }
      }
      final tag = '${data['tag_name'] ?? ''}';
      return UpdateResult(
        configured: true,
        latestVersion: tag.isEmpty ? null : tag.replaceFirst(RegExp(r'^v'), ''),
        latestName: '${data['name'] ?? ''}',
        changelog: '${data['body'] ?? ''}'.trim(),
        htmlUrl: '${data['html_url'] ?? _downloadBase}',
        apkUrl: apkUrl?.isEmpty == true ? null : apkUrl,
      );
    } catch (e) {
      return UpdateResult(configured: true, error: '检查更新失败，请稍后重试');
    }
  }

  /// 本次版本 APK 的本地保存路径（应用文档目录/updates 下）。
  /// 文件名含版本号，重复下载会覆盖旧文件。
  static Future<String> apkSavePath(String version) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/updates');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final safe = version.replaceAll(RegExp(r'[^\w.-]'), '_');
    return '${dir.path}/abts-$safe.apk';
  }

  /// 下载 APK 到本地（GitHub Releases 资产，带 302 跳转，需跟随）。
  ///
  /// [onProgress] 上报 (receivedBytes, totalBytes)，[cancelToken] 可取消；
  /// 成功后返回落盘路径，失败抛出异常。
  static Future<String> downloadApk({
    required String url,
    required String savePath,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final file = File(savePath);
    if (file.existsSync()) {
      // 上次未下完的半成品先清掉，避免拼坏文件
      await file.delete();
    }
    await Dio().download(
      url,
      savePath,
      cancelToken: cancelToken,
      options: Options(
        headers: {'User-Agent': BiliEndpoints.userAgent},
        followRedirects: true,
      ),
      onReceiveProgress: onProgress == null
          ? null
          : (received, total) => onProgress(received, total < 0 ? 0 : total),
    );
    return savePath;
  }
}