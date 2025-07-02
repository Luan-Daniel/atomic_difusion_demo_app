extends Control

# Fluxo atual
# _ready() → join multicast + JOIN_REQ
# JOIN_ACK → recebo membros + construo anel + (se coordenador) gero token
# _on_heartbeat() → PING no successor
# SUSPEITA → erra-suspeito, atualiza membros, refaz anel
# TOKEN → entrego mensagens pendentes, passo token

#region Nós e Estados Principais
@export var log_ndi :RichTextLabel = null

# Multicast e timers
var group_mngr: MulticastGroup
@onready var heartbeat_timer = Timer.new()
@onready var ping_timeout_timer = Timer.new()
@onready var token_timeout_timer = Timer.new()

# IPs e interface recebidos da Main
var egroup_ip :String # Ip do grupo emissor
var rgroup_ip :String # Ip do grupo receptor
var interface :Dictionary = {"name":"", "friendly":"", "index":-1, "addresses":[]}

# Identidade e membership
var node_id :String= str(get_unix_time_in_ms() + randi())
var members     := {} # { node_id: {ip, port} }
var predecessor := {} # { node_id, ip, port }
var successor   := {}

# Token e filas
var have_token    :bool= false
var last_token_ts :int= 0
var pending_msgs  :Array[PackedByteArray]= []
var token_id: int = 0

const HEARTBEAT_INTERVAL := 1.0
const PING_TIMEOUT       := 0.5
const TOKEN_TIMEOUT      := 5.0
#endregion

#region Setup inicial e JOIN
func _ready():
	# 1) Configura group manager
	group_mngr = MulticastGroup.new(egroup_ip, 9321, interface)
	group_mngr.message_received.connect(_on_message_received)
	add_child(group_mngr)
	group_mngr.join_group()
	
	# 2) Timers
	heartbeat_timer.wait_time = HEARTBEAT_INTERVAL
	heartbeat_timer.one_shot = false
	add_child(heartbeat_timer)
	heartbeat_timer.start()
	heartbeat_timer.timeout.connect(_on_heartbeat)
	
	ping_timeout_timer.wait_time = PING_TIMEOUT
	ping_timeout_timer.one_shot = true
	add_child(ping_timeout_timer)
	ping_timeout_timer.timeout.connect(_on_ping_timeout)

	token_timeout_timer.wait_time = TOKEN_TIMEOUT
	token_timeout_timer.one_shot = true
	add_child(token_timeout_timer)
	token_timeout_timer.timeout.connect(_on_token_timeout)
	
	# 3) Anunciar entrada
	_send_control("JOIN_REQ", { "node_id":node_id, "port":9321 })
#endregion

#region Envio e Recepção de Controle
# Helper para enviar mensagens de controle via multicast ou unicast
enum CtrlType { JOIN_REQ, JOIN_ACK, MEMBERSHIP, PING, PONG, TOKEN }
func _send_control(type:String, body:Dictionary, to_ip:String="", to_port:int=0)->void:
	var msg := { "type": type, "body": body }
	var buf := JSON.stringify(msg).to_utf8_buffer()
	if to_ip.is_empty():
		group_mngr.cast_message(buf)
		log_line("[debug] _send_control: Multicasted `{}`".format([msg],"{}"))
	else:
		group_mngr.send_message(buf, to_ip, to_port)
		log_line("[debug] _send_control: Unicasted `{}` to {}".format([msg,to_ip],"{}"))

