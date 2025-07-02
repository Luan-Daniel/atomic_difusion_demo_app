extends Control

var DEBUG:=false

#region Nós e Estados Principais
@export var log_ndi :RichTextLabel = null
@export var status_ndi :RichTextLabel = null

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
var members     := {} # { node_id: {ip, port}, ... }
var predecessor := {} # { node_id, ip, port }
var successor   := {}
var my_ip       := ""
var PORT        :int= 9321

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
	
	# 3) Anunciar entrada
	_send_control("JOIN_REQ", { "node_id":node_id, "port":PORT })
#endregion

#region Envio e Recepção de Controle
# Helper para enviar mensagens de controle via multicast ou unicast
enum CtrlType { JOIN_REQ, JOIN_ACK, MEMBERSHIP, PING, PONG, TOKEN }
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
			if body.coordinator == node_id:
				have_token = true
				last_token_ts = get_unix_time_in_ms()
				token_timeout_timer.start()
			_rebuild_ring()
			_broadcast_membership()

		# 3) Alguma mudança em membership
		CtrlType.MEMBERSHIP:
			log_line("[debug] _on_message_received: Alguma mudança em membership.", true)
			members = body.members.duplicate()
			_rebuild_ring()
			if _get_coordinator_id() == node_id and members.size() == 1:
				_init_token()
				have_token = true
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
			_deliver_pending()
#endregion

#region Heartbeat & Detecção de Falhas
# Envia PING para successor
func _on_heartbeat()->void:
	if successor.has("ip") && not members.is_empty():
		if successor['node_id'] == node_id: return
		members[ successor.node_id ].alive = false
		_send_control("PING", { "port":PORT }, successor.ip, successor.port)
		ping_timeout_timer.start()
	if successor.is_empty(): ping_timeout_timer.start()

# Se não vier PONG, suspeita e ajusta grupo
func _on_ping_timeout()->void:
	if successor and not members[ successor.node_id ].alive:
		if node_id == successor.node_id: return
		log_line("[debug] _on_ping_timeout: Suspeita.", true)
		members.erase(successor.node_id)
		_broadcast_membership()
		return
	if members.is_empty():
		log_line("[debug] _on_ping_timeout: Ninguém nunca respondeu.", true)
		members[node_id] = { "ip": my_ip, "port": PORT }
		_broadcast_membership()
		_rebuild_ring()

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
	var ids = members.keys()
	ids.sort()
	var n := ids.size()
	if n==0: return
	if n==1 && (node_id in ids):
		log_line("[debug] _rebuild_ring: Sou unico no anel", true)
		predecessor = { "node_id": node_id, "ip": my_ip, "port": PORT }
		successor   = predecessor.duplicate()
	else:
		log_line("[debug] _rebuild_ring: Anel com mais de um membro", true)
		var idx = ids.find(node_id)
		var succ_id = ids[(idx + 1) % n]
		var pred_id = ids[(idx - 1 + n) % n]
		successor = {
			"node_id": succ_id,
			"ip":       members[succ_id]["ip"],
			"port":     members[succ_id]["port"]
		}
		predecessor = {
			"node_id": pred_id,
			"ip":       members[pred_id]["ip"],
			"port":     members[pred_id]["port"]
		}

func _broadcast_membership()->void:
	_send_control("MEMBERSHIP", { "members": members })
#endregion

#region Token: Passagem e Difusão
func _init_token()->void:
	# carregue ou incremente um token_id global
	token_id += 1

func _pass_token():
	_send_control("TOKEN", { "token_id": token_id },
		successor["ip"], int(successor["port"]))
	have_token = false

func diffuse(data:PackedByteArray):
	# enfileira e tenta entregar se tiver token
	pending_msgs.append(data.duplicate())
	if have_token:
		_deliver_pending()

func _deliver_pending():
	log_line("[debug] _deliver_pending", true)
	# envia todas as mensagens ao grupo receptor
	for buf in pending_msgs:
		group_mngr.send_message(buf, rgroup_ip, 9322)
	pending_msgs.clear()
	_pass_token()
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
	status_ndi.set_text(
	"NODE ID: {}\nIP: {}\nNUMBER OF MEMBERS: {}\nMEMBERS: {}\nSUCCESSOR: {}\nPREDECESSOR: {}\nHAS_TOKEN: {}"
	.format([node_id, my_ip, n_members, members, successor, predecessor], "{}"))

func _process(_delta):
	update_status()
