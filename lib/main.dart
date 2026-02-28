import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_aria2/flutter_aria2.dart';

const kBtTrackers = [
  'udp://tracker.opentrackr.org:1337/announce',
  'udp://open.tracker.cl:1337/announce',
  'udp://tracker.openbittorrent.com:6969/announce',
  'udp://open.demonii.com:1337/announce',
  'udp://open.stealth.si:80/announce',
  'udp://tracker.torrent.eu.org:451/announce',
  'udp://exodus.desync.com:6969/announce',
  'udp://tracker.moeking.me:6969/announce',
  'udp://tracker1.bt.moack.co.kr:80/announce',
  'udp://tracker.tiny-vps.com:6969/announce',
  'udp://tracker.theoks.net:6969/announce',
  'udp://tracker.bittor.pw:1337/announce',
  'udp://tracker.dump.cl:6969/announce',
  'udp://tracker.auber.moe:6969/announce',
  'udp://explodie.org:6969/announce',
  'udp://retracker01-msk-virt.corbina.net:80/announce',
  'udp://p4p.arenabg.com:1337/announce',
  'https://tracker.tamersunion.org:443/announce',
  'https://tracker.lilithraws.org:443/announce',
  'http://tracker.mywaifu.best:6969/announce',
  'http://tracker.bt4g.com:2095/announce',
  'https://tracker.loligirl.cn:443/announce',
  'http://bvarf.tracker.sh:2086/announce',
  'wss://tracker.openwebtorrent.com',
];

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Aria2 下载器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const DownloadPage(),
    );
  }
}

class DownloadTask {
  DownloadTask({
    required this.gid,
    required this.uri,
    this.originalUri,
    this.torrentPath,
  });

  final String gid;
  final String uri;
  final String? originalUri;
  final String? torrentPath;
  Aria2DownloadStatus status = Aria2DownloadStatus.waiting;
  int totalLength = 0;
  int completedLength = 0;
  int downloadSpeed = 0;
  int uploadSpeed = 0;
  int connections = 0;
  String dir = '';
  int numFiles = 0;
  int errorCode = 0;

  double get progress => totalLength > 0 ? completedLength / totalLength : 0.0;

  void updateFrom(Aria2DownloadInfo info) {
    status = info.status;
    totalLength = info.totalLength;
    completedLength = info.completedLength;
    downloadSpeed = info.downloadSpeed;
    uploadSpeed = info.uploadSpeed;
    connections = info.connections;
    dir = info.dir;
    numFiles = info.numFiles;
    errorCode = info.errorCode;
  }
}

class DownloadPage extends StatefulWidget {
  const DownloadPage({super.key});

  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  static const String _caBundleAssetPath = 'assets/certs/cacert.pem';

  final FlutterAria2 _aria2 = FlutterAria2();
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _dirController = TextEditingController();
  final List<DownloadTask> _tasks = [];
  final List<String> _logs = [];
  final Set<String> _completedNotified = <String>{};

  String? _caCertificatePath;
  bool _initialized = false;
  bool _sessionActive = false;
  Aria2GlobalStat? _globalStat;
  Timer? _refreshTimer;
  StreamSubscription<Aria2DownloadEventData>? _eventSub;

  @override
  void initState() {
    super.initState();
    _dirController.text =
        '${Directory.systemTemp.path}${Platform.pathSeparator}flutter_aria2_downloads';
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _eventSub?.cancel();
    _aria2.dispose();
    _urlController.dispose();
    _dirController.dispose();
    super.dispose();
  }

  Future<void> _initAria2() async {
    try {
      final ret = await _aria2.libraryInit();
      _addLog('libraryInit => $ret');
      if (ret != 0) {
        _showSnackBar('aria2 库初始化失败: $ret');
        return;
      }
      if (!mounted) return;
      setState(() => _initialized = true);
      _showSnackBar('aria2 库初始化成功');
    } catch (error) {
      _addLog('libraryInit 异常: $error');
      _showSnackBar('初始化异常: $error');
    }
  }

