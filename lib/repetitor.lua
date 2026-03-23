-- repetitor.lua
-- 4-channel algorithmic trigger generator
-- inspired by Noise Engineering Multi Repetitor
--
-- modes: euclidean, fibonacci, prime, golden ratio, + traditional patterns
-- per-step: ratchets (1-4x repeats), probability (0-100%)
-- per-channel: steps, pulses, offset, accent generation

local Repetitor = {}
Repetitor.__index = Repetitor

----------------------------------------------------------------
-- bjorklund algorithm for euclidean patterns
----------------------------------------------------------------

local function bjorklund(steps, pulses)
  if pulses >= steps then
    local p = {}
    for i = 1, steps do p[i] = 1 end
    return p
  end
  if pulses == 0 then
    local p = {}
    for i = 1, steps do p[i] = 0 end
    return p
  end

  local pattern = {}
  local counts = {}
  local remainders = {}
  local level = 0

  remainders[0] = pulses
  local divisor = steps - pulses

  repeat
    counts[level] = math.floor(divisor / remainders[level])
    local newR = divisor % remainders[level]
    divisor = remainders[level]
    remainders[level + 1] = newR
    level = level + 1
  until remainders[level] <= 1

  counts[level] = divisor

  local function build(lev)
    if lev == -1 then
      pattern[#pattern + 1] = 0
    elseif lev == -2 then
      pattern[#pattern + 1] = 1
    else
      for _ = 1, counts[lev] do
        build(lev - 1)
      end
      if remainders[lev] > 0 then
        build(lev - 2)
      end
    end
  end

  build(level)
  return pattern
end

----------------------------------------------------------------
-- mathematical pattern generators
----------------------------------------------------------------

local function fibonacci_pattern(steps)
  local p = {}
  for i = 1, steps do p[i] = 0 end
  local a, b = 1, 1
  while a <= steps do
    p[a] = 1
    a, b = b, a + b
  end
  return p
end

local function prime_pattern(steps)
  local p = {}
  for i = 1, steps do p[i] = 0 end
  for i = 2, steps do
    local is_prime = true
    for j = 2, math.floor(math.sqrt(i)) do
      if i % j == 0 then is_prime = false; break end
    end
    if is_prime then p[i] = 1 end
  end
  return p
end

local function golden_pattern(steps)
  local p = {}
  for i = 1, steps do p[i] = 0 end
  local phi = (1 + math.sqrt(5)) / 2
  local pos = 0
  while pos < steps do
    pos = pos + phi
    local idx = math.floor(pos)
    if idx >= 1 and idx <= steps then p[idx] = 1 end
  end
  return p
end

----------------------------------------------------------------
-- traditional drum patterns (16-step)
----------------------------------------------------------------

local TRADITIONAL = {
  {name = "4floor", pattern = {1,0,0,0, 1,0,0,0, 1,0,0,0, 1,0,0,0}},
  {name = "backbt", pattern = {0,0,0,0, 1,0,0,0, 0,0,0,0, 1,0,0,0}},
  {name = "clave",  pattern = {1,0,0,1, 0,0,1,0, 0,0,1,0, 1,0,0,0}},
  {name = "tresl",  pattern = {1,0,0,1, 0,0,1,0, 0,0,0,0, 0,0,0,0}},
  {name = "bomba",  pattern = {1,0,0,0, 0,0,1,0, 0,0,1,0, 0,0,0,0}},
  {name = "shuff",  pattern = {1,0,0,1, 0,0,1,0, 0,1,0,0, 1,0,1,0}},
  {name = "halft",  pattern = {1,0,0,0, 0,0,0,0, 1,0,0,0, 0,0,0,0}},
  {name = "8ths",   pattern = {1,0,1,0, 1,0,1,0, 1,0,1,0, 1,0,1,0}},
}

----------------------------------------------------------------
-- accent generation
----------------------------------------------------------------

local function generate_accents(pattern)
  local accents = {}
  for i = 1, #pattern do
    if pattern[i] == 1 then
      accents[i] = ((i - 1) % 4 == 0) and 1.0 or 0.65
    else
      accents[i] = 0
    end
  end
  return accents
end

----------------------------------------------------------------
-- module
----------------------------------------------------------------

function Repetitor.new()
  local self = setmetatable({}, Repetitor)
  self.channels = {}
  for i = 1, 4 do
    self.channels[i] = {
      mode = 1,
      steps = 16,
      pulses = 4,
      offset = 0,
      pattern = {},
      accents = {},
      ratchets = {},    -- per-step ratchet count (1=normal, 2-4=repeats)
      probability = {}, -- per-step probability 0-100
      position = 0,
      muted = false,
      -- ratchet playback state
      ratchet_remaining = 0,
      ratchet_accent = 0,
    }
    -- init ratchets and probability
    for s = 1, 16 do
      self.channels[i].ratchets[s] = 1
      self.channels[i].probability[s] = 100
    end
  end
  -- ch1 acid: euclidean 7/16 — driving but syncopated
  self.channels[1].pulses = 7

  -- ch2 kick: four on the floor
  self.channels[2].mode = 5  -- traditional: 4floor

  -- ch3 noise: offbeat 8ths (backbeat hats)
  self.channels[3].mode = 8  -- traditional: 8ths
  self.channels[3].offset = 1  -- offset by 1 for offbeat feel

  -- ch4 dark: sparse euclidean 3/16
  self.channels[4].pulses = 3

  for i = 1, 4 do self:regenerate(i) end

  -- add some ratchets and probability to ch1 and ch3 for interest
  self.channels[1].ratchets[5] = 2
  self.channels[1].ratchets[13] = 3
  self.channels[3].probability[4] = 50
  self.channels[3].probability[8] = 75
  self.channels[3].probability[12] = 50
  return self
end

function Repetitor:regenerate(ch)
  local c = self.channels[ch]
  local raw

  if c.mode == 1 then
    raw = bjorklund(c.steps, c.pulses)
  elseif c.mode == 2 then
    raw = fibonacci_pattern(c.steps)
  elseif c.mode == 3 then
    raw = prime_pattern(c.steps)
  elseif c.mode == 4 then
    raw = golden_pattern(c.steps)
  else
    local tidx = c.mode - 4
    if tidx >= 1 and tidx <= #TRADITIONAL then
      raw = {}
      local src = TRADITIONAL[tidx].pattern
      for i = 1, c.steps do
        raw[i] = src[((i - 1) % #src) + 1]
      end
    else
      raw = bjorklund(c.steps, c.pulses)
    end
  end

  -- apply rotation offset
  if c.offset ~= 0 then
    local rotated = {}
    for i = 1, #raw do
      rotated[i] = raw[((i - 1 + c.offset) % #raw) + 1]
    end
    raw = rotated
  end

  c.pattern = raw
  c.accents = generate_accents(raw)
end

-- advance one step, return (hit, accent, ratchet_count)
-- ratchet_count > 1 means the caller should schedule sub-triggers
function Repetitor:advance(ch)
  local c = self.channels[ch]

  -- if we're in the middle of a ratchet burst, emit a sub-trigger
  if c.ratchet_remaining > 0 then
    c.ratchet_remaining = c.ratchet_remaining - 1
    return true, c.ratchet_accent * 0.7, 0  -- softer sub-hits
  end

  c.position = (c.position % c.steps) + 1
  -- ghost notes when muted: advance position, trigger quietly on pattern hits
  if c.muted then
    if c.pattern[c.position] == 1 then
      return true, 0.05, 1
    else
      return false, 0, 0
    end
  end

  local hit = c.pattern[c.position] == 1
  if not hit then return false, 0, 0 end

  -- probability check
  local prob = c.probability[c.position] or 100
  if prob < 100 and math.random(100) > prob then
    return false, 0, 0
  end

  local accent = c.accents[c.position] or 0.65
  local ratch = c.ratchets[c.position] or 1

  -- queue ratchet sub-triggers (they fire on subsequent advance calls)
  if ratch > 1 then
    c.ratchet_remaining = ratch - 1
    c.ratchet_accent = accent
  end

  return true, accent, ratch
end

-- set ratchet count for a step (1-4)
function Repetitor:set_ratchet(ch, step, count)
  count = math.max(1, math.min(4, count))
  self.channels[ch].ratchets[step] = count
end

-- set probability for a step (0-100)
function Repetitor:set_probability(ch, step, prob)
  prob = math.max(0, math.min(100, prob))
  self.channels[ch].probability[step] = prob
end

function Repetitor:reset(ch)
  if ch then
    self.channels[ch].position = 0
    self.channels[ch].ratchet_remaining = 0
  else
    for i = 1, 4 do
      self.channels[i].position = 0
      self.channels[i].ratchet_remaining = 0
    end
  end
end

function Repetitor:get_mode_name(ch)
  local mode = self.channels[ch].mode
  if mode == 1 then return "EUCL"
  elseif mode == 2 then return "FIB"
  elseif mode == 3 then return "PRIM"
  elseif mode == 4 then return "GOLD"
  else
    local tidx = mode - 4
    if tidx >= 1 and tidx <= #TRADITIONAL then
      return TRADITIONAL[tidx].name:upper()
    end
    return "????"
  end
end

function Repetitor:get_num_modes()
  return 4 + #TRADITIONAL
end

return Repetitor
