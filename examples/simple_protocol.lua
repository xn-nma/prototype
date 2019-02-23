-- Simple use of TCP as a transpoyrt
-- Uses cqueues

local cqueues = require "cqueues"
local cc = require "cqueues.condition"
local ce = require "cqueues.errno"
local cs = require "cqueues.socket"
local hydrogen = require "hydrogen"

local log = {}
do -- logging functions
	local function e(c)
		return "\27" .. c
	end
	local function esc(...)
		return e("["..table.concat({...},";").."m")
	end
	local function fg(c)
		return esc("38;5", c)
	end
	local function log_printf(prefix, ...)
		local s = string.format(...)
		if #s > 79 then
			s = s:sub(1, 78) .. "…"
		end
		assert(io.stderr:write(prefix, s, esc(0), "\n"))
	end
	log.debug = function(...)
		return log_printf(fg(243), ...)
	end
	log.info = function(...)
		return log_printf(fg(253), ...)
	end
	log.error = function(...)
		return log_printf(fg(160), ...)
	end
end

local function add_peer(node, peer)
	local cq = assert(cqueues.running(), "must call from a cq")

	local neighbour = node:new_neighbour(function(self, packet_type, packet_data) -- luacheck: ignore 212
		log.debug("<<<  sending %3d bytes of %s: %s", #packet_data, packet_type, hydrogen.bin2hex(packet_data))
		assert(peer:xwrite(string.pack(">c1s2", packet_type, packet_data), "bn"))
	end)

	-- Create thread to send subscriptions
	local cancel_cond = cc.new()
	local sub_send_wanted = false
	local sub_cond = cc.new()
	cq:wrap(function(neighbour)
		while not peer:eof() do
			-- Want to send a subscription on connection start
			-- XXX: assumes that :send blocks
			neighbour:send_subscription()

			-- maximum one subscription packet per 5 seconds
			-- TODO: base on latency?
			if cqueues.poll(cancel_cond, 5) == cancel_cond then
				break
			end

			-- minimum one subscription packet per 60 seconds
			if not sub_send_wanted then
				print("sub send not wanted")
				if cqueues.poll(cancel_cond, sub_cond, 60-5) == cancel_cond then
					break
				end
			else
				print("sub send wanted!")
				sub_send_wanted = false
			end
		end
	end, neighbour)

	-- Receive thread
	cq:wrap(function(peer, neighbour)
		while true do
			local header, err = peer:xread(3, "b")
			if not header then
				if err == nil or err == ce.EPIPE then
					log.info("Peer disconnected: %s", peer)
				else
					log.error("ERROR: %s", err)
					peer:close()
				end
				node:delete_neighbour(neighbour)
				cancel_cond:signal()
				return
			end
			local packet_type, len = string.unpack(">c1I2", header)
			local packet_data, err2 = assert(peer:xread(len, "b"))
			if not packet_data then
				if err2 == nil then
					err2 = "Unexpected end of file"
				end
				log.error("ERROR: %s", err2)
				peer:close()
				node:delete_neighbour(neighbour)
				cancel_cond:signal()
				return
			end
			log.debug(">>> received %3d bytes of %s: %s", #packet_data, packet_type, hydrogen.bin2hex(packet_data))
			neighbour:process_packet(packet_type, packet_data)
			if packet_type == "M" then
				print("SUB send wanted due to message")
				sub_send_wanted = true
				sub_cond:signal()
			end
			-- send messages in response to subscription
			-- send messages in response to messages too:
			-- receiving a message may have let us discover a tail
			neighbour:send_messages()
		end
	end, peer, neighbour)

	return neighbour
end

local function connect(node, host, port)
	assert(cqueues.running(), "must call from a cq")

	local peer = assert(cs.connect(host, port))
	return add_peer(node, peer)
end

return {
	add_peer = add_peer;
	connect = connect;
}
