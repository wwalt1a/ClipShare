import 'dart:convert';
import 'package:clipshare/app/data/repository/entity/tables/history.dart';
import 'package:clipshare/app/data/repository/entity/tables/server_operation_queue.dart';
import 'package:clipshare/app/services/config_service.dart';
import 'package:clipshare/app/services/db_service.dart';
import 'package:clipshare/app/services/transport/server_sync_service.dart';
import 'package:clipshare/app/utils/log.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

/// 服务器操作队列同步服务
/// 负责将本地操作队列同步到服务器
class ServerQueueSyncService extends GetxService {
  static const tag = "ServerQueueSyncService";

  final appConfig = Get.find<ConfigService>();
  final dbService = Get.find<DbService>();
  final serverSyncService = Get.find<ServerSyncService>();

  bool get _isEnabled =>
      appConfig.forwardServer != null && appConfig.hasSyncPassword;

  String get _apiBase => appConfig.forwardServer!.apiBase;
  String get _groupId => appConfig.syncGroupId;
  String get _devId => appConfig.device.guid;

  /// 首次全量同步
  Future<bool> initSync() async {
    if (!_isEnabled) {
      Log.warn(tag, "initSync: 云端同步未启用");
      return false;
    }

    try {
      Log.info(tag, "initSync: 开始首次全量同步");

      // 获取所有历史记录
      final histories = await dbService.historyDao.getAll();
      Log.info(tag, "initSync: 找到 ${histories.length} 条历史记录");

      if (histories.isEmpty) {
        Log.info(tag, "initSync: 无数据需要同步");
        return true;
      }

      final items = <Map<String, dynamic>>[];

      for (final history in histories) {
        // 获取标签
        final tags = await dbService.historyTagDao.getAllByHisId(history.id!);
        final encryptedTags = tags.map((t) => serverSyncService.encrypt(t.name)).toList();

        String? encryptedContent;
        String? fileId;
        String itemType;

        if (history.type == 'text') {
          encryptedContent = serverSyncService.encrypt(history.content);
          itemType = 'text';
        } else {
          fileId = history.fileId;
          itemType = 'image';
        }

        items.add({
          'itemId': history.serverItemId ?? history.id.toString(),
          'type': itemType,
          'content': encryptedContent,
          'fileId': fileId,
          'tags': encryptedTags,
          'createdAt': history.time.toUtc().toIso8601String(),
        });
      }

      final uri = Uri.parse('$_apiBase/api/sync/init');
      final body = jsonEncode({
        'groupId': _groupId,
        'devId': _devId,
        'items': items,
      });

      Log.info(tag, "initSync: 请求 $uri, 同步 ${items.length} 条记录");

      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: body,
      );

      if (response.statusCode == 200) {
        final result = jsonDecode(response.body);
        if (result['code'] == 200) {
          Log.info(tag, "initSync: 全量同步成功");
          return true;
        }
      }

      Log.error(tag, "initSync: 同步失败 ${response.statusCode} ${response.body}");
      return false;
    } catch (err, stack) {
      Log.error(tag, "initSync: 异常", err, stack);
      return false;
    }
  }

  /// 推送操作队列到服务器（带重试）
  Future<bool> pushQueue() async {
    if (!_isEnabled) {
      return false;
    }

    int retryCount = 0;
    const maxRetries = 3;
    const retryDelays = [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ];

    while (retryCount <= maxRetries) {
      try {
        // 获取未同步的操作
        final operations = await dbService.serverOpQueueDao.getUnsyncedOperations();
        if (operations.isEmpty) {
          return true;
        }

        Log.info(tag, "pushQueue: 推送 ${operations.length} 条操作 (尝试 ${retryCount + 1}/${maxRetries + 1})");

        final ops = <Map<String, dynamic>>[];
        for (final op in operations) {
          ops.add({
            'type': op.type,
            'itemId': op.serverItemId ?? op.itemId.toString(),
            'content': op.content,
            'fileId': op.fileId,
            'itemType': op.itemType,
            'tagName': op.tagName,
            'createdAt': op.createdAtDateTime.toUtc().toIso8601String(),
          });
        }

        final uri = Uri.parse('$_apiBase/api/sync/push');
        final body = jsonEncode({
          'groupId': _groupId,
          'devId': _devId,
          'operations': ops,
        });

        final response = await http.post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: body,
        ).timeout(const Duration(seconds: 30));

        if (response.statusCode == 200) {
          final result = jsonDecode(response.body);
          if (result['code'] == 200) {
            // 标记为已同步
            final ids = operations.map((o) => o.id!).toList();
            await dbService.serverOpQueueDao.markAllAsSynced(ids);
            Log.info(tag, "pushQueue: 推送成功");
            return true;
          }
        }

        Log.error(tag, "pushQueue: 推送失败 ${response.statusCode}");

        // 如果不是最后一次尝试，等待后重试
        if (retryCount < maxRetries) {
          final delay = retryDelays[retryCount];
          Log.info(tag, "pushQueue: ${delay.inSeconds}秒后重试...");
          await Future.delayed(delay);
          retryCount++;
          continue;
        }

        return false;
      } catch (err, stack) {
        Log.error(tag, "pushQueue: 异常", err, stack);

        // 如果不是最后一次尝试，等待后重试
        if (retryCount < maxRetries) {
          final delay = retryDelays[retryCount];
          Log.info(tag, "pushQueue: ${delay.inSeconds}秒后重试...");
          await Future.delayed(delay);
          retryCount++;
          continue;
        }

        return false;
      }
    }

    return false;
  }

  /// 从服务器拉取操作日志（带重试）
  Future<List<Map<String, dynamic>>> pullOperations(DateTime since) async {
    if (!_isEnabled) {
      return [];
    }

    int retryCount = 0;
    const maxRetries = 3;
    const retryDelays = [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ];

    while (retryCount <= maxRetries) {
      try {
        final uri = Uri.parse('$_apiBase/api/sync/pull').replace(queryParameters: {
          'groupId': _groupId,
          'since': since.toUtc().toIso8601String(),
        });

        Log.info(tag, "pullOperations: 请求 $uri (尝试 ${retryCount + 1}/${maxRetries + 1})");

        final response = await http.get(uri).timeout(const Duration(seconds: 30));

        if (response.statusCode == 200) {
          final result = jsonDecode(response.body);
          if (result['code'] == 200 && result['data'] != null) {
            final operations = (result['data']['operations'] as List)
                .map((e) => e as Map<String, dynamic>)
                .toList();
            Log.info(tag, "pullOperations: 拉取到 ${operations.length} 条操作");
            return operations;
          }
        }

        Log.error(tag, "pullOperations: 拉取失败 ${response.statusCode}");

        // 如果不是最后一次尝试，等待后重试
        if (retryCount < maxRetries) {
          final delay = retryDelays[retryCount];
          Log.info(tag, "pullOperations: ${delay.inSeconds}秒后重试...");
          await Future.delayed(delay);
          retryCount++;
          continue;
        }

        return [];
      } catch (err, stack) {
        Log.error(tag, "pullOperations: 异常", err, stack);

        // 如果不是最后一次尝试，等待后重试
        if (retryCount < maxRetries) {
          final delay = retryDelays[retryCount];
          Log.info(tag, "pullOperations: ${delay.inSeconds}秒后重试...");
          await Future.delayed(delay);
          retryCount++;
          continue;
        }

        return [];
      }
    }

    return [];
  }

  /// 添加操作到队列
  Future<void> addOperation(ServerOperationQueue operation) async {
    await dbService.serverOpQueueDao.add(operation);
    // 尝试立即推送
    await pushQueue();
  }

  /// 清理队列
  Future<void> cleanQueue() async {
    await dbService.serverOpQueueDao.cleanQueue();
  }
}

