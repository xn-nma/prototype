local new_stable_bloom_filter = require "msgthing.stable_bloom_filter".new
local subscription_type = require "msgthing.subscription"
local new_subscription = subscription_type.new
local deserialize_subscription = subscription_type.deserialize

local neighbour_methods = {}
local neighbour_mt = {
	__name = "neighbour";
	__index = neighbour_methods;
}

local function new_neighbour(node, broadcast)
	return setmetatable({
		-- Node that this belongs to
		node = node;

		-- Neighbour's subscription
		subscription = new_subscription();

		-- Stable Bloom filter of what they've already seen
		already_seen = new_stable_bloom_filter(1024, 3, 0.005);

		-- A neighbour's damping_factor is how many times to approximately
		-- halve their traffic compared to what they asked for.
		-- Example values:
		--   0: a straight-through repeater
		--   1: normal default so that traffic halves for each hop traversed
		damping_factor = 1;

		-- The filter sent to this neighbour
		our_subscription = new_subscription();

		-- Whether to process packets that match a local subscription
		-- but that you never told the neighbour about
		process_unsubscribed = true;

		-- Callback
		broadcast = broadcast;
	}, neighbour_mt)
end


function neighbour_methods:broadcast_message(msg_hash, data)
	if not self.subscription:contains(msg_hash) then
		return
	end

	if self.already_seen:check(data) then
		return
	end

	self.already_seen:add(data)

	self:broadcast("M", msg_hash .. data)
end

function neighbour_methods:send_subscription()
	local subscription = self.node:generate_subscription(self)
	self.our_subscription = subscription
	self:broadcast("S", subscription:serialize())
end

function neighbour_methods:process_incoming_message(packet)
	local msg_hash = packet:sub(1, 4)
	if not self.process_unsubscribed and self.our_subscription:contains(msg_hash) then
		return
	end

	local ciphertext = packet:sub(5)

	self.already_seen:add(ciphertext)
	self.node:process_incoming_message(msg_hash, ciphertext)
end

function neighbour_methods:process_incoming_subscribe(packet)
	local new_sub = deserialize_subscription(packet)
	if not new_sub then
		return
	end

	self.subscription = new_sub

	-- Reset already_seen
	-- their new subscription should have removed messages they're no
	-- longer interested in. If they want to receive the message again,
	-- then that's their prerogative
	self.already_seen:reset()
end

function neighbour_methods:send_messages()
	-- XXX: this currently sends *all* matching messages.
	-- instead, it should just send a selectable number
	--
	-- when updating this code, make sure that the messages
	-- in the store isn't discoverable by hash
	for msg_hash, by_hash in pairs(self.node.stored_messages) do
		if self.subscription:contains(msg_hash) then
			for message in pairs(by_hash) do
				self:broadcast_message(msg_hash, message)
			end
		end
	end
end

function neighbour_methods:process_packet(packet_type, packet)
	if packet_type == "M" then
		return self:process_incoming_message(packet)
	elseif packet_type == "S" then
		return self:process_incoming_subscribe(packet)
	else
		error("unknown packet type")
	end
end

return {
	new = new_neighbour;
}
