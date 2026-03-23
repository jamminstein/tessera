-- explorer.lua
-- autonomous mutation engine for tessera
--
-- periodically mutates rhythms, pitches, voice params, and FX
-- to keep tessera evolving as a living system
--
-- inspired by generative modular patches:
-- things change slowly, patterns shift, voices evolve
-- but there's always a coherent musical thread

local Explorer = {}
Explorer.__index = Explorer

function Explorer.new(rep, zig)
  local self = setmetatable({}, Explorer)

  self.rep = rep
  self.zig = zig
  self.active = false
  self.intensity = 0.5   -- 0=subtle, 1=chaotic

  -- mutation timers (in steps)
  self.step_count = 0
  self.rhythm_interval = 32    -- mutate rhythm every N steps
  self.pitch_interval = 24     -- mutate pitch chain every N steps
  self.voice_interval = 48     -- mutate voice params every N steps
  self.density_interval = 64   -- shift overall density every N steps

  -- density phase: controls how many channels are active
  self.phase = 1  -- 1=sparse, 2=building, 3=full, 4=breaking
  self.phase_timer = 0
  self.phase_length = 128  -- steps per phase

  return self
end

-- call this every sequencer step
function Explorer:step()
  if not self.active then return end
  self.step_count = self.step_count + 1
  self.phase_timer = self.phase_timer + 1

  -- phase transitions
  if self.phase_timer >= self.phase_length then
    self.phase_timer = 0
    self.phase = (self.phase % 4) + 1
    self:apply_phase()
  end

  -- rhythm mutations
  if self.step_count % self.rhythm_interval == 0 then
    self:mutate_rhythm()
  end

  -- pitch mutations
  if self.step_count % self.pitch_interval == 0 then
    self:mutate_pitch()
  end

  -- voice param mutations
  if self.step_count % self.voice_interval == 0 then
    self:mutate_voice()
  end
end

-- returns list of {param_key, value} pairs for Lua to apply via params:set
function Explorer:mutate_voice()
  local changes = {}
  local ch = math.random(1, 4)
  local roll = math.random()

  if roll < 0.3 * self.intensity then
    -- mutate filter cutoff (stay musical: move by ratio, not absolute)
    local mult = 1 + (math.random() - 0.5) * self.intensity
    table.insert(changes, {"ch" .. ch .. "_cutoff", "delta", math.random(-8, 8)})
  end

  if roll < 0.5 * self.intensity then
    -- mutate drive
    table.insert(changes, {"ch" .. ch .. "_drive", "delta", math.random(-3, 3)})
  end

  if roll < 0.4 * self.intensity then
    -- mutate resonance
    table.insert(changes, {"ch" .. ch .. "_res", "delta", math.random(-2, 2)})
  end

  if roll < 0.2 * self.intensity then
    -- mutate decay
    table.insert(changes, {"ch" .. ch .. "_decay", "delta", math.random(-2, 2)})
  end

  if roll < 0.15 * self.intensity then
    -- swap oscillator levels occasionally
    local sources = {"saw", "pulse", "sub", "noise"}
    local src = sources[math.random(1, 4)]
    table.insert(changes, {"ch" .. ch .. "_" .. src, "delta", math.random(-3, 3)})
  end

  return changes
end

function Explorer:mutate_rhythm()
  -- pick a random channel
  local ch = math.random(1, 4)
  local c = self.rep.channels[ch]

  local action = math.random()

  if action < 0.25 * self.intensity then
    -- toggle a random step
    local step = math.random(1, c.steps)
    c.pattern[step] = c.pattern[step] == 1 and 0 or 1
    if c.pattern[step] == 1 then
      c.accents[step] = ((step - 1) % 4 == 0) and 1.0 or 0.65
    end

  elseif action < 0.4 * self.intensity then
    -- rotate pattern by 1
    local last = c.pattern[c.steps]
    for i = c.steps, 2, -1 do
      c.pattern[i] = c.pattern[i - 1]
    end
    c.pattern[1] = last

  elseif action < 0.55 * self.intensity then
    -- add or remove a ratchet
    local step = math.random(1, c.steps)
    if c.pattern[step] == 1 then
      local cur = c.ratchets[step] or 1
      if cur >= 4 then
        c.ratchets[step] = 1
      else
        c.ratchets[step] = cur + 1
      end
    end

  elseif action < 0.65 * self.intensity then
    -- randomize probability on a step
    local step = math.random(1, c.steps)
    if c.pattern[step] == 1 then
      local probs = {100, 100, 75, 75, 50, 25}
      c.probability[step] = probs[math.random(1, #probs)]
    end

  elseif action < 0.8 * self.intensity then
    -- change euclidean pulses (if in euclidean mode)
    if c.mode == 1 then
      c.pulses = util.clamp(c.pulses + (math.random(0, 1) * 2 - 1), 1, c.steps - 1)
      self.rep:regenerate(ch)
    end
  end
end

function Explorer:mutate_pitch()
  local ch = math.random(1, 4)
  local c = self.zig.channels[ch]

  local action = math.random()

  if action < 0.3 * self.intensity then
    -- shift one note in the chain by a scale step
    local pos = math.random(1, c.chain_len)
    local note = c.chain[pos] or 60
    local delta = (math.random(0, 1) * 2 - 1) * math.random(1, 3)
    note = util.clamp(note + delta, c.range_lo, c.range_hi)
    note = self.zig:quantize(note)
    c.chain[pos] = note

  elseif action < 0.45 * self.intensity then
    -- transpose entire chain by a scale degree
    local delta = (math.random(0, 1) * 2 - 1) * math.random(1, 2)
    for i = 1, c.chain_len do
      local n = (c.chain[i] or 60) + delta
      c.chain[i] = util.clamp(self.zig:quantize(n), c.range_lo, c.range_hi)
    end

  elseif action < 0.55 * self.intensity then
    -- swap advance mode
    c.advance_mode = math.random(1, self.zig:get_num_modes())

  elseif action < 0.65 * self.intensity then
    -- reverse the chain
    local reversed = {}
    for i = 1, c.chain_len do
      reversed[i] = c.chain[c.chain_len - i + 1]
    end
    c.chain = reversed

  elseif action < 0.75 * self.intensity then
    -- extend or shrink chain
    local new_len = util.clamp(c.chain_len + (math.random(0, 1) * 2 - 1), 2, 12)
    self.zig:set_chain_length(ch, new_len)
  end
end

function Explorer:apply_phase()
  -- phases create macro-structure: sparse → building → full → breaking
  local mute_map = {
    {false, true,  true,  true },  -- sparse: only ch1
    {false, false, true,  false},  -- building: ch1 + ch2 + ch4
    {false, false, false, false},  -- full: all channels
    {false, false, false, true },  -- breaking: drop ch4, add tension
  }

  local mutes = mute_map[self.phase]
  for ch = 1, 4 do
    self.rep.channels[ch].muted = mutes[ch]
  end
end

function Explorer:get_phase_name()
  local names = {"SPARSE", "BUILD", "FULL", "BREAK"}
  return names[self.phase] or "?"
end

return Explorer
