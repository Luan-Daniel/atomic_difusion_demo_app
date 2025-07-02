extends Control

var DEBUG:=false

#region Nós e Estados Principais
@export var log_ndi :RichTextLabel = null
@export var status_ndi :RichTextLabel = null
@export var color_ndi :ColorRect = null
@export var pos_ndi :Label = null

# Multicast e timers
var group_mngr: MulticastGroup
@onready var heartbeat_timer = Timer.new()
@onready var ping_timeout_timer = Timer.new()
@onready var token_timeout_timer = Timer.new()
@onready var token_ack_timer = Timer.new()

# IPs e interface recebidos da Main
var egroup_ip :String # Ip do grupo emissor
var rgroup_ip :String # Ip do grupo receptor
var interface :Dictionary = {"name":"", "friendly":"", "index":-1, "addresses":[]}

# Identidade e membership
var node_id :String= str(get_unix_time_in_ms() + randi())
var members     := {} # { node_id: {ip, port}, ... }
var predecessor := {} # { node_id, ip, port }
var successor   := {}
var my_ip       := ""
var PORT        :int= 9321

# Token e filas
var have_token    :bool= false
var last_token_ts :int= 0
var pending_msgs  :Array[PackedByteArray]= []
var token_id      :int= 0
var token_retries := 0
var pending_token_to_send := {}   # { token_id, ip, port }

const TOKEN_ACK_TIMEOUT  := 1.0
const TOKEN_MAX_RETRIES  := 3
const HEARTBEAT_INTERVAL := 1.0
const PING_TIMEOUT       := 0.5
const TOKEN_TIMEOUT      := 5.0
#endregion

#region Setup inicial e JOIN
func _ready():
	# 0) Encontra meu IPv4 (Não muito bom)
	for addr in interface.addresses:
		if addr.count(".") == 3: my_ip = addr
	if my_ip.is_empty(): my_ip = interface.addresses[-1]
	
	# 1) Configura group manager
	group_mngr = MulticastGroup.new(egroup_ip, PORT, interface)
	group_mngr.message_received.connect(_on_message_received)
	add_child(group_mngr)
	group_mngr.join_group()
	members[node_id] = { "ip": my_ip, "port": PORT }
	
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
	
	token_ack_timer.wait_time = TOKEN_ACK_TIMEOUT
	token_ack_timer.one_shot = true
	add_child(token_ack_timer)
	token_ack_timer.timeout.connect(_on_token_ack_timeout)
	
	# 3) Anunciar entrada
	_send_control("JOIN_REQ", { "node_id":node_id, "port":PORT })
#endregion

#region Envio e Recepção de Controle
# Helper para enviar mensagens de controle via multicast ou unicast
enum CtrlType { JOIN_REQ, JOIN_ACK, MEMBERSHIP, PING, PONG, TOKEN, TOKEN_ACK }
func _send_control(type:String, body:Dictionary, to_ip:String="", to_port:int=0)->void:
	var msg := { "type": type, "body": body }
	var buf := JSON.stringify(msg).to_utf8_buffer()
	if to_ip.is_empty():
		group_mngr.cast_message(buf)
		log_line("[debug] _send_control: Multicasted `{}`".format([msg],"{}"), true)
	else:
		group_mngr.send_message(buf, to_ip, to_port)
		log_line("[debug] _send_control: Unicasted `{}` to {}".format([msg,to_ip],"{}"), true)

