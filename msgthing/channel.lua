local hydrogen = require "hydrogen"
local secretbox = hydrogen.secretbox
local random_uniform = hydrogen.random.uniform

local channel_methods = {}
local channel_mt = {
	__name = "channel";
	__index = channel_methods;
}

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
		last_counter = -1;
		top_msg_hash_sent = -1;

		-- Collection of messages (pre last_counter) that are wanted
		-- TODO: make this an ordered collection
		-- TODO: (globally) lost messages shouldn't take up memory forever
		wanted_old_messages = {};

		-- User provided callback
		on_message = on_message;
	}, channel_mt)
end

function channel_methods:next_counter()
	local c = self.last_counter
	if c >= 0x80000000 then
		error("channel rotation required")
	end
	c = c + 1
	self.last_counter = c
	return c
end

local function get_hash(self, msg_id)
	-- TODO: hydrogen_hash should take secretbox key?
	local hash_state = hydrogen.hash.init("msg_hash", self.key:asstring())
	hash_state:update(string.pack(">I4", msg_id))
	-- FIXME https://github.com/jedisct1/libhydrogen/issues/38
	return hash_state:final(16):sub(1, 32//8)
end

function channel_methods:accumulate_subscription(channel_acc)
	-- Ask for old wanted messages first
	for msg_hash in pairs(self.wanted_old_messages) do
		if not channel_acc:contains(msg_hash) then
			return channel_acc:add(msg_hash)
		end
	end

	local c = self.last_counter
	while true do
		-- As we get further from last_counter, take bigger steps
		-- This randomness helps ensure that different nodes watching the same
		-- channel don't end up with the same subscriptions
		c = c + 1 + random_uniform(c-self.last_counter)

		local msg_hash = get_hash(self, c)
		if not channel_acc:contains(msg_hash) then
			self.top_msg_hash_sent = c
			return channel_acc:add(msg_hash)
		end
	end

	error("unreachable") -- luacheck: ignore 511
end

function channel_methods:send_message(plaintext)
	local msg_id = self:next_counter()
	local msg_hash = get_hash(self, msg_id)
	local ciphertext = secretbox.encrypt(plaintext, msg_id, "message\0", self.key)
	self.node:queue_message(msg_hash, ciphertext)
end

local function find_msg_id(self, msg_hash)
	-- see if the message is a wanted message
	local msg_id = self.wanted_old_messages[msg_hash]
	if msg_id ~= nil then
		return msg_id
	end

	-- not a wanted message; increment last_counter looking for it....
	for id=self.last_counter+1, self.top_msg_hash_sent do
		if msg_hash == get_hash(self, id) then
			return id
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

	if msg_id > self.last_counter then
		for i=self.last_counter+1, msg_id-1 do
			self.wanted_old_messages[get_hash(self, i)] = i
		end
		self.last_counter = msg_id
	else
		self.wanted_old_messages[msg_hash] = nil
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
