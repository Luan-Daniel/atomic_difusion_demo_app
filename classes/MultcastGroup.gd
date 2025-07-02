extends Node
class_name MulticastGroup

signal message_received(message: PackedByteArray, sender_ip: String, port :int)

var group_ip: String
var port: int
var network_interface :Dictionary = {"name":"", "friendly":"", "index":-1, "addresses":[]}
var _udp: PacketPeerUDP
var _joined: bool = false
var _members := {}

func _init(_group_ip: String, _port: int, _interface:Dictionary) -> void:
	group_ip = _group_ip
	port = _port
	network_interface = _interface
	_udp = PacketPeerUDP.new()

# Entra no grupo multicast e começa a ouvir mensagens
func join_group() -> int:
	if _udp.is_bound(): _udp.close()
	var err = _udp.bind(port)
	if err != OK:
		push_error("MulticastGroup: erro ao bindar porta %d: %s" % [port, err])
		return -1
	err = _udp.join_multicast_group(group_ip, network_interface.name)
	print(network_interface)
	if err != OK:
		push_error("MulticastGroup: erro ao entrar no grupo %s: %s" % [group_ip, err])
		_udp.close()
		return -2
	_joined = true
	return 0

# Sai do grupo multicast e para de ouvir mensagens
func leave_group() -> void:
	if not _joined: return
	_udp.leave_multicast_group(group_ip, network_interface.name)
	_udp.close()
	_joined = false
	_members.clear()

# Envia qualquer texto/bytes ao grupo, mesmo sem ter entrado nele
func send_message(data:PackedByteArray, ip:String, prt:int) -> void:
	# Se ainda não bindou, usa porta aleatória para envio
	if not _udp.is_bound(): _udp.bind(0)
	_udp.set_dest_address(ip, prt)
	_udp.put_packet(data)

# Envia qualquer texto/bytes ao grupo, mesmo sem ter entrado nele
func cast_message(data:PackedByteArray) -> void:
	send_message(data, group_ip, port)

# Retorna um Array de String com todos os IPs conhecidos que já enviaram mensagem
func get_members() -> Array:
	return _members.keys()

# Método chamado toda frame para processar recebimento de pacotes
func _process(_delta: float) -> void:
	# Enquanto houver pacotes, lê e emite sinal
	while _udp.get_available_packet_count() > 0:
		var packet: PackedByteArray = _udp.get_packet()
		var ip:= _udp.get_packet_ip()
		var is_loopback :bool= (ip in network_interface.addresses)
		var prt := _udp.get_packet_port()
		# Armazena IP no dicionário
		_members[ip] = true
		var msg := packet.get_string_from_utf8()
		match msg:
			"CTRL:PONG":
				pass
			"CTRL:PING":
				if not is_loopback:
					send_message("CTRL:PONG".to_utf8_buffer(), ip, prt)
		if not is_loopback:
			message_received.emit(packet, ip, prt)
	return

static func is_valid_ipv4_address(ip: String) -> bool:
	var pattern := r"^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(\.|$)){4}$"
	var regex := RegEx.new()
	var error := regex.compile(pattern)
	if error != OK:
		push_error("Regex compilation failed!")
		return false
	return regex.search(ip) != null
