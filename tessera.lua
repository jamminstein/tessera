-- tessera
-- algorithmic mosaic synth
--
-- 4 channels: analog (MoogFF) or spectral (resynthesizer)
-- repetitor rhythms + ziggurat pitch chains
--
-- E1: page
-- K2: play/stop
-- K3: freeze (hold) / randomize voice (tap on voice page)
--
-- PAGE 1 PLAY: overview of all 4 channels
--   E2: select channel  E3: BPM (K3 held: division)
-- PAGE 2 RHYTHM: selected channel rhythm detail
--   E2: rhythm mode  E3: pulses/offset (K3 held)
-- PAGE 3 VOICE: mode-aware param editor
--   E2: select param  E3: adjust  K3 tap: randomize
-- PAGE 4 MACRO/FX: macro controls + FX
--   E2: select  E3: adjust

engine.name = "Tessera"

local musicutil = require "musicutil"
local Repetitor = include "lib/repetitor"
local Ziggurat = include "lib/ziggurat"
local Explorer = include "lib/explorer"

----------------------------------------------------------------
-- state
----------------------------------------------------------------

local rep = nil
local zig = nil
local g = grid.connect()
local midi_out = nil

local playing = false
local page = 1
local NUM_PAGES = 4
local sel_ch = 1
local sel_param = 1

local screen_dirty = true
local grid_dirty = true

local key3_held = false
local grid_held = nil
local frozen = false
local freeze_release_clock = nil
local explorer = nil

local active_notes = {{}, {}, {}, {}}

local NOTE_NAMES = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
local DIVISIONS = {1/4, 1/8, 1/16, 1/32}
local DIV_NAMES = {"1/4", "1/8", "1/16", "1/32"}

local MODE_NAMES = {"analog", "spectral"}

local CH_PRESETS = {
  -- ch1: ACID -- analog mode, 303-style acid
  {mode=0,
   saw=0.9, pulse=0.0, sub=0.2, noise=0.0,
   detune=0.15, pw=0.5, cutoff=800, res=0.8,
   drive=1.0, env_mod=1.0,
   drift=0.1, decay=0.2, release=0.1, amp=0.7, pan=-0.2, delay_send=0.3,
   partials=4, tilt=0.8, spread=0.2,
   peak1=600, peak2=2200, peak_spread=0.3},
  -- ch2: KICK -- analog mode, sub bass
  {mode=0,
   saw=0.5, pulse=0.0, sub=0.9, noise=0.0,
   detune=0.0, pw=0.5, cutoff=300, res=0.5,
   drive=1.8, env_mod=1.0,
   drift=0.0, decay=0.15, release=0.1, amp=0.9, pan=0.0, delay_send=0.0,
   partials=2, tilt=2.5, spread=0.0,
   peak1=80, peak2=200, peak_spread=0.0},
  -- ch3: NOISE -- spectral mode, metallic alien percussion
  {mode=1,
   saw=0.5, pulse=0.3, sub=0.0, noise=0.4,
   detune=0.3, pw=0.5, cutoff=4000, res=0.7,
   drive=1.5, env_mod=0.9,
   drift=0.05, decay=0.06, release=0.03, amp=0.75, pan=0.25, delay_send=0.2,
   partials=4, tilt=0.3, spread=0.8,
   peak1=1800, peak2=4500, peak_spread=0.6},
  -- ch4: DARK -- spectral mode, drifting spectral fog
  {mode=1,
   saw=0.4, pulse=0.0, sub=0.3, noise=0.1,
   detune=0.4, pw=0.5, cutoff=600, res=0.35,
   drive=0.4, env_mod=0.3,
   drift=0.7, decay=1.5, release=1.0, amp=0.5, pan=0.2, delay_send=0.6,
   partials=4, tilt=1.5, spread=0.7,
   peak1=400, peak2=1200, peak_spread=0.5},
}

local CH_LABELS = {"ACID", "KICK", "NOISE", "DARK"}

----------------------------------------------------------------
-- macros
----------------------------------------------------------------

local MACRO_NAMES = {"GRIT", "SPACE", "CHAOS", "TIGHT"}
local macro_values = {0, 0, 0, 0}

-- apply macro changes across all channels
local function apply_macro_grit(val)
  for ch = 1, 4 do
    local base_drive = CH_PRESETS[ch].drive
    local base_res = CH_PRESETS[ch].res
    params:set("ch" .. ch .. "_drive", base_drive + val * 1.2)
    params:set("ch" .. ch .. "_res", math.min(0.95, base_res + val * 0.3))
    if params:get("ch" .. ch .. "_mode") == 1 then
      -- analog: close filter
      local base_co = CH_PRESETS[ch].cutoff
      params:set("ch" .. ch .. "_cutoff", base_co * (1 - val * 0.4))
    else
      -- spectral: lower peaks
      local base_p1 = CH_PRESETS[ch].peak1
      params:set("ch" .. ch .. "_peak1", base_p1 * (1 - val * 0.3))
    end
  end
end

local function apply_macro_space(val)
  params:set("delay_mix", 0.2 + val * 0.5)
  params:set("halo", 0.1 + val * 0.7)
  params:set("reverb_mix", 0.15 + val * 0.5)
  params:set("reverb_size", 0.5 + val * 0.45)
  for ch = 1, 4 do
    local base_ds = CH_PRESETS[ch].delay_send
    params:set("ch" .. ch .. "_delay_send", math.min(1.0, base_ds + val * 0.4))
  end
