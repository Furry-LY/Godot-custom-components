@icon('res://images/__node_icon__/joystick.svg')
extends Control
class_name Joystick
## 针对移动端的多指触控移动摇杆


@export
var max_radius: int = 150  ## [code]stick[/code]移动的最大范围
@export
var max_trigger_radius: int = 160  ## 摇杆触发的最大范围
@export
var base_texture: Texture2D
@export
var stick_texture: Texture2D
@export
var offset_pos: Vector2i
@export_range(0.25, 5)
var base_scale: float = 1   ## [code]base[/code]纹理的显示缩放
@export_range(0.25, 5)
var stick_scale: float = 1  ## [code]stick[/code]纹理的显示缩放

var base: TextureRect   ## 摇杆底盘纹理
var stick: TextureRect  ## 摇杆握把纹理

var _event_id: int = -1  ## 握持摇杆的手指索引
var _printed_error: bool = false  ## 是否已经输出过错误


func _ready() -> void:
	base = TextureRect.new()
	stick = TextureRect.new()
	
	add_child(base)
	add_child(stick)
	
	base.texture = base_texture
	stick.texture = stick_texture

	base.pivot_offset_ratio = Vector2(0.5, 0.5)
	stick.pivot_offset_ratio = Vector2(0.5, 0.5)


func _process(_delta: float) -> void:
	if base_texture == null or stick_texture == null:
		if _printed_error: return
		Console.error('[Joystick] No joystick texture set.')
		_printed_error = true
		return
	if not base_texture.get_size() == stick_texture.get_size():
		if _printed_error: return
		Console.error('[Joystick] The sizes of the textures must be the same.')
		_printed_error = true
		return
	
	if _event_id == -1:
		stick.position += (Vector2(0, 0) - stick.position) * 0.2
	
	base.scale = Vector2.ONE * base_scale
	stick.scale = Vector2.ONE * stick_scale
	
	offset_top = -base.size.y + base.size.y * (1.1-base_scale) * 0.5 - offset_pos.y
	offset_left = -base.size.x * (1.1-base_scale) * 0.5 + offset_pos.x


func _input(event: InputEvent) -> void:
	if event is InputEventScreenDrag or (event is InputEventScreenTouch and event.is_pressed()):
		
		var event_length = (event.position - global_position - base.size / 2 ).length()
		
		if event.index == _event_id or event_length <= max_trigger_radius:
			stick.global_position = event.position - stick.size / 2 * stick.scale
			
			if event_length > max_radius:
				stick.position = stick.position.normalized() * max_radius
			
			_event_id = event.index
	
	if event is InputEventScreenTouch and not event.is_pressed():
		if event.index == _event_id:
			_event_id = -1


## 获取归一化移动方向向量
func get_vector() -> Vector2:
	if _event_id == -1:
		return Vector2(0, 0)
	else:
		return stick.position.normalized() * stick.position.length() / max_radius


## 摇杆是否被按下
func is_pressed() -> bool:
	return false if _event_id == -1 else true
