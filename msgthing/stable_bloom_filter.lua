-- https://webdocs.cs.ualberta.ca/~drafiei/papers/DupDet06Sigmod.pdf
-- https://github.com/jjedele/stable-bloom-filter/blob/master/src/main/java/de/jjedele/sbf/StableBloomFilter.java

local hydrogen = require "hydrogen"
local hash_init = hydrogen.hash.init
local random_u32 = hydrogen.random.u32
local random_uniform = hydrogen.random.uniform

local stable_bloom_filter_methods = {}
local stable_bloom_filter_mt = {
	__name = "stable_bloom_filter";
	__index = stable_bloom_filter_methods;
}

local max_value = 256

local function log2(x)
	local _, exp = math.frexp(x)
	return exp - 1
end

local function new_stable_bloom_filter(n_cells, n_hashes, unlearn_rate)
	assert(math.frexp(n_cells) == 0.5, "n_cells should be power of 2")
	assert(n_cells / 8 % 1 == 0, "n_cells should be multiple of 8")
	local cells = {}
	for i=1, n_cells do
		cells[i] = 0
	end
	return setmetatable({
		-- Number of cells: dictates how much memory is used
		n_cells = n_cells;

		-- How many bytes you need to index a cell
		cell_bytes = math.ceil(log2(n_cells) / 8);

		--
		n_hashes = n_hashes;

		-- What percentage of cells to unlearn after an add
		unlearn_rate = unlearn_rate;

		-- The data
		cells = cells;
	}, stable_bloom_filter_mt)
end

local function cells(self, data)
	local hash_bytes_wanted = self.n_hashes * self.cell_bytes
	-- need at least hydro_hash_BYTES_MIN
	local hash_state = hash_init("stablebf", nil)
	hash_state:update(data)
	local hash = hash_state:final(math.max(16, hash_bytes_wanted))
	local unpack_string = string.format(">I%d", self.cell_bytes)
	local cell_bits = log2(self.n_cells)
	local cell_mask = (1 << cell_bits)-1
	return function(_, last_i)
		local h = last_i + 1
		local h_idx = last_i*self.cell_bytes+1
		if h_idx > hash_bytes_wanted then
			return nil
		end
		local idx = (string.unpack(unpack_string, hash, h_idx) & cell_mask) + 1
		assert(idx > 0, "my math failed")
		assert(idx <= self.n_cells, "my math failed")
		return h, idx
	end, nil, 0
end

function stable_bloom_filter_methods:add(data)
	for _, i in cells(self, data) do
		-- increment cell
		local x = self.cells[i]
		if x < max_value then
			self.cells[i] = x + 1
		end
	end

	-- unlearn some cells
	local n_unlearn = self.n_cells * self.unlearn_rate
	n_unlearn = math.floor(n_unlearn + (random_u32() / 0xFFFFFFFF))
	for _=1, n_unlearn do
		local i = random_uniform(self.n_cells) + 1
		-- decrement a cell
		local x = self.cells[i]
		if x > 0 then
			self.cells[i] = x - 1
		end
	end
end

function stable_bloom_filter_methods:check(data)
	for _, i in cells(self, data) do
		if self.cells[i] == 0 then
			return false
		end
	end
	return true
end

return {
	new = new_stable_bloom_filter;
}
