## 用于与 DeepSeek API 进行交互的节点
@icon('res://images/__node_icon__/deepseek.svg')
class_name DeepSeek
extends Node

#region __配置变量__
## [code]sk-xxx[/code] 格式的 DeepSeek API 密钥
@export_multiline var api_key: String
## 启用思考模式
@export var deepseek: bool = false
## 使用的模型
@export_enum('deepseek-v4-pro', 'deepseek-flash')
var model: String = 'deepseek-flash'
## AI 输出最大 token 数
@export var max_tokens: int = 2048
## 回答随机度
@export_range(0.2, 2.0, 0.05) var temperature: float = 0.8
## DeepSeek API 请求 URL
const BASE_URL: Dictionary = {
	'HOST': 'api.deepseek.com',
	'URL': '/v1/chat/completions'
	}
## 对话角色
const ROLE: Dictionary = {
	'SYSTEM': 'system',
	'USER': 'user',
	'AI': 'assistant',
	'TOOL': 'tool'
	}
## DeepSeek 模型
const MODEL: Dictionary= {
	'DS_V4_PRO': 'deepseek-v4-pro',
	'DS_FLASH': 'deepseek-flash'
}
## SSE 流状态
enum StreamStatus {
	ERROR,            ## SSE 流出现错误
	REQUEST,          ## 正在向 API 提交请求
	THINKING,         ## 正在返回 reasoning 字段
	ANSWERING,        ## 正在返回 content 字段
	TOOLCALLING,      ## 正在返回 tool calls 字段
	TOOLCALLED,       ## SSE 流结束 - tool call
	TOOLCALL_RETURN,  ## tool 返回结果中
	STOP              ## SSE 流结束 - 回答完毕
	}


## 消息发送成功时发出
signal send_message_over()
## HTTP 连接出错时发出
signal network_error(error: HTTPClient.Status)
## 获得一个 thinking 文本增量时发出
signal get_thinking_delta(message: String)
## 获得一个 answer 文本增量时发出
signal get_answer_delta(message: String)
## 思考链结束后发出
signal think_over(message: String)
## 回复完成后发出
signal answer_over(message: String)

#endregion


#region __私有变量__
# 用于网络请求的 HTTPClient
var _http_client: HTTPClient
# HTTP 请求头
var _headers: PackedStringArray
# HTTP 请求体
var _body: String
# 可供 AI 调用的工具
var _tools: Array[Dictionary]
# AI 调用的工具
var _tool_calls: Array[Dictionary]
# 工具回调函数表
var _tools_callable_map: Dictionary
# 对话时临时指向外部 记录对话历史的Array 的指针
var _message_pointer: Array[Dictionary]
# 响应头
var _resp_headers: Dictionary
# 暂存 API 返回的 bytes 数据包
var _sse_bytes_buffer: PackedByteArray
# 暂存 API 返回的 SSE 数据流的缓冲区
var _sse_datas_buffer: String
# 回复的 thinking 字符串
var _thinking_content: String
# 回复的 answer 字符串
var _answer_content: String
# 上一帧 sse 流的状态
var _previous_frame_stream_status: StreamStatus = StreamStatus.STOP
# 上一个增量是否在思考
var _previous_delta_is_reasoning: bool = false

#endregion


#region __私有函数__
func _ready() -> void:
	_http_client = HTTPClient.new()
	_connect_to_server()
	_set_headers()


