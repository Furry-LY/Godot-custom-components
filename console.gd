## 调试用彩色日志输出类
extends Node

var output_text_array: Array
var display_values: Dictionary = {
	'console_output': 'debugging started.'
}


func _add_output_text_array(text: String) -> void:
	output_text_array.append(text)
	if len(output_text_array) > 3: output_text_array.pop_at(0)
	
	var _text: String = ''
	for i in output_text_array: _text += ('\t' + i + '\n')
	_text[-1] = ''
	_text = _text.replace('[b]', '')
	_text = _text.replace('[/b]', '')
	display_values.console_output = '\n' + _text


func error(...args: Array[Variant]) -> void:
	var text: String = ''
	for i in args: text += str(i)
	text = '[color=#ff7077]● [b]ERROR: [/b]' + text + '[/color]'
	_add_output_text_array(text)
	print_rich(text)


func warning(...args: Array[Variant]) -> void:
	var text: String = ''
	for i in args: text += str(i)
	text = '[color=#ffe28c]● [b]WARNING: [/b]' + text + '[/color]'
	_add_output_text_array(text)
	print_rich(text)


func info(...args: Array[Variant]) -> void:
	var text: String = ''
	for i in args: text += str(i)
	text = '[color=#2ed994]● [b]INFO: [/b]' + text + '[/color]'
	_add_output_text_array(text)
	print_rich(text)


func debug(...args: Array[Variant]) -> void:
	var text: String = ''
	for i in args: text += str(i)
	text = '● [b]DEBUG: [/b]' + text
	_add_output_text_array(text)
	print_rich(text)


func get_display_values() -> String:
	var text: String = ''
	for i in display_values:
		text += (
			'[color=#ffffffcc]' + str(i) + '[/color] :  '
			+ str(display_values.get(i, null)) + '\n'
			)
	return text
