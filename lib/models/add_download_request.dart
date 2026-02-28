class AddDownloadRequest {
  AddDownloadRequest({
    this.url,
    this.torrentPath,
    this.torrentName,
    required this.saveDir,
  });

  final String? url;
  final String? torrentPath;
  final String? torrentName;
  final String saveDir;

  bool get isTorrent => torrentPath != null && torrentPath!.isNotEmpty;
}
