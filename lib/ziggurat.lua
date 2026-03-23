-- ziggurat.lua
-- 4-channel pitch quantizer / chain sequencer
-- inspired by Acid Rain Technology Ziggurat
--
-- per-channel: note chain (up to 16), advance mode, slew, range
-- advance modes: forward, reverse, pendulum, random, drunk
-- harmonic drift: slow transposition that evolves the key center
-- cross-channel: one channel's output can influence another's pitch
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

  self.root = 0
  self.scale_idx = 1
  self.scale_notes = {}
  self:rebuild_scale()

  -- harmonic drift state
  self.drift_enabled = true
  self.drift_amount = 0        -- current transposition in semitones (float)
  self.drift_speed = 0.02      -- how fast drift accumulates per step
  self.drift_range = 7         -- max semitones of drift
  self.drift_direction = 1     -- 1 or -1
  self.drift_step_count = 0    -- steps since last direction change

  -- cross-channel modulation
  self.xmod_enabled = false
  self.xmod_source = 1         -- which channel's note...
  self.xmod_target = 3         -- ...offsets which channel
  self.xmod_amount = 0.3       -- how much (0-1, scaled to octave)

  self.channels = {}

  -- ch1: acid line — hypnotic, one note hammering with octave jumps
  self.channels[1] = {
    chain = {57, 57, 57, 60, 57, 55, 57, 69},
    chain_len = 8,
    position = 1,
    direction = 1,
    advance_mode = 1,
    slew = 0.02,
    range_lo = 45,
    range_hi = 76,
    last_note = 57,
  }
  -- ch2: sub kick — one low note, driving, relentless
  self.channels[2] = {
    chain = {33, 33, 33, 33, 45, 33, 33, 33},
    chain_len = 8,
    position = 1,
    direction = 1,
    advance_mode = 1,
    slew = 0.0,
    range_lo = 24,
    range_hi = 48,
    last_note = 33,
  }
  -- ch3: noise perc — pitch is texture, not melody
  self.channels[3] = {
    chain = {57, 60, 57, 64},
    chain_len = 4,
    position = 1,
    direction = 1,
    advance_mode = 4,
    slew = 0.0,
    range_lo = 40,
    range_hi = 72,
    last_note = 57,
  }
  -- ch4: dark drone — fifths and octaves, slow drunk walk
  self.channels[4] = {
    chain = {45, 52, 57, 45, 64, 57, 52, 45},
    chain_len = 8,
    position = 1,
    direction = 1,
    advance_mode = 5,
    slew = 0.15,
    range_lo = 36,
    range_hi = 72,
    last_note = 45,
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

-- update harmonic drift (call once per master step, not per channel)
function Ziggurat:update_drift()
  if not self.drift_enabled then return end

  self.drift_step_count = self.drift_step_count + 1

  -- drunk walk on transposition
  local wiggle = (math.random() - 0.5) * self.drift_speed * 2
  self.drift_amount = self.drift_amount + (self.drift_direction * self.drift_speed) + wiggle

  -- reverse direction at boundaries (with some randomness)
  if math.abs(self.drift_amount) > self.drift_range then
    self.drift_direction = -self.drift_direction
    self.drift_amount = util.clamp(self.drift_amount, -self.drift_range, self.drift_range)
  end

  -- occasional random direction change (keeps it unpredictable)
  if self.drift_step_count > 32 and math.random() < 0.08 then
    self.drift_direction = -self.drift_direction
    self.drift_step_count = 0
  end
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

  -- apply harmonic drift
  if self.drift_enabled then
    raw = raw + math.floor(self.drift_amount + 0.5)
  end

  -- apply cross-channel modulation
  if self.xmod_enabled and ch == self.xmod_target then
    local src_note = self.channels[self.xmod_source].last_note
    local offset = math.floor((src_note - 60) * self.xmod_amount)
    raw = raw + offset
  end

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
    self.drift_amount = 0
    self.drift_step_count = 0
  end
end

function Ziggurat:get_mode_name(ch)
  return MODES[self.channels[ch].advance_mode]:upper():sub(1, 4)
end

function Ziggurat:get_num_modes()
  return #MODES
end

return Ziggurat
