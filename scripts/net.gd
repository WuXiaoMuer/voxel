extends Node
## Multiplayer: the transport, the handshake, and the two authority implementations that
## plug into `world.gd`'s edit seam.
##
## Terrain is deliberately NOT streamed. `terrain.gd` is seed-deterministic, so a client
## handed the host's seed builds the same world block for block, and the two agree with no
## chunk traffic at all. Only *edits* cross the wire: the whole accumulated diff once, on
## join, and one tiny event per edit after that. This is the first shippable slice of
## MULTIPLAYER.md (its §5 and the "client generates, server sends the diff" note in §9),
## and it keeps worldgen in exactly one place.
##
## The seam it plugs into already exists: `world.set_block` is a *request* that goes
## through `world.authority`, and every edit funnels through there. A host authority is
## the single-player behaviour plus a broadcast; a client authority predicts locally,
## asks the host, and snaps to whatever the host confirms.

signal hosted()
signal join_failed(reason: String)
## A client has been told the world parameters and the accumulated edit diff.
signal welcomed(seed_value: int, creative: bool, distance: int, cheats: bool,
	edits: PackedByteArray)
signal player_joined(id: int)
signal player_left(id: int)
## The host applied an edit a client asked for (used by the two-peer test).
signal host_edit(pos: Vector3i, id: int)
## An authoritative edit arrived from the host (client side).
signal edited(pos: Vector3i, id: int)

enum Role { NONE, HOST, CLIENT }
const DEFAULT_PORT := 27015
const MAX_CLIENTS := 7

var role := Role.NONE
var player_name := "Player"
var world = null
var player = null
var players: Dictionary = {}      # peer id -> {"name": String}


## The host's authority: the request is the change (the single-player behaviour), then the
## result is broadcast. This is `world.Authority` with one extra line, kept as its own
## class so single-player never pays for a network check.
class HostAuthority:
	func request_edit(w, pos, id, record, silent := false) -> bool:
		if not w.apply_edit(pos, id, record, silent):
			return false
		Net.broadcast_edit(pos, id)
		return true

	func on_applied(_pos: Vector3i, _id: int) -> void:
		pass


## The client's authority: apply the edit to the local copy at once so placing feels
## instant, then ask the host. When the host's own confirmation comes back the block is
## set again to the same value, which is a no-op; a rejection would snap it back. v1 has no
## reach rejection, so confirmations always match and there is nothing to roll back.
class ClientAuthority:
	func request_edit(w, pos, id, record, silent := false) -> bool:
		if w.get_block(pos.x, pos.y, pos.z) == id:
			return false
		var ok: bool = w.apply_edit(pos, id, record, silent)
		Net.send_edit(pos, id)
		return ok

	func on_applied(_pos: Vector3i, _id: int) -> void:
		pass


# ================================================================ transport
func host(port: int, nm: String) -> bool:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_CLIENTS)
	if err != OK:
		join_failed.emit("Could not host on port %d." % port)
		return false
	multiplayer.multiplayer_peer = peer
	role = Role.HOST
	player_name = nm
	players.clear()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	hosted.emit()
	return true


func join(ip: String, port: int, nm: String) -> bool:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		join_failed.emit("Could not reach %s:%d." % [ip, port])
		return false
	multiplayer.multiplayer_peer = peer
	role = Role.CLIENT
	player_name = nm
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	return true


func stop() -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	role = Role.NONE
	players.clear()


func is_active() -> bool:
	return role != Role.NONE


# ================================================================ transport callbacks
func _on_peer_connected(id: int) -> void:
	# nothing yet: the client introduces itself with `_hello`, which is where the host
	# learns its name and can answer with the world parameters
	pass


func _on_peer_disconnected(id: int) -> void:
	players.erase(id)
	player_left.emit(id)


func _on_connected_to_server() -> void:
	rpc_id(1, "_hello", player_name)


func _on_connection_failed() -> void:
	role = Role.NONE
	join_failed.emit("Could not connect.")


func _on_server_disconnected() -> void:
	role = Role.NONE
	join_failed.emit("The host closed the world.")


# ================================================================ rpc
## Client -> host, on connect: who I am. The host answers with the world.
@rpc("any_peer", "reliable")
func _hello(nm: String) -> void:
	if role != Role.HOST or world == null:
		return
	var id := multiplayer.get_remote_sender_id()
	players[id] = {"name": nm}
	player_joined.emit(id)
	rpc_id(id, "_welcome", int(world.seed_value), bool(player.creative),
		int(world.render_distance), Commands.cheats_enabled, world.serialize_edits())


## Host -> a joining client: the world parameters and every edit so far.
@rpc("authority", "reliable")
func _welcome(seed_value: int, creative: bool, distance: int, cheats: bool,
		edits: PackedByteArray) -> void:
	if role != Role.CLIENT:
		return
	welcomed.emit(seed_value, creative, distance, cheats, edits)


## Client -> host: please make this edit. The host reapplies it through its own seam,
## which validates and broadcasts the result.
@rpc("any_peer", "reliable")
func _edit(pos: Vector3i, id: int) -> void:
	if role != Role.HOST or world == null:
		return
	if world.get_block(pos.x, pos.y, pos.z) == id:
		return
	# the edit goes through the host's own seam, which applies it and broadcasts the
	# result to everyone -- including the client that asked
	if world.set_block(pos.x, pos.y, pos.z, id):
		host_edit.emit(pos, id)


## Host -> everyone: this is now the truth. Sent from the host authority's `request_edit`,
## so the host and any client that predicted the same edit all converge on one value.
func broadcast_edit(pos: Vector3i, id: int) -> void:
	if role == Role.HOST and multiplayer.multiplayer_peer != null:
		rpc("_applied", pos, id)


@rpc("authority", "reliable")
func _applied(pos: Vector3i, id: int) -> void:
	if role != Role.CLIENT or world == null:
		return
	if world.get_block(pos.x, pos.y, pos.z) != id:
		world.apply_edit(pos, id, true, false)
	edited.emit(pos, id)


func send_edit(pos: Vector3i, id: int) -> void:
	if role == Role.CLIENT:
		rpc_id(1, "_edit", pos, id)