func _on_message_received(packet: PackedByteArray, sender_ip: String, port :int)->void:
	var text := packet.get_string_from_utf8()
	log_line("[{}:{}] {}".format([sender_ip, port, packet.get_string_from_utf8()], "{}"))
	var json := JSON.new()
	var res  := json.parse(text)
	if res != OK: return
	var result :Dictionary= json.get_data()
	var type   :String= result["type"]
	var value  :CtrlType= CtrlType.get(type)
	var body   :Dictionary= result["body"]

	match value:
		# 1) Novo nó quer entrar
		CtrlType.JOIN_REQ:
			if _get_coordinator_id() == node_id:
				log_line("[debug] _on_message_received: Novo nó quer entrar.", true)
				# Atualiza membership e responde
				members[ body.node_id ] = { "ip":sender_ip, "port": body.port }
				_send_control("JOIN_ACK",
					{ "members": members, "coordinator": node_id },
					sender_ip, body.port
				)
				_broadcast_membership()

		# 2) Resposta ao JOIN_REQ (coordenador)
		CtrlType.JOIN_ACK:
			log_line("[debug] _on_message_received: Resposta ao JOIN_REQ (coordenador).", true)
			members = body.members.duplicate()
			# Descobre coordenador
			if body.coordinator == node_id and not have_token:
				have_token = true
				last_token_ts = get_unix_time_in_ms()
				token_timeout_timer.start()
			_rebuild_ring()
			_broadcast_membership()
			_deliver_pending()

		# 3) Alguma mudança em membership
		CtrlType.MEMBERSHIP:
			log_line("[debug] _on_message_received: Alguma mudança em membership.", true)
			members = body.members.duplicate()
			_rebuild_ring()
			if members.size() == 1 and _get_coordinator_id() == node_id and not have_token:
				_init_token()
				have_token = true
				last_token_ts = get_unix_time_in_ms()
				token_timeout_timer.start()
				_deliver_pending()

		# 4) Heartbeat no anel
		CtrlType.PING:
			log_line("[debug] _on_message_received: Heartbeat no anel.", true)
			_send_control("PONG", {"node_id":node_id}, sender_ip, body.port)

		CtrlType.PONG:
			log_line("[debug] _on_message_received: PONG.", true)
			# quem respondeu está vivo
			members[ body.node_id ].alive = true

		# 5) Chegou token
		CtrlType.TOKEN:
			log_line("[debug] _on_message_received: Chegou token.", true)
			have_token = true
			last_token_ts = get_unix_time_in_ms()
			token_timeout_timer.start()
			# 5.1) Envia confirmação ao remetente
			var ack_body = { "token_id": body.token_id, "from_id": node_id }
			_send_control("TOKEN_ACK", ack_body, sender_ip, port)
			# 5.2) Processa entrega
			_deliver_pending()
		CtrlType.TOKEN_ACK:
			# quem passou token recebeu a confirmação
			if body.token_id == pending_token_to_send.token_id:
				token_ack_timer.stop()
				pending_token_to_send.clear()
#endregion

#region Heartbeat & Detecção de Falhas
# Envia PING para successor
func _on_heartbeat()->void:
	if successor.has("ip") && not members.is_empty():
		if successor['node_id'] == node_id: return
		if not members.has(successor.node_id): return
		members[ successor.node_id ].alive = false
		_send_control("PING", { "port":PORT }, successor.ip, successor.port)
		ping_timeout_timer.start()
	if successor.is_empty(): ping_timeout_timer.start()

# Se não vier PONG, suspeita e ajusta grupo
func _on_ping_timeout()->void:
	if members.size() == 1 and _get_coordinator_id() == node_id and not have_token:
		log_line("[debug] _on_ping_timeout: Ninguém respondeu.", true)
		_init_token()
		have_token = true
		last_token_ts = get_unix_time_in_ms()
		token_timeout_timer.start()
		_broadcast_membership()
		_rebuild_ring()
		_deliver_pending()
	if successor and members[ successor.node_id ].has("alive"):
		if members[ successor.node_id ].alive: return
		if node_id == successor.node_id: return
		log_line("[debug] _on_ping_timeout: Suspeita.", true)
		members.erase(successor.node_id)
		_broadcast_membership()
		return

func _on_token_timeout():
	# token perdido? recria se for coordenador
	if _get_coordinator_id() == node_id:
		log_line("[debug] _on_token_timeout: Recria token", true)
		_init_token()   # incrementa token ID
		_pass_token()
#endregion

#region Montando o Anel
func _get_coordinator_id() -> String:
	var ids := members.keys()
	ids.sort()
	return ids[0]  # menor node_id

