-- bandmate.lua
-- built-in creative bandmate for tessera
--
-- does what the robot mod CAN'T:
--   mutates rhythm patterns (swap modes, shift offsets, thin/thicken)
--   evolves pitch chains (transpose, shuffle, extend/contract, swap advance modes)
--   triggers spectral freeze moments with musical timing
--   shapes the spectral arc (tilt sweeps, spread blooms, halo swells)
--
-- 4 phases that cycle in a narrative arc:
--   MOSAIC     — steady, textural, small spectral shifts. listening.
--   FRACTURE   — rhythm mutations, pattern swaps, energy building.
--   CRYSTALLIZE — spectral freeze moments, partials shifting, halo swells.
--   DISSOLVE   — everything opens up. max spread, max halo. letting go.

local Bandmate = {}
Bandmate.__index = Bandmate

local PHASES = {"MOSAIC", "FRACTURE", "CRYSTALLIZE", "DISSOLVE"}

-- how many beats each phase lasts (randomized within range)
local PHASE_BEATS = {
  MOSAIC      = {min = 32, max = 64},
  FRACTURE    = {min = 16, max = 48},
  CRYSTALLIZE = {min = 16, max = 32},
  DISSOLVE    = {min = 24, max = 48},
}

-- probability of action per beat, per phase
local ACTION_PROB = {
  MOSAIC      = 0.08,
  FRACTURE    = 0.25,
  CRYSTALLIZE = 0.15,
  DISSOLVE    = 0.12,
}

function Bandmate.new(rep, zig)
  local self = setmetatable({}, Bandmate)
  self.rep = rep
  self.zig = zig
  self.active = false
  self.phase_idx = 1
  self.phase = PHASES[1]
  self.beat_count = 0
  self.phase_length = 48
  self.frozen_channels = {}
  self.intensity = 0.5  -- 0-1, rises and falls across phases
  self.clock_id = nil
  return self
end

function Bandmate:start()
  self.active = true
  self.phase_idx = 1
  self.phase = PHASES[1]
  self.beat_count = 0
  self.intensity = 0.3
  self:new_phase_length()
end

function Bandmate:stop()
  self.active = false
  -- unfreeze everything
  for ch = 1, 4 do
    if self.frozen_channels[ch] then
      engine.freeze(ch - 1, 0)
      self.frozen_channels[ch] = false
    end
  end
end

function Bandmate:new_phase_length()
  local range = PHASE_BEATS[self.phase]
  self.phase_length = math.random(range.min, range.max)
end