func _process(delta: float) -> void:
	_http_client.poll()
	
	if _http_client.get_status() == HTTPClient.STATUS_BODY:
		var resp_headers: Dictionary = _http_client.get_response_headers_as_dictionary()
		var resp: PackedByteArray = _http_client.read_response_body_chunk()
		
		if resp_headers.has('Content-Type'): _resp_headers = resp_headers
		
		if _resp_headers['Content-Type'] == 'text/event-stream; charset=utf-8':
			_sse_bytes_buffer.append_array(resp)
		else:
			_sse_datas_buffer += resp.get_string_from_utf8()
	
	if _http_client.get_status() in [
		HTTPClient.STATUS_CANT_RESOLVE, 
		HTTPClient.STATUS_CANT_CONNECT, 
		HTTPClient.STATUS_CONNECTION_ERROR
		]:
		
		if (_http_client.get_status() == HTTPClient.STATUS_CONNECTION_ERROR
			and _previous_frame_stream_status == StreamStatus.STOP):
			Console.warning('[DeepSeek] The server disconnected.')
		else:
			Console.error('[DeepSeek] Network error - id: ', _http_client.get_status())
			_previous_frame_stream_status = StreamStatus.ERROR
			network_error.emit(_http_client.get_status())
		_http_client.close()
		_set_buffers()
	
	if not _sse_bytes_buffer.is_empty():
		_process_sse_bytes()
	
	if not _sse_datas_buffer.is_empty():
		_read_server_event()


func _set_headers() -> void:
	_headers = PackedStringArray([
	'Host: api.deepseek.com',
	'Authorization: Bearer ' + api_key,
	'Content-Type: application/json'
	])


func _set_body() -> void:
	var _deepseek: bool = deepseek
	if (
	_previous_frame_stream_status == StreamStatus.TOOLCALL_RETURN
	and not _answer_content.is_empty()
	and deepseek
	):
		_deepseek = false
	
	_body = JSON.stringify({
		'model': model,
		'stream': true,
		'tools': _tools,
		'max_tokens': max_tokens,
		'temperature': temperature,
		'messages': _message_pointer,
		'thinking': {'type': ['disabled', 'enabled'][int(_deepseek)]}
	})


func _set_buffers() -> void:
	_previous_frame_stream_status = StreamStatus.STOP
	_previous_delta_is_reasoning = false
	_sse_bytes_buffer.clear()
	_sse_datas_buffer = ''
	_thinking_content = ''
	_answer_content = ''
	_message_pointer = []
	_tool_calls.clear()


func _connect_to_server() -> void:
	_http_client.close()
	_http_client.connect_to_host(BASE_URL.HOST, 443, TLSOptions.client())


func _run_tools() -> void:
	if _tool_calls.is_empty(): return
	
	var called_tool_names: Array[String]
	var ai_tool_calls_message: Dictionary
	var tool_results_messages: Array[Dictionary]
	
	# 初始化 AI 调用工具消息
	ai_tool_calls_message = {
		'role': ROLE.AI,
		'content': _answer_content,
		'tool_calls': []
	}
	
	# 遍历调用的工具 执行并暂存调用结果消息
	for tool_info in _tool_calls:
		if _tools_callable_map.has(tool_info.func_name):
			var tool: Callable = _tools_callable_map[tool_info.func_name]
			var args: Variant = JSON.parse_string(tool_info.arguments)
			if args == null: args = {}
			
			var results: Variant = tool.call(args)
			
			called_tool_names.append(tool_info.func_name)
			
			# 添加 AI 调用的工具记录
			ai_tool_calls_message.tool_calls.append({
				'id': tool_info.id,
				'type': 'function',
				'function': {
					'name': tool_info.func_name,
					'arguments': tool_info.arguments}
			})
			
			# 添加工具返回结果消息
			tool_results_messages.append({
				'role': ROLE.TOOL,
				'tool_call_id': tool_info.id,
				'content': results
			})
		
	# 拼接消息到 message
	_message_pointer.append(ai_tool_calls_message)
	_message_pointer.append_array(tool_results_messages)
	
	_previous_frame_stream_status = StreamStatus.TOOLCALL_RETURN
	send_message('deepseek.gd', 'pass', [{'message': 'tool_call_return_send', 'called_tools': called_tool_names}])


func _add_ai_message() -> void:
	if _answer_content.is_empty(): return
	_message_pointer.append({
		'role': ROLE.AI,
		'content': _answer_content
	})


