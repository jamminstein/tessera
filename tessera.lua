-- tessera
-- algorithmic mosaic synth
--
-- multi repetitor rhythms
-- ziggurat pitch chains
-- 4 channels: analog (MoogFF) or spectral (resynthesizer)
--
-- E1: page (rhythm/pitch/voice/fx)
-- E2: select channel or param
-- E3: adjust value
-- K2: play/stop
-- K3: performance freeze (hold)
--     on rhythm page: hold grid step + E3 = ratchet
--     on pitch page: hold grid step + E3 = edit note
--
-- grid top 4 rows: rhythm steps
--   brightness = probability (dim=maybe)
--   hold step + E3 = set ratchet (1-4x)
--   K3 + tap step = cycle probability
-- grid bottom 4 rows: pitch chain
--   hold step + E3 = edit pitch

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
local grid_held = nil        -- {ch=, step=, type="rhythm"|"pitch"}
local frozen = false         -- performance freeze active
local freeze_release_clock = nil
local explorer = nil         -- autonomous bandmate

local active_notes = {{}, {}, {}, {}}

local NOTE_NAMES = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
local DIVISIONS = {1/4, 1/8, 1/16, 1/32}
local DIV_NAMES = {"1/4", "1/8", "1/16", "1/32"}

local MODE_NAMES = {"analog", "spectral"}

-- mode-specific param lists for voice page navigation
local ANALOG_PARAMS = {
  "saw", "pulse", "sub", "noise",
  "detune", "pw", "cutoff", "res",
  "drive", "env_mod", "drift", "decay", "release",
  "amp", "delay_send"
}

local SPECTRAL_PARAMS = {
  "partials", "tilt", "spread", "drive",
  "peak1", "peak2", "peak_spread", "res",
  "env_mod", "drift", "decay", "release",
  "amp", "delay_send"
}

-- returns the active param list for a channel
local function voice_params_for(ch)
  local m = params:get("ch" .. ch .. "_mode")
  if m == 1 then return ANALOG_PARAMS else return SPECTRAL_PARAMS end
end

local CH_PRESETS = {
  -- ch1: ACID — analog mode, 303-style acid
  {mode=0,
   saw=0.9, pulse=0.0, sub=0.2, noise=0.0,
   detune=0.15, pw=0.5, cutoff=800, res=0.8,
   drive=1.0, env_mod=1.0,
   drift=0.1, decay=0.2, release=0.1, amp=0.6, pan=-0.5, delay_send=0.3,
   -- spectral defaults (kept in sync for mode switching)
   partials=4, tilt=0.8, spread=0.2,
   peak1=600, peak2=2200, peak_spread=0.3},
  -- ch2: KICK — analog mode, sub bass
  {mode=0,
   saw=0.5, pulse=0.0, sub=0.9, noise=0.0,
   detune=0.0, pw=0.5, cutoff=300, res=0.5,
   drive=1.8, env_mod=1.0,
   drift=0.0, decay=0.15, release=0.1, amp=0.85, pan=0.0, delay_send=0.0,
   partials=2, tilt=2.5, spread=0.0,
   peak1=80, peak2=200, peak_spread=0.0},
  -- ch3: NOISE — spectral mode, metallic alien percussion
  {mode=1,
   saw=0.5, pulse=0.3, sub=0.0, noise=0.4,
   detune=0.3, pw=0.5, cutoff=4000, res=0.7,
   drive=1.5, env_mod=0.9,
   drift=0.05, decay=0.06, release=0.03, amp=0.7, pan=0.5, delay_send=0.2,
   partials=6, tilt=0.3, spread=0.8,
   peak1=1800, peak2=4500, peak_spread=0.6},
  -- ch4: DARK — spectral mode, drifting spectral fog
  {mode=1,
   saw=0.4, pulse=0.0, sub=0.3, noise=0.1,
   detune=0.4, pw=0.5, cutoff=600, res=0.35,
   drive=0.4, env_mod=0.3,
   drift=0.7, decay=1.5, release=1.0, amp=0.4, pan=0.7, delay_send=0.6,
   partials=5, tilt=1.5, spread=0.7,
   peak1=400, peak2=1200, peak_spread=0.5},
}

