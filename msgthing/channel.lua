local hydrogen = require "hydrogen"
local secretbox = hydrogen.secretbox
local random_uniform = hydrogen.random.uniform

local channel_methods = {}
local channel_mt = {
	__name = "channel";
	__index = channel_methods;
}

local function get_hash(key, msg_id)
	-- TODO: hydrogen_hash should take secretbox key?
	local hash_state = hydrogen.hash.init("msg_hash", key:asstring())
	hash_state:update(string.pack(">I4", msg_id))
	-- FIXME https://github.com/jedisct1/libhydrogen/issues/38
	return hash_state:final(16):sub(1, 32//8)
end

local function new_channel(node, key, on_message)
	if key == nil then
		key = secretbox.keygen()
	elseif type(key) == "string" then
		key = secretbox.newkey(key)
	else
		error("invalid key")
	end
	return setmetatable({
		node = node;
		key = key;

		top_msg_seen = -1;
		top_msg_hash_sent = -1;

		-- Collection of messages that are wanted
		-- TODO: this needs to be a much better data structure
		wanted_old = {};
		want_after = nil;

		-- User provided callback
		on_message = on_message;
	}, channel_mt)
end

function channel_methods:next_counter()
	local c = self.top_msg_seen
	if c >= 0x80000000 then
		error("channel rotation required")
	end
	c = c + 1
	self.top_msg_seen = c
	return c
end

function channel_methods:accumulate_subscription(channel_acc)
	-- Ask for old wanted messages first
	for msg_hash, msg_id in pairs(self.wanted_old) do
		if not channel_acc:contains(msg_hash) then
			self.top_msg_hash_sent = math.max(self.top_msg_hash_sent, msg_id)
			return channel_acc:add(msg_hash)
		end
	end

	if self.want_after ~= nil then
		local c = self.want_after
		while true do
			-- As we get further from the counter, take bigger steps
			-- This randomness helps ensure that different nodes watching the same
			-- channel don't end up with the same subscriptions
			c = c + random_uniform(c-self.want_after)

			local msg_hash = get_hash(self.key, c)
			if not channel_acc:contains(msg_hash) then
				self.top_msg_hash_sent = math.max(self.top_msg_hash_sent, c)
				return channel_acc:add(msg_hash)
			end

			c = c + 1
		end
	end

	return nil
end

function channel_methods:tail_from(msg_id)
	self.want_after = msg_id
end

function channel_methods:send_message(plaintext)
	local msg_id = self:next_counter()
	local msg_hash = get_hash(self.key, msg_id)
	local ciphertext = secretbox.encrypt(plaintext, msg_id, "message\0", self.key)
	self.node:queue_message(msg_hash, ciphertext)
end

local function find_msg_id(self, msg_hash)
	-- see if the message is a wanted message
	local msg_id = self.wanted_old[msg_hash]
	if msg_id ~= nil then
		return msg_id
	end

	if self.want_after ~= nil then
		-- increment want_after looking for it....
		for id=self.want_after, self.top_msg_hash_sent do
			if msg_hash == get_hash(self.key, id) then
				return id
			end
		end
	end

	-- hash not known (maybe already received?)
	return nil
end

function channel_methods:try_parse_msg(msg_hash, ciphertext)
	local msg_id = find_msg_id(self, msg_hash)
	if msg_id == nil then
		return
	end

	local result = secretbox.decrypt(ciphertext, msg_id, "message\0", self.key)
	if result == nil then
		return
	end

	if msg_id >= self.want_after then
		for i=self.want_after, msg_id-1 do
			self.wanted_old[get_hash(self.key, i)] = i
		end
		self.want_after = msg_id + 1
	else
		self.wanted_old[msg_hash] = nil
	end

	if msg_id > self.top_msg_seen then
		self.top_msg_seen = msg_id
	end

	return msg_id, result
end

function channel_methods:process_incoming_message(msg_hash, ciphertext)
	local msg_id, result = self:try_parse_msg(msg_hash, ciphertext)
	if msg_id == nil then
		return nil
	end

	self:on_message(msg_id, result)
end

return {
	new = new_channel;
}
