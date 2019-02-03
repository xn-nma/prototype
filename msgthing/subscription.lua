-- Currently implementation is a degenerate bloomfilter
-- Immutable type for subscriptions

local hydrogen = require "hydrogen"
local hydrogen_random_uniform = hydrogen.random.uniform

local subscription_methods = {}
local subscription_mt = {
	__name = "subscription";
	__index = subscription_methods;
}

local function new_subscription()
	return setmetatable({
		0x00000000
	}, subscription_mt)
end

local function deserialize_subscription(raw)
	assert(#raw == 4)
	return setmetatable({
		string.unpack(">I4", raw)
	}, subscription_mt)
end

function subscription_methods:serialize()
	return string.pack(">I4", self[1])
end

local function union(x, y)
	assert(getmetatable(x) == subscription_mt)
	assert(getmetatable(y) == subscription_mt)
	return setmetatable({
		x[1] | y[1]
	}, subscription_mt)
end

subscription_methods.union = union

function subscription_methods:add(hash)
	assert(#hash == 4)
	hash = string.unpack(">I4", hash)
	return setmetatable({
		self[1] | hash
	}, subscription_mt)
end

-- Have more false positives
function subscription_methods:widen(min_size)
	local r = setmetatable({
		self[1]
	}, subscription_mt)
	while r:popcount() < min_size do
		r[1] = r[1] | (1 << hydrogen_random_uniform(32))
	end
	return r
end

-- Drop n bits
function subscription_methods:discard(n)
	local r = self[1]
	for _=0, n do
		local bit = hydrogen_random_uniform(32)
		r = r & ~(1 << bit)
	end
	return setmetatable({
		r
	}, subscription_mt)
end

function subscription_methods:contains(hash)
	assert(#hash == 4)
	hash = string.unpack(">I4", hash)
	return (self[1] & hash) == hash
end

function subscription_methods:popcount()
	local n = 0
	local x = self[1]
	for i=0, 31 do
		if x & (1<<i) ~= 0 then
			n = n + 1
		end
	end
	return n
end

return {
	new = new_subscription;
	deserialize = deserialize_subscription;
	union = union;
}
