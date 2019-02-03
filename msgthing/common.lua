local function hash_matches(subscription, hash)
	assert(#subscription == 4)
	assert(#hash == 4)
	subscription = string.unpack(">I4", subscription)
	hash = string.unpack(">I4", hash)
	return (subscription & hash) == hash
end

return {
	hash_matches = hash_matches;
}
