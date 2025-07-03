extends Control

const DEBUG:=false

@export var log_ndi :RichTextLabel = null
@export var grid_ndi :Control = null
var group_mngr :MulticastGroup = null

# espera receber esses valores da main
var _egroup_ip :String = "" # Ip do grupo de emissores, não usado aqui
var rgroup_ip  :String = "" # Ip do grupo de servidores receptores
var network_interface:Dictionary = {"name":"", "friendly":"", "index":-1, "addresses":[]}

# Handler de mensagens
var next_expected_seq := 1
var holdback_buffer   := {} # {seq (int):payload (Variant)}
@onready var holdback_timer = Timer.new()

func _ready():
	if _egroup_ip.is_empty() || rgroup_ip.is_empty():
		breakpoint # Não recebeu valores esperados
	group_mngr = MulticastGroup.new(rgroup_ip, 9321, network_interface)
	group_mngr.message_received.connect(_on_message_received)
	add_child(group_mngr)
	var err := group_mngr.join_group()
	if err<0:
		log_line("[!] Falhou em entrar no grupo, err:{}.".format([err],"{}"))
		breakpoint
	log_line("[i] Entrou no grupo com sucesso.")
	group_mngr.cast_message("CTRL:PING".to_utf8_buffer())
	
	var response_timer := Timer.new()
	response_timer.wait_time = 1.0
	response_timer.one_shot = true
	response_timer.autostart = true
	response_timer.timeout.connect(func():
		if message_count==0: log_line("[i] Ninguém respondeu o ping dentro de 3s.")
		else:
			log_line("[i] {} membros responderam ao ping: {}\n".format([group_mngr.get_members().size(), group_mngr.get_members()], "{}"))
	)
	add_child(response_timer)
	
	holdback_timer.wait_time = 2.0
	holdback_timer.one_shot = false
	add_child(holdback_timer)
	holdback_timer.start()
	holdback_timer.timeout.connect(_on_holdback_timer)

func _on_holdback_timer()->void:
	if holdback_buffer.size() > 5:
		log_line("[i] Mais de 5 mensagens no buffer, limpando...")
		var buffered_seqs := holdback_buffer.keys()
		buffered_seqs.sort()
		for _seq in buffered_seqs:
			if _seq >= next_expected_seq:
				var p = holdback_buffer[_seq]
				handle_payload(p)
				next_expected_seq = _seq+1
			holdback_buffer.erase(_seq)

func _process(_delta):
	pass

var message_count :int=0
func _on_message_received(message: PackedByteArray, sender_ip: String, port :int)->void:
	message_count+=1
	var msg := message.get_string_from_utf8()
	log_line("[{}:{}] `{}`".format([sender_ip, port, msg], "{}"))
	
	var json := JSON.new()
	var parse_result := json.parse(msg)
	if parse_result != OK: return
	var data = json.get_data()
	if typeof(data) == TYPE_DICTIONARY and data.has_all(["seq", "payload"]):
		var seq     :int= data["seq"]
		var payload :Variant= data["payload"]
		
		if seq == next_expected_seq:
			handle_payload(payload)
			next_expected_seq += 1
			while holdback_buffer.has(next_expected_seq):
				var p = holdback_buffer[next_expected_seq]
				holdback_buffer.erase(next_expected_seq)
				handle_payload(p)
				next_expected_seq += 1
		elif seq > next_expected_seq:
			holdback_buffer[seq] = payload
		# se seq < next_expected_seq: duplicata ou atrasada, ignora

func handle_payload(payload: Variant)->void:
	var msg := payload as String
	var json := JSON.new()
	var parse_result := json.parse(msg)
	if parse_result != OK: return
	var data = json.get_data()
	if typeof(data) == TYPE_DICTIONARY and data.has_all(["pos", "rgb"]):
		on_color_payload(data)

func on_color_payload(data: Dictionary)->void:
	var pos = data["pos"]
	var rgb = data["rgb"]
	var color := Color(
		int(rgb[0]) /255.0,
		int(rgb[1]) /255.0,
		int(rgb[2]) /255.0
	)
	grid_ndi.change_rect(pos, color)

func _on_ping_button_button_down():
	group_mngr.cast_message("CTRL:PING".to_utf8_buffer())

func log_line(line:String, is_debug:bool=false)->void:
	if (is_debug&&!DEBUG): return
	print(line)
	line += "\n"
	log_ndi.text += line
