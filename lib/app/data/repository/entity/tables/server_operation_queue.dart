import 'package:floor/floor.dart';

/// 服务器同步操作队列（用于离线操作缓存）
@Entity(tableName: 'ServerOperationQueue')
class ServerOperationQueue {
  @PrimaryKey(autoGenerate: true)
  final int? id;

  /// 操作类型：addItem, deleteItem, addTag, removeTag
  final String type;

  /// 关联的记录ID（historyId）
  final int itemId;

  /// 服务器端的itemId（如果有）
  final String? serverItemId;

  /// 标签名称（标签操作时使用，已加密）
  final String? tagName;

  /// 加密的内容（addItem时使用）
  final String? content;

  /// 文件ID（图片类型时使用）
  final String? fileId;

  /// 记录类型（addItem时使用：text/image）
  final String? itemType;

  /// 操作时间
  final DateTime createdAt;

  /// 是否已同步到服务器
  final bool synced;

  /// 是否无效（如操作已删除的记录）
  final bool invalid;

  ServerOperationQueue({
    this.id,
    required this.type,
    required this.itemId,
    this.serverItemId,
    this.tagName,
    this.content,
    this.fileId,
    this.itemType,
    required this.createdAt,
    this.synced = false,
    this.invalid = false,
  });

  ServerOperationQueue copyWith({
    int? id,
    String? type,
    int? itemId,
    String? serverItemId,
    String? tagName,
    String? content,
    String? fileId,
    String? itemType,
    DateTime? createdAt,
    bool? synced,
    bool? invalid,
  }) {
    return ServerOperationQueue(
      id: id ?? this.id,
      type: type ?? this.type,
      itemId: itemId ?? this.itemId,
      serverItemId: serverItemId ?? this.serverItemId,
      tagName: tagName ?? this.tagName,
      content: content ?? this.content,
      fileId: fileId ?? this.fileId,
      itemType: itemType ?? this.itemType,
      createdAt: createdAt ?? this.createdAt,
      synced: synced ?? this.synced,
      invalid: invalid ?? this.invalid,
    );
  }
}
