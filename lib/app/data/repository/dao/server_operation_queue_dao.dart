import 'package:floor/floor.dart';
import '../entity/tables/server_operation_queue.dart';

@dao
abstract class ServerOperationQueueDao {
  /// 添加操作到队列
  @Insert(onConflict: OnConflictStrategy.replace)
  Future<int> add(ServerOperationQueue operation);

  /// 批量添加操作
  @Insert(onConflict: OnConflictStrategy.replace)
  Future<List<int>> addAll(List<ServerOperationQueue> operations);

  /// 获取所有未同步的操作
  @Query('SELECT * FROM ServerOperationQueue WHERE synced = 0 AND invalid = 0 ORDER BY createdAt ASC')
  Future<List<ServerOperationQueue>> getUnsyncedOperations();

  /// 标记操作为已同步
  @Query('UPDATE ServerOperationQueue SET synced = 1 WHERE id = :id')
  Future<void> markAsSynced(int id);

  /// 批量标记为已同步
  @Query('UPDATE ServerOperationQueue SET synced = 1 WHERE id IN (:ids)')
  Future<void> markAllAsSynced(List<int> ids);

  /// 标记操作为无效
  @Query('UPDATE ServerOperationQueue SET invalid = 1 WHERE id = :id')
  Future<void> markAsInvalid(int id);

  /// 标记针对某个itemId的所有操作为无效（当记录被删除时）
  @Query('UPDATE ServerOperationQueue SET invalid = 1 WHERE itemId = :itemId AND synced = 0')
  Future<void> markItemOperationsAsInvalid(int itemId);

  /// 删除已同步的操作
  @Query('DELETE FROM ServerOperationQueue WHERE synced = 1')
  Future<void> deleteSyncedOperations();

  /// 删除无效的操作
  @Query('DELETE FROM ServerOperationQueue WHERE invalid = 1')
  Future<void> deleteInvalidOperations();

  /// 清理队列（删除已同步和无效的操作）
  Future<void> cleanQueue() async {
    await deleteSyncedOperations();
    await deleteInvalidOperations();
  }

  /// 获取队列中的操作数量
  @Query('SELECT COUNT(*) FROM ServerOperationQueue WHERE synced = 0 AND invalid = 0')
  Future<int?> getUnsyncedCount();

  /// 根据itemId和type查询操作
  @Query('SELECT * FROM ServerOperationQueue WHERE itemId = :itemId AND type = :type AND synced = 0 ORDER BY createdAt DESC LIMIT 1')
  Future<ServerOperationQueue?> getLatestOperationByItemAndType(int itemId, String type);
}
