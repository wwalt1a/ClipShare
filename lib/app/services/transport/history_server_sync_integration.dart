import 'package:clipshare/app/data/repository/entity/tables/history.dart';
import 'package:clipshare/app/data/repository/entity/tables/server_operation_queue.dart';
import 'package:clipshare/app/services/config_service.dart';
import 'package:clipshare/app/services/db_service.dart';
import 'package:clipshare/app/services/transport/server_queue_sync_service.dart';
import 'package:clipshare/app/services/transport/server_sync_service.dart';
import 'package:clipshare/app/utils/log.dart';
import 'package:get/get.dart';

/// 历史记录服务器同步集成服务
/// 负责在历史记录变更时自动添加到操作队列
class HistoryServerSyncIntegration extends GetxService {
  static const tag = "HistoryServerSyncIntegration";

  final appConfig = Get.find<ConfigService>();
  final dbService = Get.find<DbService>();
  final serverSyncService = Get.find<ServerSyncService>();
  final queueSyncService = Get.find<ServerQueueSyncService>();

  bool get _isEnabled =>
      appConfig.forwardServer != null && appConfig.hasSyncPassword;

  /// 历史记录添加时调用
  Future<void> onHistoryAdded(History history, List<String> tags) async {
    if (!_isEnabled) return;

    try {
      Log.info(tag, "onHistoryAdded: historyId=${history.id}");

      // 加密内容
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

      // 添加 addItem 操作
      final addItemOp = ServerOperationQueue(
        type: 'addItem',
        itemId: history.id!,
        serverItemId: history.serverItemId,
        content: encryptedContent,
        fileId: fileId,
        itemType: itemType,
        createdAt: ServerOperationQueue.dateTimeToTimestamp(history.time),
      );
      await queueSyncService.addOperation(addItemOp);

      // 添加标签操作
      for (final tagName in tags) {
        final encryptedTag = serverSyncService.encrypt(tagName);
        final addTagOp = ServerOperationQueue(
          type: 'addTag',
          itemId: history.id!,
          serverItemId: history.serverItemId,
          tagName: encryptedTag,
          createdAt: ServerOperationQueue.dateTimeToTimestamp(DateTime.now()),
        );
        await queueSyncService.addOperation(addTagOp);
      }

      Log.info(tag, "onHistoryAdded: 已添加到队列");
    } catch (err, stack) {
      Log.error(tag, "onHistoryAdded: 异常", err, stack);
    }
  }

  /// 历史记录删除时调用
  Future<void> onHistoryDeleted(int historyId, String? serverItemId) async {
    if (!_isEnabled) return;

    try {
      Log.info(tag, "onHistoryDeleted: historyId=$historyId");

      // 标记该记录的所有未同步操作为无效
      await dbService.serverOpQueueDao.markItemOperationsAsInvalid(historyId);

      // 如果有 serverItemId，添加删除操作
      if (serverItemId != null) {
        final deleteOp = ServerOperationQueue(
          type: 'deleteItem',
          itemId: historyId,
          serverItemId: serverItemId,
          createdAt: ServerOperationQueue.dateTimeToTimestamp(DateTime.now()),
        );
        await queueSyncService.addOperation(deleteOp);
      }

      Log.info(tag, "onHistoryDeleted: 已添加删除操作");
    } catch (err, stack) {
      Log.error(tag, "onHistoryDeleted: 异常", err, stack);
    }
  }

  /// 标签添加时调用
  Future<void> onTagAdded(int historyId, String? serverItemId, String tagName) async {
    if (!_isEnabled) return;

    try {
      Log.info(tag, "onTagAdded: historyId=$historyId, tag=$tagName");

      final encryptedTag = serverSyncService.encrypt(tagName);
      final addTagOp = ServerOperationQueue(
        type: 'addTag',
        itemId: historyId,
        serverItemId: serverItemId,
        tagName: encryptedTag,
        createdAt: ServerOperationQueue.dateTimeToTimestamp(DateTime.now()),
      );
      await queueSyncService.addOperation(addTagOp);

      Log.info(tag, "onTagAdded: 已添加到队列");
    } catch (err, stack) {
      Log.error(tag, "onTagAdded: 异常", err, stack);
    }
  }

  /// 标签移除时调用
  Future<void> onTagRemoved(int historyId, String? serverItemId, String tagName) async {
    if (!_isEnabled) return;

    try {
      Log.info(tag, "onTagRemoved: historyId=$historyId, tag=$tagName");

      final encryptedTag = serverSyncService.encrypt(tagName);
      final removeTagOp = ServerOperationQueue(
        type: 'removeTag',
        itemId: historyId,
        serverItemId: serverItemId,
        tagName: encryptedTag,
        createdAt: ServerOperationQueue.dateTimeToTimestamp(DateTime.now()),
      );
      await queueSyncService.addOperation(removeTagOp);

      Log.info(tag, "onTagRemoved: 已添加到队列");
    } catch (err, stack) {
      Log.error(tag, "onTagRemoved: 异常", err, stack);
    }
  }

  /// 定期同步（推送队列 + 拉取操作）
  Future<void> periodicSync() async {
    if (!_isEnabled) return;

    try {
      Log.info(tag, "periodicSync: 开始定期同步");

      // 推送队列
      await queueSyncService.pushQueue();

      // 拉取操作日志
      final lastPullTime = DateTime.fromMillisecondsSinceEpoch(
        appConfig.lastServerPullTime ?? 0,
      );
      final operations = await queueSyncService.pullOperations(lastPullTime);

      if (operations.isNotEmpty) {
        Log.info(tag, "periodicSync: 拉取到 ${operations.length} 条操作，需要应用到本地");
        // TODO: 应用操作到本地数据库
      }

      // 更新拉取时间
      await appConfig.setLastServerPullTime(DateTime.now().millisecondsSinceEpoch);

      // 清理队列
      await queueSyncService.cleanQueue();

      Log.info(tag, "periodicSync: 同步完成");
    } catch (err, stack) {
      Log.error(tag, "periodicSync: 异常", err, stack);
    }
  }
}
