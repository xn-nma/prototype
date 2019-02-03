local hydrogen = require "hydrogen"
local hydrogen_random_uniform = hydrogen.random.uniform
local new_channel = require "msgthing.channel".new
local new_neighbour = require "msgthing.neighbour".new

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

		min_sub_density = 17; -- RANDOM GUESS (32/2+a bit)
		max_neighbour_prop = 24; -- RANDOM GUESS

		stored_messages = {};
	}, node_mt)
end

local function popcount(x)
	local n = 0
	for i=0, 31 do
		if x & (1<<i) ~= 0 then
			n = n + 1
		end
	end
	return n
end

function node_methods:generate_subscription(skip_neighbour)
	local neighbour_acc
	local overload_factor = 0
	repeat
		neighbour_acc = 0
		for neighbour in pairs(self.neighbours) do
			if neighbour ~= skip_neighbour then
				local ns = string.unpack(">I4", neighbour.subscriptions)
				for _=0, neighbour.damping_factor + overload_factor do
					ns = ns & ~(1 << hydrogen_random_uniform(32))
				end
				neighbour_acc = neighbour_acc | ns
			end
		end
		overload_factor = overload_factor + 1
	until popcount(neighbour_acc) < self.max_neighbour_prop

	local acc
	if self.n_channels == 0 then
		-- make up fake subscriptions
		acc = neighbour_acc
		repeat
			acc = acc | (1 << hydrogen_random_uniform(32))
		until popcount(acc) >= self.min_sub_density
	else
		local channel_acc = 0
		repeat
			-- balance equally across channels
			-- TODO: weigh towards more active channels?
			for channel in pairs(self.channels) do
				channel_acc = channel:accumulate_subscription(channel_acc)
			end
			acc = channel_acc | neighbour_acc
		until popcount(acc) >= self.min_sub_density
	end
	return string.pack(">I4", acc)
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

