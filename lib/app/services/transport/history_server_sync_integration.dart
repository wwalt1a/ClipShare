import 'package:clipshare/app/data/repository/entity/tables/history.dart';
import 'package:clipshare/app/data/repository/entity/tables/history_tag.dart';
import 'package:clipshare/app/data/repository/entity/tables/server_operation_queue.dart';
import 'package:clipshare/app/services/config_service.dart';
import 'package:clipshare/app/services/db_service.dart';
import 'package:clipshare/app/services/tag_service.dart';
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
  TagService? tagService;

  @override
  void onInit() {
    super.onInit();
    if (Get.isRegistered<TagService>()) {
      tagService = Get.find<TagService>();
    }
  }

  bool get _isEnabled =>
      appConfig.forwardServer != null && appConfig.hasSyncPassword;

  /// 历史记录添加时调用
  Future<void> onHistoryAdded(History history, List<String> tags) async {
    if (!_isEnabled) return;

    try {
      Log.info(tag, "onHistoryAdded: historyId=${history.id}");

      // 加密内容
      String? encryptedContent;
      String itemType;

      if (history.type == 'text') {
        encryptedContent = serverSyncService.encrypt(history.content);
        itemType = 'text';
      } else {
        // 图片类型，content字段存储的是文件路径
        itemType = 'image';
      }

      // 添加 addItem 操作
      final addItemOp = ServerOperationQueue(
        type: 'addItem',
        itemId: history.id!,
        serverItemId: history.serverItemId,
        content: encryptedContent,
        fileId: itemType == 'image' ? history.content : null,
        itemType: itemType,
        createdAt: ServerOperationQueue.dateTimeToTimestamp(DateTime.parse(history.time)),
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
      Log.error(tag, "onHistoryAdded: 异常 $err", stack);
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
      Log.error(tag, "onHistoryDeleted: 异常 $err", stack);
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
      Log.error(tag, "onTagAdded: 异常 $err", stack);
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
      Log.error(tag, "onTagRemoved: 异常 $err", stack);
    }
  }

  /// 定期同步（推送队列 + 拉取操作）
  Future<void> periodicSync() async {
    if (!_isEnabled) return;

    try {
      Log.info(tag, "periodicSync: 开始定期同步");

      // 检查是否需要首次全量同步
      final lastPullTime = appConfig.lastServerPullTime ?? 0;
      if (lastPullTime == 0) {
        Log.info(tag, "periodicSync: 检测到首次同步，执行全量同步");
        final success = await queueSyncService.initSync();
        if (success) {
          Log.info(tag, "periodicSync: 首次全量同步成功");
          await appConfig.setLastServerPullTime(DateTime.now().millisecondsSinceEpoch);
        } else {
          Log.error(tag, "periodicSync: 首次全量同步失败");
          return;
        }
      }

      // 推送队列
      await queueSyncService.pushQueue();

      // 拉取操作日志
      final pullTime = DateTime.fromMillisecondsSinceEpoch(
        appConfig.lastServerPullTime ?? 0,
      );
      final operations = await queueSyncService.pullOperations(pullTime);

      if (operations.isNotEmpty) {
        Log.info(tag, "periodicSync: 拉取到 ${operations.length} 条操作，应用到本地");
        await _applyOperations(operations);
      }

      // 更新拉取时间
      await appConfig.setLastServerPullTime(DateTime.now().millisecondsSinceEpoch);

      // 清理队列
      await queueSyncService.cleanQueue();

      Log.info(tag, "periodicSync: 同步完成");
    } catch (err, stack) {
      Log.error(tag, "periodicSync: 异常 $err", stack);
    }
  }

  /// 应用操作到本地数据库
  Future<void> _applyOperations(List<Map<String, dynamic>> operations) async {
    for (final op in operations) {
      try {
        final type = op['type'] as String;
        final serverItemId = op['serverItemId'] as String?;

        Log.info(tag, "_applyOperations: 处理操作 type=$type, serverItemId=$serverItemId");

        switch (type) {
          case 'addItem':
            await _applyAddItem(op);
            break;
          case 'deleteItem':
            if (serverItemId != null) {
              await _applyDeleteItem(serverItemId);
            }
            break;
          case 'addTag':
            if (serverItemId != null) {
              await _applyAddTag(serverItemId, op['tagName'] as String);
            }
            break;
          case 'removeTag':
            if (serverItemId != null) {
              await _applyRemoveTag(serverItemId, op['tagName'] as String);
            }
            break;
          default:
            Log.warn(tag, "_applyOperations: 未知操作类型 $type");
        }
      } catch (err, stack) {
        Log.error(tag, "_applyOperations: 应用操作失败 $err", stack);
      }
    }
  }

  /// 应用添加记录操作
  Future<void> _applyAddItem(Map<String, dynamic> op) async {
    final serverItemId = op['itemId'] as String;
    final encryptedContent = op['content'] as String?;
    final fileId = op['fileId'] as String?;
    final itemType = op['itemType'] as String;
    final createdAtStr = op['createdAt'] as String;

    // 检查是否已存在
    final existing = await dbService.historyDao.getByServerItemId(serverItemId);
    if (existing != null) {
      Log.info(tag, "_applyAddItem: 记录已存在，跳过 serverItemId=$serverItemId");
      return;
    }

    // 解密内容
    String content;
    if (itemType == 'text') {
      if (encryptedContent == null) {
        Log.warn(tag, "_applyAddItem: 文本记录缺少内容");
        return;
      }
      content = serverSyncService.decrypt(encryptedContent);
    } else {
      // 图片类型，content是fileId
      content = fileId ?? '';
    }

    final createdAt = DateTime.parse(createdAtStr);

    // 创建历史记录
    final history = History(
      id: 0, // 自动生成
      uid: appConfig.userId,
      content: content,
      type: itemType,
      time: createdAt.toIso8601String(),
      devId: appConfig.device.guid,
      size: content.length,
      serverItemId: serverItemId,
    );

    // 添加到数据库（不触发同步）
    final historyId = await dbService.historyDao.add(history);
    if (historyId > 0) {
      Log.info(tag, "_applyAddItem: 添加记录成功 historyId=$historyId, serverItemId=$serverItemId");
    }
  }

  /// 应用删除记录操作
  Future<void> _applyDeleteItem(String serverItemId) async {
    final history = await dbService.historyDao.getByServerItemId(serverItemId);
    if (history == null) {
      Log.info(tag, "_applyDeleteItem: 记录不存在，跳过 serverItemId=$serverItemId");
      return;
    }

    await dbService.historyDao.deleteByCascade(history.id);
    Log.info(tag, "_applyDeleteItem: 删除记录成功 historyId=${history.id}, serverItemId=$serverItemId");
  }

  /// 应用添加标签操作
  Future<void> _applyAddTag(String serverItemId, String encryptedTagName) async {
    final history = await dbService.historyDao.getByServerItemId(serverItemId);
    if (history == null) {
      Log.warn(tag, "_applyAddTag: 记录不存在 serverItemId=$serverItemId");
      return;
    }

    // 解密标签名
    final tagName = serverSyncService.decrypt(encryptedTagName);

    // 确保tagService已初始化
    if (tagService == null && Get.isRegistered<TagService>()) {
      tagService = Get.find<TagService>();
    }

    if (tagService == null) {
      Log.error(tag, "_applyAddTag: TagService未注册，无法添加标签");
      return;
    }

    // 添加标签（不触发同步）
    final historyTag = HistoryTag(tagName, history.id);
    await tagService!.add(historyTag, false);
    Log.info(tag, "_applyAddTag: 添加标签成功 historyId=${history.id}, tag=$tagName");
  }

  /// 应用移除标签操作
  Future<void> _applyRemoveTag(String serverItemId, String encryptedTagName) async {
    final history = await dbService.historyDao.getByServerItemId(serverItemId);
    if (history == null) {
      Log.warn(tag, "_applyRemoveTag: 记录不存在 serverItemId=$serverItemId");
      return;
    }

    // 解密标签名
    final tagName = serverSyncService.decrypt(encryptedTagName);

    // 确保tagService已初始化
    if (tagService == null && Get.isRegistered<TagService>()) {
      tagService = Get.find<TagService>();
    }

    if (tagService == null) {
      Log.error(tag, "_applyRemoveTag: TagService未注册，无法移除标签");
      return;
    }

    // 查找标签
    final existingTag = await dbService.historyTagDao.getByHistoryIdAndName(history.id, tagName);
    if (existingTag == null) {
      Log.info(tag, "_applyRemoveTag: 标签不存在，跳过 historyId=${history.id}, tag=$tagName");
      return;
    }

    // 移除标签（不触发同步）
    await tagService!.remove(existingTag, false);
    Log.info(tag, "_applyRemoveTag: 移除标签成功 historyId=${history.id}, tag=$tagName");
  }
}
