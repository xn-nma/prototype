local new_channel = require "msgthing.channel".new
local new_neighbour = require "msgthing.neighbour".new
local subscription_type = require "msgthing.subscription"
local new_subscription = subscription_type.new
local subscription_union = subscription_type.union

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
		min_sub_density = 512 * 0.6;

		-- Heuristic to be tuned
		-- (don't want to let an eagerly listening neighbour saturate our subscriptions?)
		max_neighbour_propagate = 512 * 0.7;

		stored_messages = {};
	}, node_mt)
end

function node_methods:generate_subscription(skip_neighbour)
	local neighbour_acc
	local overload_factor = 0
	repeat
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

	local acc
	if self.n_channels == 0 then
		-- make up fake subscriptions
		acc = neighbour_acc:widen(self.min_sub_density)
	else
		local channel_acc = new_subscription()
		repeat
			-- balance equally across channels
			-- TODO: weigh towards more active channels?
			for channel in pairs(self.channels) do
				channel_acc = channel:accumulate_subscription(channel_acc)
			end
			acc = subscription_union(channel_acc, neighbour_acc)
		until acc:popcount() >= self.min_sub_density
	end
	return acc
end

function node_methods:new_channel(key, on_message)
	local channel = new_channel(self, key, on_message)
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
	local by_hash = self.stored_messages[msg_hash]
	if by_hash == nil then
		by_hash = {}
		self.stored_messages[msg_hash] = by_hash
	end
	by_hash[data] = true
end

function node_methods:process_incoming_message(msg_hash, data)
	-- Send to local channels
	for channel in pairs(self.channels) do
		channel:process_incoming_message(msg_hash, data)
	end
	-- Relay to neighbours
	self:queue_message(msg_hash, data)
end

return {
	new = new_node;
}

