-- ziggurat.lua
-- 4-channel pitch quantizer / chain sequencer
-- inspired by Acid Rain Technology Ziggurat
--
-- per-channel: note chain (up to 16), advance mode, slew, range
-- advance modes: forward, reverse, pendulum, random, drunk
-- all notes quantized to active scale

local musicutil = require "musicutil"

local Ziggurat = {}
Ziggurat.__index = Ziggurat

local MODES = {"forward", "reverse", "pendulum", "random", "drunk"}

----------------------------------------------------------------
-- module
----------------------------------------------------------------

function Ziggurat.new()
  local self = setmetatable({}, Ziggurat)

  self.root = 0           -- 0=C
  self.scale_idx = 1      -- index into musicutil.SCALES
  self.scale_notes = {}
  self:rebuild_scale()

  self.channels = {}

  -- ch1: major arp
  self.channels[1] = {
    chain = {60, 64, 67, 72, 67, 64},
    chain_len = 6,
    position = 1,
    direction = 1,
    advance_mode = 1, -- forward
    slew = 0.03,
    range_lo = 48,
    range_hi = 84,
    last_note = 60,
  }
  -- ch2: bass walk
  self.channels[2] = {
    chain = {48, 50, 52, 55, 52},
    chain_len = 5,
    position = 1,
    direction = 1,
    advance_mode = 1,
    slew = 0.08,
    range_lo = 36,
    range_hi = 60,
    last_note = 48,
  }
  -- ch3: sub pulse
  self.channels[3] = {
    chain = {36, 36, 43},
    chain_len = 3,
    position = 1,
    direction = 1,
    advance_mode = 1,
    slew = 0.15,
    range_lo = 24,
    range_hi = 48,
    last_note = 36,
  }
  -- ch4: melodic, drunk walk
  self.channels[4] = {
    chain = {67, 69, 71, 72, 74, 76, 72, 69},
    chain_len = 8,
    position = 1,
    direction = 1,
    advance_mode = 5, -- drunk
    slew = 0.05,
    range_lo = 60,
    range_hi = 96,
    last_note = 67,
  }

  return self
end

function Ziggurat:rebuild_scale()
  local scale_name = musicutil.SCALES[self.scale_idx].name
  self.scale_notes = musicutil.generate_scale(self.root, scale_name, 8)
end

function Ziggurat:set_scale(root, scale_idx)
  self.root = root
  self.scale_idx = scale_idx
  self:rebuild_scale()
end

function Ziggurat:quantize(note)
  if #self.scale_notes == 0 then return note end
  return musicutil.snap_note_to_array(note, self.scale_notes)
end

-- advance channel, return quantized MIDI note
function Ziggurat:advance(ch)
  local c = self.channels[ch]
  if c.chain_len == 0 then return c.last_note end

  local mode = MODES[c.advance_mode]

  if mode == "forward" then
    c.position = (c.position % c.chain_len) + 1

  elseif mode == "reverse" then
    c.position = c.position - 1
    if c.position < 1 then c.position = c.chain_len end

  elseif mode == "pendulum" then
    c.position = c.position + c.direction
    if c.position > c.chain_len then
      c.position = math.max(c.chain_len - 1, 1)
      c.direction = -1
    elseif c.position < 1 then
      c.position = math.min(2, c.chain_len)
      c.direction = 1
    end

  elseif mode == "random" then
    c.position = math.random(1, c.chain_len)

  elseif mode == "drunk" then
    c.position = c.position + (math.random(0, 1) * 2 - 1)
    if c.position < 1 then c.position = 1 end
    if c.position > c.chain_len then c.position = c.chain_len end
  end

  local raw = c.chain[c.position] or 60
  local quantized = self:quantize(raw)
  quantized = util.clamp(quantized, c.range_lo, c.range_hi)
  c.last_note = quantized
  return quantized
end

function Ziggurat:set_chain_note(ch, pos, note)
  self.channels[ch].chain[pos] = note
end

function Ziggurat:set_chain_length(ch, len)
  local c = self.channels[ch]
  c.chain_len = util.clamp(len, 1, 16)
  -- extend chain if needed
  for i = #c.chain + 1, c.chain_len do
    c.chain[i] = c.chain[#c.chain] or 60
  end
  if c.position > c.chain_len then c.position = 1 end
end

function Ziggurat:reset(ch)
  if ch then
    self.channels[ch].position = 1
    self.channels[ch].direction = 1
  else
    for i = 1, 4 do
      self.channels[i].position = 1
      self.channels[i].direction = 1
    end
  end
end

function Ziggurat:get_mode_name(ch)
  return MODES[self.channels[ch].advance_mode]:upper():sub(1, 4)
end

function Ziggurat:get_num_modes()
  return #MODES
end

return Ziggurat
