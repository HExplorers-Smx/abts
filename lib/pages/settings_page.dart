import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../player/book_player.dart';
import '../services/download_manager.dart';

import '../core/theme/app_theme.dart';
import '../services/auth_store.dart';
import '../services/baidu_asr.dart';
import '../services/device_service.dart';
import 'login_page.dart';

/// 设置（独立页面）：账号信息 + 播放与后台。未登录也可进入
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _loading = true;
  bool _ignoring = false;

  // 百度语音转写配置（内存副本，保存时写回 SharedPreferences）
  String _asrAppId = '';
  String _asrApiKey = '';
  String _asrSecretKey = '';
  bool _asrEnabled = false;

  bool get _asrConfigured =>
      _asrAppId.isNotEmpty && _asrApiKey.isNotEmpty && _asrSecretKey.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _refresh();
    _refreshAsr();
  }

  Future<void> _refresh() async {
    final v = await DeviceService.instance.isIgnoringBatteryOptimizations();
    if (!mounted) return;
    setState(() {
      _ignoring = v;
      _loading = false;
    });
  }

  Future<void> _toggle(bool value) async {
    if (value) {
      await DeviceService.instance.requestIgnoreBatteryOptimization();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_ignoring
              ? '已开启后台留存保护'
              : '请在系统弹窗中允许「不受限制」'),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('如需关闭，请在系统电池设置中恢复限制')),
      );
    }
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('退出登录',
            style: TextStyle(color: AppTheme.textMain, fontSize: 17)),
        content: Text(
          '退出后需要重新扫码登录，书架与收听进度仍保留在本机。',
          style: TextStyle(color: AppTheme.textSub, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: AppTheme.textSub)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('退出', style: TextStyle(color: AppTheme.accent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await LoginStore.instance.markLoggedOut();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已退出登录')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<LoginStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('系统设置')),
      body: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 32),
        children: [
          _buildAccountCard(auth),
          const SizedBox(height: 12),
          _sectionTitle('播放与后台'),
          SwitchListTile(
            value: _ignoring,
            onChanged: _loading ? null : _toggle,
            activeThumbColor: AppTheme.accent,
            secondary:
                Icon(Icons.battery_saver_rounded, color: AppTheme.accent),
            title: Text(
              '后台留存保护',
              style: TextStyle(fontSize: 14, color: AppTheme.textMain),
            ),
            subtitle: Text(
              _loading
                  ? '检测中…'
                  : _ignoring
                      ? '已豁免电池优化，退到后台更不易被系统清理'
                      : '未开启，长时间后台播放可能被系统中断',
              style: TextStyle(fontSize: 12, color: AppTheme.textSub),
            ),
          ),
          ListTile(
            leading: Icon(Icons.volume_up_rounded, color: AppTheme.accent),
            title: Text(
              '音量增强',
              style: TextStyle(fontSize: 14, color: AppTheme.textMain),
            ),
            subtitle: Text(
              '当前 ${BookPlayer.instance.volumeBoostPercent}%'
              '（超过 100% 需音频后端支持）',
              style: TextStyle(fontSize: 12, color: AppTheme.textSub),
            ),
            trailing: DropdownButton<int>(
              value: BookPlayer.instance.volumeBoostPercent,
              underline: const SizedBox.shrink(),
              dropdownColor: AppTheme.surface,
              items: const [
                DropdownMenuItem(value: 100, child: Text('100%')),
                DropdownMenuItem(value: 125, child: Text('125%')),
                DropdownMenuItem(value: 150, child: Text('150%')),
              ],
              onChanged: (v) {
                if (v != null) {
                  BookPlayer.instance.setVolumeBoost(v);
                  setState(() {});
                }
              },
            ),
          ),
          _sectionTitle('下载与存储'),
          Consumer<DownloadManager>(
            builder: (context, mgr, _) => SwitchListTile(
              value: mgr.wifiOnly,
              onChanged: (v) => mgr.setWifiOnly(v),
              activeThumbColor: AppTheme.accent,
              secondary: Icon(Icons.wifi_rounded, color: AppTheme.accent),
              title: Text(
                '仅 Wi-Fi 下载',
                style: TextStyle(fontSize: 14, color: AppTheme.textMain),
              ),
              subtitle: Text(
                mgr.wifiOnly
                    ? '开启后仅在 Wi-Fi 下开始/继续下载，避免消耗流量；'
                        '非 Wi-Fi 的任务会自动排队，连上 Wi-Fi 后继续'
                    : '关闭后可在移动网络下直接下载（注意流量）',
                style: TextStyle(fontSize: 12, color: AppTheme.textSub),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.divider),
              ),
              child: Text(
                '播放时应用会以前台服务常驻（通知栏可见），熄屏/锁屏也能继续听。'
                '开启「后台留存保护」可进一步降低被清理的概率。\n\n'
                '若仍被中断，建议在系统设置中为本应用打开「自启动」并设置「无限制」后台策略。',
                style: TextStyle(
                    fontSize: 12, color: AppTheme.textSub, height: 1.6),
              ),
            ),
          ),
          _sectionTitle('语音转写（百度）'),
          ListTile(
            leading: Icon(Icons.translate_rounded, color: AppTheme.accent),
            title: Text(
              '百度语音转写',
              style: TextStyle(fontSize: 14, color: AppTheme.textMain),
            ),
            subtitle: Text(
              _asrConfigured
                  ? '已配置${_asrEnabled ? '，导入音频后自动转写文稿' : '，自动转写已关闭'}'
                  : '未配置 · 点此填写 AppID / API Key / Secret Key',
              style: TextStyle(fontSize: 12, color: AppTheme.textSub),
            ),
            trailing: Icon(Icons.chevron_right_rounded,
                color: AppTheme.textHint, size: 20),
            onTap: _editAsrConfig,
          ),
          SwitchListTile(
            value: _asrEnabled,
            onChanged: _asrConfigured
                ? (v) async {
                    await BaiduAsr.saveConfig(
                      appId: _asrAppId,
                      apiKey: _asrApiKey,
                      secretKey: _asrSecretKey,
                      enabled: v,
                    );
                    _refreshAsr();
                  }
                : null,
            activeThumbColor: AppTheme.accent,
            secondary:
                Icon(Icons.auto_awesome_rounded, color: AppTheme.accent),
            title: Text(
              '导入音频后自动转写文稿',
              style: TextStyle(fontSize: 14, color: AppTheme.textMain),
            ),
            subtitle: Text(
              '开启后，导入的本地音频没有匹配到歌词时会自动调用百度'
              '转写生成文稿（消耗免费额度/余额）',
              style: TextStyle(fontSize: 12, color: AppTheme.textSub),
            ),
          ),
        ],
      ),
    );
  }

  /// 编辑百度语音转写配置
  Future<void> _editAsrConfig() async {
    final appId = TextEditingController(text: _asrAppId);
    final apiKey = TextEditingController(text: _asrApiKey);
    final secretKey = TextEditingController(text: _asrSecretKey);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('百度语音转写',
            style: TextStyle(color: AppTheme.textMain, fontSize: 17)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: appId,
                keyboardType: TextInputType.number,
                decoration: _asrInputDeco('AppID'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: apiKey,
                decoration: _asrInputDeco('API Key'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: secretKey,
                decoration: _asrInputDeco('Secret Key'),
                obscureText: true,
              ),
              const SizedBox(height: 10),
              Text(
                '凭证只保存在本机，用于调用百度「录音文件识别」服务。'
                '获取方式：百度智能云控制台 → 语音技术 → 创建应用。',
                style: TextStyle(
                    fontSize: 11, color: AppTheme.textHint, height: 1.5),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await BaiduAsr.clearConfig();
              if (ctx.mounted) Navigator.of(ctx).pop('cleared');
            },
            child: Text('清除',
                style: TextStyle(color: AppTheme.error)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消', style: TextStyle(color: AppTheme.textSub)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('save'),
            child: Text('保存', style: TextStyle(color: AppTheme.accent)),
          ),
        ],
      ),
    );
    if (result == 'save') {
      await BaiduAsr.saveConfig(
        appId: appId.text,
        apiKey: apiKey.text,
        secretKey: secretKey.text,
        enabled: _asrEnabled,
      );
      _refreshAsr();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已保存，可在播放页体验文稿转写')),
        );
      }
    } else if (result == 'cleared') {
      _refreshAsr();
    }
  }

  InputDecoration _asrInputDeco(String label) => InputDecoration(
        labelText: label,
        labelStyle: TextStyle(fontSize: 13, color: AppTheme.textSub),
        hintStyle: TextStyle(fontSize: 13, color: AppTheme.textHint),
        filled: true,
        fillColor: AppTheme.surfaceHigh,
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppTheme.divider),
        ),
      );

  void _refreshAsr() {
    BaiduAsr.loadConfig().then((c) {
      if (!mounted) return;
      setState(() {
        _asrAppId = c.appId;
        _asrApiKey = c.apiKey;
        _asrSecretKey = c.secretKey;
        _asrEnabled = c.enabled;
      });
    });
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: AppTheme.textMain,
        ),
      ),
    );
  }

  /// 账号信息：未登录显示登录入口，已登录显示昵称头像与退出登录
  Widget _buildAccountCard(LoginStore auth) {
    final logged = auth.isLogin;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.divider),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.surfaceHigh,
                border: Border.all(color: AppTheme.divider),
                image: logged && auth.userFace.isNotEmpty
                    ? DecorationImage(
                        image: NetworkImage(auth.userFace),
                        fit: BoxFit.cover,
                        onError: (_, _) {},
                      )
                    : null,
              ),
              child: !logged || auth.userFace.isEmpty
                  ? Icon(Icons.person_rounded, size: 28, color: AppTheme.accent)
                  : null,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    logged
                        ? (auth.userName.isEmpty ? 'B 站用户' : auth.userName)
                        : '未登录',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textMain,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    logged ? '已登录' : '登录后可同步昵称与头像',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSub),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (logged)
              OutlinedButton(
                onPressed: _logout,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textSub,
                  side: BorderSide(color: AppTheme.divider),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  minimumSize: const Size(0, 34),
                ),
                child: const Text('退出登录', style: TextStyle(fontSize: 13)),
              )
            else
              FilledButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LoginPage()),
                  );
                },
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  minimumSize: const Size(0, 34),
                ),
                child: const Text('登录', style: TextStyle(fontSize: 13)),
              ),
          ],
        ),
      ),
    );
  }
}
