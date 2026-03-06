import 'package:clipshare/app/data/enums/module.dart';
import 'package:clipshare/app/data/enums/op_method.dart';
import 'package:clipshare/app/data/repository/entity/tables/history_tag.dart';
import 'package:clipshare/app/data/repository/entity/tables/operation_record.dart';
import 'package:clipshare/app/services/db_service.dart';
import 'package:clipshare/app/services/transport/history_server_sync_integration.dart';
import 'package:clipshare/app/utils/constants.dart';
import 'package:get/get.dart';

import '../listeners/tag_changed_listener.dart';

class TagService extends GetxService {
  final _dbService = Get.find<DbService>();
  late final HistoryServerSyncIntegration _serverSyncIntegration;
  final _tags = <int, Set<String>>{}.obs;
  final _tagNameCntMap = <String, int>{};
  final _listeners = List<TagChangedListener>.empty(growable: true);

  Future<TagService> init() async {
    // 延迟获取，因为可能还未注册
    if (Get.isRegistered<HistoryServerSyncIntegration>()) {
      _serverSyncIntegration = Get.find<HistoryServerSyncIntegration>();
    }
    final lst = await _dbService.historyTagDao.getAll();
    for (var tag in lst) {
      if (_tags.containsKey(tag.hisId)) {
        _tags[tag.hisId]!.add(tag.tagName);
      } else {
        _tags[tag.hisId] = <String>{}..add(tag.tagName);
      }
      if (_tagNameCntMap.containsKey(tag.tagName)) {
        _tagNameCntMap[tag.tagName] = _tagNameCntMap[tag.tagName]! + 1;
      } else {
        _tagNameCntMap[tag.tagName] = 1;
      }
    }
    return this;
  }

  Set<String> getTagList(int hisId) {
    if (_tags.containsKey(hisId)) {
      return _tags[hisId]!;
    } else {
      return <String>{};
    }
  }

  Future<void> _remove(HistoryTag tag, [bool notify = true]) async {
    await _dbService.historyTagDao.removeById(tag.id);
    if (_tags.containsKey(tag.hisId)) {
      if (_tags[tag.hisId]!.length == 1) {
        _tags.remove(tag.hisId);
      } else {
        _tags[tag.hisId] = Set.from(_tags[tag.hisId]!..remove(tag.tagName));
      }
    }

    if (notify) {
      var opRecord = OperationRecord.fromSimple(
        Module.tag,
        OpMethod.delete,
        tag.id.toString(),
      );
      //添加操作记录
      _dbService.opRecordDao.addAndNotify(opRecord);
    }

    if (_tagNameCntMap[tag.tagName] == 1) {
      _tagNameCntMap.remove(tag.tagName);
      _onChanged(tag.tagName, true);
    } else {
      _tagNameCntMap[tag.tagName] = _tagNameCntMap[tag.tagName]! - 1;
    }

    // 服务器同步集成：标签删除
    if (notify && Get.isRegistered<HistoryServerSyncIntegration>()) {
      final history = await _dbService.historyDao.getById(tag.hisId);
      if (history != null) {
        _serverSyncIntegration.onTagRemoved(tag.hisId, history.serverItemId, tag.tagName);
      }
    }
  }

  Future<bool> _add(HistoryTag tag, [bool notify = true]) async {
    var hasTag = _tags.containsKey(tag.hisId) ? _tags[tag.hisId]!.contains(tag.tagName) : false;
    if (hasTag) return false;

    // 添加到数据库
    var res = await _dbService.historyTagDao.add(tag) > 0;
    if (!res) {
      return false;
    }

    // 更新本地缓存
    if (_tags.containsKey(tag.hisId)) {
      _tags[tag.hisId] = (_tags[tag.hisId]!..add(tag.tagName));
    } else {
      _tags[tag.hisId] = <String>{}..add(tag.tagName);
    }

    if (_tagNameCntMap.containsKey(tag.tagName)) {
      _tagNameCntMap[tag.tagName] = _tagNameCntMap[tag.tagName]! + 1;
    } else {
      _tagNameCntMap[tag.tagName] = 1;
      _onChanged(tag.tagName, false);
    }

    // 仅在 notify=true 时添加操作记录和触发服务器同步
    if (notify) {
      var opRecord = OperationRecord.fromSimple(
        Module.tag,
        OpMethod.add,
        tag.id.toString(),
      );
      //添加操作记录
      _dbService.opRecordDao.addAndNotify(opRecord);

      // 服务器同步集成：标签添加
      if (Get.isRegistered<HistoryServerSyncIntegration>()) {
        final history = await _dbService.historyDao.getById(tag.hisId);
        if (history != null) {
          _serverSyncIntegration.onTagAdded(tag.hisId, history.serverItemId, tag.tagName);
        }
      }
    }

    return res;
  }

  ///添加
  Future<bool> add(HistoryTag tag, [bool notify = true]) async {
    return await _add(tag, notify);
  }

  ///批量添加
  Future<void> addList(Iterable<HistoryTag> tags, [bool notify = true]) async {
    for (var tag in tags) {
      await _add(tag, notify);
    }
  }

  ///删除 tag
  Future<void> remove(HistoryTag tag, [bool notify = true]) async {
    await _remove(tag, notify);
  }

  ///批量删除
  Future<void> removeList(
    Iterable<HistoryTag> tags, [
    bool notify = true,
  ]) async {
    for (var tag in tags) {
      await _remove(tag, notify);
    }
  }

  void _onChanged(String tagName, bool isDelete) {
    for (var listener in _listeners) {
      if (isDelete) {
        listener.onDistinctRemove(tagName);
      } else {
        listener.onDistinctAdd(tagName);
      }
    }
  }

  void addListener(TagChangedListener listener) {
    _listeners.add(listener);
  }

  void removeListener(TagChangedListener listener) {
    _listeners.remove(listener);
  }
}
