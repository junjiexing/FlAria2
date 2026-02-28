import 'dart:async';

import 'package:flutter/material.dart';

import '../models/add_download_request.dart';
import '../services/aria2_download_controller.dart';
import '../widgets/add_download_dialog.dart';
import '../widgets/task_list_item.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final Aria2DownloadController _controller = Aria2DownloadController();

  @override
  void initState() {
    super.initState();
    _controller.onInfo = _showSnackBar;
    _controller.onError = _showSnackBar;
    _controller.onDownloadCompleted = _showSnackBar;
    unawaited(_controller.start());
  }

  @override
  void dispose() {
    unawaited(_controller.close());
    _controller.dispose();
    super.dispose();
  }

  Future<void> _openAddDialog() async {
    final isMobileWidth = MediaQuery.of(context).size.width < 700;
    AddDownloadRequest? request;
    if (isMobileWidth) {
      request = await showModalBottomSheet<AddDownloadRequest>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => const FractionallySizedBox(
          heightFactor: 1,
          child: AddDownloadDialog(presentation: AddDownloadPresentation.sheet),
        ),
      );
    } else {
      request = await showDialog<AddDownloadRequest>(
        context: context,
        builder: (_) => const AddDownloadDialog(),
      );
    }

    if (!mounted || request == null) return;
    await _controller.addDownload(request);
  }

  void _openSettings() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsPage()));
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载任务'),
        actions: [
          IconButton(
            tooltip: '设置',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings),
          ),
          IconButton(
            tooltip: '添加下载',
            onPressed: _openAddDialog,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          if (_controller.isInitializing) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!_controller.isReady) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, size: 40),
                    const SizedBox(height: 12),
                    Text(_controller.initializationError ?? 'aria2 初始化失败'),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () => unawaited(_controller.start()),
                      child: const Text('重试初始化'),
                    ),
                  ],
                ),
              ),
            );
          }

          if (_controller.tasks.isEmpty) {
            return const Center(child: Text('暂无下载任务，点击右上角 + 添加'));
          }

          return ListView.builder(
            itemCount: _controller.tasks.length,
            itemBuilder: (context, index) {
              final task = _controller.tasks[index];
              return TaskListItem(
                task: task,
                onPause: () => unawaited(_controller.pauseTask(task)),
                onResume: () => unawaited(_controller.resumeTask(task)),
                onRetry: () => unawaited(_controller.retryTask(task)),
                onRemove: () => unawaited(_controller.removeTask(task)),
              );
            },
          );
        },
      ),
    );
  }
}
