import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_aria2/flutter_aria2.dart';

import '../models/add_download_request.dart';
import '../models/download_task.dart';

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

class Aria2DownloadController extends ChangeNotifier {
  static const String _caBundleAssetPath = 'assets/certs/cacert.pem';

  final FlutterAria2 _aria2 = FlutterAria2();
  final List<DownloadTask> _tasks = [];
  final Set<String> _notifiedCompleteGids = <String>{};

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  bool isInitializing = false;
  bool isReady = false;
  String? initializationError;

  Timer? _refreshTimer;
  StreamSubscription<Aria2DownloadEventData>? _eventSub;
  String? _caCertificatePath;
  bool _started = false;
  bool _isDisposed = false;

  void Function(String message)? onInfo;
  void Function(String message)? onError;
  void Function(String message)? onDownloadCompleted;

  Future<void> start() async {
    if (_started || isInitializing) return;
    _started = true;
    isInitializing = true;
    initializationError = null;
    _notifySafely();

    try {
      final initResult = await _aria2.libraryInit();
      if (initResult != 0) {
        throw Exception('aria2 库初始化失败: $initResult');
      }

      final needCustomCa = Platform.isIOS || Platform.isAndroid;
      String? caCertificatePath;
      if (needCustomCa) {
        caCertificatePath = await _ensureCaCertificatePath();
      }

      final defaultDir =
          '${Directory.systemTemp.path}${Platform.pathSeparator}flutter_aria2_downloads';
      final dir = Directory(defaultDir);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }

      await _aria2.sessionNew(
        options: {
          'dir': defaultDir,
          if (needCustomCa && caCertificatePath != null)
            'ca-certificate': caCertificatePath,
          if (needCustomCa) 'check-certificate': 'true',
          'allow-overwrite': 'true',
          'auto-file-renaming': 'true',
          'continue': 'true',
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

      _eventSub = _aria2.onDownloadEvent.listen(_onDownloadEvent);
      await _aria2.startRunLoop();
      _refreshTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _refreshStatus(),
      );

      isReady = true;
      onInfo?.call('aria2 会话已启动');
    } catch (error) {
      initializationError = '$error';
      onError?.call('启动 aria2 失败: $error');
      _started = false;
    } finally {
      isInitializing = false;
      _notifySafely();
    }
  }

  Future<void> close() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;

    await _eventSub?.cancel();
    _eventSub = null;

    try {
      await _aria2.stopRunLoop();
    } catch (_) {}

    try {
      await _aria2.sessionFinal();
    } catch (_) {}

    try {
      await _aria2.libraryDeinit();
    } catch (_) {}

    _tasks.clear();
    _notifiedCompleteGids.clear();
    isReady = false;
    isInitializing = false;
    _started = false;
    _notifySafely();
  }

  Future<void> addDownload(AddDownloadRequest request) async {
    if (!isReady) {
      onError?.call('aria2 尚未准备完成');
      return;
    }

    final saveDir = request.saveDir.trim();
    if (saveDir.isEmpty) {
      onError?.call('请选择保存目录');
      return;
    }

    final dir = Directory(saveDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    try {
      if (request.isTorrent) {
        final gid = await _aria2.addTorrent(
          request.torrentPath!,
          options: {'dir': saveDir},
        );
        final name = request.torrentName ?? 'Torrent 任务';
        _tasks.add(
          DownloadTask(
            gid: gid,
            displayName: '[Torrent] $name',
            torrentPath: request.torrentPath,
            saveDir: saveDir,
          ),
        );
      } else {
        final url = request.url?.trim() ?? '';
        if (url.isEmpty) {
          onError?.call('请输入下载链接或选择种子文件');
          return;
        }

        final gid = await _aria2.addUri([url], options: {'dir': saveDir});
        _tasks.add(
          DownloadTask(
            gid: gid,
            displayName: url,
            originalUri: url,
            saveDir: saveDir,
          ),
        );
      }

      _notifySafely();
    } catch (error) {
      onError?.call('添加下载失败: $error');
    }
  }

  Future<void> pauseTask(DownloadTask task) async {
    try {
      await _aria2.pauseDownload(task.gid, force: true);
    } catch (error) {
      onError?.call('暂停失败: $error');
    }
  }

  Future<void> resumeTask(DownloadTask task) async {
    try {
      await _aria2.unpauseDownload(task.gid);
    } catch (error) {
      onError?.call('恢复失败: $error');
    }
  }

  Future<void> removeTask(DownloadTask task) async {
    try {
      await _aria2.removeDownload(task.gid, force: true);
      _tasks.remove(task);
      _notifiedCompleteGids.remove(task.gid);
      _notifySafely();
    } catch (error) {
      onError?.call('移除失败: $error');
    }
  }

  Future<void> retryTask(DownloadTask task) async {
    try {
      DownloadTask? newTask;
      if (task.torrentPath != null && task.torrentPath!.isNotEmpty) {
        final gid = await _aria2.addTorrent(
          task.torrentPath!,
          options: {'dir': task.saveDir},
        );
        newTask = DownloadTask(
          gid: gid,
          displayName: task.displayName,
          torrentPath: task.torrentPath,
          saveDir: task.saveDir,
        );
      } else if (task.originalUri != null && task.originalUri!.isNotEmpty) {
        final gid = await _aria2.addUri(
          [task.originalUri!],
          options: {'dir': task.saveDir},
        );
        newTask = DownloadTask(
          gid: gid,
          displayName: task.originalUri!,
          originalUri: task.originalUri,
          saveDir: task.saveDir,
        );
      }

      if (newTask == null) {
        onError?.call('该任务不支持重试');
        return;
      }

      try {
        await _aria2.removeDownload(task.gid, force: true);
      } catch (_) {}

      _tasks.remove(task);
      _tasks.add(newTask);
      _notifiedCompleteGids.remove(task.gid);
      _notifySafely();
    } catch (error) {
      onError?.call('重试失败: $error');
    }
  }

  Future<void> _refreshStatus() async {
    for (final task in _tasks) {
      if (task.status == Aria2DownloadStatus.complete ||
          task.status == Aria2DownloadStatus.removed) {
        continue;
      }
      await _refreshTask(task);
    }
  }

  Future<void> _refreshTask(DownloadTask task) async {
    try {
      final info = await _aria2.getDownloadInfo(task.gid);
      task.updateFrom(info);

      if (task.status == Aria2DownloadStatus.complete &&
          !_notifiedCompleteGids.contains(task.gid)) {
        _notifiedCompleteGids.add(task.gid);
        onDownloadCompleted?.call('下载完成: ${task.displayName}');
      }

      _notifySafely();
    } catch (_) {}
  }

  void _onDownloadEvent(Aria2DownloadEventData event) {
    if (event.event == Aria2DownloadEvent.onDownloadComplete ||
        event.event == Aria2DownloadEvent.onBtDownloadComplete) {
      final task = _taskByGid(event.gid);
      final displayName = task?.displayName ?? 'GID=${event.gid}';
      if (!_notifiedCompleteGids.contains(event.gid)) {
        _notifiedCompleteGids.add(event.gid);
        onDownloadCompleted?.call('下载完成: $displayName');
      }
    }
    final task = _taskByGid(event.gid);
    if (task != null) {
      unawaited(_refreshTask(task));
    }
  }

  DownloadTask? _taskByGid(String gid) {
    for (final task in _tasks) {
      if (task.gid == gid) {
        return task;
      }
    }
    return null;
  }

  void _notifySafely() {
    if (_isDisposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
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
}
