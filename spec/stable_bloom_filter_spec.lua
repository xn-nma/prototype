describe("stable_bloom_filter", function()
	local new_stable_bloom_filter = require "msgthing.stable_bloom_filter".new
	it("works", function()
		local a = new_stable_bloom_filter(1024, 3, 0)
		a:add("x")
		assert.equal(true, a:check("x"))
	end)
end)
