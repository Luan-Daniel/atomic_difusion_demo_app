extends Control

# espera receber esses valores da main
var egroup_ip : String = ""
var rgroup_ip : String = ""
var network_interface:Dictionary = {"name":"", "friendly":"", "index":-1, "addresses":[]}

func _ready():
	if egroup_ip.is_empty() || rgroup_ip.is_empty():
		breakpoint # Não recebeu valores esperados