func _process_sse_bytes() -> void:
	var try_convert_string: String = _sse_bytes_buffer.get_string_from_utf8()
	if try_convert_string.to_utf8_buffer() == _sse_bytes_buffer:
		_sse_datas_buffer += try_convert_string
		_sse_bytes_buffer.clear()


func _read_server_event() -> void:
	# 检查 API 是否返回错误
	if (_sse_datas_buffer.begins_with('{"error"')
		or _sse_datas_buffer.begins_with('Authentication Fails')):
		_previous_frame_stream_status = StreamStatus.ERROR
		Console.error('[DeepSeek] API Error: ', _sse_datas_buffer)
		_sse_datas_buffer = ''
		return
	
	# 检查缓冲区是否有完整事件
	if not '\n\n' in _sse_datas_buffer: return
	
	# 从事件缓冲区取出第一个事件
	var first_event_pos: int = _sse_datas_buffer.find('\n\n')
	var first_event: String = _sse_datas_buffer.substr(0, first_event_pos)
	_sse_datas_buffer = _sse_datas_buffer.substr(first_event_pos + 2)
	
	# 去掉 data: 开头
	var data_string: String = first_event.substr(6)
	
	# 判断增量类型
	var current_delta_type: StreamStatus
	# 回答结束
	if data_string == '[DONE]':
		if _previous_frame_stream_status == StreamStatus.TOOLCALLING:
			current_delta_type = StreamStatus.TOOLCALLED
			_previous_frame_stream_status = current_delta_type
			return _run_tools()
		else:
			current_delta_type = StreamStatus.STOP
			_previous_frame_stream_status = current_delta_type
			_add_ai_message()
			_message_pointer = []
			answer_over.emit(_answer_content)
			return 
	
	# delta 字符串转字典
	var delta: Dictionary = JSON.parse_string(data_string)
	if delta == null:
		Console.error('[DeepSeek] The string is not a dict: ', data_string)
		return
	delta = delta.get('choices', [{}])[0].get('delta')
	
	# reasoning 增量
	if (not delta.get('reasoning_content', null) == null
		and not _previous_frame_stream_status == StreamStatus.TOOLCALLING): 
		get_thinking_delta.emit(delta.reasoning_content)
		_thinking_content += delta.reasoning_content
		_previous_delta_is_reasoning = true
		current_delta_type = StreamStatus.THINKING
	
	# answer 增量
	if not delta.get('content', null) == null:
		if _previous_frame_stream_status == StreamStatus.TOOLCALLING:
			current_delta_type = StreamStatus.TOOLCALLING
		else:
			if _previous_delta_is_reasoning:
				think_over.emit(_thinking_content)
				_previous_delta_is_reasoning = false
			
			get_answer_delta.emit(delta.content)
			_answer_content += delta.content
			current_delta_type = StreamStatus.ANSWERING
	
	# tool_calls 增量
	if not delta.get('tool_calls', null) == null:
		var tool_call_info: Dictionary = delta['tool_calls'][0]
		current_delta_type = StreamStatus.TOOLCALLING
		# 建立一个 tool_call
		if tool_call_info.has('id'):
			_tool_calls.append({
				'id': tool_call_info.id,
				'func_name': tool_call_info.function.name,
				'arguments': tool_call_info.function.arguments
			})
		# 追加 tool_call 参数
		else:
			_tool_calls[int(tool_call_info.index)
			].arguments += tool_call_info.function.arguments
	
	_previous_frame_stream_status = current_delta_type

#endregion


