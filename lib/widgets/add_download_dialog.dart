import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/add_download_request.dart';

enum AddDownloadPresentation { dialog, sheet }

class AddDownloadDialog extends StatefulWidget {
  const AddDownloadDialog({
    super.key,
    this.presentation = AddDownloadPresentation.dialog,
  });

  final AddDownloadPresentation presentation;

  @override
  State<AddDownloadDialog> createState() => _AddDownloadDialogState();
}

class _AddDownloadDialogState extends State<AddDownloadDialog> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _saveDirController = TextEditingController();

  String? _torrentPath;
  String? _torrentName;

  @override
  void initState() {
    super.initState();
    _saveDirController.text =
        '${Directory.systemTemp.path}${Platform.pathSeparator}flutter_aria2_downloads';
  }

  @override
  void dispose() {
    _urlController.dispose();
    _saveDirController.dispose();
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
    final url = _urlController.text.trim();
    final saveDir = _saveDirController.text.trim();

    final hasUrl = url.isNotEmpty;
    final hasTorrent = _torrentPath != null && _torrentPath!.isNotEmpty;

    if (!hasUrl && !hasTorrent) {
      _showMessage('请输入下载链接或选择种子文件');
      return;
    }

    if (saveDir.isEmpty) {
      _showMessage('请选择保存目录');
      return;
    }

    Navigator.of(context).pop(
      AddDownloadRequest(
        url: hasUrl ? url : null,
        torrentPath: hasTorrent ? _torrentPath : null,
        torrentName: _torrentName,
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
                        '添加下载任务',
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
      title: const Text('添加下载任务'),
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
}
