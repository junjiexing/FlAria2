import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/add_download_request.dart';
import '../models/torrent_task_file.dart';

enum AddDownloadPresentation { dialog, sheet }

class AddDownloadPreparedRequest {
  AddDownloadPreparedRequest({
    this.url,
    this.torrentPath,
    this.torrentName,
    required this.torrentFiles,
  });

  final String? url;
  final String? torrentPath;
  final String? torrentName;
  final List<TorrentTaskFile> torrentFiles;
}

class AddDownloadDialog extends StatefulWidget {
  const AddDownloadDialog({
    super.key,
    required this.onLoadTorrentFiles,
    required this.onLoadMagnetTorrentAndFiles,
    this.presentation = AddDownloadPresentation.dialog,
  });

  final Future<List<TorrentTaskFile>> Function(String torrentPath)
  onLoadTorrentFiles;
  final Future<({
    String torrentPath,
    String? torrentName,
    List<TorrentTaskFile> files,
  })> Function(String magnetUrl)
  onLoadMagnetTorrentAndFiles;
  final AddDownloadPresentation presentation;

  @override
  State<AddDownloadDialog> createState() => _AddDownloadDialogState();
}

class _AddDownloadDialogState extends State<AddDownloadDialog> {
  final TextEditingController _urlController = TextEditingController();

