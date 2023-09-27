# Linux Move Fix
#
# This mod is a workaround for the Linux bug which makes dragging objects
# incredibly slow.
#
# It prevents the Select tool from moving the object (to avoid a tug-of-war),
# and recalculates where the objects *should* be based on how far the mouse
# has moved.
#
# Control flow starts at the update() function at the bottom of the script,
# which is called continuously by Dungeondraft.
var script_class = "tool"


var select_tool = null

var enabled = true
var move_data = null
var stop_mode = false


class MoveData:
  var start_time: Dictionary
  var relative: bool
  var mouse_start_pos: Vector2
  var box_start_pos: Vector2
  var length: int
  var objects: Array
  var last_select_rect: Rect2


func log_msg(msg):
  print("[Linux Move Fix] ", msg)


func start():
  select_tool = Global.Editor.Tools["SelectTool"]

  var tool_panel = Global.Editor.Toolset.GetToolPanel("SelectTool")
  var section = tool_panel.BeginSection(false)
  var enable_button = tool_panel.CreateCheckButton(
    "Enable Move Fix", "EnableMoveFixID", true)
  enable_button.connect("toggled", self, "on_enable_toggle")
  var separator = tool_panel.CreateSeparator()
  tool_panel.EndSection()

  # Move the section to the top so it isn't clobbered when something is selected.
  tool_panel.Align.move_child(section, 0)
  log_msg("Mod loaded.")
  log_msg("NOTE: This mod will spam this console with uncaught C# exceptions. If you need to read the console, disable the it first.")


func on_enable_toggle(value):
  if value:
    log_msg("Enabled.")
    enabled = true
  else:
    log_msg("Disabled.")
    enabled = false


func get_mouse_position() -> Vector2:
  return Global.WorldUI.get_global_mouse_position()


func get_selected_objects():
  # Returns all currently selected objects.
  var objects = []
  # Selectables will crash if the user has shift-clicked and selected the same
  # object twice. Use RawSelectables instead and skip duplicates.
  for raw in select_tool.RawSelectables:
    if raw.Thing in objects:
      continue
    objects.append(raw.Thing)
  return objects


func get_box_center() -> Vector2:
  # Returns the center of the rectangle which encloses the selected objects.
  var select_rect = select_tool.GetSelectionRect()

  # If this is the final move, there may be no selection. Use the last one.
  if select_rect.size == Vector2(0, 0):
    select_rect = move_data.last_select_rect
  move_data.last_select_rect = select_rect

  return select_rect.position + select_rect.size / 2


func snap_vector(target: Vector2) -> Vector2:
  # Snaps the provided end vector according to the grid size.
  #
  # If relative is true, end will be snapped relative to start.
  # Otherwise, end will be snapped relative to the grid.
  #
  # If snapping is disable, end will be returned unmodified.
  if not Global.Editor.IsSnapping:
    return target


  var snap_length = Global.WorldUI.CellSize.x / 2
  var snapped_target = Vector2(
    round(target.x / snap_length) * snap_length,
    round(target.y / snap_length) * snap_length)

  return snapped_target


func move_selection(objects: Array, relative: bool):
  # Moves the selected objects based on the position of the mouse.
  var mouse_delta = get_mouse_position() - move_data.mouse_start_pos
  if mouse_delta.length() == 0:
    return

  # Calculate the new box position based on how far the mouse has moved.
  var box_pos = null
  if relative:
    box_pos = move_data.box_start_pos + snap_vector(mouse_delta)
  else:
    box_pos = snap_vector(move_data.box_start_pos + mouse_delta)

  var box_center = get_box_center()
  for object in objects:
    # Compute the object's position based on the new center of the box and how
    # far from the center the object is.
    var local_box_delta = object.global_position - box_center
    object.global_position = box_pos + local_box_delta

  # Update the selection box for a relative (box selected) move.
  if relative and mouse_delta.length() > 0:
    select_tool.OnFinishSelection()
    if move_data.relative:
      reselect()  # Required to stop the real Select move from overwriting us.


func check_refs() -> bool:
  # Returns true if the reference to each object in move_data is valid. This
  # will be false if a user undoes an object spawn while moving.
  for object in move_data.objects:
    if not is_instance_valid(object):
      return false
  return true


func get_move_data(relative: bool) -> MoveData:
  # Store the initial state.
  move_data = MoveData.new()
  move_data.start_time = OS.get_time()
  move_data.relative = relative
  move_data.mouse_start_pos = get_mouse_position()
  move_data.box_start_pos = get_box_center()
  move_data.objects = get_selected_objects()
  move_data.last_select_rect = null

  return move_data


func reselect():
  # Deselects and then reselects the objects being moved.
  #
  # This prevents the Select tool from overwriting the position and rotation.
  var objects = get_selected_objects()
  select_tool.ClearTransformSelection()
  select_tool.DeselectAll()
  for object in objects:
    select_tool.SelectThing(object, true)
  select_tool.EnableTransformBox(true)


func update(delta: float):
  # This is a workaround for when a user undoes an object while moving it.
  stop_mode = stop_mode and (select_tool.transformMode == 1 or select_tool.manualAction == 1)
  if stop_mode:
    log_msg("Move after undo object spawn detected! Right click and then left click to restore normal function.")
    return

  if not enabled:
    return

  var mode = select_tool.transformMode  # A move using box select.
  var action = select_tool.manualAction # An instant move without a box select.

  if action == 1 or mode == 1:
    if move_data == null:
      move_data = get_move_data(mode == 1)
    # If an object has an invalid reference, or the size of the selected objects
    # has changed, enter stop mode to allow the user to recover.
    if !check_refs() or len(get_selected_objects()) != len(move_data.objects):
      log_msg("Undo during move detected!")
      select_tool.DeselectAll()
      select_tool.ClearTransformSelection()
      move_data = null
      stop_mode = true
      return

    move_selection(move_data.objects, move_data.relative)
  elif move_data != null:
    # Move one last time to prevent rubberbanding from the Select's move.
    move_selection(move_data.objects, move_data.relative)
    move_data = null
