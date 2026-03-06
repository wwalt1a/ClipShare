import 'dart:async';
import 'package:clipshare/app/services/config_service.dart';
import 'package:clipshare/app/services/transport/history_server_sync_integration.dart';
import 'package:clipshare/app/utils/log.dart';
import 'package:get/get.dart';

/// 定期同步服务
/// 负责定期推送队列和拉取操作日志
class PeriodicSyncService extends GetxService {
  static const tag = "PeriodicSyncService";

  final appConfig = Get.find<ConfigService>();
  late final HistoryServerSyncIntegration _syncIntegration;

  Timer? _timer;
  static const _syncInterval = Duration(minutes: 5); // 每5分钟同步一次

  @override
  void onInit() {
    super.onInit();
    if (Get.isRegistered<HistoryServerSyncIntegration>()) {
      _syncIntegration = Get.find<HistoryServerSyncIntegration>();
      _startPeriodicSync();
    }
  }

  @override
  void onClose() {
    _timer?.cancel();
    super.onClose();
  }

  void _startPeriodicSync() {
    if (!_isEnabled) {
      Log.info(tag, "_startPeriodicSync: 云端同步未启用，跳过定期同步");
      return;
    }

    Log.info(tag, "_startPeriodicSync: 启动定期同步，间隔 ${_syncInterval.inMinutes} 分钟");

    // 立即执行一次
    _performSync();

    // 定期执行
    _timer = Timer.periodic(_syncInterval, (_) {
      _performSync();
    });
  }

  void _performSync() async {
    if (!_isEnabled) {
      return;
    }

    try {
      Log.info(tag, "_performSync: 开始定期同步");
      await _syncIntegration.periodicSync();
      Log.info(tag, "_performSync: 定期同步完成");
    } catch (err, stack) {
      Log.error(tag, "_performSync: 定期同步异常", err, stack);
    }
  }

  bool get _isEnabled =>
      appConfig.forwardServer != null && appConfig.hasSyncPassword;

  /// 手动触发同步
  Future<void> triggerSync() async {
    Log.info(tag, "triggerSync: 手动触发同步");
    await _performSync();
  }

  /// 重启定期同步（配置更改后调用）
  void restart() {
    Log.info(tag, "restart: 重启定期同步");
    _timer?.cancel();
    _startPeriodicSync();
  }
}