end

local function apply_macro_chaos(val)
  for ch = 1, 4 do
    local base_drift = CH_PRESETS[ch].drift
    params:set("ch" .. ch .. "_drift", math.min(1.0, base_drift + val * 0.6))
    if params:get("ch" .. ch .. "_mode") == 2 then
      local base_spread = CH_PRESETS[ch].spread
      params:set("ch" .. ch .. "_spread", math.min(1.0, base_spread + val * 0.5))
    end
  end
  if explorer then
    explorer.intensity = 0.3 + val * 0.6
    params:set("explorer_intensity", explorer.intensity)
  end
end

local function apply_macro_tight(val)
  for ch = 1, 4 do
    local base_dec = CH_PRESETS[ch].decay
    local base_rel = CH_PRESETS[ch].release
    local base_drive = CH_PRESETS[ch].drive
    params:set("ch" .. ch .. "_decay", base_dec * (1 - val * 0.6))
    params:set("ch" .. ch .. "_release", base_rel * (1 - val * 0.6))
    params:set("ch" .. ch .. "_drive", base_drive + val * 0.8)
  end
end

local macro_fns = {apply_macro_grit, apply_macro_space, apply_macro_chaos, apply_macro_tight}

local function set_macro(idx, val)
  macro_values[idx] = util.clamp(val, 0, 1)
  macro_fns[idx](macro_values[idx])
end

----------------------------------------------------------------
-- voice page params
----------------------------------------------------------------

-- analog params shown on voice page (display name, param suffix, bar_max)
local ANALOG_VOICE = {
  {name="cutoff", key="cutoff", max=18000, log=true},
  {name="res",    key="res",    max=0.95},
  {name="drive",  key="drive",  max=2.0},
  {name="envmod", key="env_mod", max=1.0},
  {name="saw",    key="saw",    max=1.0},
  {name="pulse",  key="pulse",  max=1.0},
  {name="sub",    key="sub",    max=1.0},
  {name="noise",  key="noise",  max=1.0},
  {name="detune", key="detune", max=1.0},
  {name="decay",  key="decay",  max=4.0, log=true},
  {name="amp",    key="amp",    max=1.0},
  {name="dlysnd", key="delay_send", max=1.0},
}

-- spectral params shown on voice page
local SPECTRAL_VOICE = {
  {name="peak1",  key="peak1",  max=8000, log=true},
  {name="peak2",  key="peak2",  max=12000, log=true},
  {name="res",    key="res",    max=0.95},
  {name="drive",  key="drive",  max=2.0},
  {name="parts",  key="partials", max=4},
  {name="tilt",   key="tilt",   max=3.0},
  {name="spread", key="spread", max=1.0},
  {name="envmod", key="env_mod", max=1.0},
  {name="decay",  key="decay",  max=4.0, log=true},
  {name="amp",    key="amp",    max=1.0},
  {name="dlysnd", key="delay_send", max=1.0},
}

local function voice_param_list()
  local m = params:get("ch" .. sel_ch .. "_mode")
  return m == 1 and ANALOG_VOICE or SPECTRAL_VOICE
end

----------------------------------------------------------------
-- FX params for macro page bottom half
----------------------------------------------------------------

local FX_PAGE = {
  {name="dly time", key="delay_time"},
  {name="dly fb",   key="delay_feedback"},
  {name="dly color", key="delay_color"},
  {name="dly mix",  key="delay_mix"},
  {name="halo",     key="halo"},
  {name="rev mix",  key="reverb_mix"},
  {name="rev size", key="reverb_size"},
}

-- macro page items: 4 macros + 7 FX = 11 total
local MACRO_PAGE_COUNT = #MACRO_NAMES + #FX_PAGE

----------------------------------------------------------------
-- voice randomize
----------------------------------------------------------------

local function randomize_voice(ch)
  local m = params:get("ch" .. ch .. "_mode")
  if m == 1 then
    -- analog
    params:set("ch" .. ch .. "_cutoff", 200 + math.random() * 5800)
    params:set("ch" .. ch .. "_res", 0.1 + math.random() * 0.7)
    params:set("ch" .. ch .. "_drive", 0.1 + math.random() * 1.4)
    params:set("ch" .. ch .. "_env_mod", math.random() * 1.0)
    -- random osc mix that sums to ~1
    local s = math.random() * 0.9
    local p = math.random() * (1 - s) * 0.8
    local sb = math.random() * (1 - s - p) * 0.9
    local n = math.random() * 0.3
    params:set("ch" .. ch .. "_saw", s)
    params:set("ch" .. ch .. "_pulse", p)
    params:set("ch" .. ch .. "_sub", sb)
    params:set("ch" .. ch .. "_noise", n)
    params:set("ch" .. ch .. "_detune", math.random() * 0.5)
  else
    -- spectral
    params:set("ch" .. ch .. "_peak1", 100 + math.random() * 3900)
    params:set("ch" .. ch .. "_peak2", 500 + math.random() * 7500)
    params:set("ch" .. ch .. "_res", 0.1 + math.random() * 0.7)
    params:set("ch" .. ch .. "_tilt", 0.3 + math.random() * 2.2)
    params:set("ch" .. ch .. "_spread", 0.1 + math.random() * 0.7)
    params:set("ch" .. ch .. "_partials", math.random(2, 4))
    params:set("ch" .. ch .. "_drive", 0.1 + math.random() * 1.2)
    params:set("ch" .. ch .. "_env_mod", math.random() * 0.8)
  end
