class AddDownloadRequest {
  AddDownloadRequest({
    required this.taskName,
    this.url,
    this.torrentPath,
    this.torrentName,
    this.selectedTorrentFileIndexes,
    required this.saveDir,
  });

  final String taskName;
  final String? url;
  final String? torrentPath;
  final String? torrentName;
  final List<int>? selectedTorrentFileIndexes;
  final String saveDir;

  bool get isTorrent => torrentPath != null && torrentPath!.isNotEmpty;
}