local CH_LABELS = {"ACID", "KICK", "NOISE", "DARK"}

local FX_PARAMS = {"delay_time", "delay_feedback", "delay_color", "delay_mix",
                    "halo", "reverb_mix", "reverb_size"}

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

  -- default to A (index 10) for dark minor feel
  params:add_option("root", "root note", NOTE_NAMES, 10)
  params:set_action("root", function(v)
    zig:set_scale(v - 1, params:get("scale"))
  end)

  local scale_names = {}
  for i = 1, #musicutil.SCALES do
    scale_names[i] = musicutil.SCALES[i].name
  end
  -- default to minor pentatonic (index 6 in musicutil) for dark/tribal feel
  -- find minor pentatonic index
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
  params:add_option("explorer_active", "bandmate", {"off", "on"}, 2)
  params:set_action("explorer_active", function(v) explorer.active = v == 2 end)

  params:add_control("explorer_intensity", "intensity",
    controlspec.new(0, 1, 'lin', 0.01, 0.5))
  params:set_action("explorer_intensity", function(v) explorer.intensity = v end)

  -- per-channel voice params
  for ch = 1, 4 do
    local pre = CH_PRESETS[ch]
    params:add_separator("CH " .. ch .. " " .. CH_LABELS[ch])

    -- engine mode: analog or spectral
    params:add_option("ch" .. ch .. "_mode", "engine mode", MODE_NAMES, pre.mode + 1)
    params:set_action("ch" .. ch .. "_mode", function(v)
      engine.mode(ch - 1, v - 1)
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
      controlspec.new(1, 6, 'lin', 1, pre.partials))
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

  -- ratchet sub-clock (runs at 4x division for ratchet bursts)
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

-- pending ratchets: {ch, freq, accent, remaining, slew}
local ratchet_queue = {}

