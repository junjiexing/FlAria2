import 'package:flutter_aria2/flutter_aria2.dart';

class DownloadTask {
  DownloadTask({
    required this.gid,
    required this.displayName,
    this.originalUri,
    this.torrentPath,
    this.selectedTorrentFileIndexes,
    required this.saveDir,
  });

  final String gid;
  final String displayName;
  final String? originalUri;
  final String? torrentPath;
  final List<int>? selectedTorrentFileIndexes;
  final String saveDir;

  Aria2DownloadStatus status = Aria2DownloadStatus.waiting;
  int totalLength = 0;
  int completedLength = 0;
  int downloadSpeed = 0;
  int connections = 0;
  int errorCode = 0;

  double get progress => totalLength > 0 ? completedLength / totalLength : 0;

  bool get isActive => status == Aria2DownloadStatus.active;
  bool get isPaused => status == Aria2DownloadStatus.paused;
  bool get isWaiting => status == Aria2DownloadStatus.waiting;
  bool get isError => status == Aria2DownloadStatus.error;
  bool get isComplete => status == Aria2DownloadStatus.complete;

  Map<String, dynamic> toMap() {
    return {
      'gid': gid,
      'displayName': displayName,
      'originalUri': originalUri,
      'torrentPath': torrentPath,
      'selectedTorrentFileIndexes': selectedTorrentFileIndexes,
      'saveDir': saveDir,
      'status': status.name,
      'totalLength': totalLength,
      'completedLength': completedLength,
      'downloadSpeed': downloadSpeed,
      'connections': connections,
      'errorCode': errorCode,
    };
  }

  factory DownloadTask.fromMap(Map<String, dynamic> map) {
    final task = DownloadTask(
      gid: (map['gid'] as String?) ?? '',
      displayName: (map['displayName'] as String?) ?? '',
      originalUri: map['originalUri'] as String?,
      torrentPath: map['torrentPath'] as String?,
      selectedTorrentFileIndexes: (map['selectedTorrentFileIndexes'] as List?)
          ?.whereType<int>()
          .toList(),
      saveDir: (map['saveDir'] as String?) ?? '',
    );

    final statusName = map['status'] as String?;
    task.status = Aria2DownloadStatus.values.firstWhere(
      (s) => s.name == statusName,
      orElse: () => Aria2DownloadStatus.waiting,
    );
    task.totalLength = (map['totalLength'] as int?) ?? 0;
    task.completedLength = (map['completedLength'] as int?) ?? 0;
    task.downloadSpeed = (map['downloadSpeed'] as int?) ?? 0;
    task.connections = (map['connections'] as int?) ?? 0;
    task.errorCode = (map['errorCode'] as int?) ?? 0;
    return task;
  }

  void updateFrom(Aria2DownloadInfo info) {
    status = info.status;
    totalLength = info.totalLength;
    completedLength = info.completedLength;
    downloadSpeed = info.downloadSpeed;
    connections = info.connections;
    errorCode = info.errorCode;
  }
}
