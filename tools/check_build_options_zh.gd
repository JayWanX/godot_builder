extends SceneTree
## 汉化覆盖检查工具（本地 CLI，不进 CI）：委托共享核心 CliCommands 的 check-options 命令。[br][br]
## 运行：godot --headless --path <本项目> --script res://tools/check_build_options_zh.gd -- --engine-dir=<引擎源码目录>[br][br]
## 退出码：0 = 覆盖完整；1 = 存在缺失/过时/无效分组；2 = 参数或环境错误。

## 命令核心（引用 class_name，由 Godot 类表解析，不 preload 路径）。
var _commands: CliCommands = null


func _initialize() -> void:
	# 协程须由 _initialize 启动：_init 阶段主循环未开始，await 不会恢复
	_run()


## 执行检查并退出（把旧参数 --engine-dir 归一到共享核心的 --source）。
func _run() -> void:
	var cli_args: PackedStringArray = [CliCommands.CMD_CHECK_OPTIONS]
	for arg: String in OS.get_cmdline_user_args():
		cli_args.append(arg)
	_commands = CliCommands.new()
	var code: int = await _commands.run(cli_args)
	quit(code)
