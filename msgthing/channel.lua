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

local function is_sync_msg(msg_id)
	return msg_id & (limit-1) == 0 and msg_id ~= 0
end

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

local function new_channel(room, key, top_msg_id_seen, on_message)
	if type(key) == "string" then
		key = secretbox.newkey(key)
	elseif type(key) ~= "userdata" then -- TODO: check key type properly
		error("invalid key")
	end
	if top_msg_id_seen == nil then
		top_msg_id_seen = -1
	elseif type(top_msg_id_seen) ~= "number" or top_msg_id_seen < 0 then
		error("invalid top_msg_id_seen")
	end
	return setmetatable({
		room = room;
		key = key;

		top_msg_id_seen = top_msg_id_seen;
		top_msg_hash_sent = -1;

		-- Known DAG heads
		-- Collection of full message hashes
		heads = setmetatable({n=0}, heads_mt);

		-- Last seen sync messages for each power of two
		sync_messages = {
			nil, nil, nil, nil, -- limit_pow -1 nils
			{}, {}, {}, {},
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

-- TODO: take channel properties should include:
--  - admin keys
--  - parent channel (optional)
local function create_channel(room, on_message)
	local key = secretbox.keygen()
	local channel = new_channel(room, key, nil, on_message)
	-- Create message id 0
	-- channel:store_message("START OF CHANNEL")
	return channel
end

function channel_methods:accumulate_subscription(channel_acc)
	-- Ask for old wanted messages first
	for msg_hash, msg_id in pairs(self.wanted_by_hash) do
		if not channel_acc:contains(msg_hash) then
			self.top_msg_hash_sent = math.max(self.top_msg_hash_sent, msg_id)
			-- print("ASKING FOR WANTED", msg_id)
			return channel_acc:add(msg_hash)
		end
	end

	if self.want_after ~= nil then
		local c = math.max(self.top_msg_id_seen+1, self.want_after)

		-- if c == 0 then
		-- 	local msg_hash = get_hash(self.key, 0)
		-- 	if not channel_acc:contains(msg_hash) then
		-- 		return channel_acc:add(msg_hash)
		-- 	end
		-- 	c = c + 1
		-- end

		-- 50/50 chance
		if random_uniform(2) == 0 then
			-- Ask for a random sync message
			local x = 1<<(limit_pow+random_uniform(32-limit_pow))
			-- pick next power of two message id
			-- e.g. if x == 1500, we want:
			-- 1500+(32-1500%32)=1504
			-- 1500+(64-1500%64)=1536
			-- 1500+(128-1500%128)=1536
			-- 1500+(256-1500%256)=1536
			-- 1500+(512-1500%512)=1536
			-- 1500+(1024-1500%1024)=2048
			--
			-- e.g. at 190: starting at `top+1`
			-- powers of two:  32,  64, 128, 256, 512, 1024, 2048, ...
			-- will ask for:  192, 192, 256, 256, 512, 1024, 2048, ...
			--
			-- now say you receive 256; we start again with `top+1`
			-- powers of two   32,  64, 128, 256, 512, 1024, 2048, ...
			-- will ask for:  288, 320, 384, 512, 512, 1024, 2048, ...
			--
			-- XXX: Is there an information leak of the sync message position?
			-- (because of frequency of given msg_hash in a subscription)
			-- Could it be solve by making sure you never pick a higher power?
			-- e.g. in the above example, 256 would pick 768 instead

			-- The operation we're doing is
			-- `p = c + (x - c % x)` where x is a power of two
			-- `x % y` where y is a power of two is equivalent to `x & (y-1)`
			-- i.e. `p = c + x - (c & (x-1))`
			-- which can be further simplified to:
			local p = (c|(x-1))+1

			local msg_hash = get_hash(self.key, p)
			if not channel_acc:contains(msg_hash) then
				-- print("ASKING FOR SYNC ", p)
				return channel_acc:add(msg_hash)
			end
		end

		-- TODO: check for rotation message?

		while true do
			local msg_hash = get_hash(self.key, c)
			if not channel_acc:contains(msg_hash) then
				self.top_msg_hash_sent = math.max(self.top_msg_hash_sent, c)

				-- print("ASKING FOR TAIL", c)
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

function channel_methods:tail(toggle)
	if toggle then
		if not self.want_after or self.want_after < self.top_msg_id_seen then
			local from = math.max(self.top_msg_id_seen, 0)
			self:tail_from(from)
		end
	else
		self.want_after = nil
	end
end

function channel_methods:next_id_matches(subscription)
	local next_msg_id = self.top_msg_id_seen + 1
	local msg_hash = get_hash(self.key, next_msg_id)
	return subscription:contains(msg_hash)
end

function channel_methods:write_message(msg)
	local msg_id = self.top_msg_id_seen + 1
	if msg_id >= 0x80000000 then
		error("channel rotation required")
	end
	if is_sync_msg(msg_id) then
		-- send sync message
		local sync_msg = cbor.encode(self.heads)
		local msg_hash = get_hash(self.key, msg_id)
		local ciphertext = secretbox.encrypt(sync_msg, msg_id, "message\0", self.key)
		local msg_obj = {
			ref_count = 1; -- for going into sync_messages
			ciphertext = ciphertext;
		}
		for i=limit_pow, 31 do
			if msg_id % (1<<i) == 0 then
				self.sync_messages[i][1] = msg_obj
			end
		end
		self.top_msg_id_seen = msg_id
		print("STORING SYNC MESSAGE", msg_id)
		self.room.node:store_message(msg_hash, msg_obj)
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
	self.top_msg_id_seen = msg_id
	print("STORING MESSAGE", msg_id, msg)
	self.room.node:store_message(msg_hash, msg_obj)
	self.heads = setmetatable({
		{ id = msg_id, full_hash = get_full_hash(self.key, ciphertext) };
		n = 1;
	}, heads_mt)
end

local function find_msg_id(self, msg_hash)
	do -- see if the message is a known wanted message
		local msg_id = self.wanted_by_hash[msg_hash]
		if msg_id ~= nil then
			return msg_id
		end
	end

	local want_after = self.want_after
	if want_after ~= nil then
		do -- check sync messages
			local c = math.max(want_after, 1)
			for pow=limit_pow,31 do
				local msg_id = (c|((1<<pow)-1))+1
				if msg_hash == get_hash(self.key, msg_id) then
					return msg_id
				end
			end
		end

		-- increment want_after looking for it....
		for msg_id=want_after, self.top_msg_hash_sent do
			if msg_hash == get_hash(self.key, msg_id) then
				return msg_id
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

	if is_sync_msg(msg_id) then
		-- is sync message
		if pos - 1 ~= #result then
			return nil, "invalid message: sync messages may not have a payload"
		end
		-- TODO: confirm that `msg_id - 1` is in `after`
	end

	return msg_id, after, result:sub(pos)
end

function channel_methods:process_incoming_message(msg_hash, msg_obj)
	local msg_id, after, result = self:try_parse_msg(msg_hash, msg_obj.ciphertext)
	if msg_id == nil then
		print("FAILED TO PARSE MESSAGE", after)
		return nil
	end

	if is_sync_msg(msg_id) or msg_id == 0 then
		-- is a sync or creation message: hang onto it!
		msg_obj.ref_count = msg_obj.ref_count + 1
		for i=limit_pow, 31 do
			if msg_id % (1<<i) == 0 then
				table.insert(self.sync_messages[i], msg_obj)
			end
		end
	end

	do -- Remove full hash if it was wanted
		local by_id = self.wanted_by_id[msg_id]
		if by_id then
			local full_hash = get_full_hash(self.key, msg_obj.ciphertext)
			if by_id[full_hash] ~= nil then
				by_id[full_hash] = nil
				if next(by_id) == nil then
					self.wanted_by_id[msg_id] = nil
					print("REMOVED", msg_id)
					self.wanted_by_hash[msg_hash] = nil
				end
			end
		end
	end

	for i=1, after.n do
		local ref = after[i]
		print("AFTER", ref.id)--, ref.msg_hash, ref.full_hash)
		if self.want_after and ref.id >= self.want_after then
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

	if msg_id > self.top_msg_id_seen then
		self.top_msg_id_seen = msg_id
	end

	self:on_message(msg_id, result)

	return true
end

return {
	new = new_channel;
	create = create_channel;
}
