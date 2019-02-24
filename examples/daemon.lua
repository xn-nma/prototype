-- Example relay daemon

local control_channel_key = "abcdefghijklmnopqrstuvwxyz123456"

local new_node = require "msgthing.node".new
local simple_protocol = require "examples.simple_protocol"
local cqueues = require "cqueues"
local cs = require "cqueues.socket"
local cbor = require "org.conman.cbor"

local node = new_node()
local cq = cqueues.new()

local subscriptions = {}

local last_tail = 0
local control_room = node:new_room(function(channel, msg_id, data) -- luacheck: ignore 212
	print(string.format("Got control channel message (msg id=%d) of length %3d: %q", msg_id, #data, data))
	last_tail = math.max(last_tail, msg_id+1)
	print("LAST TAIL IS NOW", last_tail)
	channel:tail_from(last_tail)
	if #data == 0 then return end
	local msg = cbor.decode(data)
	p(msg)
end)
control_room:new_channel(control_channel_key, nil):tail_from(last_tail)

local m = cs.listen("127.0.0.1", 8000)
cq:wrap(function()
	while true do
		local peer = m:accept({
			nodelay = true;
		})
		print("Peer connected", peer)

		simple_protocol.add_peer(node, peer)
	end
end)
local ok, err, _, thread = cq:loop()
if not ok then
	error(debug.traceback(thread, err))
end

