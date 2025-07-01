extends Control

signal successfull_configuration(emissor_group_ip:String, receptor_group_ip:String, node_type:int, interface:Dictionary)

@export var validate_button_ndi:Button = null
@export var dsnode_type_button_ndi:OptionButton = null
@export var interface_button_ndi:OptionButton = null
@export var egroup_form_ndi:TextEdit = null
@export var rgroup_form_ndi:TextEdit = null
@export var log_ndi:RichTextLabel = null
var interfaces :Array[Dictionary] = []

func _ready():
	log_ndi.text += "[i] dpi: {}.\n".format([DisplayServer.screen_get_dpi()], "{}")
	if validate_button_ndi == null || \
	dsnode_type_button_ndi == null || \
	interface_button_ndi == null || \
	egroup_form_ndi == null || \
	rgroup_form_ndi == null || \
	log_ndi == null:
		breakpoint # Nós não selecionados no editor
	interfaces = IP.get_local_interfaces()
	populate_interfaces()

func validate(eip:String, rip:String, ndtp:int, ifid:int) -> int:
	if (eip.is_empty() || rip.is_empty()): return -1
	if (ndtp < 0 || ndtp > 1): return -2
	if (!MulticastGroup.is_valid_ipv4_address(eip) || !MulticastGroup.is_valid_ipv4_address(rip)): return -3
	if (eip == rip): return -4
	if (ifid<0): return -5
	return 0

func _on_button_button_down() -> void:
	log_ndi.set_text("")
	validate_button_ndi.set_disabled(true)
	var eip := egroup_form_ndi.get_text().strip_edges()
	var rip := rgroup_form_ndi.get_text().strip_edges()
	var ndtp := dsnode_type_button_ndi.get_selected_id()
	var ifid := interface_button_ndi.get_selected_id()
	var selected_interface := {"name":"", "friendly":"", "index":-1, "addresses":[]}
	for iface in interfaces:
		if int(iface["index"])==ifid:
			selected_interface.name = iface["name"]
			selected_interface.friendly = iface["friendly"]
			selected_interface.index = int(iface["index"])
			selected_interface.addresses = iface["addresses"]
	
	var res := validate(eip, rip, ndtp, ifid)
	if res == 0:
		successfull_configuration.emit(eip, rip, ndtp, selected_interface)
		return
	match res:
		-1: log_ndi.text += "[!] Campo de IP não pode estar vazio.\n"
		-2: log_ndi.text += "[!] Opção de Nó invalida.\n"
		-3: log_ndi.text += "[!] IP invalido.\n"
		-4: log_ndi.text += "[!] Grupos não podem ter mesmo IP.\n"
		-5: log_ndi.text += "[!] Interface invalida.\n"
	validate_button_ndi.set_disabled(false)

func populate_interfaces() -> void:
	for iface in interfaces:
		print(iface)
		if not iface["index"].is_valid_int(): breakpoint # ????
		var iface_name :String = "{friendly}".format(iface)
		interface_button_ndi.add_item(iface_name, int(iface["index"]))
