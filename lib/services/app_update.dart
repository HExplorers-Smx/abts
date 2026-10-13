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
  /// 官方 API 失败时自动走加速镜像重试（国内网络兜底）。
  static Future<UpdateResult> check() async {
    if (!configured) {
      return const UpdateResult(configured: false);
    }
    final endpoints = <String>[
      _apiUrl,
      for (final m in _downloadMirrors) '$m$_apiUrl',
    ];
    for (final endpoint in endpoints) {
      try {
        final resp = await Dio(
          BaseOptions(connectTimeout: const Duration(seconds: 12)),
        ).get(
          endpoint,
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
      } catch (_) {
        // 该端点失败，继续尝试下一个（官方 → 镜像）
      }
    }
    return UpdateResult(configured: true, error: '检查更新失败，请稍后重试');
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
  /// 国内直连 GitHub 下载很慢，内置多个加速镜像按顺序尝试，
  /// 全部失败后回退官方地址再试一次；[onProgress] 上报进度，
  /// [cancelToken] 可取消；成功后返回落盘路径，失败抛出异常。
  ///
  /// 镜像格式：`<镜像根>/<原始URL>`，仅对 GitHub 官方域名做代理。
  static const List<String> _downloadMirrors = [
    'https://ghproxy.net/',
    'https://ghfast.top/',
    'https://gh-proxy.com/',
  ];

  /// 检查本地是否已下载完整 APK（文件存在且非空即视为已下载）。
  /// 返回路径或 null，供「检查更新」时避免重复下载。
  static Future<String?> downloadedApk(String version) async {
    final p = await apkSavePath(version);
    final f = File(p);
    if (f.existsSync() && f.lengthSync() > 0) return p;
    return null;
  }

  static Future<String> downloadApk({
    required String url,
    required String savePath,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final existing = File(savePath);
    if (existing.existsSync() && existing.lengthSync() > 0) {
      // 上次已下载完整，直接复用，避免重复下载浪费流量
      return savePath;
    }
    final candidates = <String>[
      for (final m in _downloadMirrors) '$m$url',
      url, // 兜底：镜像全部失败后回退官方直连
    ];
    Object? lastErr;
    for (final target in candidates) {
      try {
        if (existing.existsSync()) {
          // 上次未下完的半成品先清掉，避免拼坏文件
          await existing.delete();
        }
        await Dio(BaseOptions(connectTimeout: const Duration(seconds: 12)))
            .download(
          target,
          savePath,
          cancelToken: cancelToken,
          options: Options(
            headers: {'User-Agent': BiliEndpoints.userAgent},
            followRedirects: true,
          ),
          onReceiveProgress: onProgress == null
              ? null
              : (received, total) =>
                  onProgress(received, total < 0 ? 0 : total),
        );
        return savePath;
      } catch (e) {
        lastErr = e;
        // 下载失败清掉残留半成品，避免下次误判为已下载
        try {
          if (existing.existsSync()) await existing.delete();
        } catch (_) {}
      }
    }
    throw lastErr!;
  }
}