  Future<void> _startSession() async {
    if (!_initialized) {
      _showSnackBar('请先初始化 aria2 库');
      return;
    }

    try {
      final dir = _dirController.text.trim();
      if (dir.isNotEmpty) {
        final folder = Directory(dir);
        if (!folder.existsSync()) {
          folder.createSync(recursive: true);
        }
      }

      final needCustomCa = Platform.isIOS || Platform.isAndroid;
      String? caCertificatePath;
      if (needCustomCa) {
        caCertificatePath = await _ensureCaCertificatePath();
      }

      await _aria2.sessionNew(
        options: {
          if (dir.isNotEmpty) 'dir': dir,
          if (needCustomCa && caCertificatePath != null)
            'ca-certificate': caCertificatePath,
          'allow-overwrite': 'true',
          'auto-file-renaming': 'true',
          'continue': 'true',
          if (needCustomCa) 'check-certificate': 'true',
          'max-connection-per-server': '16',
          'split': '16',
          'min-split-size': '1M',
          'max-concurrent-downloads': '5',
          'max-tries': '1',
          'retry-wait': '0',
          'bt-tracker': kBtTrackers.join(','),
          'enable-dht': 'true',
          'enable-peer-exchange': 'true',
          'seed-time': '0',
        },
        keepRunning: true,
      );

      await _eventSub?.cancel();
      _eventSub = _aria2.onDownloadEvent.listen(_onDownloadEvent);

      await _aria2.startRunLoop();
      _refreshTimer?.cancel();
      _refreshTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _refreshStatus(),
      );

      _addLog('sessionNew 成功, dir=$dir');
      if (!mounted) return;
      setState(() => _sessionActive = true);
      _showSnackBar('会话启动成功');
    } catch (error) {
      _addLog('sessionNew 异常: $error');
      _showSnackBar('启动会话失败: $error');
    }
  }

  Future<void> _stopSession() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;

    await _eventSub?.cancel();
    _eventSub = null;

    try {
      await _aria2.stopRunLoop();
      _addLog('stopRunLoop 成功');
    } catch (error) {
      _addLog('stopRunLoop 异常: $error');
    }

    try {
      await _aria2.sessionFinal();
      _addLog('sessionFinal 成功');
    } catch (error) {
      _addLog('sessionFinal 异常: $error');
    }

    if (!mounted) return;
    setState(() {
      _sessionActive = false;
      _tasks.clear();
      _completedNotified.clear();
      _globalStat = null;
    });
    _showSnackBar('会话已关闭');
  }

  Future<void> _deinitAria2() async {
    if (_sessionActive) {
      await _stopSession();
    }
    try {
      final ret = await _aria2.libraryDeinit();
      _addLog('libraryDeinit => $ret');
    } catch (error) {
      _addLog('libraryDeinit 异常: $error');
    }

    if (!mounted) return;
    setState(() => _initialized = false);
    _showSnackBar('aria2 库已释放');
  }

  void _onDownloadEvent(Aria2DownloadEventData event) {
    _addLog('事件: ${event.event.name} GID=${event.gid}');
    _handleEventNotification(event);
    _refreshTaskByGid(event.gid);
  }

  void _handleEventNotification(Aria2DownloadEventData event) {
    final eventName = event.event.name.toLowerCase();
    if (!eventName.contains('complete')) {
      return;
    }
    if (_completedNotified.contains(event.gid)) {
      return;
    }

    _completedNotified.add(event.gid);
    final task = _taskByGid(event.gid);
    final name = task?.uri ?? 'GID=${event.gid}';
    _showSnackBar('下载完成: $name');
  }

  Future<void> _addDownload() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      _showSnackBar('请输入下载链接');
      return;
    }
    if (!_sessionActive) {
      _showSnackBar('请先启动会话');
      return;
    }

    try {
      final gid = await _aria2.addUri([url]);
      _addLog('addUri => GID=$gid');
      _urlController.clear();

      if (!mounted) return;
      setState(() {
        _tasks.add(DownloadTask(gid: gid, uri: url, originalUri: url));
      });
      _showSnackBar('下载已添加');
    } catch (error) {
      _addLog('addUri 异常: $error');
      _showSnackBar('添加失败: $error');
    }
  }

  Future<void> _addTorrentDownload() async {
    if (!_sessionActive) {
      _showSnackBar('请先启动会话');
      return;
    }

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['torrent'],
        dialogTitle: '选择种子文件',
      );
      if (result == null || result.files.isEmpty) {
        return;
      }

      final filePath = result.files.single.path;
      if (filePath == null || filePath.isEmpty) {
        return;
      }

      final fileName = result.files.single.name;
      final gid = await _aria2.addTorrent(filePath);
      _addLog('addTorrent => GID=$gid');

      if (!mounted) return;
      setState(() {
        _tasks.add(
          DownloadTask(
            gid: gid,
            uri: '[Torrent] $fileName',
            torrentPath: filePath,
          ),
        );
      });
      _showSnackBar('种子下载已添加');
    } catch (error) {
      _addLog('addTorrent 异常: $error');
      _showSnackBar('添加种子失败: $error');
    }
  }

  Future<void> _pauseTask(DownloadTask task) async {
    try {
      await _aria2.pauseDownload(task.gid, force: true);
      _addLog('暂停 GID=${task.gid}');
    } catch (error) {
      _addLog('暂停异常: $error');
      _showSnackBar('暂停失败: $error');
    }
  }

  Future<void> _resumeTask(DownloadTask task) async {
    try {
      await _aria2.unpauseDownload(task.gid);
      _addLog('恢复 GID=${task.gid}');
    } catch (error) {
      _addLog('恢复异常: $error');
      _showSnackBar('恢复失败: $error');
    }
  }

  Future<void> _removeTask(DownloadTask task) async {
    try {
      await _aria2.removeDownload(task.gid, force: true);
      _addLog('移除 GID=${task.gid}');
      if (!mounted) return;
      setState(() {
        _tasks.remove(task);
        _completedNotified.remove(task.gid);
      });
    } catch (error) {
      _addLog('移除异常: $error');
      _showSnackBar('移除失败: $error');
    }
  }

  Future<void> _retryTask(DownloadTask task) async {
    if (!_sessionActive) {
      _showSnackBar('请先启动会话');
      return;
    }

    try {
      DownloadTask newTask;
      if (task.torrentPath != null) {
        final gid = await _aria2.addTorrent(task.torrentPath!);
        newTask = DownloadTask(
          gid: gid,
          uri: task.uri,
          torrentPath: task.torrentPath,
        );
      } else if (task.originalUri != null) {
        final gid = await _aria2.addUri([task.originalUri!]);
        newTask = DownloadTask(
          gid: gid,
          uri: task.originalUri!,
          originalUri: task.originalUri,
        );
      } else {
        _showSnackBar('当前任务无法重试');
        return;
      }

      try {
        await _aria2.removeDownload(task.gid, force: true);
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _tasks.remove(task);
        _tasks.add(newTask);
        _completedNotified.remove(task.gid);
      });
      _addLog('重试任务: ${task.uri} -> ${newTask.gid}');
      _showSnackBar('已手动重试任务');
    } catch (error) {
      _addLog('重试异常: $error');
      _showSnackBar('重试失败: $error');
    }
  }

  Future<void> _refreshStatus() async {
    if (!_sessionActive) return;

    try {
      final stat = await _aria2.getGlobalStat();
      if (!mounted) return;
      setState(() => _globalStat = stat);
    } catch (_) {}

    for (final task in _tasks) {
      if (task.status == Aria2DownloadStatus.complete ||
          task.status == Aria2DownloadStatus.removed) {
        continue;
      }
      await _refreshTaskByGid(task.gid);
    }
  }

  Future<void> _refreshTaskByGid(String gid) async {
    final task = _taskByGid(gid);
    if (task == null) return;

    try {
      final info = await _aria2.getDownloadInfo(gid);
      if (!mounted) return;
      setState(() => task.updateFrom(info));
    } catch (_) {}
  }

  DownloadTask? _taskByGid(String gid) {
    for (final task in _tasks) {
      if (task.gid == gid) {
        return task;
      }
    }
    return null;
  }

  Future<String> _ensureCaCertificatePath() async {
    if (_caCertificatePath != null && File(_caCertificatePath!).existsSync()) {
      return _caCertificatePath!;
    }

    final certDir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}flutter_aria2_certs',
    );
    if (!certDir.existsSync()) {
      certDir.createSync(recursive: true);
    }

    final certFile = File('${certDir.path}${Platform.pathSeparator}cacert.pem');
    final certAsset = await rootBundle.load(_caBundleAssetPath);
    await certFile.writeAsBytes(certAsset.buffer.asUint8List(), flush: true);
    _caCertificatePath = certFile.path;
    return certFile.path;
  }

  void _addLog(String msg) {
    final now = DateTime.now();
    final ts =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    if (!mounted) return;
    setState(() {
      _logs.insert(0, '[$ts] $msg');
      if (_logs.length > 200) {
        _logs.removeLast();
      }
    });
  }

  void _showSnackBar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flutter Aria2 下载管理器'),
        centerTitle: true,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 900;
          if (isWide) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(flex: 3, child: _buildTaskAndLogArea(colorScheme)),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 2,
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          _buildEngineControls(colorScheme),
                          const SizedBox(height: 12),
                          if (_globalStat != null) ...[
                            _buildGlobalStatBar(colorScheme),
                            const SizedBox(height: 12),
                          ],
                          if (_sessionActive) _buildAddDownloadSection(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          }

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                const SizedBox(height: 8),
                _buildEngineControls(colorScheme),
                const SizedBox(height: 12),
                if (_globalStat != null) ...[
                  _buildGlobalStatBar(colorScheme),
                  const SizedBox(height: 12),
                ],
                if (_sessionActive) ...[
                  _buildAddDownloadSection(),
                  const SizedBox(height: 12),
                ],
                Expanded(child: _buildTaskAndLogArea(colorScheme)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildTaskAndLogArea(ColorScheme colorScheme) {
    if (_tasks.isEmpty && _logs.isEmpty) {
      return Center(
        child: Text(
          _sessionActive ? '暂无下载任务，请添加下载链接' : '请初始化 aria2 并启动会话',
          style: TextStyle(color: colorScheme.outline),
        ),
      );
    }

    return Column(
      children: [
        if (_tasks.isNotEmpty)
          Expanded(flex: 3, child: _buildTaskList(colorScheme)),
        if (_logs.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Divider(height: 1),
          const SizedBox(height: 8),
          Expanded(flex: 2, child: _buildLogPanel(colorScheme)),
        ],
      ],
    );
  }

  Widget _buildEngineControls(ColorScheme colorScheme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '引擎控制',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('下载目录'),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _dirController,
                    enabled: !_sessionActive,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _initialized ? null : _initAria2,
                  icon: const Icon(Icons.power_settings_new, size: 18),
                  label: const Text('初始化库'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _initialized && !_sessionActive
                      ? _startSession
                      : null,
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('启动会话'),
                ),
                OutlinedButton.icon(
                  onPressed: _sessionActive ? _stopSession : null,
                  icon: const Icon(Icons.stop, size: 18),
                  label: const Text('关闭会话'),
                ),
                OutlinedButton.icon(
                  onPressed: _initialized && !_sessionActive
                      ? _deinitAria2
                      : null,
                  icon: const Icon(Icons.power_off, size: 18),
                  label: const Text('释放库'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGlobalStatBar(ColorScheme colorScheme) {
    final stat = _globalStat!;
    return Card(
      color: colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            _statChip(Icons.download, _formatSpeed(stat.downloadSpeed)),
            _statChip(Icons.upload, _formatSpeed(stat.uploadSpeed)),
            _statChip(Icons.downloading, '${stat.numActive} 活跃'),
            _statChip(Icons.hourglass_empty, '${stat.numWaiting} 等待'),
            _statChip(Icons.check_circle_outline, '${stat.numStopped} 停止'),
          ],
        ),
      ),
    );
  }

  Widget _statChip(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  Widget _buildAddDownloadSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            TextField(
              controller: _urlController,
              decoration: InputDecoration(
                hintText: '输入下载链接 (HTTP/HTTPS/FTP/Magnet)',
                prefixIcon: const Icon(Icons.link),
                border: const OutlineInputBorder(),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.content_paste),
                  tooltip: '从剪贴板粘贴',
                  onPressed: () async {
                    final data = await Clipboard.getData(Clipboard.kTextPlain);
                    final text = data?.text;
                    if (text != null && text.isNotEmpty) {
                      _urlController.text = text;
                    }
                  },
                ),
              ),
              onSubmitted: (_) => _addDownload(),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _addDownload,
                  icon: const Icon(Icons.add),
                  label: const Text('下载'),
                ),
                OutlinedButton.icon(
                  onPressed: _addTorrentDownload,
                  icon: const Icon(Icons.file_open, size: 18),
                  label: const Text('种子文件'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskList(ColorScheme colorScheme) {
    return ListView.builder(
      itemCount: _tasks.length,
      itemBuilder: (context, index) {
        final task = _tasks[index];
        return _buildTaskCard(task, colorScheme);
      },
    );
  }

  Widget _buildTaskCard(DownloadTask task, ColorScheme colorScheme) {
    final statusColor = _statusColor(task.status, colorScheme);
    final statusText = _statusText(task.status);
    final isActive = task.status == Aria2DownloadStatus.active;
    final isPaused = task.status == Aria2DownloadStatus.paused;
    final isWaiting = task.status == Aria2DownloadStatus.waiting;
    final isDone = task.status == Aria2DownloadStatus.complete;
    final isError = task.status == Aria2DownloadStatus.error;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    task.uri,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withAlpha(30),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: statusColor.withAlpha(80)),
                  ),
                  child: Text(
                    statusText,
                    style: TextStyle(
                      fontSize: 11,
                      color: statusColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: isDone ? 1 : task.progress,
                minHeight: 6,
                backgroundColor: colorScheme.surfaceContainerHighest,
                color: isDone
                    ? colorScheme.primary
                    : isError
                    ? colorScheme.error
                    : colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '${(task.progress * 100).toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: colorScheme.onSurface,
                  ),
                ),
                Text(
                  '${_formatSize(task.completedLength)} / ${_formatSize(task.totalLength)}',
                  style: TextStyle(fontSize: 11, color: colorScheme.outline),
                ),
                if (isActive)
                  Text(
                    '${_formatSpeed(task.downloadSpeed)} · ${task.connections} 连接',
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (isError)
                  Text(
                    '错误码: ${task.errorCode}',
                    style: TextStyle(fontSize: 11, color: colorScheme.error),
                  ),
                Text(
                  'GID: ${task.gid.length > 8 ? '${task.gid.substring(0, 8)}...' : task.gid}',
                  style: TextStyle(fontSize: 10, color: colorScheme.outline),
                ),
                if (isActive)
                  _iconBtn(Icons.pause, '暂停', () => _pauseTask(task)),
                if (isPaused || isWaiting)
                  _iconBtn(Icons.play_arrow, '恢复', () => _resumeTask(task)),
                if (isError)
                  _iconBtn(Icons.refresh, '重试', () => _retryTask(task)),
                _iconBtn(Icons.close, '移除', () => _removeTask(task)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, String tooltip, VoidCallback onPressed) {
    return SizedBox(
      width: 30,
      height: 30,
      child: IconButton(
        icon: Icon(icon, size: 16),
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
      ),
    );
  }

  Widget _buildLogPanel(ColorScheme colorScheme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.terminal, size: 14, color: colorScheme.outline),
                const SizedBox(width: 4),
                Text(
                  '事件日志',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: colorScheme.outline,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(_logs.clear),
                  child: const Text('清除', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest.withAlpha(120),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  itemCount: _logs.length,
                  itemBuilder: (context, index) {
                    return Text(
                      _logs[index],
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatSize(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var unitIndex = 0;
    var size = bytes.toDouble();
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex++;
    }
    return '${size.toStringAsFixed(unitIndex == 0 ? 0 : 1)} ${units[unitIndex]}';
  }

  static String _formatSpeed(int bytesPerSec) {
    if (bytesPerSec <= 0) return '0 B/s';
    return '${_formatSize(bytesPerSec)}/s';
  }

  static Color _statusColor(
    Aria2DownloadStatus status,
    ColorScheme colorScheme,
  ) {
    switch (status) {
      case Aria2DownloadStatus.active:
        return colorScheme.primary;
      case Aria2DownloadStatus.waiting:
        return colorScheme.tertiary;
      case Aria2DownloadStatus.paused:
        return colorScheme.secondary;
      case Aria2DownloadStatus.complete:
        return colorScheme.primary;
      case Aria2DownloadStatus.error:
        return colorScheme.error;
      case Aria2DownloadStatus.removed:
        return colorScheme.outline;
    }
  }

  static String _statusText(Aria2DownloadStatus status) {
    switch (status) {
      case Aria2DownloadStatus.active:
        return '下载中';
      case Aria2DownloadStatus.waiting:
        return '等待中';
      case Aria2DownloadStatus.paused:
        return '已暂停';
      case Aria2DownloadStatus.complete:
        return '已完成';
      case Aria2DownloadStatus.error:
        return '出错';
      case Aria2DownloadStatus.removed:
        return '已移除';
    }
  }
}
