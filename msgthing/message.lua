local hydrogen = require "hydrogen"
local secretbox = hydrogen.secretbox

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

local function encode(key, msg_id, plaintext)
	local msg_hash = get_hash(key, msg_id)
	-- TODO: pad msg?
	local ciphertext = secretbox.encrypt(plaintext, msg_id, "message\0", key)
	return {
		ref_count = 1;
		msg_hash = msg_hash;
		ciphertext = ciphertext;
	}
end

return {
	limit_pow = limit_pow;
	is_sync_msg = is_sync_msg;
	get_hash = get_hash;
	get_full_hash = get_full_hash;
	encode = encode;
}
