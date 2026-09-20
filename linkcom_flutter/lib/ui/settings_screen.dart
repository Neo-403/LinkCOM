import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../state/app_state.dart';

// 项目 GitHub 仓库地址(设置页一键打开)
const String _githubUrl = 'https://github.com/Neo-403/LinkCOM';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _urlCtl;
  final FocusNode _focus = FocusNode();
  late final AppState _app;

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _urlCtl = TextEditingController(text: _app.serverUrl);
    // 本地存储加载完成(异步)或外部变更后, 回填到输入框; 用户正在输入时不打断
    _app.addListener(_syncUrl);
  }

  void _syncUrl() {
    if (!_focus.hasFocus && _urlCtl.text != _app.serverUrl) {
      _urlCtl.text = _app.serverUrl;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppState>();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
        TextField(
          controller: _urlCtl,
          focusNode: _focus,
          decoration: const InputDecoration(
            labelText: '中继服务器地址 (WebSocket)',
            hintText: 'ws://host:port/ws',
          ),
          onChanged: (v) => s.serverUrl = v.trim(),
        ),
        if (s.serverHistory.isNotEmpty) ...[
          const SizedBox(height: 8),
          ExpansionTile(
            title: const Text('服务器地址历史'),
            initiallyExpanded: false, // 默认折叠
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final url in s.serverHistory)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(url,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
                  onTap: () {
                    _urlCtl.text = url;
                    s.serverUrl = url;
                  },
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: '从历史移除',
                    onPressed: () => s.removeServerHistory(url),
                  ),
                ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: s.clearServerHistory,
                  child: const Text('清空历史'),
                ),
              ),
            ],
          ),
        ],
        const Divider(),
        const Text('主题', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          selected: {s.themeModeInt},
          showSelectedIcon: false, // 去掉勾选图标, 窄屏下避免文字换行
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          onSelectionChanged: (set) => s.themeMode = set.first,
          segments: const [
            ButtonSegment(value: 0, label: Text('自动')),
            ButtonSegment(value: 1, label: Text('白天')),
            ButtonSegment(value: 2, label: Text('黑夜')),
          ],
        ),
        const SizedBox(height: 50),
        ElevatedButton.icon(
          icon: const Icon(Icons.open_in_new),
          label: const Text('在 GitHub 上查看本项目'),
          onPressed: () async {
            final uri = Uri.parse(_githubUrl);
            try {
              if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('无法打开: $_githubUrl')),
                  );
                }
              }
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('打开失败: $e')),
                );
              }
            }
          },
        ),
      ],
      ),
    );
  }

  @override
  void dispose() {
    _app.removeListener(_syncUrl);
    _focus.dispose();
    _urlCtl.dispose();
    super.dispose();
  }
}
