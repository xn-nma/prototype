local new_channel = require "msgthing.channel".new
local new_neighbour = require "msgthing.neighbour".new
local subscription_type = require "msgthing.subscription"
local new_subscription = subscription_type.new

local node_methods = {}
local node_mt = {
	__name = "node";
	__index = node_methods;
}

local function new_node()
	return setmetatable({
		channels = {};
		n_channels = 0;

		neighbours = {};

		-- Heuristic to be tuned
		min_sub_density = subscription_type.N_BITS * 0.6;

		-- Heuristic to be tuned
		-- (don't want to let an eagerly listening neighbour saturate our subscriptions?)
		max_neighbour_propagate = subscription_type.N_BITS * 0.7;

		stored_messages = {};
	}, node_mt)
end

function node_methods:generate_subscription(skip_neighbour)
	local neighbour_acc
	local overload_factor = 0
	repeat
		-- XXX: does this result in leaking the number of neighbours?
		neighbour_acc = new_subscription()
		for neighbour in pairs(self.neighbours) do
			if neighbour ~= skip_neighbour then
				local ns = neighbour.subscription
				ns = ns:discard(neighbour.damping_factor + overload_factor)
				neighbour_acc = neighbour_acc:union(ns)
			end
		end
		overload_factor = overload_factor + 1
	until neighbour_acc:popcount() <= self.max_neighbour_propagate

	local acc = neighbour_acc
	repeat
		-- balances equally across channels
		-- TODO: weigh towards more active channels?
		local non_null_channels = 0
		for channel in pairs(self.channels) do
			local tmp = channel:accumulate_subscription(acc)
			if tmp ~= nil then
				acc = tmp
				non_null_channels = non_null_channels + 1
			end
		end
	until non_null_channels == 0 or acc:popcount() >= self.min_sub_density

	-- make up fake subscriptions
	acc = acc:widen(self.min_sub_density)

	return acc
end

function node_methods:new_channel(key, top_msg_id_seen, on_message)
	local channel = new_channel(self, key, top_msg_id_seen, on_message)
	self.channels[channel] = true
	self.n_channels = self.n_channels + 1
	return channel
end

function node_methods:new_neighbour(broadcast_cb)
	local neighbour = new_neighbour(self, broadcast_cb)
	self.neighbours[neighbour] = true
	return neighbour
end

function node_methods:queue_message(msg_hash, data)
	data.ref_count = data.ref_count + 1
	local by_hash = self.stored_messages[msg_hash]
	if by_hash == nil then
		by_hash = {}
		self.stored_messages[msg_hash] = by_hash
	end
	by_hash[data] = true
end

function node_methods:process_incoming_message(msg_hash, data)
	local msg_obj = {
		ref_count = 0;
		ciphertext = data;
	}
	-- Send to local channels
	for channel in pairs(self.channels) do
		channel:process_incoming_message(msg_hash, msg_obj)
	end
	-- Relay to neighbours
	self:queue_message(msg_hash, msg_obj)
end

return {
	new = new_node;
}

