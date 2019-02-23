-- Example relay daemon control application

local control_channel_key = "abcdefghijklmnopqrstuvwxyz123456"

local new_node = require "msgthing.node".new
local cqueues = require "cqueues"
local simple_protocol = require "examples.simple_protocol"
local cbor = require "org.conman.cbor"

local node = new_node()
local cq = cqueues.new()

-- local channel_cond = cc.new()
local control_room = node:new_room(function(channel, msg_id, data) -- luacheck: ignore 212
	print(string.format("Got control channel message (msg id=%d) of length %3d", msg_id, #data))
	if #data == 0 then return end
	local msg = cbor.decode(data)
	p(msg)
end)
control_room:new_channel(control_channel_key, 0)

cq:wrap(function()
	local neighbour = simple_protocol.connect(node, "127.0.0.1", 8000)

	local message_has_been_sent = false
	control_room:queue_message(cbor.encode({
		message = string.format("relayctl started at %s", os.date());
	}), function()
		-- message was sent
		message_has_been_sent = true
		control_room:tail(false)
	end)
	if not message_has_been_sent then
		-- the message was not sent yet; we need to tail the room
		control_room:tail(true)
	end

	neighbour:send_messages()
end)
local ok, err, _, thread = cq:loop()
if not ok then
	error(debug.traceback(thread, err))
end
