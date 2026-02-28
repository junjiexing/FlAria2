import 'package:flutter_aria2/flutter_aria2.dart';

class DownloadTask {
  DownloadTask({
    required this.gid,
    required this.displayName,
    this.originalUri,
    this.torrentPath,
    required this.saveDir,
  });

  final String gid;
  final String displayName;
  final String? originalUri;
  final String? torrentPath;
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

  void updateFrom(Aria2DownloadInfo info) {
    status = info.status;
    totalLength = info.totalLength;
    completedLength = info.completedLength;
    downloadSpeed = info.downloadSpeed;
    connections = info.connections;
    errorCode = info.errorCode;
  }
}