#region __外部方法__
## 发送一条消息
func send_message(role: String, content: String, messages: Array[Dictionary]) -> void:
	# 如果 AI 正在回复 - 返回
	if not _previous_frame_stream_status == StreamStatus.STOP:
		if len(messages) == 1:
			if not messages[0].get('message', 'null') == 'tool_call_return_send':
				return
		else:
			return
	
	# 判断 http client 连接状态 | 尝试1次重连 失败则退出函数
	_http_client.poll()
	if not _http_client.get_status() == HTTPClient.STATUS_CONNECTED:
		_connect_to_server()
		await get_tree().create_timer(1.25).timeout
		_http_client.poll()
	if not _http_client.get_status() == HTTPClient.STATUS_CONNECTED:
		Console.error('[DeepSeek] Not connected to the server.')
		network_error.emit(HTTPClient.STATUS_CANT_CONNECT)
		return
	
	# 不为 toolcall return 调用该函数时初始化 buffers 和 message pointer
	if not _previous_frame_stream_status == StreamStatus.TOOLCALL_RETURN:
		_set_buffers()
		_message_pointer = messages
		_message_pointer.append({'role': role, 'content': content})
	
	_set_body()
	_tool_calls.clear()
	
	_previous_frame_stream_status = StreamStatus.REQUEST
	
	var error: Error = _http_client.request(
		HTTPClient.METHOD_POST,
		BASE_URL.URL,
		_headers, _body
	)
	
	if error == OK and len(messages) >= 1:
		if not messages[0].get('message', 'null') == 'tool_call_return_send':
			Console.info('[DeepSeek] Send message.')
			send_message_over.emit()
		else:
			Console.info('[DeepSeek] Send tool ', messages[0].get('called_tools', ['null']), ' result.')
	else:
		Console.error('[DeepSeek] Send message failed.')


## 添加工具
func add_tool(tool: Dictionary, callback: Callable) -> void:
	if tool.get('function', {}).get('name', '').is_empty():
		Console.error('[DeepSeek] The format of the added tool is incorrect.')
		return
	
	if _tools_callable_map.has(tool['function']['name']):
		Console.warning('[DeepSeek] Tool "' + tool['function']['name'] + '" is registered')
		return
	
	_tools_callable_map[tool['function']['name']] = callback
	_tools.append(tool.duplicate_deep())


## 删除工具
func remove_tool(tool_name: String) -> void:
	if not _tools_callable_map.has(tool_name):
		Console.warning('[DeepSeek] The tool ' + tool_name + ' does not exist.')
		return
	
	_tools_callable_map.erase(tool_name)
	var index: int = 0
	for i in _tools:
		if i['function']['name'] == tool_name:
			_tools.remove_at(index)
			break
		index += 1


## 停止 AI 输出
func stop() -> void:
	_http_client.close()
	_set_buffers()
	_connect_to_server()

#region __setter__
## 设置 [code]api_key[/code]
func set_api_key(key: String) -> void:
	api_key = key
	_set_headers()

## 设置使用模型（可通过常量 [code]MODEL[/code] 设置）
##[codeblock]DeepSeek.MODEL.DS_ModelName[/codeblock]
func set_model(model_name: String) -> void:
	if not MODEL.find_key(model_name) == null:
		model = model_name
	else:
		Console.warning("[DeepSeek] Does not have model 「", model_name, "」")

## 设置思考模式
func set_deepseek(open: bool = true) -> void:
	deepseek = open

## 设置最大输出 token 量
func set_max_tokens(num: int = 1024) -> void:
	max_tokens = max(1, num)

## 设置模型回复随机度
func set_temperature(num: float = 0.8) -> void:
	temperature = min(max(0.0, num), 2.0)

#endregion __setter__


#region __getter__
## 获取当前 api key
func get_api_key() -> String:
	return api_key

## 获取当前模型名称
func get_current_model() -> String:
	return model

## 获取当前思考模式
func get_deepseek() -> bool:
	return deepseek

## 获取当前输出最大 token
func get_max_tokens() -> int:
	return max_tokens

## 获取当前模型回复随机度
func get_temperature() -> float:
	return temperature

#endregion __getter__

#endregion

## Script END.