end

----------------------------------------------------------------
-- init
----------------------------------------------------------------

function init()
  rep = Repetitor.new()
  zig = Ziggurat.new()
  explorer = Explorer.new(rep, zig)

  params:add_separator("TESSERA")

  params:add_number("bpm", "BPM", 20, 300, 130)
  params:set_action("bpm", function(v) params:set("clock_tempo", v) end)

  params:add_option("division", "division", DIV_NAMES, 3)

  params:add_option("root", "root note", NOTE_NAMES, 10)
  params:set_action("root", function(v)
    zig:set_scale(v - 1, params:get("scale"))
  end)

  local scale_names = {}
  for i = 1, #musicutil.SCALES do
    scale_names[i] = musicutil.SCALES[i].name
  end
  local default_scale = 1
  for i = 1, #scale_names do
    if scale_names[i] == "Minor Pentatonic" then default_scale = i; break end
  end
  params:add_option("scale", "scale", scale_names, default_scale)
  params:set_action("scale", function(v)
    zig:set_scale(params:get("root") - 1, v)
  end)

  -- harmonic drift
  params:add_separator("DRIFT")
  params:add_option("drift_enabled", "harmonic drift", {"off", "on"}, 2)
  params:set_action("drift_enabled", function(v) zig.drift_enabled = v == 2 end)

  params:add_control("drift_speed", "drift speed",
    controlspec.new(0.001, 0.1, 'exp', 0.001, 0.02))
  params:set_action("drift_speed", function(v) zig.drift_speed = v end)

  params:add_control("drift_range", "drift range",
    controlspec.new(1, 12, 'lin', 1, 7, "st"))
  params:set_action("drift_range", function(v) zig.drift_range = v end)

  -- cross-channel modulation
  params:add_separator("XMOD")
  params:add_option("xmod_enabled", "cross-mod", {"off", "on"}, 1)
  params:set_action("xmod_enabled", function(v) zig.xmod_enabled = v == 2 end)

  params:add_number("xmod_source", "xmod source ch", 1, 4, 1)
  params:set_action("xmod_source", function(v) zig.xmod_source = v end)

  params:add_number("xmod_target", "xmod target ch", 1, 4, 3)
  params:set_action("xmod_target", function(v) zig.xmod_target = v end)

  params:add_control("xmod_amount", "xmod amount",
    controlspec.new(0, 1, 'lin', 0.01, 0.3))
  params:set_action("xmod_amount", function(v) zig.xmod_amount = v end)

  -- explorer (autonomous bandmate)
  params:add_separator("EXPLORER")
  params:add_option("explorer_active", "bandmate", {"off", "on"}, 1)
  params:set_action("explorer_active", function(v) explorer.active = v == 2 end)

  params:add_control("explorer_intensity", "intensity",
    controlspec.new(0, 1, 'lin', 0.01, 0.5))
  params:set_action("explorer_intensity", function(v) explorer.intensity = v end)

  -- per-channel voice params
  for ch = 1, 4 do
    local pre = CH_PRESETS[ch]
    params:add_separator("CH " .. ch .. " " .. CH_LABELS[ch])

    params:add_option("ch" .. ch .. "_mode", "engine mode", MODE_NAMES, pre.mode + 1)
    params:set_action("ch" .. ch .. "_mode", function(v)
      engine.mode(ch - 1, (v - 1) * 1.0)  -- float: 0.0=analog, 1.0=spectral
      sel_param = 1
      screen_dirty = true
    end)

    -- analog-only params
    params:add_control("ch" .. ch .. "_saw", "saw level",
      controlspec.new(0, 1, 'lin', 0.01, pre.saw))
    params:set_action("ch" .. ch .. "_saw", function(v) engine.saw(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_pulse", "pulse level",
      controlspec.new(0, 1, 'lin', 0.01, pre.pulse))
    params:set_action("ch" .. ch .. "_pulse", function(v) engine.pulse(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_sub", "sub level",
      controlspec.new(0, 1, 'lin', 0.01, pre.sub))
    params:set_action("ch" .. ch .. "_sub", function(v) engine.sub(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_noise", "noise level",
      controlspec.new(0, 1, 'lin', 0.01, pre.noise))
    params:set_action("ch" .. ch .. "_noise", function(v) engine.noise(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_detune", "detune",
      controlspec.new(0, 1, 'lin', 0.01, pre.detune))
    params:set_action("ch" .. ch .. "_detune", function(v) engine.detune(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_pw", "pulse width",
      controlspec.new(0.05, 0.95, 'lin', 0.01, pre.pw))
    params:set_action("ch" .. ch .. "_pw", function(v) engine.pw(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_cutoff", "cutoff",
      controlspec.new(40, 18000, 'exp', 1, pre.cutoff, "hz"))
    params:set_action("ch" .. ch .. "_cutoff", function(v) engine.cutoff(ch - 1, v) end)

    -- spectral-only params
    params:add_control("ch" .. ch .. "_partials", "partials",
      controlspec.new(1, 4, 'lin', 1, pre.partials))
    params:set_action("ch" .. ch .. "_partials", function(v) engine.partials(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_tilt", "tilt",
      controlspec.new(0, 3, 'lin', 0.01, pre.tilt))
    params:set_action("ch" .. ch .. "_tilt", function(v) engine.tilt(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_spread", "spread",
      controlspec.new(0, 1, 'lin', 0.01, pre.spread))
    params:set_action("ch" .. ch .. "_spread", function(v) engine.spread(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_peak1", "peak 1",
      controlspec.new(40, 8000, 'exp', 1, pre.peak1, "hz"))
    params:set_action("ch" .. ch .. "_peak1", function(v) engine.peak1(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_peak2", "peak 2",
      controlspec.new(40, 12000, 'exp', 1, pre.peak2, "hz"))
    params:set_action("ch" .. ch .. "_peak2", function(v) engine.peak2(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_peak_spread", "peak spread",
      controlspec.new(0, 1, 'lin', 0.01, pre.peak_spread))
    params:set_action("ch" .. ch .. "_peak_spread", function(v) engine.peak_spread(ch - 1, v) end)

    -- shared params
    params:add_control("ch" .. ch .. "_drive", "drive",
      controlspec.new(0, 2, 'lin', 0.01, pre.drive))
    params:set_action("ch" .. ch .. "_drive", function(v) engine.drive(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_res", "resonance",
      controlspec.new(0, 0.95, 'lin', 0.01, pre.res))
    params:set_action("ch" .. ch .. "_res", function(v) engine.res(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_env_mod", "env mod",
      controlspec.new(0, 1, 'lin', 0.01, pre.env_mod))
    params:set_action("ch" .. ch .. "_env_mod", function(v) engine.env_mod(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_drift", "drift",
      controlspec.new(0, 1, 'lin', 0.01, pre.drift))
    params:set_action("ch" .. ch .. "_drift", function(v) engine.drift(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_decay", "decay",
      controlspec.new(0.01, 4, 'exp', 0.01, pre.decay, "s"))
    params:set_action("ch" .. ch .. "_decay", function(v) engine.dec(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_release", "release",
      controlspec.new(0.01, 4, 'exp', 0.01, pre.release, "s"))
    params:set_action("ch" .. ch .. "_release", function(v) engine.rel(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_amp", "amp",
      controlspec.new(0, 1, 'lin', 0.01, pre.amp))
    params:set_action("ch" .. ch .. "_amp", function(v) engine.amp(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_delay_send", "delay send",
      controlspec.new(0, 1, 'lin', 0.01, pre.delay_send))
    params:set_action("ch" .. ch .. "_delay_send", function(v) engine.delay_send(ch - 1, v) end)

    params:add_control("ch" .. ch .. "_pan", "pan",
      controlspec.new(-1, 1, 'lin', 0.01, pre.pan))
    params:set_action("ch" .. ch .. "_pan", function(v) engine.pan(ch - 1, v) end)
  end

  -- FX
  params:add_separator("FX")

  params:add_control("delay_time", "delay time",
    controlspec.new(0.01, 2.0, 'exp', 0.01, 0.3, "s"))
  params:set_action("delay_time", function(v) engine.delay_time(v) end)

  params:add_control("delay_feedback", "delay fb",
    controlspec.new(0, 0.9, 'lin', 0.01, 0.6))
  params:set_action("delay_feedback", function(v) engine.delay_feedback(v) end)

  params:add_control("delay_color", "delay color",
    controlspec.new(200, 12000, 'exp', 1, 2500, "hz"))
  params:set_action("delay_color", function(v) engine.delay_color(v) end)

  params:add_control("delay_mix", "delay mix",
    controlspec.new(0, 1, 'lin', 0.01, 0.4))
  params:set_action("delay_mix", function(v) engine.delay_mix(v) end)

  params:add_control("halo", "halo",
    controlspec.new(0, 1, 'lin', 0.01, 0.4))
  params:set_action("halo", function(v) engine.halo(v) end)

  params:add_control("reverb_mix", "reverb mix",
    controlspec.new(0, 1, 'lin', 0.01, 0.35))
  params:set_action("reverb_mix", function(v) engine.reverb_mix(v) end)

  params:add_control("reverb_size", "reverb size",
    controlspec.new(0, 1, 'lin', 0.01, 0.9))
  params:set_action("reverb_size", function(v) engine.reverb_size(v) end)

  -- MIDI
  params:add_separator("MIDI")
  params:add_number("midi_device", "midi device", 1, 4, 1)
  params:set_action("midi_device", function(v) midi_out = midi.connect(v) end)
  for ch = 1, 4 do
    params:add_number("midi_ch_" .. ch, "ch " .. ch .. " midi ch", 1, 16, ch)
  end
  params:add_option("midi_enabled", "midi out", {"off", "on"}, 1)

  midi_out = midi.connect(params:get("midi_device"))
  params:bang()

  -- main sequencer
  clock.run(step_clock)

  -- ratchet sub-clock
  clock.run(ratchet_clock)

  -- screen/grid refresh
  clock.run(function()
    while true do
      clock.sleep(1/15)
      if screen_dirty then redraw(); screen_dirty = false end
      if grid_dirty then grid_redraw(); grid_dirty = false end
    end
  end)
end

----------------------------------------------------------------
-- sequencer
----------------------------------------------------------------

local ratchet_queue = {}

function step_clock()
  while true do
    clock.sync(DIVISIONS[params:get("division")])
    if playing and not frozen then
      zig:update_drift()

      local voice_changes = explorer:step()
      if voice_changes then
        for _, change in ipairs(voice_changes) do
          local pkey, action, val = change[1], change[2], change[3]
          if params.lookup[pkey] then
            if action == "delta" then params:delta(pkey, val)
            else params:set(pkey, val) end
          end
        end
      end

      for ch = 1, 4 do
        local hit, accent, ratch = rep:advance(ch)
        if hit then
          local note = zig:advance(ch)
          local freq = musicutil.note_num_to_freq(note)
          local slew = zig.channels[ch].slew

          trigger_voice(ch, freq, accent, slew, note)

          if ratch and ratch > 1 then
            ratchet_queue[ch] = {
              freq = freq,
              accent = accent * 0.7,
              remaining = ratch - 1,
              slew = slew,
              note = note,
            }
          end
        end
      end
      screen_dirty = true
      grid_dirty = true
    end
  end
end

function ratchet_clock()
  while true do
    clock.sync(DIVISIONS[params:get("division")] / 4)
    if playing and not frozen then
      for ch = 1, 4 do
        local r = ratchet_queue[ch]
        if r and r.remaining > 0 then
          trigger_voice(ch, r.freq, r.accent, r.slew, r.note)
          r.remaining = r.remaining - 1
          r.accent = r.accent * 0.85
          if r.remaining <= 0 then
            ratchet_queue[ch] = nil
          end
        end
      end
    end
  end
end

function trigger_voice(ch, freq, accent, slew, note)
  engine.slew(ch - 1, slew)
  engine.hz(ch - 1, freq)
  engine.accent(ch - 1, accent)
  engine.gate(ch - 1, 1)

  if params:get("midi_enabled") == 2 and midi_out then
    local midi_ch = params:get("midi_ch_" .. ch)
    for _, n in ipairs(active_notes[ch]) do
      midi_out:note_off(n, 0, midi_ch)
    end
    local vel = util.clamp(math.floor(accent * 127), 1, 127)
    midi_out:note_on(note, vel, midi_ch)
    active_notes[ch] = {note}
  end
end

----------------------------------------------------------------
-- performance freeze
----------------------------------------------------------------

function enter_freeze()
  frozen = true
  for ch = 1, 4 do
    local note = zig.channels[ch].last_note
    local freq = musicutil.note_num_to_freq(note)
    engine.slew(ch - 1, 0.5)
    engine.hz(ch - 1, freq)
    engine.accent(ch - 1, 0.6)
    if params:get("ch" .. ch .. "_mode") == 2 then
      engine.freeze(ch - 1, 1)
    end
    engine.gate(ch - 1, 1)
  end
  screen_dirty = true
end

function release_freeze()
  frozen = false
  ratchet_queue = {}
  for ch = 1, 4 do
    if params:get("ch" .. ch .. "_mode") == 2 then
      engine.freeze(ch - 1, 0)
    end
  end
  screen_dirty = true
end

----------------------------------------------------------------
-- encoders
----------------------------------------------------------------

function enc(n, d)
  if n == 1 then
    page = util.clamp(page + d, 1, NUM_PAGES)
    sel_param = 1
  elseif n == 2 then
    if page == 1 then
      sel_ch = util.clamp(sel_ch + d, 1, 4)
    elseif page == 2 then
      -- rhythm mode
      local c = rep.channels[sel_ch]
      c.mode = util.clamp(c.mode + d, 1, rep:get_num_modes())
      rep:regenerate(sel_ch)
    elseif page == 3 then
      local vp = voice_param_list()
      sel_param = util.clamp(sel_param + d, 1, #vp)
    elseif page == 4 then
      sel_param = util.clamp(sel_param + d, 1, MACRO_PAGE_COUNT)
    end
  elseif n == 3 then
    if grid_held then
      if grid_held.type == "rhythm" then
        local c = rep.channels[grid_held.ch]
        local cur = c.ratchets[grid_held.step] or 1
        local new = util.clamp(cur + d, 1, 4)
        rep:set_ratchet(grid_held.ch, grid_held.step, new)
      elseif grid_held.type == "pitch" then
        local c = zig.channels[grid_held.ch]
        local cur = c.chain[grid_held.step] or 60
        local new = util.clamp(cur + d, c.range_lo, c.range_hi)
        new = zig:quantize(new)
        c.chain[grid_held.step] = new
      end
    elseif page == 1 then
      -- E3 on play page: main param per channel (K3: BPM/division)
      if key3_held then
        params:delta("bpm", d)
      else
        -- control the key tone param for selected channel
        local mode_idx = params:get("ch" .. sel_ch .. "_mode")
        if mode_idx == 1 then
          params:delta("ch" .. sel_ch .. "_cutoff", d)
        else
          params:delta("ch" .. sel_ch .. "_peak1", d)
        end
      end
    elseif page == 2 then
      -- E3 on rhythm page: pulses/offset
      local c = rep.channels[sel_ch]
      if key3_held then
        c.offset = (c.offset + d) % c.steps
      else
        if c.mode == 1 then
          c.pulses = util.clamp(c.pulses + d, 0, c.steps)
        else
          c.offset = (c.offset + d) % c.steps
        end
      end
      rep:regenerate(sel_ch)
    elseif page == 3 then
      -- E3 on voice page: adjust selected param
      local vp = voice_param_list()
      local p = vp[sel_param]
      if p then
        local pkey = "ch" .. sel_ch .. "_" .. p.key
        if params.lookup[pkey] then params:delta(pkey, d) end
      end
    elseif page == 4 then
      -- E3 on macro page: adjust macro or FX param
      if sel_param <= #MACRO_NAMES then
        set_macro(sel_param, macro_values[sel_param] + d * 0.02)
      else
        local fx_idx = sel_param - #MACRO_NAMES
        local fp = FX_PAGE[fx_idx]
        if fp and params.lookup[fp.key] then
          params:delta(fp.key, d)
        end
      end
    end
  end
  screen_dirty = true
  grid_dirty = true
end

----------------------------------------------------------------
-- keys
----------------------------------------------------------------

function key(n, z)
  if n == 2 and z == 1 then
    if playing then
      playing = false
      frozen = false
      ratchet_queue = {}
      all_notes_off()
      rep:reset()
      zig:reset()
    else
      playing = true
    end
  elseif n == 3 then
    if z == 1 then
      key3_held = true
      if page == 3 then
        -- K3 tap on voice page = randomize selected channel
        randomize_voice(sel_ch)
      elseif playing then
        enter_freeze()
      end
    else
      key3_held = false
      if frozen then
        release_freeze()
      end
    end
  end
  screen_dirty = true
end

function all_notes_off()
  for ch = 1, 4 do
    engine.gate(ch - 1, 0)
    if midi_out then
      local midi_ch = params:get("midi_ch_" .. ch)
      for _, note in ipairs(active_notes[ch]) do
        midi_out:note_off(note, 0, midi_ch)
      end
      active_notes[ch] = {}
    end
  end
end

----------------------------------------------------------------
-- screen
----------------------------------------------------------------

local PAGE_NAMES = {"PLAY", "RHYTHM", "VOICE", "MACRO"}

function redraw()
  screen.clear()
  screen.aa(0)
  screen.font_face(1)
  screen.font_size(8)

  -- header
  screen.level(playing and 15 or 5)
  screen.move(1, 7)
  screen.text("TESSERA")

  if frozen then
    screen.level(15)
    screen.move(50, 7)
    screen.text("FRZ")
  end

  screen.level(8)
  screen.move(128, 7)
  screen.text_right(PAGE_NAMES[page])

  -- page dots
  for i = 1, NUM_PAGES do
    screen.level(i == page and 15 or 3)
    screen.rect(55 + (i-1)*5, 3, 3, 3)
    screen.fill()
  end

  screen.level(2)
  screen.move(1, 9)
  screen.line(128, 9)
  screen.stroke()

  if page == 1 then draw_play()
  elseif page == 2 then draw_rhythm()
  elseif page == 3 then draw_voice()
  elseif page == 4 then draw_macro()
  end

  -- footer
  screen.level(3)
  if explorer and explorer.active then
    screen.level(8)
    screen.move(1, 63)
    screen.text(explorer:get_phase_name())
    screen.level(3)
  end
  if zig.drift_enabled then
    screen.move(50, 63)
    local drift_st = string.format("%+.1f", zig.drift_amount)
    screen.text("drft " .. drift_st)
  end
  screen.move(128, 63)
  screen.text_right(params:string("bpm"))

  screen.update()
end

----------------------------------------------------------------
-- PAGE 1: PLAY -- overview of all 4 channels
----------------------------------------------------------------

function draw_play()
  for ch = 1, 4 do
    local c = rep.channels[ch]
    local zc = zig.channels[ch]
    local y = 11 + (ch - 1) * 13
    local is_sel = ch == sel_ch

    -- channel label
    screen.level(is_sel and 15 or 5)
    screen.move(1, y + 8)
    screen.text(CH_LABELS[ch])

    -- mini pattern visualization (32px wide)
    local x0 = 32
    local pw = math.floor(30 / c.steps)
    if pw < 1 then pw = 1 end
    for i = 1, math.min(c.steps, 16) do
      local x = x0 + (i - 1) * pw
      if c.pattern[i] == 1 then
        local bright = (i == c.position and playing) and 15 or (is_sel and 8 or 4)
        if c.muted then bright = 2 end
        screen.level(bright)
        screen.rect(x, y + 2, pw - 1, 5)
        screen.fill()
      elseif i == c.position and playing then
        screen.level(3)
        screen.rect(x, y + 2, pw - 1, 5)
        screen.fill()
      end
    end

    -- current note
    local note = zc.last_note or 60
    local name = musicutil.note_num_to_name(note, true)
    screen.level(is_sel and 12 or 5)
    screen.move(66, y + 8)
    screen.text(name)

    -- mode indicator
    local mode_idx = params:get("ch" .. ch .. "_mode")
    screen.level(is_sel and 7 or 3)
    screen.move(86, y + 8)
    screen.text(mode_idx == 1 and "ANLG" or "SPEC")

    -- key param value (what E3 controls)
    local mode_idx = params:get("ch" .. ch .. "_mode")
    if is_sel then
      screen.level(12)
      screen.move(104, y + 8)
      if mode_idx == 1 then
        screen.text_right(string.format("%.0f", params:get("ch" .. ch .. "_cutoff")))
      else
        screen.text_right(string.format("%.0f", params:get("ch" .. ch .. "_peak1")))
      end
    end

    -- mute indicator
    if c.muted then
      screen.level(2)
      screen.move(108, y + 8)
      screen.text("x")
    end

    -- playhead dot
    if playing and not c.muted then
      screen.level(15)
      screen.rect(126, y + 3, 2, 2)
      screen.fill()
    end
  end

  -- footer: BPM + division
  screen.level(8)
  screen.move(1, 63)
  screen.text("E3:" .. (key3_held and "BPM" or "filter"))
  screen.level(5)
  screen.move(128, 63)
  screen.text_right(params:get("bpm") .. " " .. DIV_NAMES[params:get("division")])
end

----------------------------------------------------------------
-- PAGE 2: RHYTHM -- selected channel rhythm detail
----------------------------------------------------------------

function draw_rhythm()
  local c = rep.channels[sel_ch]

  -- channel header
  screen.level(12)
  screen.move(1, 18)
  screen.text("CH" .. sel_ch .. " " .. CH_LABELS[sel_ch])
  screen.level(6)
  screen.move(60, 18)
  screen.text(rep:get_mode_name(sel_ch))
  if c.mode == 1 then
    screen.move(90, 18)
    screen.text(c.pulses .. "/" .. c.steps)
  end

  -- large pattern display
  local x0 = 2
  local y0 = 22
  local step_w = math.floor(124 / c.steps)
  if step_w < 2 then step_w = 2 end
  local step_h = 16

  for i = 1, c.steps do
    local x = x0 + (i - 1) * step_w
    local prob = c.probability[i] or 100
    local ratch = c.ratchets[i] or 1
    local is_pos = (i == c.position and playing)

    if c.pattern[i] == 1 then
      -- brightness reflects probability
      local base = 10
      if prob < 100 then
        base = math.max(3, math.floor(10 * prob / 100))
      end
      screen.level(is_pos and 15 or base)
      screen.rect(x, y0, step_w - 1, step_h)
      screen.fill()

      -- ratchet dots below step
      if ratch > 1 then
        screen.level(12)
        for r = 1, ratch do
          local dot_x = x + math.floor((step_w - 1) / 2) - math.floor(ratch / 2) + r - 1
          screen.pixel(dot_x, y0 + step_h + 2)
          screen.fill()
        end
      end

      -- probability text for low-prob steps
      if prob < 100 then
        screen.level(1)
        screen.move(x + 1, y0 + step_h - 2)
        screen.font_size(6)
        screen.text(prob)
        screen.font_size(8)
      end
    else
      if is_pos then
        screen.level(4)
        screen.rect(x, y0, step_w - 1, step_h)
        screen.fill()
      else
        screen.level(2)
        screen.rect(x, y0, step_w - 1, step_h)
        screen.stroke()
      end
    end
  end

  -- offset indicator
  if c.offset > 0 then
    screen.level(5)
    screen.move(1, 52)
    screen.text("off:" .. c.offset)
  end

  -- pitch advance mode
  screen.level(5)
  screen.move(90, 52)
  screen.text("pitch:" .. zig:get_mode_name(sel_ch))
end

----------------------------------------------------------------
-- PAGE 3: VOICE -- mode-aware param bars
----------------------------------------------------------------

function draw_voice()
  local mode = params:get("ch" .. sel_ch .. "_mode")
  local mode_label = MODE_NAMES[mode]

  -- header
  screen.level(12)
  screen.move(1, 18)
  screen.text("CH" .. sel_ch .. " " .. CH_LABELS[sel_ch])
  screen.level(6)
  screen.move(75, 18)
  screen.text(mode_label)
  screen.level(3)
  screen.move(112, 18)
  screen.text("K3:rnd")

  local vp = voice_param_list()
  local y0 = 22
  local bar_h = 5
  local gap = 1
  local max_visible = 6
  -- scroll offset so selected param is visible
  local scroll = 0
  if sel_param > max_visible then
    scroll = sel_param - max_visible
  end

  for i = 1, math.min(max_visible, #vp) do
    local idx = i + scroll
    if idx > #vp then break end
    local p = vp[idx]
    local is_sel = idx == sel_param
    local y = y0 + (i - 1) * (bar_h + gap + 1)
    local pkey = "ch" .. sel_ch .. "_" .. p.key

    -- param name
    screen.level(is_sel and 15 or 5)
    screen.move(1, y + bar_h)
    screen.text(p.name)

    -- bar
    local bar_x = 35
    local bar_w = 68
    local val = 0
    if params.lookup[pkey] then
      val = params:get(pkey)
    end
    local norm
    if p.log then
      local min_v = 0.01
      if p.key == "cutoff" then min_v = 40
      elseif p.key == "peak1" then min_v = 40
      elseif p.key == "peak2" then min_v = 40
      elseif p.key == "decay" then min_v = 0.01
      end
      norm = math.log(val / min_v) / math.log(p.max / min_v)
    else
      norm = val / p.max
    end
    norm = util.clamp(norm, 0, 1)

    -- background
    screen.level(2)
    screen.rect(bar_x, y, bar_w, bar_h)
    screen.stroke()

    -- fill
    screen.level(is_sel and 12 or 6)
    local fill_w = math.floor(norm * bar_w)
    if fill_w > 0 then
      screen.rect(bar_x, y, fill_w, bar_h)
      screen.fill()
    end

    -- value text
    screen.level(is_sel and 15 or 7)
    screen.move(106, y + bar_h)
    if params.lookup[pkey] then
      local str = params:string(pkey)
      -- truncate long strings
      if #str > 6 then str = str:sub(1, 6) end
      screen.text(str)
    end
  end

  -- scroll indicators
  if scroll > 0 then
    screen.level(4)
    screen.move(125, 22)
    screen.text("^")
  end
  if scroll + max_visible < #vp then
    screen.level(4)
    screen.move(125, 56)
    screen.text("v")
  end
end

----------------------------------------------------------------
-- PAGE 4: MACRO / FX
----------------------------------------------------------------

function draw_macro()
  -- MACROS section (top half)
  screen.level(5)
  screen.move(1, 17)
  screen.text("MACROS")

  for i = 1, #MACRO_NAMES do
    local is_sel = sel_param == i
    local y = 20 + (i - 1) * 8

    screen.level(is_sel and 15 or 6)
    screen.move(1, y + 6)
    screen.text(MACRO_NAMES[i])

    -- bar
    local bar_x = 35
    local bar_w = 60
    screen.level(2)
    screen.rect(bar_x, y, bar_w, 5)
    screen.stroke()

    local fill = math.floor(macro_values[i] * bar_w)
    if fill > 0 then
      screen.level(is_sel and 12 or 6)
      screen.rect(bar_x, y, fill, 5)
      screen.fill()
    end

    -- percentage
    screen.level(is_sel and 10 or 4)
    screen.move(100, y + 6)
    screen.text(math.floor(macro_values[i] * 100) .. "%")
  end

  -- divider
  screen.level(2)
  screen.move(1, 53)
  screen.line(128, 53)
  screen.stroke()

  -- FX section (bottom -- just show selected if in FX zone)
  local fx_sel = sel_param - #MACRO_NAMES
  if fx_sel >= 1 and fx_sel <= #FX_PAGE then
    local fp = FX_PAGE[fx_sel]
    screen.level(10)
    screen.move(1, 61)
    screen.text(fp.name)
    if params.lookup[fp.key] then
      screen.move(60, 61)
      screen.text(params:string(fp.key))
    end
    -- arrows
    if fx_sel > 1 then
      screen.level(4)
      screen.move(115, 61)
      screen.text("<")
    end
    if fx_sel < #FX_PAGE then
      screen.level(4)
      screen.move(123, 61)
      screen.text(">")
    end
  else
    -- show first FX as preview
    screen.level(4)
    screen.move(1, 61)
    screen.text("E2 v for FX")
  end
end

----------------------------------------------------------------
-- grid
----------------------------------------------------------------

g.key = function(x, y, z)
  if y >= 1 and y <= 4 then
    local ch = y
    local c = rep.channels[ch]
    if z == 1 then
      if x >= 1 and x <= c.steps then
        if key3_held then
          local cur = c.probability[x] or 100
          if cur > 75 then c.probability[x] = 75
          elseif cur > 50 then c.probability[x] = 50
          elseif cur > 25 then c.probability[x] = 25
          else c.probability[x] = 100 end
        else
          grid_held = {ch = ch, step = x, type = "rhythm"}
        end
      end
      sel_ch = ch
    else
      if grid_held and grid_held.type == "rhythm" and grid_held.ch == ch and grid_held.step == x then
        if not key3_held then
          c.pattern[x] = c.pattern[x] == 1 and 0 or 1
          if c.pattern[x] == 1 then
            c.accents[x] = ((x - 1) % 4 == 0) and 1.0 or 0.65
          else
            c.accents[x] = 0
          end
        end
        grid_held = nil
      end
    end

  elseif y >= 5 and y <= 8 then
    local ch = y - 4
    local c = zig.channels[ch]
    if z == 1 then
      if x >= 1 and x <= c.chain_len then
        grid_held = {ch = ch, step = x, type = "pitch"}
        sel_ch = ch
      elseif x == c.chain_len + 1 and c.chain_len < 16 then
        zig:set_chain_length(ch, c.chain_len + 1)
        sel_ch = ch
      end
    else
      if grid_held and grid_held.type == "pitch" and grid_held.ch == ch then
        grid_held = nil
      end
    end
  end

  screen_dirty = true; grid_dirty = true
end

function grid_redraw()
  g:all(0)

  -- rhythm rows (1-4)
  for ch = 1, 4 do
    local c = rep.channels[ch]
    for x = 1, math.min(c.steps, 16) do
      local bright = 0
      local prob = c.probability[x] or 100
      local ratch = c.ratchets[x] or 1

      if c.pattern[x] == 1 then
        local base = 8
        if prob < 100 then base = math.max(3, math.floor(8 * prob / 100)) end
        if ratch > 1 then base = math.min(base + 2, 12) end
        bright = (x == c.position and playing) and 15 or base
      else
        bright = (x == c.position and playing) and 4 or 0
      end
      if c.muted then bright = math.floor(bright * 0.3) end
      g:led(x, ch, bright)
    end
  end

  -- pitch rows (5-8)
  for ch = 1, 4 do
    local c = zig.channels[ch]
    for x = 1, math.min(c.chain_len, 16) do
      local bright = 4
      if x == c.position and playing then bright = 15
      elseif grid_held and grid_held.type == "pitch" and grid_held.ch == ch and grid_held.step == x then bright = 12
      else
        local note = c.chain[x] or 60
        bright = math.floor(util.linlin(24, 96, 3, 10, note))
      end
      g:led(x, ch + 4, bright)
    end
    if c.chain_len < 16 then g:led(c.chain_len + 1, ch + 4, 2) end
  end

  g:refresh()
end

----------------------------------------------------------------
-- cleanup
----------------------------------------------------------------

function cleanup()
  playing = false
  frozen = false
  all_notes_off()
end
