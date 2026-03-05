import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_aria2/flutter_aria2.dart';
import 'package:path_provider/path_provider.dart';

import '../models/add_download_request.dart';
import '../models/download_task.dart';
import '../models/torrent_task_file.dart';

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
  String? _sessionFilePath;
  String? _taskStoreFilePath;
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

      await _ensurePersistencePaths();

      final defaultDir =
          '${Directory.systemTemp.path}${Platform.pathSeparator}flutter_aria2_downloads';
      final dir = Directory(defaultDir);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }

      final options = <String, String>{
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
        'save-session-interval': '2',
        'bt-tracker': kBtTrackers.join(','),
        'enable-dht': 'true',
        'enable-peer-exchange': 'true',
        'seed-time': '0',
      };

      final sessionFilePath = _sessionFilePath;
      if (sessionFilePath != null) {
        options['input-file'] = sessionFilePath;
        options['save-session'] = sessionFilePath;
      }

      try {
        await _aria2.sessionNew(options: options, keepRunning: true);
      } catch (error) {
        final fallbackOptions = <String, String>{...options}
          ..remove('input-file')
          ..remove('save-session')
          ..remove('save-session-interval');
        onInfo?.call('会话持久化参数不可用，已使用兼容模式启动');
        await _aria2.sessionNew(options: fallbackOptions, keepRunning: true);
      }

      _eventSub = _aria2.onDownloadEvent.listen(_onDownloadEvent);
      await _aria2.startRunLoop();
      _refreshTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _refreshStatus(),
      );
      await _restorePersistedTasks();
      await _recoverInterruptedTasksOnStartup();
      await _refreshStatus();

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
    await _persistTasks();

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
        final stableTorrentPath = await _ensureStableTorrentFile(
          request.torrentPath!,
        );
        final gid = await _addTorrentWithFallback(
          torrentPath: stableTorrentPath,
          saveDir: saveDir,
          selectedFileIndexes: request.selectedTorrentFileIndexes,
        );
        final name = request.torrentName ?? 'Torrent 任务';
        _tasks.add(
          DownloadTask(
            gid: gid,
            displayName: '[Torrent] $name',
            torrentPath: stableTorrentPath,
            selectedTorrentFileIndexes: request.selectedTorrentFileIndexes,
            saveDir: saveDir,
          ),
        );
      } else {
        final url = request.url?.trim() ?? '';
        if (url.isEmpty) {
          onError?.call('请输入下载链接或选择种子文件');
          return;
        }

        final isMagnet = _isMagnetUrl(url);
        final selectedIndexes = request.selectedTorrentFileIndexes;
        final validIndexes =
            selectedIndexes == null
                  ? <int>[]
                  : selectedIndexes.where((index) => index > 0).toList()
              ..sort();

        final gid = await _aria2.addUri(
          [url],
          options: {
            'dir': saveDir,
            'continue': 'true',
            'allow-overwrite': 'true',
            'auto-file-renaming': 'true',
            if (isMagnet) 'follow-torrent': 'true',
            if (isMagnet && validIndexes.isNotEmpty)
              'select-file': validIndexes.join(','),
          },
        );
        _tasks.add(
          DownloadTask(
            gid: gid,
            displayName: url,
            originalUri: url,
            selectedTorrentFileIndexes: isMagnet ? validIndexes : null,
            saveDir: saveDir,
          ),
        );
      }

      await _persistTasks();
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
      await _persistTasks();
      _notifySafely();
    } catch (error) {
      onError?.call('移除失败: $error');
    }
  }

  Future<void> retryTask(DownloadTask task) async {
    try {
      try {
        await _aria2.removeDownload(task.gid, force: true);
      } catch (_) {}

      DownloadTask? newTask;
      if (task.torrentPath != null && task.torrentPath!.isNotEmpty) {
        final sourceFile = File(task.torrentPath!);
        if (!sourceFile.existsSync()) {
          onError?.call('种子文件不存在，请重新选择种子文件');
          return;
        }

        final stableTorrentPath = await _ensureStableTorrentFile(
          task.torrentPath!,
        );
        final gid = await _addTorrentWithFallback(
          torrentPath: stableTorrentPath,
          saveDir: task.saveDir,
          selectedFileIndexes: task.selectedTorrentFileIndexes,
        );
        newTask = DownloadTask(
          gid: gid,
          displayName: task.displayName,
          torrentPath: stableTorrentPath,
          selectedTorrentFileIndexes: task.selectedTorrentFileIndexes,
          saveDir: task.saveDir,
        );
      } else if (task.originalUri != null && task.originalUri!.isNotEmpty) {
        final isMagnet = _isMagnetUrl(task.originalUri!);
        final selectedIndexes = task.selectedTorrentFileIndexes;
        final validIndexes =
            selectedIndexes == null
                  ? <int>[]
                  : selectedIndexes.where((index) => index > 0).toList()
              ..sort();

        final gid = await _aria2.addUri(
          [task.originalUri!],
          options: {
            'dir': task.saveDir,
            'continue': 'true',
            'allow-overwrite': 'true',
            'auto-file-renaming': 'true',
            if (isMagnet) 'follow-torrent': 'true',
            if (isMagnet && validIndexes.isNotEmpty)
              'select-file': validIndexes.join(','),
          },
        );
        newTask = DownloadTask(
          gid: gid,
          displayName: task.originalUri!,
          originalUri: task.originalUri,
          selectedTorrentFileIndexes: isMagnet ? validIndexes : null,
          saveDir: task.saveDir,
        );
      }

      if (newTask == null) {
        onError?.call('该任务不支持重试');
        return;
      }

      _tasks.remove(task);
      _tasks.add(newTask);
      _notifiedCompleteGids.remove(task.gid);
      await _persistTasks();
      _notifySafely();
    } catch (error) {
      if (_isErrorCode12(error)) {
        final hint = await _buildCode12Hint(task.saveDir);
        onError?.call('重试失败（错误码12）：$hint。若目录中有同名任务，请先移除旧任务');
      } else {
        onError?.call('重试失败: $error');
      }
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
      final previousStatus = task.status;
      task.updateFrom(info);

      if (task.status == Aria2DownloadStatus.complete &&
          !_notifiedCompleteGids.contains(task.gid)) {
        _notifiedCompleteGids.add(task.gid);
        onDownloadCompleted?.call('下载完成: ${task.displayName}');
        unawaited(_persistTasks());
      }

      if (task.status != previousStatus) {
        unawaited(_persistTasks());
      }

      _notifySafely();
    } catch (_) {}
  }

  Future<void> _recoverInterruptedTasksOnStartup() async {
    final candidates = _tasks
        .where(
          (task) =>
              task.status != Aria2DownloadStatus.complete &&
              task.status != Aria2DownloadStatus.removed,
        )
        .toList();

    for (final task in candidates) {
      try {
        final info = await _aria2.getDownloadInfo(task.gid);
        task.updateFrom(info);
      } catch (error) {
        task.status = Aria2DownloadStatus.error;
        task.errorCode = _isErrorCode12(error) ? 12 : task.errorCode;
        if (_isErrorCode12(error)) {
          final hint = await _buildCode12Hint(task.saveDir);
          onError?.call('任务恢复失败（错误码12）：$hint');
        }
      }
    }

    await _persistTasks();
    _notifySafely();
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

  Future<void> _ensurePersistencePaths() async {
    if (_sessionFilePath != null && _taskStoreFilePath != null) {
      return;
    }

    final appSupportDir = await getApplicationSupportDirectory();
    if (!appSupportDir.existsSync()) {
      appSupportDir.createSync(recursive: true);
    }

    _sessionFilePath =
        '${appSupportDir.path}${Platform.pathSeparator}aria2.session';
    _taskStoreFilePath =
        '${appSupportDir.path}${Platform.pathSeparator}tasks.json';

    final sessionFilePath = _sessionFilePath;
    if (sessionFilePath != null) {
      final sessionFile = File(sessionFilePath);
      if (!sessionFile.existsSync()) {
        sessionFile.createSync(recursive: true);
      }
    }
  }

  Future<String> _ensureStableTorrentFile(String sourcePath) async {
    await _ensurePersistencePaths();

    final sourceFile = File(sourcePath);
    if (!sourceFile.existsSync()) {
      throw Exception('种子文件不存在: $sourcePath');
    }

    final appSupportDir = await getApplicationSupportDirectory();
    final torrentsDir = Directory(
      '${appSupportDir.path}${Platform.pathSeparator}torrents',
    );
    if (!torrentsDir.existsSync()) {
      torrentsDir.createSync(recursive: true);
    }

    final safeName = sourceFile.uri.pathSegments.isNotEmpty
        ? sourceFile.uri.pathSegments.last
        : 'task.torrent';
    final targetPath =
        '${torrentsDir.path}${Platform.pathSeparator}${DateTime.now().millisecondsSinceEpoch}_$safeName';
    await sourceFile.copy(targetPath);
    return targetPath;
  }

  Future<String> _addTorrentWithFallback({
    required String torrentPath,
    required String saveDir,
    List<int>? selectedFileIndexes,
    bool strictResume = false,
  }) async {
    final validIndexes =
        selectedFileIndexes == null
              ? <int>[]
              : selectedFileIndexes.where((index) => index > 0).toList()
          ..sort();

    final btOptions = <String, String>{
      'dir': saveDir,
      'bt-tracker': kBtTrackers.join(','),
      'enable-dht': 'true',
      'enable-peer-exchange': 'true',
      'follow-torrent': 'true',
      'continue': 'true',
      'allow-overwrite': 'true',
      'auto-file-renaming': strictResume ? 'false' : 'true',
      if (validIndexes.isNotEmpty) 'select-file': validIndexes.join(','),
    };

    try {
      return await _aria2.addTorrent(torrentPath, options: btOptions);
    } catch (_) {
      final gid = await _aria2.addTorrent(torrentPath);
      await _aria2.changeOption(gid, btOptions);
      return gid;
    }
  }

  Future<List<TorrentTaskFile>> loadTorrentFiles(String torrentPath) async {
    final result = await loadTorrentBtMetaInfoAndFiles(torrentPath);
    return _toTorrentTaskFiles(result.files);
  }

  Future<({Aria2BtMetaInfoData btMetaInfo, List<Aria2FileData> files})>
  loadTorrentBtMetaInfoAndFiles(String torrentPath) async {
    if (!isReady) {
      throw Exception('aria2 尚未准备完成');
    }

    final sourceFile = File(torrentPath);
    if (!sourceFile.existsSync()) {
      throw Exception('种子文件不存在');
    }

    final stableTorrentPath = await _ensureStableTorrentFile(torrentPath);
    final cacheDir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}FlAria2Cache',
    );
    if (!cacheDir.existsSync()) {
      cacheDir.createSync(recursive: true);
    }

    String? gid;
    try {
      gid = await _aria2.addTorrent(
        stableTorrentPath,
        options: {'pause': 'true', 'dir': cacheDir.path},
      );

      final btMetaInfo = await _aria2.getDownloadBtMetaInfo(gid);
      final files = await _aria2.getDownloadFiles(gid);
      final normalizedFiles = files
          .map((file) {
            final normalizedFilePath = file.path.replaceAll('\\', '/');
            final normalizedDirPath = cacheDir.path.replaceAll('\\', '/');
            final dirPrefix = '$normalizedDirPath/';

            var relativePath = normalizedFilePath;
            if (normalizedFilePath == normalizedDirPath) {
              relativePath = '';
            } else if (normalizedFilePath.startsWith(dirPrefix)) {
              relativePath = normalizedFilePath.substring(dirPrefix.length);
            }

            return Aria2FileData(
              index: file.index,
              path: relativePath,
              length: file.length,
              completedLength: file.completedLength,
              selected: file.selected,
              uris: file.uris,
            );
          })
          .toList(growable: false);
      return (btMetaInfo: btMetaInfo, files: normalizedFiles);
    } finally {
      if (gid != null) {
        try {
          await _aria2.removeDownload(gid, force: true);
        } catch (_) {}
      }
    }
  }

  Future<({Aria2BtMetaInfoData btMetaInfo, List<Aria2FileData> files})>
  loadMagnetBtMetaInfoAndFiles(String magnetUrl) async {
    if (!isReady) {
      throw Exception('aria2 尚未准备完成');
    }

    if (!_isMagnetUrl(magnetUrl)) {
      throw Exception('请输入有效的磁力链接');
    }

    final cacheDir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}FlAria2Cache',
    );
    if (!cacheDir.existsSync()) {
      cacheDir.createSync(recursive: true);
    }

    String? gid;
    try {
      gid = await _aria2.addUri(
        [magnetUrl],
        options: {
          'dir': cacheDir.path,
          'bt-save-metadata': 'true',
          'bt-metadata-only': 'true',
          'follow-torrent': 'false',
          'allow-overwrite': 'true',
          'auto-file-renaming': 'true',
        },
      );

      final info = await _waitUntilDownloadFinished(gid);
      if (info.status != Aria2DownloadStatus.complete) {
        throw Exception('磁力元数据下载失败，状态: ${info.status}，错误码: ${info.errorCode}');
      }
      final torrentPath = '${cacheDir.path}${Platform.pathSeparator}${info.infoHash}.torrent';

      return loadTorrentBtMetaInfoAndFiles(torrentPath);
    } finally {
      if (gid != null) {
        try {
          await _aria2.removeDownload(gid, force: true);
        } catch (_) {}
      }
    }
  }

  Future<Aria2DownloadInfo> _waitUntilDownloadFinished(
    String gid, {
    Duration timeout = const Duration(seconds: 60),
    Duration pollInterval = const Duration(milliseconds: 500),
  }) async {
    final deadline = DateTime.now().add(timeout);
    Aria2DownloadInfo? lastInfo;

    while (DateTime.now().isBefore(deadline)) {
      final info = await _aria2.getDownloadInfo(gid);
      lastInfo = info;

      if (info.status == Aria2DownloadStatus.complete ||
          info.status == Aria2DownloadStatus.error ||
          info.status == Aria2DownloadStatus.removed) {
        return info;
      }

      await Future.delayed(pollInterval);
    }

    throw Exception(
      '等待任务完成超时: gid=$gid, status=${lastInfo?.status}, errorCode=${lastInfo?.errorCode}',
    );
  }

  Future<List<TorrentTaskFile>> loadMagnetFiles(String magnetUrl) async {
    final result = await loadMagnetBtMetaInfoAndFiles(magnetUrl);
    return _toTorrentTaskFiles(result.files);
  }

  List<TorrentTaskFile> _toTorrentTaskFiles(List<Aria2FileData> files) {
    return files
        .map(
          (file) => TorrentTaskFile(
            index: file.index,
            path: file.path,
            length: file.length,
          ),
        )
        .toList(growable: false);
  }

  bool _isMagnetUrl(String url) {
    return url.toLowerCase().startsWith('magnet:?');
  }

  bool _isErrorCode12(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('error code12') ||
        message.contains('error code 12') ||
        message.contains('errorcode=12') ||
        message.contains('errorcode: 12') ||
        message.contains('error code: 12');
  }

  Future<String> _buildCode12Hint(String saveDir) async {
    try {
      final dir = Directory(saveDir);
      if (!dir.existsSync()) {
        return '请删除损坏的下载文件和 .aria2 文件后重试';
      }

      final hasAria2Partial = dir
          .listSync(followLinks: false)
          .any((entity) => entity.path.toLowerCase().endsWith('.aria2'));
      if (hasAria2Partial) {
        return '检测到目录中存在 .aria2 断点文件，请删除对应损坏文件和 .aria2 后重试';
      }
    } catch (_) {}

    return '请删除损坏的下载文件和 .aria2 文件后重试';
  }

  Future<void> _restorePersistedTasks() async {
    try {
      await _ensurePersistencePaths();
      final taskStorePath = _taskStoreFilePath;
      if (taskStorePath == null) return;

      final file = File(taskStorePath);
      if (!file.existsSync()) return;

      final content = await file.readAsString();
      if (content.trim().isEmpty) return;

      final decoded = jsonDecode(content);
      if (decoded is! List) return;

      _tasks
        ..clear()
        ..addAll(
          decoded.whereType<Map>().map(
            (e) => DownloadTask.fromMap(Map<String, dynamic>.from(e)),
          ),
        );
      _tasks.removeWhere(
        (task) => task.gid.isEmpty || task.displayName.isEmpty,
      );

      _notifiedCompleteGids
        ..clear()
        ..addAll(
          _tasks
              .where((task) => task.status == Aria2DownloadStatus.complete)
              .map((task) => task.gid),
        );

      _notifySafely();
    } catch (_) {}
  }

  Future<void> _persistTasks() async {
    try {
      await _ensurePersistencePaths();
      final taskStorePath = _taskStoreFilePath;
      if (taskStorePath == null) return;

      final file = File(taskStorePath);
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }

      final jsonList = _tasks.map((task) => task.toMap()).toList();
      await file.writeAsString(jsonEncode(jsonList), flush: true);
    } catch (_) {}
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
