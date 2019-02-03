local hash_matches = require "msgthing.common".hash_matches
local new_stable_bloom_filter = require "msgthing.stable_bloom_filter".new

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
		subscriptions = "\0\0\0\0";

		-- Stable Bloom filter of what they've already seen
		already_seen = new_stable_bloom_filter(1024, 3, 0.005);

		-- A neighbour's damping_factor is how many times to approximately
		-- halve their traffic compared to what they asked for.
		-- Example values:
		--   0: a straight-through repeater
		--   1: normal default so that traffic halves for each hop traversed
		damping_factor = 1;

		-- The filter sent to this neighbour
		our_subscription = "\0\0\0\0";

		-- Whether to process packets that match a local subscription
		-- but that you never told the neighbour about
		process_unsubscribed = true;

		-- Callback
		broadcast = broadcast;
	}, neighbour_mt)
end


function neighbour_methods:broadcast_message(msg_hash, data)
	if not hash_matches(self.subscriptions, msg_hash) then
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
	self:broadcast("S", subscription)
end

function neighbour_methods:process_incoming_message(packet)
	local msg_hash = packet:sub(1, 4)
	if not self.process_unsubscribed and hash_matches(self.our_subscription, msg_hash) then
		return
	end

	local ciphertext = packet:sub(5)

	self.already_seen:add(ciphertext)
	self.node:process_incoming_message(msg_hash, ciphertext)
end

function neighbour_methods:process_incoming_subscribe(packet)
	assert(#packet == 4)
	self.subscriptions = packet
end

function neighbour_methods:send_messages()
	-- XXX: this currently sends *all* matching messages.
	-- instead, it should just send a selectable number
	--
	-- when updating this code, make sure that the messages
	-- in the store isn't discoverable by hash
	for msg_hash, by_hash in pairs(self.node.stored_messages) do
		if hash_matches(self.subscriptions, msg_hash) then
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
