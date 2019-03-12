local new_room = require "msgthing.room".new
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
		rooms = {};
		n_rooms = 0;

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
		-- balances equally across rooms+channels
		-- TODO: weigh towards more active channels?
		local non_null_rooms = 0
		for room in pairs(self.rooms) do
			for _, channel in ipairs(room.channels) do
				local tmp = channel:accumulate_subscription(acc)
				if tmp ~= nil then
					acc = tmp
					non_null_rooms = non_null_rooms + 1
				end
			end
		end
	until non_null_rooms == 0 or acc:popcount() >= self.min_sub_density

	-- make up fake subscriptions
	acc = acc:widen(self.min_sub_density)

	return acc
end

function node_methods:new_room(on_message)
	local room = new_room(self, on_message)
	self.rooms[room] = true
	self.n_rooms = self.n_rooms + 1
	return room
end

function node_methods:new_neighbour(broadcast_cb)
	local neighbour = new_neighbour(self, broadcast_cb)
	self.neighbours[neighbour] = true
	return neighbour
end

function node_methods:delete_neighbour(neighbour)
	self.neighbours[neighbour] = nil
end

function node_methods:prepare_messages_for_subscription(subscription)
	for room in pairs(self.rooms) do
		room:prepare_messages_for_subscription(subscription)
	end
end

-- takes ownership of msg_obj
function node_methods:store_message(msg_obj)
	local msg_hash = msg_obj.msg_hash
	local by_hash = self.stored_messages[msg_hash]
	if by_hash == nil then
		by_hash = {}
		self.stored_messages[msg_hash] = by_hash
	end
	by_hash[msg_obj] = true
end

function node_methods:process_incoming_message(neighbour, msg_hash, data)
	local msg_obj = {
		ref_count = 0;
		msg_hash = msg_hash;
		ciphertext = data;
	}
	-- Send to local rooms
	for room in pairs(self.rooms) do
		if room:process_incoming_message(neighbour, msg_hash, msg_obj) then
			-- matching room found; no need to try others
			-- (should never match more than one)
			break
		end
	end
	-- Relay to neighbours
	self:store_message(msg_obj)
end

return {
	new = new_node;
}