  String? _torrentPath;
  String? _torrentName;
  bool _loadingMetadata = false;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _pickTorrentFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['torrent'],
      dialogTitle: '选择种子文件',
    );

    if (result == null || result.files.isEmpty) return;

    final selectedPath = result.files.single.path;
    if (selectedPath == null || selectedPath.isEmpty) return;

    setState(() {
      _torrentPath = selectedPath;
      _torrentName = result.files.single.name;
      _urlController.clear();
    });
  }

  Future<({
    String torrentPath,
    String? torrentName,
    List<TorrentTaskFile> files,
  })>
  _loadMagnetTorrentAndFiles() async {
    final magnet = _urlController.text.trim();
    if (!_isMagnetUrl(magnet)) {
      throw Exception('请输入有效的磁力链接');
    }

    return widget.onLoadMagnetTorrentAndFiles(magnet);
  }

  Future<void> _submit() async {
    final url = _urlController.text.trim();

    final hasUrl = url.isNotEmpty;
    final hasTorrent = _torrentPath != null && _torrentPath!.isNotEmpty;
    final isMagnet = _isMagnetUrl(url);

    if (!hasUrl && !hasTorrent) {
      _showMessage('请输入下载链接或选择种子文件');
      return;
    }

    setState(() {
      _loadingMetadata = true;
    });

    try {
      var files = <TorrentTaskFile>[];
      var preparedTorrentPath = hasTorrent ? _torrentPath : null;
      var preparedTorrentName = _torrentName;
      var preparedUrl = hasUrl ? url : null;

      if (hasTorrent) {
        files = await widget.onLoadTorrentFiles(_torrentPath!);
      } else if (isMagnet) {
        final magnetData = await _loadMagnetTorrentAndFiles();
        files = magnetData.files;
        preparedTorrentPath = magnetData.torrentPath;
        preparedTorrentName = magnetData.torrentName;
        preparedUrl = null;
      }

      if (!mounted) return;
      Navigator.of(context).pop(
        AddDownloadPreparedRequest(
          url: preparedUrl,
          torrentPath: preparedTorrentPath,
          torrentName: preparedTorrentName,
          torrentFiles: files,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      final errorPrefix = hasTorrent ? '读取种子文件列表失败' : '读取磁力文件列表失败';
      _showMessage('$errorPrefix: $error');
    } finally {
      if (mounted) {
        setState(() {
          _loadingMetadata = false;
        });
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.presentation == AddDownloadPresentation.sheet) {
      return SafeArea(
        child: Material(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                    const Expanded(
                      child: Text(
                        '添加下载任务',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    FilledButton(
                      onPressed: _loadingMetadata ? null : _submit,
                      child: const Text('确定'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: _buildFormContent(),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return AlertDialog(
      title: const Text('添加下载任务'),
      content: SingleChildScrollView(
        child: SizedBox(width: 520, child: _buildFormContent()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _loadingMetadata ? null : _submit,
          child: const Text('确定'),
        ),
      ],
    );
  }

  Widget _buildFormContent() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _urlController,
          enabled: _torrentPath == null,
          decoration: const InputDecoration(
            labelText: '下载链接',
            hintText: 'HTTP/HTTPS/FTP/Magnet',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                _torrentName == null ? '未选择种子文件' : '已选择: $_torrentName',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _pickTorrentFile,
              child: const Text('选择 Torrent'),
            ),
            if (_torrentPath != null) ...[
              const SizedBox(width: 8),
              IconButton(
                tooltip: '清除种子文件',
                onPressed: () {
                  setState(() {
                    _torrentPath = null;
                    _torrentName = null;
                  });
                },
                icon: const Icon(Icons.close),
              ),
            ],
          ],
        ),
        if (_loadingMetadata)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('正在加载下载元数据...'),
              ],
            ),
          ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '点击“确定”后会加载元数据，并进入第二步确认下载信息。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  bool _isMagnetUrl(String value) {
    return value.toLowerCase().startsWith('magnet:?');
  }
}

class AddDownloadConfirmDialog extends StatefulWidget {
  const AddDownloadConfirmDialog({
    super.key,
    required this.preparedRequest,
    this.presentation = AddDownloadPresentation.dialog,
  });

  final AddDownloadPreparedRequest preparedRequest;
  final AddDownloadPresentation presentation;

  @override
  State<AddDownloadConfirmDialog> createState() =>
      _AddDownloadConfirmDialogState();
}

class _AddDownloadConfirmDialogState extends State<AddDownloadConfirmDialog> {
  final TextEditingController _saveDirController = TextEditingController();
  final ScrollController _fileListVerticalController = ScrollController();
  final ScrollController _fileListHorizontalController = ScrollController();

  final Set<int> _selectedFileIndexes = <int>{};
  List<String> _torrentDisplayPaths = [];

  @override
  void initState() {
    super.initState();
    _saveDirController.text =
        '${Directory.systemTemp.path}${Platform.pathSeparator}flutter_aria2_downloads';
    _torrentDisplayPaths = _buildDisplayPaths(widget.preparedRequest.torrentFiles);
    _selectedFileIndexes.addAll(
      widget.preparedRequest.torrentFiles.map((file) => file.index),
    );
  }

  @override
  void dispose() {
    _saveDirController.dispose();
    _fileListVerticalController.dispose();
    _fileListHorizontalController.dispose();
    super.dispose();
  }

  Future<void> _pickSaveDirectory() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择保存目录',
    );
    if (path == null || path.isEmpty) return;

    setState(() {
      _saveDirController.text = path;
    });
  }

  void _submit() {
    final saveDir = _saveDirController.text.trim();
    if (saveDir.isEmpty) {
      _showMessage('请选择保存目录');
      return;
    }

    final files = widget.preparedRequest.torrentFiles;
    if (files.isNotEmpty && _selectedFileIndexes.isEmpty) {
      _showMessage('请至少选择一个种子文件');
      return;
    }

    Navigator.of(context).pop(
      AddDownloadRequest(
        url: widget.preparedRequest.url,
        torrentPath: widget.preparedRequest.torrentPath,
        torrentName: widget.preparedRequest.torrentName,
        selectedTorrentFileIndexes: files.isEmpty
            ? null
            : (_selectedFileIndexes.toList()..sort()),
        saveDir: saveDir,
      ),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.presentation == AddDownloadPresentation.sheet) {
      return SafeArea(
        child: Material(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                    const Expanded(
                      child: Text(
                        '确认下载信息',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    FilledButton(onPressed: _submit, child: const Text('添加')),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: _buildFormContent(),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return AlertDialog(
      title: const Text('确认下载信息'),
      content: SingleChildScrollView(
        child: SizedBox(width: 520, child: _buildFormContent()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('添加')),
      ],
    );
  }

  Widget _buildFormContent() {
    final files = widget.preparedRequest.torrentFiles;
    final sourceValue = widget.preparedRequest.torrentName ??
        widget.preparedRequest.url ??
        '-';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('类型: ${_sourceTypeLabel()}'),
              const SizedBox(height: 2),
              Text(
                '下载源: $sourceValue',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        if (files.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('文件选择'),
              const Spacer(),
              TextButton(
                onPressed: () {
                  setState(() {
                    _selectedFileIndexes.clear();
                    _selectedFileIndexes.addAll(files.map((file) => file.index));
                  });
                },
                child: const Text('全选'),
              ),
              TextButton(
                onPressed: () {
                  setState(_selectedFileIndexes.clear);
                },
                child: const Text('清空'),
              ),
            ],
          ),
          Container(
            constraints: const BoxConstraints(maxHeight: 220),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final minWidth = constraints.maxWidth;
                final estimatedWidth = _estimateFileListContentWidth();
                final contentWidth = estimatedWidth > minWidth
                    ? estimatedWidth
                    : minWidth;

                return Scrollbar(
                  controller: _fileListHorizontalController,
                  thumbVisibility: true,
                  notificationPredicate: (notification) =>
                      notification.metrics.axis == Axis.horizontal,
                  child: SingleChildScrollView(
                    controller: _fileListHorizontalController,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: contentWidth,
                      child: Scrollbar(
                        controller: _fileListVerticalController,
                        thumbVisibility: true,
                        child: ListView.builder(
                          controller: _fileListVerticalController,
                          shrinkWrap: true,
                          itemCount: files.length,
                          itemBuilder: (context, index) {
                            final file = files[index];
                            final selected = _selectedFileIndexes.contains(
                              file.index,
                            );
                            final displayPath = index < _torrentDisplayPaths.length
                                ? _torrentDisplayPaths[index]
                                : _fileNameOnly(file.path);
                            return CheckboxListTile(
                              value: selected,
                              dense: true,
                              controlAffinity: ListTileControlAffinity.leading,
                              onChanged: (value) {
                                setState(() {
                                  if (value == true) {
                                    _selectedFileIndexes.add(file.index);
                                  } else {
                                    _selectedFileIndexes.remove(file.index);
                                  }
                                });
                              },
                              title: Text(displayPath, maxLines: 1),
                              subtitle: Text(_formatSize(file.length)),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _saveDirController,
                decoration: const InputDecoration(
                  labelText: '保存目录',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _pickSaveDirectory,
              child: const Text('选择目录'),
            ),
          ],
        ),
      ],
    );
  }

  String _formatSize(int bytes) {
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

  double _estimateFileListContentWidth() {
    var maxLength = 0;
    for (final path in _torrentDisplayPaths) {
      if (path.length > maxLength) {
        maxLength = path.length;
      }
    }

    const basePaddingWidth = 260.0;
    final textWidth = maxLength * 8.2;
    return basePaddingWidth + textWidth;
  }

  List<String> _buildDisplayPaths(List<TorrentTaskFile> files) {
    if (files.isEmpty) return const [];

    final normalized = files.map((file) => _normalizePath(file.path)).toList();
    if (normalized.length == 1) {
      return [_fileNameOnly(normalized.first)];
    }

    final commonPrefix = _commonPathPrefix(normalized);
    return normalized.map((path) {
      var value = path;
      if (commonPrefix.isNotEmpty && value.startsWith(commonPrefix)) {
        value = value.substring(commonPrefix.length);
      }
      if (value.startsWith('/')) {
        value = value.substring(1);
      }
      if (value.isEmpty) {
        return _fileNameOnly(path);
      }
      return value;
    }).toList();
  }

  String _commonPathPrefix(List<String> paths) {
    if (paths.isEmpty) return '';
    var prefix = paths.first;
    for (final path in paths.skip(1)) {
      var i = 0;
      final max = prefix.length < path.length ? prefix.length : path.length;
      while (i < max && prefix.codeUnitAt(i) == path.codeUnitAt(i)) {
        i++;
      }
      prefix = prefix.substring(0, i);
      if (prefix.isEmpty) break;
    }

    final lastSlash = prefix.lastIndexOf('/');
    if (lastSlash <= 0) return '';
    return prefix.substring(0, lastSlash + 1);
  }

  String _normalizePath(String path) => path.replaceAll('\\', '/');

  String _fileNameOnly(String path) {
    final normalized = _normalizePath(path);
    final parts = normalized.split('/');
    return parts.isEmpty ? normalized : parts.last;
  }

  String _sourceTypeLabel() {
    if (widget.preparedRequest.torrentPath != null) {
      return 'Torrent 文件';
    }
    final url = widget.preparedRequest.url ?? '';
    if (_isMagnetUrl(url)) {
      return 'Magnet 链接';
    }
    final uri = Uri.tryParse(url);
    final scheme = (uri?.scheme ?? '').toLowerCase();
    if (scheme == 'https') {
      return 'HTTPS 链接';
    }
    if (scheme == 'http') {
      return 'HTTP 链接';
    }
    if (scheme == 'ftp') {
      return 'FTP 链接';
    }
    return '普通链接';
  }

  bool _isMagnetUrl(String value) {
    return value.toLowerCase().startsWith('magnet:?');
  }
}
