extends SceneTree
## GodotBuilder CLI 独立入口（Godot 无头 CLI 运行，不进 CI）：转发到共享核心 CliCommands。[br][br]
## 运行：godot --headless --path <本项目> --script res://tools/cli.gd -- <命令> [参数][br][br]
## 退出码：0 成功 / 1 执行失败 / 2 参数或环境错误。

## 命令核心（引用 class_name，由 Godot 类表解析，不 preload 路径）。
var _commands: CliCommands = null


func _initialize() -> void:
	# 协程须由 _initialize 启动：_init 阶段主循环未开始，await 不会恢复
	_run()


## 执行 CLI 命令并以结果码退出。
func _run() -> void:
	_commands = CliCommands.new()
	var code: int = await _commands.run(OS.get_cmdline_user_args())
	quit(code)