function step_clock()
  while true do
    clock.sync(DIVISIONS[params:get("division")])
    if playing and not frozen then
      -- update harmonic drift once per master step
      zig:update_drift()

      -- explorer autonomous mutations
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

          -- queue ratchet sub-hits
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
    -- run at 4x the main division for sub-triggers
    clock.sync(DIVISIONS[params:get("division")] / 4)
    if playing and not frozen then
      for ch = 1, 4 do
        local r = ratchet_queue[ch]
        if r and r.remaining > 0 then
          trigger_voice(ch, r.freq, r.accent, r.slew, r.note)
          r.remaining = r.remaining - 1
          r.accent = r.accent * 0.85  -- each sub-hit softer
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
  -- retrigger all voices with long decay + spectral freeze (spectral only)
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
  -- release spectral freeze (spectral channels only)
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
    if page == 3 then
      local vp = voice_params_for(sel_ch)
      sel_param = util.clamp(sel_param + d, 1, #vp)
    elseif page == 4 then
      sel_param = util.clamp(sel_param + d, 1, #FX_PARAMS)
    else
      sel_ch = util.clamp(sel_ch + d, 1, 4)
    end
  elseif n == 3 then
    if grid_held then
      if grid_held.type == "rhythm" then
        -- hold rhythm step + E3 = set ratchet count
        local c = rep.channels[grid_held.ch]
        local cur = c.ratchets[grid_held.step] or 1
        local new = util.clamp(cur + d, 1, 4)
        rep:set_ratchet(grid_held.ch, grid_held.step, new)
      elseif grid_held.type == "pitch" then
        -- hold pitch step + E3 = edit note
        local c = zig.channels[grid_held.ch]
        local cur = c.chain[grid_held.step] or 60
        local new = util.clamp(cur + d, c.range_lo, c.range_hi)
        new = zig:quantize(new)
        c.chain[grid_held.step] = new
      end
    elseif page == 1 then enc_rhythm(d)
    elseif page == 2 then enc_pitch(d)
    elseif page == 3 then enc_voice(d)
    elseif page == 4 then enc_fx(d)
    end
  end
  screen_dirty = true
  grid_dirty = true
end

function enc_rhythm(d)
  local c = rep.channels[sel_ch]
  if key3_held then
    if c.mode == 1 then
      c.pulses = util.clamp(c.pulses + d, 0, c.steps)
    else
      c.offset = (c.offset + d) % c.steps
    end
  else
    c.mode = util.clamp(c.mode + d, 1, rep:get_num_modes())
  end
  rep:regenerate(sel_ch)
end

function enc_pitch(d)
  local c = zig.channels[sel_ch]
  if key3_held then
    zig:set_chain_length(sel_ch, c.chain_len + d)
  else
    c.advance_mode = util.clamp(c.advance_mode + d, 1, zig:get_num_modes())
  end
end

function enc_voice(d)
  local vp = voice_params_for(sel_ch)
  local pname = vp[sel_param]
  if pname then
    local pkey = "ch" .. sel_ch .. "_" .. pname
    if params.lookup[pkey] then params:delta(pkey, d) end
  end
end

function enc_fx(d)
  local pkey = FX_PARAMS[sel_param]
  if pkey and params.lookup[pkey] then params:delta(pkey, d) end
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
    key3_held = z == 1
    -- performance freeze: hold K3 = freeze, release = unfreeze
    if z == 1 and playing then
      enter_freeze()
    elseif z == 0 and frozen then
      release_freeze()
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

local PAGE_NAMES = {"RHYTHM", "PITCH", "VOICE", "FX"}

function redraw()
  screen.clear()
  screen.aa(0)
  screen.font_face(1)
  screen.font_size(8)

  -- header
  screen.level(playing and 15 or 5)
  screen.move(1, 7)
  screen.text("TESSERA")

  -- freeze indicator
  if frozen then
    screen.level(15)
    screen.move(50, 7)
    screen.text("FROZEN")
  end

  screen.level(8)
  screen.move(128, 7)
  screen.text_right(PAGE_NAMES[page])

  for i = 1, NUM_PAGES do
    screen.level(i == page and 15 or 3)
    screen.rect(55 + (i-1)*5, 3, 3, 3)
    screen.fill()
  end

  screen.level(2)
  screen.move(1, 9)
  screen.line(128, 9)
  screen.stroke()

  if page == 1 then draw_rhythm()
  elseif page == 2 then draw_pitch()
  elseif page == 3 then draw_voice()
  elseif page == 4 then draw_fx()
  end

  -- footer
  screen.level(3)
  screen.move(1, 63)
  if explorer.active then
    screen.level(8)
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

function draw_rhythm()
  for ch = 1, 4 do
    local c = rep.channels[ch]
    local y = 12 + (ch - 1) * 12
    local is_sel = ch == sel_ch

    screen.level(is_sel and 15 or 4)
    screen.move(1, y + 7)
    screen.text(ch)

    local x0 = 10
    local w = math.floor(78 / c.steps)
    for i = 1, c.steps do
      local x = x0 + (i - 1) * w
      local is_play = (i == c.position and playing)
      local prob = c.probability[i] or 100
      local ratch = c.ratchets[i] or 1

      if c.pattern[i] == 1 then
        -- brightness reflects probability
        local base_bright = is_sel and 10 or 5
        if prob < 100 then
          base_bright = math.max(2, math.floor(base_bright * prob / 100))
        end
        screen.level(is_play and 15 or base_bright)
        screen.rect(x, y + 1, w - 1, 6)
        screen.fill()

        -- ratchet dots (small dots above step)
        if ratch > 1 then
          screen.level(is_sel and 12 or 6)
          for r = 1, ratch - 1 do
            screen.pixel(x + r - 1, y)
            screen.fill()
          end
        end
      elseif is_play then
        screen.level(4)
        screen.rect(x, y + 1, w - 1, 6)
        screen.fill()
      end
    end

    screen.level(is_sel and 12 or 4)
    screen.move(92, y + 7)
    screen.text(rep:get_mode_name(ch))
  end
end

function draw_pitch()
  local rn = NOTE_NAMES[params:get("root")]
  local sn = musicutil.SCALES[params:get("scale")].name
  screen.level(3)
  screen.move(50, 7)
  screen.text_right(rn .. " " .. string.sub(sn, 1, 8))

  for ch = 1, 4 do
    local c = zig.channels[ch]
    local y = 12 + (ch - 1) * 12
    local is_sel = ch == sel_ch

    screen.level(is_sel and 15 or 4)
    screen.move(1, y + 7)
    screen.text(ch)

    local x = 10
    for i = 1, c.chain_len do
      local note = c.chain[i] or 60
      local name = musicutil.note_num_to_name(note, true)
      screen.level((i == c.position and playing) and 15 or (is_sel and 7 or 3))
      screen.move(x, y + 7)
      screen.text(name)
      x = x + screen.text_extents(name) + 2
      if x > 95 then screen.text(".."); break end
    end

    screen.level(is_sel and 10 or 4)
    screen.move(116, y + 7)
    screen.text_right(zig:get_mode_name(ch))
  end

  -- xmod indicator
  if zig.xmod_enabled then
    screen.level(6)
    screen.move(1, 60)
    screen.text("xmod " .. zig.xmod_source .. ">" .. zig.xmod_target)
  end
end

function draw_voice()
  local mode = params:get("ch" .. sel_ch .. "_mode")
  local mode_label = MODE_NAMES[mode]

  screen.level(12)
  screen.move(50, 7)
  screen.text_right("CH" .. sel_ch .. " " .. CH_LABELS[sel_ch])
  screen.level(6)
  screen.move(78, 7)
  screen.text(mode_label)

  if mode == 1 then
    draw_voice_analog()
  else
    draw_voice_spectral()
  end

  -- selected param readout
  local vp = voice_params_for(sel_ch)
  local pname = vp[sel_param]
  if pname then
    local pkey = "ch" .. sel_ch .. "_" .. pname
    screen.level(10)
    screen.move(1, 60)
    if params.lookup[pkey] then
      screen.text(pname:gsub("_", " ") .. ": " .. params:string(pkey))
    end
  end
end

function draw_voice_analog()
  -- oscillator mixer bars
  local osc_names = {"saw", "pls", "sub", "nse"}
  local osc_keys = {"saw", "pulse", "sub", "noise"}
  local bar_y = 13
  local bar_w = 12
  local bar_gap = 4
  local bar_x0 = 4
  for i = 1, 4 do
    local x = bar_x0 + (i - 1) * (bar_w + bar_gap)
    local val = params:get("ch" .. sel_ch .. "_" .. osc_keys[i])
    local bh = math.floor(val * 14)
    screen.level(val > 0.01 and 10 or 2)
    screen.rect(x, bar_y + 14 - bh, bar_w, bh)
    screen.fill()
    screen.level(2)
    screen.rect(x, bar_y, bar_w, 14)
    screen.stroke()
    screen.level(5)
    screen.move(x + 1, bar_y + 18)
    screen.text(osc_names[i])
  end

  -- MoogFF filter curve
  local co = params:get("ch" .. sel_ch .. "_cutoff")
  local r = params:get("ch" .. sel_ch .. "_res")
  local drv = params:get("ch" .. sel_ch .. "_drive")
  local filt_y = 42
  local filt_h = 12

  screen.level(8)
  for x = 4, 124 do
    local f = 40 * ((18000 / 40) ^ ((x - 4) / 120))
    local ratio = f / co
    -- approximate moog response: 4-pole with resonance bump
    local lp_gain = 1 / (1 + ratio ^ 4)
    local res_bump = r * 2 / (1 + ((ratio - 1) / 0.15) ^ 2)
    local gain = math.min(lp_gain + res_bump, 1.4)
    local y = filt_y - math.floor(gain * filt_h)
    if x == 4 then screen.move(x, y) else screen.line(x, y) end
  end
  screen.stroke()

  -- cutoff marker
  local cox = 4 + math.floor(math.log(co / 40) / math.log(18000 / 40) * 120)
  cox = util.clamp(cox, 4, 124)
  screen.level(15)
  screen.pixel(cox, filt_y - filt_h - 1)
  screen.pixel(cox - 1, filt_y - filt_h)
  screen.pixel(cox + 1, filt_y - filt_h)
  screen.fill()

  -- drive indicator
  if drv > 0.1 then
    screen.level(math.floor(util.linlin(0, 2, 3, 12, drv)))
    screen.move(108, filt_y + 4)
    screen.text("drv")
  end
end

function draw_voice_spectral()
  -- partial level bars
  local npart = params:get("ch" .. sel_ch .. "_partials")
  local tlt = params:get("ch" .. sel_ch .. "_tilt")
  local bar_y = 13
  local bar_w = 8
  local bar_gap = 2
  local bar_x0 = 4
  for i = 1, 6 do
    local x = bar_x0 + (i - 1) * (bar_w + bar_gap)
    local amp = 1 / ((i) ^ (tlt * 0.5))
    if i > npart then amp = 0 end
    local bh = math.floor(amp * 14)
    screen.level(i <= npart and 10 or 2)
    screen.rect(x, bar_y + 14 - bh, bar_w, bh)
    screen.fill()
    screen.level(2)
    screen.rect(x, bar_y, bar_w, 14)
    screen.stroke()
  end

  screen.level(5)
  screen.move(bar_x0, bar_y + 18)
  screen.text("partials")

  -- dual filter peaks visualization
  local p1 = params:get("ch" .. sel_ch .. "_peak1")
  local p2 = params:get("ch" .. sel_ch .. "_peak2")
  local r = params:get("ch" .. sel_ch .. "_res")
  local drv = params:get("ch" .. sel_ch .. "_drive")
  local filt_y = 42
  local filt_h = 12

  screen.level(8)
  for x = 4, 124 do
    local f = 40 * ((12000 / 40) ^ ((x - 4) / 120))
    local ratio1 = f / p1
    local ratio2 = f / p2
    local bw = util.linlin(0, 0.95, 0.8, 0.03, r)
    local g1 = 1 / (1 + ((ratio1 - 1) / bw) ^ 2)
    local g2 = 1 / (1 + ((ratio2 - 1) / bw) ^ 2)
    local gain = math.max(g1, g2)
    gain = math.min(gain, 1.4)
    local y = filt_y - math.floor(gain * filt_h)
    if x == 4 then screen.move(x, y) else screen.line(x, y) end
  end
  screen.stroke()

  -- peak markers
  local p1x = 4 + math.floor(math.log(p1 / 40) / math.log(12000 / 40) * 120)
  local p2x = 4 + math.floor(math.log(p2 / 40) / math.log(12000 / 40) * 120)
  p1x = util.clamp(p1x, 4, 124)
  p2x = util.clamp(p2x, 4, 124)
  screen.level(15)
  screen.pixel(p1x, filt_y - filt_h - 1)
  screen.pixel(p1x - 1, filt_y - filt_h)
  screen.pixel(p1x + 1, filt_y - filt_h)
  screen.fill()
  screen.pixel(p2x, filt_y - filt_h - 1)
  screen.pixel(p2x - 1, filt_y - filt_h)
  screen.pixel(p2x + 1, filt_y - filt_h)
  screen.fill()

  -- drive indicator
  if drv > 0.1 then
    screen.level(math.floor(util.linlin(0, 2, 3, 12, drv)))
    screen.move(108, filt_y + 4)
    screen.text("drv")
  end
end

function draw_fx()
  local y = 14
  for i, pkey in ipairs(FX_PARAMS) do
    local is_sel = i == sel_param
    screen.level(is_sel and 15 or 5)
    screen.move(3, y + (i - 1) * 7)
    screen.text(pkey:gsub("_", " "))

    screen.level(is_sel and 12 or 4)
    screen.move(126, y + (i - 1) * 7)
    screen.text_right(params:string(pkey))
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
          -- K3 + tap = cycle probability (100 -> 75 -> 50 -> 25 -> 100)
          local cur = c.probability[x] or 100
          if cur > 75 then c.probability[x] = 75
          elseif cur > 50 then c.probability[x] = 50
          elseif cur > 25 then c.probability[x] = 25
          else c.probability[x] = 100 end
        else
          -- hold for ratchet editing via E3
          grid_held = {ch = ch, step = x, type = "rhythm"}
          -- if quick tap (released before next grid scan), toggle step
        end
      end
      sel_ch = ch; page = 1
    else
      -- release: if still held and no E3 turn happened, toggle step
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
        sel_ch = ch; page = 2
      elseif x == c.chain_len + 1 and c.chain_len < 16 then
        zig:set_chain_length(ch, c.chain_len + 1)
        sel_ch = ch; page = 2
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
        -- dim for low probability
        if prob < 100 then base = math.max(3, math.floor(8 * prob / 100)) end
        -- brighter for ratchets
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
