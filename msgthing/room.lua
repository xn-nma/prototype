-- A room is sort of a collection of channels,
-- This is an interface on top of the underlying channels as they rotate.

local new_fifo = require "fifo"
local msgthing_channel = require "msgthing.channel"

local room_methods = {}
local room_mt = {
	__name = "room";
	__index = room_methods;
}

local function new_room(node, on_message)
	return setmetatable({
		-- Node this room belongs too
		node = node;

		-- Collection of channels known about in this room
		channels = {};

		-- Messages yet to leave this node
		queued_messages = new_fifo();

		-- User provided callback
		on_message = on_message;
	}, room_mt)
end

function room_methods:add_channel(channel)
	table.insert(self.channels, channel)
end

function room_methods:new_channel(key, top_msg_id_seen)
	local channel = msgthing_channel.new(self, key, top_msg_id_seen, self.on_message)
	self:add_channel(channel)
	return channel
end

function room_methods:create_channel()
	local channel = msgthing_channel.create(self, self.on_message)
	self:add_channel(channel)
	return channel
end

function room_methods:process_incoming_message(neighbour, msg_hash, msg_obj)
	for _, channel in ipairs(self.channels) do
		if channel:process_incoming_message(msg_hash, msg_obj) then
			if #self.queued_messages > 0 and channel:next_id_matches(neighbour.subscription) then
				print("TAIL FOUND")
				-- TODO: want to process as many as possible before attempting?
				local queued_msg = self.queued_messages:pop()
				channel:write_message(queued_msg.message)
				if queued_msg.on_written then
					queued_msg.on_written()
				end
				return
			end

			return true
		end
	end
	return nil
end

function room_methods:tail(toggle)
	for _, channel in ipairs(self.channels) do
		channel:tail(toggle)
	end
end

function room_methods:prepare_messages_for_subscription(subscription)
	if #self.queued_messages == 0 then
		return
	end

	local most_recent_channel = self.channels[#self.channels]
	while most_recent_channel:next_id_matches(subscription) do
		print("NEW SUBSCRIPTION MATCHED")
		local queued_msg = self.queued_messages:pop()
		most_recent_channel:write_message(queued_msg.message)
		if queued_msg.on_written then
			queued_msg.on_written()
		end

		if #self.queued_messages == 0 then
			break
		end
	end
end

-- on_written is an optional callback for when the message gets a message id
-- note that it may have gone to another node only as chaff,
-- but the important thing is that it has been assigned a channel+message id
function room_methods:queue_message(msg, on_written)
	-- if there is a known subscription, we want to write it immediately
	local most_recent_channel = self.channels[#self.channels]
	for neighbour in pairs(self.node.neighbours) do
		if most_recent_channel:next_id_matches(neighbour.subscription) then
			print("FOUND EXISTING SUBSCRIPTION")
			most_recent_channel:write_message(msg)
			if on_written then
				on_written()
			end
			return
		end
	end

	-- otherwise we queue up message for a future subscriber
	print("QUEUING MESSAGE FOR LATER")
	self.queued_messages:push({
		message = msg;
		on_written = on_written;
	})
end

return {
	new = new_room;
}
