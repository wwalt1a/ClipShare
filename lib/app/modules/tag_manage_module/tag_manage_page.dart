import 'package:clipshare/app/data/enums/translation_key.dart';
import 'package:clipshare/app/modules/history_module/history_controller.dart';
import 'package:clipshare/app/services/db_service.dart';
import 'package:clipshare/app/utils/global.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// 标签管理页面 - 支持批量选择并删除标签（不影响被打标签的剪贴板内容）
class TagManagePage extends StatefulWidget {
  const TagManagePage({super.key});

  @override
  State<TagManagePage> createState() => _TagManagePageState();
}

class _TagManagePageState extends State<TagManagePage> {
  final dbService = Get.find<DbService>();

  List<String> _allTags = [];
  final Set<String> _selected = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadTags();
  }

  Future<void> _loadTags() async {
    final tags = await dbService.historyTagDao.getAllTagNames();
    setState(() {
      _allTags = tags;
      _loading = false;
    });
  }

  void _toggleSelect(String tag) {
    setState(() {
      if (_selected.contains(tag)) {
        _selected.remove(tag);
      } else {
        _selected.add(tag);
      }
    });
  }

  void _selectAll() {
    setState(() {
      _selected.addAll(_allTags);
    });
  }

  void _clearSelect() {
    setState(() {
      _selected.clear();
    });
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("确认删除"),
        content: Text(
          "将删除 ${_selected.length} 个标签，被打了这些标签的剪贴板内容不受影响。\n\n确认继续？",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(TranslationKey.dialogCancelText.tr),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(TranslationKey.dialogConfirmText.tr),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    Global.showLoadingDialog(context: context);
    try {
      await dbService.historyTagDao.removeByTagNames(_selected.toList());
      _selected.clear();
      await _loadTags();
      Get.back(); // 关闭 loading
      Global.showSnackBarSuc(
        context: context,
        text: "标签已删除",
      );
      // 通知历史页面刷新标签列表
      if (Get.isRegistered<HistoryController>()) {
        Get.find<HistoryController>().debounceUpdate();
      }
    } catch (e) {
      Get.back();
      Global.showSnackBarWarn(context: context, text: "删除失败: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("标签管理"),
        actions: [
          if (_allTags.isNotEmpty)
            TextButton(
              onPressed: _selected.length == _allTags.length
                  ? _clearSelect
                  : _selectAll,
              child: Text(
                _selected.length == _allTags.length ? "取消全选" : "全选",
              ),
            ),
          if (_selected.isNotEmpty)
            IconButton(
              onPressed: _deleteSelected,
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              tooltip: "删除选中标签",
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _allTags.isEmpty
              ? const Center(child: Text("暂无标签"))
              : Column(
                  children: [
                    if (_selected.isNotEmpty)
                      Container(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            Text(
                              "已选 ${_selected.length} 个",
                              style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onPrimaryContainer,
                              ),
                            ),
                            const Spacer(),
                            TextButton.icon(
                              onPressed: _deleteSelected,
                              icon: const Icon(Icons.delete_outline,
                                  color: Colors.red, size: 18),
                              label: const Text(
                                "删除选中",
                                style: TextStyle(color: Colors.red),
                              ),
                            ),
                          ],
                        ),
                      ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _allTags.length,
                        itemBuilder: (context, i) {
                          final tag = _allTags[i];
                          final isSelected = _selected.contains(tag);
                          return CheckboxListTile(
                            value: isSelected,
                            onChanged: (_) => _toggleSelect(tag),
                            title: Row(
                              children: [
                                const Icon(Icons.label_outline,
                                    size: 18, color: Colors.blueGrey),
                                const SizedBox(width: 8),
                                Text(tag),
                              ],
                            ),
                            controlAffinity: ListTileControlAffinity.leading,
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}
