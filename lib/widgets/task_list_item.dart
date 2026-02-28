import 'package:flutter/material.dart';
import 'package:flutter_aria2/flutter_aria2.dart';

import '../models/download_task.dart';

class TaskListItem extends StatelessWidget {
  const TaskListItem({
    super.key,
    required this.task,
    required this.onPause,
    required this.onResume,
    required this.onRetry,
    required this.onRemove,
  });

  final DownloadTask task;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onRetry;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final statusColor = _statusColor(task.status, colorScheme);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    task.displayName,
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
                    color: statusColor.withAlpha(24),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _statusText(task.status),
                    style: TextStyle(
                      color: statusColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: task.isComplete ? 1 : task.progress,
              minHeight: 6,
              borderRadius: BorderRadius.circular(4),
              backgroundColor: colorScheme.surfaceContainerHighest,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('${(task.progress * 100).toStringAsFixed(1)}%'),
                Text(
                  '${_formatSize(task.completedLength)} / ${_formatSize(task.totalLength)}',
                ),
                if (task.isActive)
                  Text(
                    '${_formatSpeed(task.downloadSpeed)} · ${task.connections} 连接',
                  ),
                if (task.isError) Text('错误码: ${task.errorCode}'),
                Text(
                  '保存至: ${task.saveDir}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: [
                if (task.isActive)
                  OutlinedButton.icon(
                    onPressed: onPause,
                    icon: const Icon(Icons.pause, size: 16),
                    label: const Text('暂停'),
                  ),
                if (task.isPaused || task.isWaiting)
                  OutlinedButton.icon(
                    onPressed: onResume,
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: const Text('恢复'),
                  ),
                if (task.isError)
                  OutlinedButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('重试'),
                  ),
                TextButton.icon(
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('移除'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
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
        return '失败';
      case Aria2DownloadStatus.removed:
        return '已移除';
    }
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
}