func _on_message_received(packet: PackedByteArray, sender_ip: String)->void:
	var text := packet.get_string_from_utf8()
	log_line("[{}] {}".format([sender_ip, packet.get_string_from_utf8()], "{}"))
	var json := JSON.new()
	var res  := json.parse(text)
	if res != OK: return
	var result :Dictionary= json.get_data()
	var type   :String= result["type"]
	var body   :Dictionary= result["body"]

	match type:
		# 1) Novo nó quer entrar
		CtrlType.JOIN_REQ:
			log_line("[debug] _on_message_received: Novo nó quer entrar.")
			# Atualiza membership e responde
			members[ body.node_id ] = { "ip":sender_ip, "port": body.port }
			_send_control("JOIN_ACK",
				{ "members": members, "coordinator": _get_coordinator_id() },
				sender_ip, body.port
			)
			_broadcast_membership()

		# 2) Resposta ao JOIN_REQ (coordenador)
		CtrlType.JOIN_ACK:
			log_line("[debug] _on_message_received: Resposta ao JOIN_REQ (coordenador).")
			members = body.members.duplicate()
			# Descobre coordenador
			if body.coordinator == node_id:
				have_token = true
				last_token_ts = get_unix_time_in_ms()
				token_timeout_timer.start()
			_rebuild_ring()

		# 3) Alguma mudança em membership
		CtrlType.MEMBERSHIP:
			log_line("[debug] _on_message_received: Alguma mudança em membership.")
			members = body.members.duplicate()
			_rebuild_ring()

		# 4) Heartbeat no anel
		CtrlType.PING:
			log_line("[debug] _on_message_received: Heartbeat no anel.")
			_send_control("PONG", {}, sender_ip, body.port)

		CtrlType.PONG:
			log_line("[debug] _on_message_received: PONG.")
			# quem respondeu está vivo
			members[ body.node_id ].alive = true

		# 5) Chegou token
		CtrlType.TOKEN:
			log_line("[debug] _on_message_received: Chegou token.")
			have_token = true
			last_token_ts = get_unix_time_in_ms()
			token_timeout_timer.start()
			_deliver_pending()
#endregion

#region Heartbeat & Detecção de Falhas
# Envia PING para successor
func _on_heartbeat()->void:
	if successor.has("ip"):
		members[ successor.node_id ].alive = false
		_send_control("PING", { "port":9321 }, successor.ip, successor.port)
		ping_timeout_timer.start()

# Se não vier PONG, suspeita e ajusta grupo
func _on_ping_timeout()->void:
	if successor and not members[ successor.node_id ].alive:
		log_line("[debug] _on_ping_timeout: Suspeita.")
		members.erase(successor.node_id)
		_broadcast_membership()

func _on_token_timeout():
	# token perdido? recria se for coordenador
	if _get_coordinator_id() == node_id:
		_init_token()   # incrementa token ID
		_pass_token()
#endregion

#region Montando o Anel
func _get_coordinator_id() -> String:
	var ids = members.keys()
	ids.sort()
	return ids[0]  # menor node_id

func _rebuild_ring()->void:
	var ids = members.keys()
	ids.sort()
	var idx = ids.find(node_id)
	var n = ids.size()
	predecessor = members[ ids[(idx-1 + n) % n] ]
	predecessor.node_id = ids[(idx-1 + n) % n]

	successor = members[ ids[(idx+1) % n] ]
	successor.node_id = ids[(idx+1) % n]

func _broadcast_membership()->void:
	_send_control("MEMBERSHIP", { "members": members })
#endregion

#region Token: Passagem e Difusão
func _init_token()->void:
	# carregue ou incremente um token_id global
	token_id += 1

func _pass_token():
	_send_control("TOKEN", { "token_id": token_id }, successor.ip, successor.port)
	have_token = false

func diffuse(data:PackedByteArray):
	# enfileira e tenta entregar se tiver token
	pending_msgs.append(data.duplicate())
	if have_token:
		_deliver_pending()

func _deliver_pending():
	# envia todas as mensagens ao grupo receptor
	for buf in pending_msgs:
		group_mngr.send_message(buf, rgroup_ip, 9322)
	pending_msgs.clear()
	_pass_token()
#endregion

static func get_unix_time_in_ms()->int:
	return int(Time.get_unix_time_from_system()*1000.0)

func log_line(line:String)->void:
	log_ndi.text += line
	log_ndi.text += "\n"
