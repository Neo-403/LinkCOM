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
            // 路径可省略 /ws: 连不上时会自动补 /ws 重试
            hintText: 'wss://host:8443/linkcom (可省略 /ws)',
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
        const Divider(),
        const Text('串口 / 性能', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text('影响收发及时性与资源占用; 改完即时写入(下次打开端口/读取时应用)',
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6))),
        const SizedBox(height: 6),
        _pickRow('读取轮询间隔', s.readPollMs, ' ms',
            const [1, 2, 3, 5, 10, 20, 50], (v) => s.readPollMs = v),
        _pickRow('单次读取超时', s.readTimeoutMs, ' ms',
            const [5, 10, 15, 25, 50, 100, 200], (v) => s.readTimeoutMs = v),
        _pickRow('驱动读缓冲', s.rxBufKb, ' KB',
            const [4, 8, 16, 32, 64, 128, 256, 512], (v) => s.rxBufKb = v),
        _pickRow('日志最大行数', s.maxLogLines, '',
            const [1000, 2000, 5000, 10000, 20000], (v) => s.maxLogLines = v),
        _pickRow('BLE 扫描时长', s.bleScanSec, ' s',
            const [3, 6, 10, 15, 30], (v) => s.bleScanSec = v),
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

  // 一行"标签 + 下拉"设置项: 候选值天然合法, 免校验
  Widget _pickRow(String label, int cur, String unit, List<int> opts,
      ValueChanged<int> onPick) {
    final vals = [...opts];
    if (!vals.contains(cur)) {
      vals.add(cur);
      vals.sort();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          DropdownButton<int>(
            value: cur,
            isDense: true,
            borderRadius: BorderRadius.circular(8),
            items: [
              for (final v in vals)
                DropdownMenuItem(value: v, child: Text('$v$unit')),
            ],
            onChanged: (v) {
              if (v != null) onPick(v);
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
