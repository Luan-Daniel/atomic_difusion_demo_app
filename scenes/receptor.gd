extends Control

@export var log_ndi :RichTextLabel = null
var group_mngr :MulticastGroup = null

# espera receber esses valores da main
var _egroup_ip :String = "" # Ip do grupo de emissores, não usado aqui
var rgroup_ip  :String = "" # Ip do grupo de servidores receptores
var network_interface:Dictionary = {"name":"", "friendly":"", "index":-1, "addresses":[]}

func _ready():
	if _egroup_ip.is_empty() || rgroup_ip.is_empty():
		breakpoint # Não recebeu valores esperados
	group_mngr = MulticastGroup.new(rgroup_ip, 9321, network_interface)
	group_mngr.message_received.connect(_on_message_received)
	add_child(group_mngr)
	var err := group_mngr.join_group()
	if err<0:
		log_ndi.text += "[!] Falhou em entrar no grupo, err:{}.\n".format([err],"{}")
		breakpoint
	log_ndi.text += "[i] Entrou no grupo com sucesso.\n"
	group_mngr.cast_message("CTRL:PING".to_utf8_buffer())
	
	var response_timer := Timer.new()
	response_timer.wait_time = 1.0  # Wait 3 seconds
	response_timer.one_shot = true
	response_timer.autostart = true
	response_timer.timeout.connect(func():
		if message_count==0: log_ndi.text += "[i] Ninguém respondeu o ping dentro de 3s.\n"
		else:
			log_ndi.text += "[i] {} membros responderam ao ping: {}\n".format([message_count, group_mngr.get_members()], "{}")
	)
	add_child(response_timer)

func _process(_delta):
	pass

var message_count :int=0
func _on_message_received(message: PackedByteArray, sender_ip: String)->void:
	message_count+=1
	log_ndi.text += "[m] {}> `{}`\n".format([sender_ip, message.get_string_from_utf8()], "{}")


func _on_ping_button_button_down():
	group_mngr.cast_message("CTRL:PING".to_utf8_buffer())
