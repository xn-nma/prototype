local hydrogen = require "hydrogen"
local secretbox = hydrogen.secretbox
local random_uniform = hydrogen.random.uniform
local cbor = require "org.conman.cbor"

local channel_methods = {}
local channel_mt = {
	__name = "channel";
	__index = channel_methods;
}

-- msg ids that are a multiple of 'limit'
-- are 'sync' messages
-- they should be held onto with longer lifetime than other messages
-- they should have no body
local limit_pow = 5
local limit = 1 << limit_pow -- i.e. 32

local function get_hash(key, msg_id)
	-- TODO: hydrogen_hash should take secretbox key?
	local hash_state = hydrogen.hash.init("msg_hash", key:asstring())
	hash_state:update(string.pack(">I4", msg_id))
	-- FIXME https://github.com/jedisct1/libhydrogen/issues/38
	return hash_state:final(16):sub(1, 32//8)
end

local function get_full_hash(key, ciphertext)
	local hash_state = hydrogen.hash.init("fullhash", key:asstring())
	hash_state:update(ciphertext)
	return hash_state:final(16)
end

local heads_mt = {
	__name = "channel.heads";
	-- For cbor to detect as array
	__len = function(self) return self.n end;
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

		top_msg_seen = -1;
		top_msg_hash_sent = -1;

		-- Known DAG heads
		-- Collection of full message hashes
		heads = setmetatable({n=0}, heads_mt);

		-- Last seen sync messages for each power of two
		sync_messages = {
			nil, nil, nil, nil, nil, -- limit_pow nils
			{}, {}, {},
			{}, {}, {}, {}, {}, {}, {}, {},
			{}, {}, {}, {}, {}, {}, {}, {},
			{}, {}, {}, {}, {}, {}, {}, {}
		};

		-- Collection of messages that are wanted
		-- TODO: this needs to be a much better data structure
		wanted_by_id = {}; -- indexed by id then by full_hash
		wanted_by_hash = {}; -- map from msg_hash to msg_id for things in `wanted`
		want_after = nil;

		-- User provided callback
		on_message = on_message;
	}, channel_mt)
end

function channel_methods:accumulate_subscription(channel_acc)
	-- Ask for old wanted messages first
	for msg_hash, msg_id in pairs(self.wanted_by_hash) do
		if not channel_acc:contains(msg_hash) then
			self.top_msg_hash_sent = math.max(self.top_msg_hash_sent, msg_id)
			return channel_acc:add(msg_hash)
		end
	end

	if self.want_after ~= nil then
		local c = math.max(self.top_msg_seen+1, self.want_after)

		-- 50/50 chance
		if random_uniform(2) == 0 then
			-- pick next power of two message id
			-- e.g. if x == 1500, we want:
			-- 1500+(32-1500%32)=1504
			-- 1500+(64-1500%64)=1536
			-- 1500+(128-1500%128)=1536
			-- 1500+(256-1500%256)=1536
			-- 1500+(512-1500%512)=1536
			-- 1500+(1024-1500%1024)=2048
			-- etc.
			local pow = 32
			while true do
				local p = c + (pow - c%pow)

				local msg_hash = get_hash(self.key, p)
				if not channel_acc:contains(msg_hash) then
					return channel_acc:add(msg_hash)
				end

				if pow == 0x80000000 then
					break
				end

				pow = pow << 1
			end
		end

		while true do
			local msg_hash = get_hash(self.key, c)
			if not channel_acc:contains(msg_hash) then
				self.top_msg_hash_sent = math.max(self.top_msg_hash_sent, c)
				return channel_acc:add(msg_hash)
			end

			-- As we get further from the counter, take bigger steps
			-- This randomness helps ensure that different nodes watching the same
			-- channel don't end up with the same subscriptions
			c = c + 1 + random_uniform(c-self.want_after)
		end
	end

	return nil
end

function channel_methods:tail_from(msg_id)
	self.want_after = msg_id
end

