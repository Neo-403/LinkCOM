import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'version.dart';
import 'net/deep_link.dart';
import 'state/app_state.dart';
import 'sniffer/sniffer_controller.dart';
import 'background/bg_service.dart';
import 'theme/app_theme.dart';
import 'ui/share_screen.dart';
import 'ui/link_screen.dart';
import 'ui/settings_screen.dart';

Future<void> main(List<String> args) async {
  // 必须在 AppState 构造里读取 SharedPreferences 之前初始化绑定, 否则 _loadPrefs 会静默失败
  WidgetsFlutterBinding.ensureInitialized();
  // Android 前台服务保活(非 Android 平台内部直接返回, 不影响 Windows)
  unawaited(initializeBackgroundService());
  // 全局状态(服务器地址/历史/主题) + 两端各自的会话与嗅探器(AppState 内持有)
  final app = AppState();
  // 等持久化值载入完成再应用深链: 否则深链写入的服务器地址/房间码会被异步载入的旧值覆盖
  await app.ready;
  final link = _argDeepLink(args);
  if (link != null) app.applyDeepLink(link);
  runApp(
    MultiProvider(
      providers: [ChangeNotifierProvider.value(value: app)],
      child: const MyApp(),
    ),
  );
}

// 从命令行参数里找出第一个 linkcom:// 深链
DeepLink? _argDeepLink(List<String> args) {
  for (final a in args) {
    final d = parseDeepLink(a);
    if (d != null) return d;
  }
  return null;
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    // 仅依赖 themeMode: 避免 AppState 每次(串口数据流)notify 都重建整个 MaterialApp/Home,
    // 否则双屏 TerminalView 被每秒重建数十次, 引发 GlobalKey 抖动/Controller 被 dispose 后访问/Overlay 崩溃等级联异常
    final themeMode = context.select<AppState, ThemeMode>((a) => a.themeMode);
    return MaterialApp(
      title: 'LinkCOM',
      theme: geekTheme(Brightness.light),
      darkTheme: geekTheme(Brightness.dark),
      themeMode: themeMode,
      // 中文界面(含输入框右键的 复制/粘贴/剪切/全选 等系统菜单)
      locale: const Locale('zh', 'CN'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      home: const Home(),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int _idx = 0;
  bool _userExpanded = true;
  bool _userToggled = false;
  static const _deepLinkChannel = MethodChannel('linkcom/deeplink');
  static const _navIcons = [Icons.usb, Icons.link, Icons.settings];
  static const _navLabels = ['共享端', '链接端', '设置'];
  late final AppState _app = context.read<AppState>();

  @override
  void initState() {
    super.initState();
    // 深链(桌面启动参数 / 安卓 intent)统一走 AppState.applyDeepLink,
    // 这里监听它请求的板块并切换
    _app.addListener(_onAppChanged);
    _onAppChanged();
    if (Platform.isAndroid) unawaited(_watchAndroidDeepLink());
  }

  @override
  void dispose() {
    _app.removeListener(_onAppChanged);
    super.dispose();
  }

  // 消费深链请求的目标板块(0=共享端, 1=链接端)
  void _onAppChanged() {
    if (!mounted) return;
    final t = _app.pendingTab;
    if (t == null) return;
    _app.pendingTab = null;
    if (t != _idx) setState(() => _idx = t);
  }

  // 安卓: 冷启动读取 intent, 热启动(onNewIntent)由原生回调
  Future<void> _watchAndroidDeepLink() async {
    try {
      _deepLinkChannel.setMethodCallHandler((call) async {
        if (call.method == 'link') {
          final d = parseDeepLink(call.arguments?.toString() ?? '');
          if (d != null) _app.applyDeepLink(d);
        }
        return null;
      });
      final uri = await _deepLinkChannel.invokeMethod<String>('initialLink');
      final d = uri == null ? null : parseDeepLink(uri);
      if (d != null) _app.applyDeepLink(d);
    } catch (_) {}
  }
  // 宽屏(>=720)用可折叠侧栏; 窄屏(手机)改为隐藏式抽屉: 平时不占任何横向空间,
  // 从屏幕左缘向右滑(Scaffold 自带手势)或点左上角菜单键打开。
  static const _wideBreakpoint = 720.0;

  // 三个页面: 共享端/链接端各自注入独立会话与嗅探器, 两端完全隔离
  Widget _content(AppState app) => IndexedStack(
        index: _idx,
        children: [
          ChangeNotifierProvider<RelaySession>.value(
            value: app.shareSession,
            child: ChangeNotifierProvider<SnifferController>.value(
              value: app.shareSniffer,
              child: const ShareScreen(),
            ),
          ),
          ChangeNotifierProvider<RelaySession>.value(
            value: app.linkSession,
            child: ChangeNotifierProvider<SnifferController>.value(
              value: app.linkSniffer,
              child: const LinkScreen(),
            ),
          ),
          const SettingsScreen(),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final theme = Theme.of(context);
    final width = MediaQuery.of(context).size.width;

    // 窄屏(手机): 抽屉式导航, 平时隐藏 -> 内容占满宽度
    if (width < _wideBreakpoint) {
      return Scaffold(
        // 抽屉: 左缘右滑或点左上角菜单键打开; 打开后内容区变暗可点外部关闭。
        // 注意: 这里**不用** GlobalKey<ScaffoldState> —— 它在窄/宽布局分支切换时会把整棵
        // 子树(含其中的 Provider 等 InheritedWidget)"搬移/取回", 与依赖者生命周期不同步,
        // 触发 framework 的 '_dependents.isEmpty' 断言。改用 Builder + Scaffold.of 打开抽屉。
        drawer: Drawer(
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                  child: Row(
                    children: [
                      const Icon(Icons.usb),
                      const SizedBox(width: 12),
                      Text('LinkCOM v$appVersion',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16)),
                    ],
                  ),
                ),
                const Divider(height: 1),
                for (var i = 0; i < _navIcons.length; i++)
                  _navItem(i, true, theme,
                      onClosed: () => Navigator.of(context).maybePop()),
              ],
            ),
          ),
        ),
        // 细顶栏(48): 左 菜单键, 中 当前板块名, 右 版本号; 仅此一处占纵向空间
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                border: Border(bottom: BorderSide(color: theme.dividerColor)),
              ),
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  // 顶栏压到 40, 标题缩小, 给下方内容多留空间
                  height: 40,
                  child: Row(
                    children: [
                      Builder(
                        builder: (ctx) => IconButton(
                          icon: const Icon(Icons.menu, size: 20),
                          tooltip: '菜单',
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          onPressed: () => Scaffold.of(ctx).openDrawer(),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(_navLabels[_idx],
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 14)),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Text('LinkCOM',
                            style: TextStyle(
                                fontSize: 12, color: theme.hintColor)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(child: _content(app)),
          ],
        ),
      );
    }

    // 宽屏(桌面/平板): 保留可折叠侧栏
    final expanded = _userToggled ? _userExpanded : true;
    return Scaffold(
      // 不用 AppBar: 标题移入左侧折叠侧栏头部, 释放实际使用空间
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: expanded ? 220 : 64,
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(right: BorderSide(color: theme.dividerColor)),
            ),
            child: Column(
              children: [
                // 侧栏头部: 点击折叠/展开; 展开时显示 LinkCOM 标题
                // 标题 softWrap:false + overflow:clip: 宽度动画期间只裁切不换行,
                // 消除"v1.0.2 跳到下一行"的跳动; 折叠时图标居中保持左右边距一致
                InkWell(
                  onTap: () => setState(() {
                    _userToggled = true;
                    _userExpanded = !expanded;
                  }),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: expanded ? 12 : 0, vertical: 16),
                    child: Row(
                      mainAxisAlignment: expanded
                          ? MainAxisAlignment.start
                          : MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.menu),
                        if (expanded)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(left: 12),
                              child: Text('LinkCOM v$appVersion',
                                  softWrap: false,
                                  overflow: TextOverflow.clip,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16)),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1),
                for (var i = 0; i < _navIcons.length; i++)
                  _navItem(i, expanded, theme),
              ],
            ),
          ),
          Expanded(child: _content(app)),
        ],
      ),
    );
  }

  Widget _navItem(int i, bool expanded, ThemeData theme, {VoidCallback? onClosed}) {
    final sel = i == _idx;
    return InkWell(
      onTap: () {
        setState(() => _idx = i);
        onClosed?.call(); // 抽屉里点击后自动收起
      },
      child: Container(
        color: sel ? theme.colorScheme.primaryContainer : null,
        padding: EdgeInsets.symmetric(
            vertical: 14, horizontal: expanded ? 12 : 0),
        child: Row(
          // 折叠时居中图标, 左右边距一致; 展开时左对齐图标+标签
          mainAxisAlignment:
              expanded ? MainAxisAlignment.start : MainAxisAlignment.center,
          children: [
            Icon(_navIcons[i], color: sel ? theme.colorScheme.primary : null),
            if (expanded)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(
                    _navLabels[i],
                    softWrap: false,
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                      color: sel ? theme.colorScheme.primary : null,
                      fontWeight: sel ? FontWeight.bold : null,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
