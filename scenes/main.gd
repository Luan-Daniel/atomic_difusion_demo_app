extends Control

@export var config_menu_pscn:PackedScene = null
@export var receptor_pscn:PackedScene = null
@export var emissor_pscn:PackedScene = null
var config_menu_ndi:Node = null
var dsnode_ndi:Node = null

# config variables
var dsnode_type:int = -1
var egroup_ip:String = ""
var rgroup_ip:String = ""
var network_interface:Dictionary = {"name":"", "friendly":"", "index":-1, "addresses":[]}

func _ready():
	if config_menu_pscn == null or \
	receptor_pscn == null or \
	emissor_pscn == null:
		breakpoint # Valores não selecionados no editor
	start_config_menu()

func start_config_menu() -> void:
	# creates and connects config menu
	config_menu_ndi = config_menu_pscn.instantiate()
	add_child(config_menu_ndi)
	config_menu_ndi.successfull_configuration.connect(_on_successfull_configuration)

func _on_successfull_configuration(_egroup_ip:String, _rgroup_ip:String, _node_type:int, _sel_intrface:Dictionary):
	egroup_ip = _egroup_ip
	rgroup_ip = _rgroup_ip
	dsnode_type = _node_type
	network_interface = _sel_intrface
	match dsnode_type:
		0: start_ds_emissor()
		1: start_ds_receptor()
		_: breakpoint # Falha na validação ?
	# disconnects and destroy config menu
	config_menu_ndi.successfull_configuration.disconnect(_on_successfull_configuration)
	config_menu_ndi.queue_free()

func start_ds_emissor() -> void:
	dsnode_ndi = emissor_pscn.instantiate()
	dsnode_ndi.egroup_ip = egroup_ip
	dsnode_ndi.rgroup_ip = rgroup_ip
	dsnode_ndi.interface = network_interface
	add_child(dsnode_ndi)

func start_ds_receptor() -> void:
	dsnode_ndi = receptor_pscn.instantiate()
	dsnode_ndi._egroup_ip = egroup_ip
	dsnode_ndi.rgroup_ip = rgroup_ip
	dsnode_ndi.network_interface = network_interface
	add_child(dsnode_ndi)