function channel_methods:queue_message(msg)
	local msg_id = self.top_msg_seen + 1
	if msg_id >= 0x80000000 then
		error("channel rotation required")
	end
	if msg_id % limit == 0 then
		-- send sync message
		local sync_msg = cbor.encode(self.heads)
		local msg_hash = get_hash(self.key, msg_id)
		local ciphertext = secretbox.encrypt(sync_msg, msg_id, "message\0", self.key)
		local msg_obj = {
			ref_count = 1; -- for going into sync_messages
			ciphertext = ciphertext;
		}
		for i=limit, 31 do
			if msg_id % (1<<i) == 0 then
				self.sync_messages[i][1] = msg_obj
			end
		end
		self.top_msg_seen = msg_id
		self.node:queue_message(msg_hash, msg_obj)
		self.heads = setmetatable({
			{ id = msg_id, full_hash = get_full_hash(self.key, ciphertext) };
			n = 1;
		}, heads_mt)
		msg_id = msg_id + 1
	end

	local msg_hash = get_hash(self.key, msg_id)
	-- TODO: pad msg?
	local plaintext = cbor.encode(self.heads) .. msg
	local ciphertext = secretbox.encrypt(plaintext, msg_id, "message\0", self.key)
	local msg_obj = {
		ref_count = 0;
		ciphertext = ciphertext;
	}
	self.top_msg_seen = msg_id
	self.node:queue_message(msg_hash, msg_obj)
	self.heads = setmetatable({
		{ id = msg_id, full_hash = get_full_hash(self.key, ciphertext) };
		n = 1;
	}, heads_mt)
end

local function find_msg_id(self, msg_hash)
	-- see if the message is a wanted message
	local msg_id = self.wanted_by_hash[msg_hash]
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
		return nil, "unable to find suitable message id"
	end

	local result = secretbox.decrypt(ciphertext, msg_id, "message\0", self.key)
	if result == nil then
		return nil, "unable to decrypt"
	end

	local after, pos, after_type = cbor.decode(result)
	if after_type ~= "ARRAY" then
		return nil, "invalid message: 'after' field malformed"
	end
	after.n = #after
	for i=1, after.n do
		local ref = after[i]
		if type(ref) ~= "table" or
			type(ref.id) ~= "number" or
			ref.id < 0 or ref.id > 0x80000000 or ref.id % 1 ~= 0 or
			type(ref.full_hash) ~= "string" or
			#ref.full_hash ~= 16 then
			return nil, "invalid message: 'after' field malformed"
		elseif ref.id >= msg_id then
			return nil, "invalid message: message id precedes 'after'"
		end
	end
	setmetatable(after, heads_mt)

	if msg_id % limit == 0 then
		-- is sync message
		if pos - 1 ~= #result then
			return nil, "invalid message: sync messages may not have a payload"
		end
		-- TODO: confirm that `msg_id - 1` is in `after`
	end

	return msg_id, after, result:sub(pos)
end

function channel_methods:process_incoming_message(msg_hash, ciphertext)
	local msg_id, after, result = self:try_parse_msg(msg_hash, ciphertext)
	if msg_id == nil then
		return nil
	end

	do -- Remove full hash if it was 'wanted'
		local by_id = self.wanted_by_id[msg_id]
		if by_id then
			local full_hash = get_full_hash(self.key, ciphertext)
			local msg = by_id[full_hash]
			if msg ~= nil then
				by_id[full_hash] = nil
				if next(by_id) == nil then
					self.wanted_by_id[msg_id] = nil
					self.wanted_by_hash[msg_hash] = nil
				end
			end
		end
	end

	for i=1, after.n do
		local ref = after[i]
		if ref.id >= self.want_after then
			local by_id = self.wanted_by_id[ref.id]
			if by_id == nil then
				by_id = {}
				self.wanted_by_id[ref.id] = by_id
				local ref_hash = get_hash(self.key, ref.id)
				self.wanted_by_hash[ref_hash] = ref.id
			end
			by_id[ref.full_hash] = true
		end
	end

	if msg_id > self.top_msg_seen then
		self.top_msg_seen = msg_id
	end

	self:on_message(msg_id, result)

	return true
end

return {
	new = new_channel;
}