func _rebuild_ring()->void:
	# 1) Assegura self em members
	if not members.has(node_id):
		members[node_id] = { "ip": my_ip, "port": PORT }
	# 2) Ordena lista de IDs
	var ids = members.keys()
	ids.sort()
	# 3) Indice e vizinhos
	var n = ids.size()
	var idx = ids.find(node_id)
	if idx == -1:
		push_error("[!] rebuild_ring: node_id não encontrado")
		return
	
	var succ_id = ids[(idx + 1) % n]
	var pred_id = ids[(idx - 1 + n) % n]
	# 4) Atualiza successor e predecessor
	successor = {
		"node_id": succ_id,
		"ip": members[succ_id]["ip"],
		"port": members[succ_id]["port"]
	}
	predecessor = {
		"node_id": pred_id,
		"ip": members[pred_id]["ip"],
		"port": members[pred_id]["port"]
	}

func _broadcast_membership()->void:
	_send_control("MEMBERSHIP", { "members": members })
#endregion

#region Token: Passagem e Difusão
func _init_token()->void:
	# carregue ou incremente um token_id global
	token_id += 1

func _send_token(data:Dictionary)->void:
	var body = { "token_id": data.token_id }
	_send_control("TOKEN", body, data.ip, data.port)
	token_ack_timer.start()

func _pass_token()->void:
	pending_token_to_send = {
		"token_id": token_id,
		"ip": successor.ip,
		"port": successor.port
	}
	token_retries = 0
	_send_token(pending_token_to_send)
	have_token = false

func _deliver_pending()->void:
	# cria mensagem aleatoria
	var msg := {
	"pos": randi_range(0, 11),
	"rgb": [
		randi_range(0, 255),
		randi_range(0, 255),
		randi_range(0, 255)]
	}
	var color := Color(msg.rgb[0]/255.0, msg.rgb[1]/255.0, msg.rgb[2]/255.0)
	color_ndi.set_color(color)
	pos_ndi.set_text(JSON.stringify(msg, "  "))
	pending_msgs.append(JSON.stringify(msg).to_utf8_buffer())
	
	log_line("[debug] _deliver_pending", true)
	# envia todas as mensagens ao grupo receptor
	for buf in pending_msgs:
		group_mngr.send_message(buf, rgroup_ip, PORT)
	pending_msgs.clear()
	_pass_token()

func _on_token_ack_timeout():
	# falha na confirmação
	if token_retries < TOKEN_MAX_RETRIES:
		token_retries += 1
		log_line("[debug] Retransmitindo token (tentativa %d)".format([token_retries]), true)
		_send_token(pending_token_to_send)
	else:
		log_line("[debug] Sucessor falho detectado. Atualizando anel.", true)
		# Suspeita de falha do successor
		members.erase(successor.node_id)
		_broadcast_membership()
		# Repassa token ao novo successor
		_rebuild_ring()
		pending_token_to_send.clear()
		# o nó atual ainda detém o token
		have_token = true
		last_token_ts = get_unix_time_in_ms()
		token_timeout_timer.start()
		_deliver_pending()
#endregion

static func get_unix_time_in_ms()->int:
	return int(Time.get_unix_time_from_system()*1000.0)

func log_line(line:String, is_debug:bool=false)->void:
	if (is_debug&&!DEBUG): return
	print(line)
	line += "\n"
	log_ndi.text += line

func update_status()->void:
	var n_members := members.size()
	var is_coordinator := _get_coordinator_id()==node_id
	status_ndi.set_text(
	"IS_COORDINATOR: {}\nNODE ID: {}\nIP: {}\nNUMBER OF MEMBERS: {}\nMEMBERS: {}\nSUCCESSOR: {}\nPREDECESSOR: {}\nHAS_TOKEN: {}\n LAST_TOKEN_TS: {}"
	.format([is_coordinator, node_id, my_ip, n_members, members, successor, predecessor, have_token, last_token_ts], "{}"))

func _process(_delta):
	update_status()
