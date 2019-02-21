local hydrogen = require "hydrogen"
local new_node = require "msgthing.node".new

-- Simulate 3 separate nodes
local nodea = new_node()
local nodeb = new_node()
local nodec = new_node()

-- Create link between node a and node b
local na_b, nb_a
na_b = nodea:new_neighbour(function(self, packet_type, data) -- luacheck: ignore 212
	print(string.format("A SENDS B %3d bytes of %s: %s", #data, packet_type, hydrogen.bin2hex(data)))
	nb_a:process_packet(packet_type, data)
end)
nb_a = nodeb:new_neighbour(function(self, packet_type, data) -- luacheck: ignore 212
	print(string.format("B SENDS A %3d bytes of %s: %s", #data, packet_type, hydrogen.bin2hex(data)))
	na_b:process_packet(packet_type, data)
end)

-- Create link between node b and node c
local nb_c, nc_b
nb_c = nodeb:new_neighbour(function(self, packet_type, data) -- luacheck: ignore 212
	print(string.format("B SENDS C %3d bytes of %s: %s", #data, packet_type, hydrogen.bin2hex(data)))
	nc_b:process_packet(packet_type, data)
end)
nc_b = nodec:new_neighbour(function(self, packet_type, data) -- luacheck: ignore 212
	print(string.format("C SENDS B %3d bytes of %s: %s", #data, packet_type, hydrogen.bin2hex(data)))
	nb_c:process_packet(packet_type, data)
end)

-- ra_1 = room as seen from node a, id '1'.
local ra_1 = nodea:new_room(function(channel, msg_id, data) -- luacheck: ignore 212
	print(string.format("A receives message in room 1 (msg id=%d): %s", msg_id, data))
end)
local ca_1 = ra_1:create_channel()
ra_1:tail(true)

-- Send a message *before* B joins the room
ra_1:queue_message("this 79 character message that may fill a traditional/old terminal screen width")

-- now have node b join the room
local rb_1 = nodeb:new_room(function(channel, msg_id, data) -- luacheck: ignore 212
	print(string.format("B receives message in room 1 (msg id=%d): %s", msg_id, data))
end)
rb_1:new_channel(ca_1.key:asstring(), nil)
rb_1:tail(true)

-- nodes now meet
na_b:send_subscription()
nb_a:send_subscription()
nb_c:send_subscription()
nc_b:send_subscription()
-- note that node a here has not yet been propagated any of C's subsciptions
-- during normal operation, nodes would update their subscriptions periodically

-- we now have nodes send any messages they feel like
na_b:send_messages()
nb_a:send_messages()
nb_c:send_messages()
nc_b:send_messages()
