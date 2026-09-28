extends Node
## Tiny translation layer. English is the source language: every UI string is
## written in English at the call site and passed through `t()`. That keeps the
## code readable and means an untranslated string still shows something sensible
## (the English source) instead of a raw key.
##
## Adding a language = adding one dictionary below. Adding a string = adding one
## line to each dictionary; miss it and you get English, never a crash.

signal changed

const LANGS := ["en", "zh"]
const LANG_NAMES := {"en": "English", "zh": "中文"}

var lang := "en"

## English source -> Simplified Chinese.
const ZH := {
	# ---- title
	"a voxel sandbox   -   dig, build, explore": "体素沙盒 —— 挖掘、建造、探索",
	"CREATE NEW WORLD": "创建新世界",
	"LOAD WORLD": "载入世界",
	"SETTINGS": "设置",
	"QUIT GAME": "退出游戏",
	"WASD move   SPACE jump   MOUSE look   LMB dig   RMB place   E inventory   T chat   / command   F3 debug":
		"WASD 移动   空格 跳跃   鼠标 视角   左键 挖掘   右键 放置   E 背包   T 聊天   / 命令   F3 调试",

	# ---- create world
	"World name": "世界名称",
	"Seed (empty = random)": "种子（留空随机）",
	"Random": "随机",
	"Game mode": "游戏模式",
	"Creative": "创造",
	"Survival": "生存",
	"Render distance": "渲染距离",
	"%d chunks": "%d 区块",
	"chunks": "区块",
	"CREATE": "创建",
	"BACK": "返回",
	"Survival: health, fall damage, drowning, drops.\nCreative: double-tap SPACE to fly, instant mining,\nendless blocks in the inventory.":
		"生存：生命、摔落伤害、溺水、掉落物。\n创造：双击空格飞行、瞬间挖掘、\n背包内方块无限。",

	# ---- world list
	"SELECT A WORLD": "选择世界",
	"   No saved worlds yet.": "   还没有已保存的世界。",
	"Delete": "删除",

	# ---- settings
	"VIDEO": "画面",
	"PLAYER": "角色",
	"AUDIO": "声音",
	"GAME": "游戏",
	"Field of view": "视野范围",
	"Mouse sensitivity": "鼠标灵敏度",
	"Quality": "画质",
	"Low": "低",
	"Medium": "中",
	"High": "高",
	"Fullscreen": "全屏",
	"V-Sync": "垂直同步",
	"View bobbing": "视角摇晃",
	"Show FPS": "显示帧率",
	"Max framerate": "最大帧率",
	"Unlimited": "不限",
	"Render pack": "光影包",
	"Classic": "经典",
	"Soft": "柔和",
	"Vibrant": "鲜艳",
	"Language": "语言",
	"Allow cheats (commands)": "允许作弊（命令）",
	"Distant fog": "远景迷雾",
	"Fog distance": "迷雾距离",
	"Chunk load budget": "区块生成预算",
	"Skin: %s   (press F5 for third person)": "皮肤：%s   （按 F5 切换视角）",
	"Skin file: %s": "皮肤文件：%s",
	"Load skin file...   (64x64 / 64x32 PNG)": "载入皮肤文件……（64x64 / 64x32 PNG）",
	"Pick a Minecraft skin (64x64, 64x32 or an HD multiple)":
		"选择一张 Minecraft 皮肤（64x64、64x32 或高清倍数）",
	"Could not read that file as an image.": "无法读取该图片文件。",
	"Not a Minecraft skin: %s.": "不是 Minecraft 皮肤：%s。",
	"ON": "开",
	"OFF": "关",

	# ---- pause / death / loading
	"GAME PAUSED": "游戏已暂停",
	"BACK TO GAME": "返回游戏",
	"SAVE GAME": "保存游戏",
	"SAVE AND QUIT TO TITLE": "保存并返回标题",
	"Coordinates, seed and chunk info are on the F3 screen.": "坐标、种子与区块信息在 F3 界面。",
	"YOU DIED!": "你死了！",
	"Respawn to keep building.": "重生后继续建造。",
	"RESPAWN": "重生",
	"QUIT TO TITLE": "返回标题",
	"GENERATING WORLD": "正在生成世界",

	# ---- HUD / inventory
	"INVENTORY": "背包",
	"CRAFTING": "合成",
	"BLOCKS  (click to take a stack)": "方块（点击取一整叠）",
	"BACKPACK": "物品栏",
	"HOTBAR": "快捷栏",
	"Drag items into the grid.": "把物品拖进网格。",

	# ---- toasts / camera
	"World saved  (%d blocks changed)": "世界已保存（%d 个方块变更）",
	"Screenshot saved": "截图已保存",
	"Camera: %s": "视角：%s",
	"first person": "第一人称",
	"third person (behind)": "第三人称（身后）",
	"second person (front)": "第二人称（正面）",

	# ---- chat / console / commands
	"VoxelCraft console  -  /help lists commands": "VoxelCraft 控制台 —— /help 查看命令列表",
	"Unknown command: %s. Try /help.": "未知命令：%s。输入 /help 查看列表。",
	"Unknown command: %s.": "未知命令：%s。",
	"Cheats are disabled for this world.": "这个世界已禁用作弊。",
	"%s needs a higher permission level.": "%s 需要更高的权限等级。",
	"%d commands. Type /help <command> for detail.": "共 %d 条命令。输入 /help <命令> 查看详情。",
	"Position: %.1f %.1f %.1f  (chunk %d %d, %s)":
		"坐标：%.1f %.1f %.1f（区块 %d %d，%s）",
	"creative": "创造",
	"survival": "生存",
	"Seed: %d": "种子：%d",
	"Game mode set to %s.": "游戏模式已设为 %s。",
	"No block or item named %s.": "没有名为 %s 的方块或物品。",
	"Gave %d x %s.": "已给予 %d 个 %s。",
	"Inventory cleared.": "背包已清空。",
	"Time set to %.2f.": "时间已设为 %.2f。",
	"There is no weather yet; the sky is always clear.": "暂时还没有天气，天空永远是晴的。",
	"Teleported to %.1f %.1f %.1f.": "已传送到 %.1f %.1f %.1f。",
	"Teleported to the world spawn.": "已传送到世界出生点。",
	"Flight is creative-only. Try /gamemode creative.": "飞行仅限创造模式。试试 /gamemode creative。",
	"Flight %s.": "飞行 %s。",
	"Health and hunger restored.": "生命与饥饿值已恢复。",
	"You died.": "你死了。",
	"Fog reset to automatic.": "迷雾已恢复自动。",
	"Fog distance scale set to %.2f.": "迷雾距离倍率已设为 %.2f。",
	"Render distance set to %d chunks.": "渲染距离已设为 %d 区块。",

	# ---- block / item names
	"Air": "空气",
	"Stone": "石头",
	"Grass Block": "草方块",
	"Dirt": "泥土",
	"Cobblestone": "圆石",
	"Oak Planks": "橡木木板",
	"Oak Log": "橡木原木",
	"Oak Leaves": "橡木树叶",
	"Sand": "沙子",
	"Glass": "玻璃",
	"Water": "水",
	"Bedrock": "基岩",
	"Coal Ore": "煤矿石",
	"Iron Ore": "铁矿石",
	"Gold Ore": "金矿石",
	"Diamond Ore": "钻石矿石",
	"Gravel": "砂砾",
	"Sandstone": "砂岩",
	"Bricks": "砖块",
	"Glowstone": "萤石",
	"Obsidian": "黑曜石",
	"Snow Block": "雪块",
	"Ice": "冰",
	"Grass": "草",
	"Poppy": "虞美人",
	"Dandelion": "蒲公英",
	"Cactus": "仙人掌",
	"Torch": "火把",
	"Crafting Table": "工作台",
	"Stick": "木棍",
	"Coal": "煤炭",
	"Iron Ingot": "铁锭",
	"Gold Ingot": "金锭",
	"Diamond": "钻石",
	"Apple": "苹果",
	"Bread": "面包",

	# ---- building blocks
	"Stone Bricks": "石砖",
	"Block of Iron": "铁块",
	"Block of Gold": "金块",
	"Block of Diamond": "钻石块",
	"Oak Fence": "橡木栅栏",
	"Ladder": "梯子",
	"Glass Pane": "玻璃板",
	"Oak Door": "橡木门",
	"Chest": "箱子",

	# ---- power system
	"Copper Ore": "铜矿石",
	"Copper Ingot": "铜锭",
	"Battery": "电池",
	"Wire": "导线",
	"Inverter": "反相器",
	"Switch": "开关",
	"Lamp": "电灯",
	"Signal Relay": "中继器",
	"Button": "按钮",
	"Piston": "活塞",
	"Pressure Plate": "压力板",
	"Piston Arm": "活塞臂",

	# ---- tooltip descriptions
	"A block. Place it, or build with it.": "一个方块。可以放置或用来搭建。",
	"An item.": "一个物品。",
	"Cut stone. A tidy building block.": "切制石料。整洁的建筑方块。",
	"Nine iron in one block. Storage, or a sturdy build.": "九块铁锭合成。可存储，也可用于坚固的建筑。",
	"Nine gold in one block.": "九块金锭合成。",
	"Nine diamonds in one block.": "九颗钻石合成。",
	"A fence. Keeps things in, and out.": "栅栏。挡在里面，也挡在外面。",
	"Climb a wall with it.": "用它攀爬墙壁。",
	"A thin pane of glass.": "薄薄的一片玻璃。",
	"A door. Right-click to open it.": "一扇门。右键开关。",
	"A chest for storage.": "用于存储的箱子。",
	"Ore. Drops copper, the metal the wire is drawn from.": "矿石。掉落铜，导线就是用它拉出来的。",
	"A cell. Always live, so wire it straight to a load.": "电池。始终有电，可以直接接到负载上。",
	"Refined copper. The conductor the wire is made of.": "精炼铜。导线的导体材料。",
	"Copper conductor laid on the ground. It drops 1 level per block, so a run dies out after 15.":
		"铺在地面的铜导线。每格衰减 1 级，超过 15 格信号就会消失。",
	"A NOT gate. Its output is live while its input is dead, and dark when the input is driven.":
		"非门。输入无电时输出带电，输入被驱动时输出断电。",
	"A knife switch. Right-click to open or close the circuit.": "闸刀开关。右键接通或断开电路。",
	"A momentary switch. Springs back on its own.": "瞬时开关。会自动弹回。",
	"A sensor. Live while something stands on it.": "传感器。有东西站上去时输出信号。",
	"A diode with a delay: passes signal one way, at full strength, after a short wait. Right-click to aim it.":
		"带延迟的二极管：只单向导通，短暂延时后以满强度重新输出。右键调整朝向。",
	"An indicator. Lights up when powered.": "指示灯。通电时亮起。",
	"An actuator. Powered, it shoves the block in front one cell on.":
		"执行器。通电时把前方的方块向前推动一格。",
}


## Translates a UI string. Unknown strings fall through unchanged, so a missing
## entry is a cosmetic gap rather than a broken screen.
func t(s: String) -> String:
	if lang == "zh":
		return str(ZH.get(s, s))
	return s


## Translates a format string and then substitutes. Keeps `%d`/`%s` placeholders
## working no matter which language is active, because the substitution happens
## after the lookup.
func tf(s: String, values: Array) -> String:
	return t(s) % values


func lang_index() -> int:
	return maxi(0, LANGS.find(lang))


func set_lang(code: String) -> void:
	if not LANGS.has(code) or code == lang:
		return
	lang = code
	changed.emit()


func next_lang() -> String:
	lang = LANGS[(lang_index() + 1) % LANGS.size()]
	changed.emit()
	return lang