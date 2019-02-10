-- Immutable type for subscriptions
-- Currently implementation is a bloomfilter

local hydrogen = require "hydrogen"
local hydrogen_random_uniform = hydrogen.random.uniform
local hash_init = hydrogen.hash.init

local subscription_methods = {}
local subscription_mt = {
	__name = "subscription";
	__index = subscription_methods;
}

-- Using 512 bits as 64 bytes seems like a reasonable subscription packet size
local N_BITS = 512
assert(N_BITS % 8 == 0, "invalid N_BITS")

-- number of hash functions
-- trade off of how quickly to fill subscription table
-- approx#subscriptions = N_BITS / K * ln(2)
local K = 8

local function new_subscription()
	return setmetatable({
		0x0000000000000000, 0x0000000000000000,
		0x0000000000000000, 0x0000000000000000,
		0x0000000000000000, 0x0000000000000000,
		0x0000000000000000, 0x0000000000000000,
	}, subscription_mt)
end

local function deserialize_subscription(raw)
	if #raw ~= N_BITS // 8 then
		return nil, "invalid length"
	end
	return setmetatable({
		string.unpack(">I8I8I8I8I8I8I8I8", raw)
	}, subscription_mt)
end

function subscription_methods:serialize()
	return string.pack(">I8I8I8I8I8I8I8I8",
		self[1], self[2], self[3], self[4],
		self[5], self[6], self[7], self[8]
	)
end

local function union(x, y)
	assert(getmetatable(x) == subscription_mt)
	assert(getmetatable(y) == subscription_mt)
	return setmetatable({
		x[1] | y[1],
		x[2] | y[2],
		x[3] | y[3],
		x[4] | y[4],
		x[5] | y[5],
		x[6] | y[6],
		x[7] | y[7],
		x[8] | y[8]
	}, subscription_mt)
end

subscription_methods.union = union

function subscription_methods:add(hash)
	assert(#hash == 4)
	local hash_state = hash_init("subscrip", nil)
	hash_state:update(hash)
	local r = {
		self[1], self[2], self[3], self[4],
		self[5], self[6], self[7], self[8]
	}
	local extended_hash = hash_state:final(math.max(16, K*2))
	for i=0, K-1 do
		local bit = string.unpack(">I2", extended_hash, i*2+1) & (N_BITS - 1)
		local idx = (bit >> 6) + 1
		local shift = bit & (64-1)
		r[idx] = r[idx] | (1 << shift)
	end
	return setmetatable(r, subscription_mt)
end

function subscription_methods:contains(hash)
	assert(#hash == 4)
	local hash_state = hash_init("subscrip", nil)
	hash_state:update(hash)
	local extended_hash = hash_state:final(math.max(16, K*2))
	for i=0, K-1 do
		local bit = string.unpack(">I2", extended_hash, i*2+1) & (N_BITS - 1)
		local idx = (bit >> 6) + 1
		local shift = bit & (64-1)
		if self[idx] & (1 << shift) == 0 then
			return false
		end
	end
	return true
end

-- Inject more false positives
function subscription_methods:widen(min_size)
	local r = setmetatable({
		self[1], self[2], self[3], self[4],
		self[5], self[6], self[7], self[8]
	}, subscription_mt)
	while r:popcount() < min_size do
		local bit = hydrogen_random_uniform(N_BITS)
		local idx = (bit >> 6) + 1
		local shift = bit & 0x3F
		r[idx] = r[idx] | (1 << shift)
	end
	return r
end

-- Drop n bits
function subscription_methods:discard(n)
	local r = {
		self[1], self[2], self[3], self[4],
		self[5], self[6], self[7], self[8]
	}
	for _=0, n do
		local bit = hydrogen_random_uniform(N_BITS)
		local idx = (bit >> 6) + 1
		local shift = bit & 0x3F
		r[idx] = r[idx] & ~(1 << shift)
	end
	return setmetatable(r, subscription_mt)
end

function subscription_methods:popcount()
	local n = 0
	for b=1, N_BITS//64 do
		local x = self[b]
		for i=0, 63 do
			if x & (1<<i) ~= 0 then
				n = n + 1
			end
		end
	end
	return n
end

return {
	N_BITS = N_BITS;
	new = new_subscription;
	deserialize = deserialize_subscription;
	union = union;
}
