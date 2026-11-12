class_name DependencySelectionDialog
extends ConfirmationDialog
## 编译依赖选择对话框：勾选要安装的依赖项后确认，由调用方执行下载与解压。
##
## 候选来自引擎源码里上游 install_*.py 的解析结果，依赖被勾选才安装。

## 确认安装时发出，携带选中的依赖 id（可能为空）。
signal install_requested(dependency_ids: PackedStringArray)

## 依赖项行容器（场景内定义）
@export var items_container: VBoxContainer
## 说明标签（场景内定义）
@export var hint_label: Label

## 依赖 id → 勾选框
var _check_boxes: Dictionary[String, CheckBox] = {}


## 用候选依赖填充列表。[br][br]
## [param p_items] 每项含键：id(String)、tag(String)、target(String)。[br]
func setup(p_items: Array[Dictionary]) -> void:
	_clear_items()
	if p_items.is_empty():
		hint_label.text = "没有可安装的依赖（引擎源码里未找到上游安装脚本）"
		return
	hint_label.text = "勾选要安装的依赖"
	for item: Dictionary in p_items:
		_add_item(str(item.get("id", "")), str(item.get("tag", "")),
				str(item.get("target", "")))


## 当前选中的依赖 id。
func get_selected_ids() -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	for id: String in _check_boxes:
		if (_check_boxes[id] as CheckBox).button_pressed:
			result.append(id)
	return result


func _on_confirmed() -> void:
	install_requested.emit(get_selected_ids())

## 追加一行依赖勾选框（带版本号后缀），安装位置作悬浮提示。
func _add_item(p_id: String, p_tag: String, p_target: String) -> void:
	var check_box: CheckBox = CheckBox.new()
	check_box.text = p_id if p_tag.is_empty() else "%s（%s）" % [p_id, p_tag]
	check_box.button_pressed = true
	check_box.tooltip_text = "安装位置：%s" % p_target if not p_target.is_empty() else ""
	items_container.add_child(check_box)
	_check_boxes[p_id] = check_box

## 清空既有行（重复 setup 时不残留旧候选）。
func _clear_items() -> void:
	_check_boxes.clear()
	for child: Node in items_container.get_children():
		items_container.remove_child(child)
		child.queue_free()
