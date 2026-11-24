--!nonstrict
--[[
	Signed report helpers for the security channel.

    The server issues a secret and nonce for each handshake. Signed reports
    include the session nonce, sequence, kind and payload. The server uses the
    sequence to reject duplicates. A client controls its copy of the secret,
    so gameplay decisions still need independent server validation.
]]

--> FNV-1a style 32-bit hash with an avalanche step. Same construction as the
--> reference anticheat's tinyHash, kept deterministic across client and server.
local function hash(text: string, seed: number?): number
	local value = bit32.band(seed or 0x811C9DC5, 0xFFFFFFFF)
	for index = 1, #text do
		value = bit32.bxor(value, string.byte(text, index))
		value = bit32.band((value * 16777619) % 4294967296, 0xFFFFFFFF)
		value = bit32.bxor(value, bit32.rshift(value, 13))
	end
	return bit32.band(value, 0xFFFFFFFF)
end

local SIGN_SALT = "cheeto_report_v1"

--> Canonical string that both sides sign. Field order is fixed so client and
--> server always hash identical bytes.
local function canonical(secret: string, nonce: string, seq: number, kind: string, payload: string): string
	return table.concat({ secret, nonce, tostring(seq), kind, payload, SIGN_SALT }, "|")
end

local function sign(secret: string, nonce: string, seq: number, kind: string, payload: string): string
	return string.format("%08x", hash(canonical(secret, nonce, seq, kind, payload), 0x6D2B79F5))
end

local function verify(
	secret: string,
	nonce: string,
	seq: number,
	kind: string,
	payload: string,
	signature: string
): boolean
	if type(signature) ~= "string" or #signature ~= 8 then
		return false
	end
	return string.lower(signature) == sign(secret, nonce, seq, kind, payload)
end

return {
	hash = hash,
	sign = sign,
	verify = verify,
}
