import 'dart:io';
import 'package:clipshare/app/data/repository/entity/tables/history.dart';
import 'package:clipshare/app/data/repository/entity/tables/history_tag.dart';
import 'package:clipshare/app/data/repository/entity/tables/server_operation_queue.dart';
import 'package:clipshare/app/data/enums/history_content_type.dart';
import 'package:clipshare/app/modules/history_module/history_controller.dart';
import 'package:clipshare/app/utils/constants.dart';
import 'package:clipshare/app/utils/extensions/string_extension.dart';
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
      Log.info(tag, "onHistoryAdded: historyId=${history.id}, type='${history.type}', contentLength=${history.content.length}");

      // 加密内容
      String? encryptedContent;
      String itemType;

      // 规范化类型字符串，处理可能的空格和大小写问题
      final normalizedType = history.type.trim().toLowerCase();

      if (normalizedType == 'text') {
        encryptedContent = serverSyncService.encrypt(history.content);
        itemType = 'text';
      } else if (normalizedType == 'image') {
        // 图片类型：先上传文件到服务器获得 fileId
        itemType = 'image';
        final uploadedFileId = await serverSyncService.uploadImageForSync(history.content);
        if (uploadedFileId == null) {
          Log.warn(tag, 'onHistoryAdded: 图片上传失败，跳过 historyId=${history.id}');
          return;
        }
        // 添加 addItem 操作，fileId 使用服务器返回的 ID
        final addItemOp = ServerOperationQueue(
          type: 'addItem',
          itemId: history.id!,
          serverItemId: history.serverItemId,
          fileId: uploadedFileId,
          itemType: itemType,
          createdAt: ServerOperationQueue.dateTimeToTimestamp(DateTime.parse(history.time)),
        );
        await queueSyncService.addOperation(addItemOp);
        Log.info(tag, 'onHistoryAdded: 图片已上传并加入队列 fileId=$uploadedFileId');
        return;
      } else {
        Log.error(tag, "onHistoryAdded: 不支持的记录类型 type='${history.type}' (normalized='$normalizedType'), historyId=${history.id}");
        return;
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

      // 添加标签操作（使用与 addItem 相同的时间戳，避免 since 时间窗口漏掉标签）
      for (final tagName in tags) {
        final encryptedTag = serverSyncService.encrypt(tagName);
        final addTagOp = ServerOperationQueue(
          type: 'addTag',
          itemId: history.id!,
          serverItemId: history.serverItemId,
          tagName: encryptedTag,
          createdAt: ServerOperationQueue.dateTimeToTimestamp(DateTime.parse(history.time)),
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
        // 操作应用完成后刷新 UI
        try {
          if (Get.isRegistered<HistoryController>()) {
            Get.find<HistoryController>().refreshData();
          }
        } catch (e) {
          Log.warn(tag, "periodicSync: 刷新UI失败 $e");
        }
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
        final serverItemId = op['itemId'] as String?;  // 服务器返回的字段名是 itemId
        final tagName = op['tagName'] as String?;

        // 详细日志：输出完整操作数据
        Log.info(tag, "_applyOperations: 处理操作 type=$type, itemId=$serverItemId, tagName=$tagName, 完整数据=${op.toString()}");

        switch (type) {
          case 'addItem':
            await _applyAddItem(op);
            break;
          case 'deleteItem':
            if (serverItemId != null) {
              await _applyDeleteItem(serverItemId);
            } else {
              Log.warn(tag, "_applyOperations: deleteItem 缺少 itemId");
            }
            break;
          case 'addTag':
            if (serverItemId != null && tagName != null) {
              await _applyAddTag(serverItemId, tagName);
            } else {
              Log.warn(tag, "_applyOperations: addTag 缺少必要字段 itemId=$serverItemId, tagName=$tagName");
            }
            break;
          case 'removeTag':
            if (serverItemId != null && tagName != null) {
              await _applyRemoveTag(serverItemId, tagName);
            } else {
              Log.warn(tag, "_applyOperations: removeTag 缺少必要字段 itemId=$serverItemId, tagName=$tagName");
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
    Log.info(tag, "_applyAddItem: 开始处理 op=$op");

    final serverItemId = op['itemId'] as String;
    final encryptedContent = op['content'] as String?;
    final fileId = op['fileId'] as String?;
    final itemType = op['itemType'] as String;
    final createdAtStr = op['createdAt'] as String;

    Log.info(tag, "_applyAddItem: 参数解析完成 serverItemId=$serverItemId, itemType=$itemType, fileId=$fileId, encryptedContent长度=${encryptedContent?.length ?? 0}");

    // 检查是否已存在（按 serverItemId）
    Log.info(tag, "_applyAddItem: 检查记录是否已存在 serverItemId=$serverItemId");
    final existing = await dbService.historyDao.getByServerItemId(serverItemId);
    if (existing != null) {
      Log.info(tag, "_applyAddItem: 记录已存在，跳过 serverItemId=$serverItemId, existingHistoryId=${existing.id}");
      return;
    }
    Log.info(tag, "_applyAddItem: 记录不存在，继续添加");

    // 解密内容
    String content;
    Log.info(tag, "_applyAddItem: 开始处理内容 itemType=$itemType");
    if (itemType == 'text') {
      if (encryptedContent == null) {
        Log.warn(tag, "_applyAddItem: 文本记录缺少内容 serverItemId=$serverItemId");
        return;
      }
      Log.info(tag, "_applyAddItem: 开始解密文本内容");
      content = serverSyncService.decrypt(encryptedContent);
      Log.info(tag, "_applyAddItem: 解密完成 content长度=${content.length}");
    } else {
      // 图片类型：从服务器下载文件保存到本地
      if (fileId == null || fileId.isEmpty) {
        Log.warn(tag, '_applyAddItem: 图片记录缺少 fileId serverItemId=$serverItemId');
        return;
      }
      final bytes = await serverSyncService.downloadSyncImage(fileId);
      if (bytes == null) {
        Log.warn(tag, '_applyAddItem: 图片下载失败 fileId=$fileId');
        return;
      }
      final fileName = '$fileId.png';
      final dirPath = Platform.isAndroid
          ? (appConfig.saveToPictures
              ? '${Constants.androidPicturesPath}/${Constants.appName}'
              : appConfig.androidPrivatePicturesPath)
          : appConfig.fileStorePath;
      final filePath = '$dirPath/$fileName';
      final file = File(filePath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      content = file.path.normalizePath;
      Log.info(tag, '_applyAddItem: 图片已保存 filePath=$filePath');
    }

    // 按内容和来源设备去重（防止P2P路径已添加，服务器路径再次添加）
    final sourceDevId = op['devId'] as String? ?? '';
    if (sourceDevId.isNotEmpty && itemType == 'text') {
      final existingByContent = await dbService.historyDao.getByContentAndDevId(content, sourceDevId);
      if (existingByContent != null) {
        // 已存在，只更新 serverItemId
        if (existingByContent.serverItemId == null || existingByContent.serverItemId!.isEmpty) {
          await dbService.historyDao.updateServerFields(existingByContent.id, serverItemId, null);
          Log.info(tag, "_applyAddItem: P2P记录已存在，更新serverItemId serverItemId=$serverItemId");
        } else {
          Log.info(tag, "_applyAddItem: 内容已存在，跳过 serverItemId=$serverItemId");
        }
        return;
      }
    }

    Log.info(tag, "_applyAddItem: 解析创建时间 createdAtStr=$createdAtStr");
    final createdAt = DateTime.parse(createdAtStr);

    // 转换类型为数据库格式（首字母大写）
    final dbType = HistoryContentType.parse(itemType).value;
    Log.info(tag, "_applyAddItem: 类型转换 itemType=$itemType -> dbType=$dbType");

    // 创建历史记录
    Log.info(tag, "_applyAddItem: 创建History对象");
    final history = History(
      id: appConfig.snowflake.nextId(),
      uid: appConfig.userId,
      content: content,
      type: dbType,
      time: createdAt.toLocal().toString(),
      devId: sourceDevId.isNotEmpty ? sourceDevId : appConfig.device.guid,
      size: content.length,
      serverItemId: serverItemId,
      sync: true, // 来自服务器同步，标记为已同步，避免显示未同步图标
    );

    // 添加到数据库（不触发同步）
    Log.info(tag, "_applyAddItem: 准备添加到数据库");
    final historyId = await dbService.historyDao.add(history);
    Log.info(tag, "_applyAddItem: 数据库添加完成 historyId=$historyId");
    if (historyId > 0) {
      Log.info(tag, "_applyAddItem: 添加记录成功 historyId=$historyId, serverItemId=$serverItemId");
    } else {
      Log.error(tag, "_applyAddItem: 添加记录失败 historyId=$historyId, serverItemId=$serverItemId");
      return; // Exit early — don't proceed if DB add failed
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