function Bandmate:advance_phase()
  -- unfreeze any frozen channels from CRYSTALLIZE
  for ch = 1, 4 do
    if self.frozen_channels[ch] then
      engine.freeze(ch - 1, 0)
      self.frozen_channels[ch] = false
    end
  end

  self.phase_idx = (self.phase_idx % #PHASES) + 1
  self.phase = PHASES[self.phase_idx]
  self.beat_count = 0
  self:new_phase_length()

  -- set intensity arc
  if self.phase == "MOSAIC" then
    self.intensity = 0.2 + math.random() * 0.2
  elseif self.phase == "FRACTURE" then
    self.intensity = 0.5 + math.random() * 0.3
  elseif self.phase == "CRYSTALLIZE" then
    self.intensity = 0.6 + math.random() * 0.3
  elseif self.phase == "DISSOLVE" then
    self.intensity = 0.7 + math.random() * 0.3
  end
end

-- called every beat from the main clock
function Bandmate:tick()
  if not self.active then return end

  self.beat_count = self.beat_count + 1

  -- check for phase transition
  if self.beat_count >= self.phase_length then
    self:advance_phase()
  end

  -- roll for action
  if math.random() < ACTION_PROB[self.phase] then
    self:act()
  end
end

function Bandmate:act()
  if self.phase == "MOSAIC" then
    self:act_mosaic()
  elseif self.phase == "FRACTURE" then
    self:act_fracture()
  elseif self.phase == "CRYSTALLIZE" then
    self:act_crystallize()
  elseif self.phase == "DISSOLVE" then
    self:act_dissolve()
  end
end

----------------------------------------------------------------
-- MOSAIC: gentle spectral sculpting, listening
----------------------------------------------------------------

function Bandmate:act_mosaic()
  local roll = math.random()
  local ch = math.random(1, 4)

  if roll < 0.3 then
    -- gentle filter sweep
    local cur = params:get("ch" .. ch .. "_filter")
    local delta = (math.random() - 0.5) * 600
    params:set("ch" .. ch .. "_filter", util.clamp(cur + delta, 200, 8000))

  elseif roll < 0.5 then
    -- subtle tilt shift
    local cur = params:get("ch" .. ch .. "_tilt")
    local delta = (math.random() - 0.5) * 0.3
    params:set("ch" .. ch .. "_tilt", util.clamp(cur + delta, 0, 2.5))

  elseif roll < 0.7 then
    -- halo swell
    local cur = params:get("halo")
    local target = cur + (math.random() * 0.15)
    params:set("halo", util.clamp(target, 0.1, 0.7))

  elseif roll < 0.85 then
    -- spread bloom on one channel
    local cur = params:get("ch" .. ch .. "_spread")
    params:set("ch" .. ch .. "_spread", util.clamp(cur + 0.005, 0, 0.06))

  else
    -- shift a pitch chain note by one scale degree
    local c = self.zig.channels[ch]
    local step = math.random(1, c.chain_len)
    local cur = c.chain[step]
    local dir = math.random(0, 1) * 2 - 1
    local new = self.zig:quantize(cur + dir)
    new = util.clamp(new, c.range_lo, c.range_hi)
    c.chain[step] = new
  end
end

----------------------------------------------------------------
-- FRACTURE: rhythm mutations, energy building
----------------------------------------------------------------

function Bandmate:act_fracture()
  local roll = math.random()
  local ch = math.random(1, 4)

  if roll < 0.25 then
    -- swap rhythm mode
    local c = self.rep.channels[ch]
    c.mode = math.random(1, self.rep:get_num_modes())
    self.rep:regenerate(ch)

  elseif roll < 0.45 then
    -- shift rhythm offset
    local c = self.rep.channels[ch]
    c.offset = (c.offset + math.random(1, 4)) % c.steps
    self.rep:regenerate(ch)

  elseif roll < 0.6 then
    -- adjust euclidean density
    local c = self.rep.channels[ch]
    if c.mode == 1 then
      c.pulses = util.clamp(c.pulses + (math.random(0, 1) * 2 - 1) * math.random(1, 3), 1, c.steps - 1)
      self.rep:regenerate(ch)
    end

  elseif roll < 0.75 then
    -- swap pitch advance mode
    local c = self.zig.channels[ch]
    c.advance_mode = math.random(1, self.zig:get_num_modes())

  elseif roll < 0.85 then
    -- filter sweep (more aggressive than MOSAIC)
    local cur = params:get("ch" .. ch .. "_filter")
    local delta = (math.random() - 0.3) * 2000 * self.intensity
    params:set("ch" .. ch .. "_filter", util.clamp(cur + delta, 200, 10000))

  else
    -- shuffle 2 notes in a pitch chain
    local c = self.zig.channels[ch]
    if c.chain_len >= 2 then
      local a = math.random(1, c.chain_len)
      local b = math.random(1, c.chain_len)
      c.chain[a], c.chain[b] = c.chain[b], c.chain[a]
    end
  end
end

----------------------------------------------------------------
-- CRYSTALLIZE: spectral freeze, partials shifting, halo
----------------------------------------------------------------

function Bandmate:act_crystallize()
  local roll = math.random()
  local ch = math.random(1, 4)

  if roll < 0.3 then
    -- toggle freeze on a channel
    if self.frozen_channels[ch] then
      engine.freeze(ch - 1, 0)
      self.frozen_channels[ch] = false
    else
      engine.freeze(ch - 1, 1)
      self.frozen_channels[ch] = true
    end

  elseif roll < 0.5 then
    -- shift partials count
    local cur = params:get("ch" .. ch .. "_partials")
    local delta = math.random(-3, 3)
    params:set("ch" .. ch .. "_partials", util.clamp(cur + delta, 2, 16))

  elseif roll < 0.65 then
    -- halo swell (bigger than MOSAIC)
    local target = 0.4 + math.random() * 0.4
    params:set("halo", target)

  elseif roll < 0.8 then
    -- reverb bloom
    local cur = params:get("reverb_mix")
    params:set("reverb_mix", util.clamp(cur + 0.1, 0.1, 0.6))
    params:set("reverb_size", util.clamp(params:get("reverb_size") + 0.05, 0.5, 0.95))

  elseif roll < 0.9 then
    -- tilt towards brightness or darkness
    local target = math.random() < 0.5 and 0.1 or 2.0
    local cur = params:get("ch" .. ch .. "_tilt")
    params:set("ch" .. ch .. "_tilt", cur + (target - cur) * 0.3)

  else
    -- delay time shift for rhythmic interest
    local times = {0.15, 0.2, 0.3, 0.375, 0.5, 0.75}
    params:set("delay_time", times[math.random(1, #times)])
  end
end

----------------------------------------------------------------
-- DISSOLVE: everything opens, letting go
----------------------------------------------------------------

function Bandmate:act_dissolve()
  local roll = math.random()
  local ch = math.random(1, 4)

  if roll < 0.25 then
    -- spread bloom on all channels
    for i = 1, 4 do
      local cur = params:get("ch" .. i .. "_spread")
      params:set("ch" .. i .. "_spread", util.clamp(cur + 0.008, 0, 0.08))
    end

  elseif roll < 0.4 then
    -- max halo
    local cur = params:get("halo")
    params:set("halo", util.clamp(cur + 0.1, 0.3, 0.9))

  elseif roll < 0.55 then
    -- open all filters
    for i = 1, 4 do
      local cur = params:get("ch" .. i .. "_filter")
      params:set("ch" .. i .. "_filter", util.clamp(cur * 1.2, 200, 12000))
    end

  elseif roll < 0.65 then
    -- extend a pitch chain
    local c = self.zig.channels[ch]
    if c.chain_len < 16 then
      self.zig:set_chain_length(ch, c.chain_len + 1)
      -- new note: random scale note in range
      local note = math.random(c.range_lo, c.range_hi)
      c.chain[c.chain_len] = self.zig:quantize(note)
    end

  elseif roll < 0.75 then
    -- switch to drunk walk (everything wanders)
    self.zig.channels[ch].advance_mode = 5 -- drunk

  elseif roll < 0.85 then
    -- long decay
    local cur = params:get("ch" .. ch .. "_decay")
    params:set("ch" .. ch .. "_decay", util.clamp(cur * 1.3, 0.1, 4))

  else
    -- delay feedback rise
    local cur = params:get("delay_feedback")
    params:set("delay_feedback", util.clamp(cur + 0.08, 0.2, 0.85))
  end
end

return Bandmate
