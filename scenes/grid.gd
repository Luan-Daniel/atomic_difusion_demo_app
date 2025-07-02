extends Control

var rects: Array[ColorRect]

func change_rect(pos:int, color:Color)->void:
	if (pos<0 or pos>11): return
	rects[pos].set_color(color)

func _ready():
	randomize()

	# Create the GridContainer
	var grid = GridContainer.new()
	grid.columns = 4
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.custom_minimum_size = Vector2(400, 300)
	add_child(grid)

	# Create and add 12 ColorRects
	for i in range(12):
		var rect = ColorRect.new()
		rect.color = Color(0,0,0)
		rect.custom_minimum_size = Vector2(80, 80)
		grid.add_child(rect)
		rects.append(rect)
