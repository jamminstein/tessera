-- robot profile: tessera
-- algorithmic spectral mosaic
-- engine: Tessera (additive spectral resynthesis)
--
-- musical strategy:
-- tessera has three rich layers: rhythm (repetitor), pitch (ziggurat),
-- and spectrum (spectraphon-inspired additive partials + mimeophon halo).
-- robot should sculpt the spectral layer as its primary canvas —
-- sweeping filters, morphing tilt/spread, toggling freeze for dramatic
-- moments. delay/halo are the spatial expanders. rhythm and pitch params
-- are structural — robot should shift those rarely for maximum impact.
-- the "freeze" moments are the secret weapon: capturing a spectral
-- fingerprint and holding it while everything else moves around it.

return {
  name = "tessera",
  description = "spectral mosaic — rhythm/pitch/spectrum layers",
  phrase_len = 16,

  -- SPIRITUAL for spectral meditation, AMBIENT for frozen halo textures,
  -- APHEX for micro-rhythmic spectral glitch, JAZZ for harmonic drift,
  -- MINIMALIST for slow spectral evolution
  recommended_modes = {2, 4, 3, 5, 6},

  never_touch = {
    "clock_tempo",
    "clock_source",
    "midi_device",
    "midi_ch_1", "midi_ch_2", "midi_ch_3", "midi_ch_4",
    "midi_enabled",
    "root",      -- human chooses the key
    "scale",     -- human chooses the scale
    "division",  -- human chooses the pulse
    "bpm",
  },

  params = {
    -----------------------------------------------------------
    -- TIMBRAL: the spectral layer — robot's primary canvas
    -----------------------------------------------------------

    -- channel 1 (arp voice)
    ch1_partials =    { group = "timbral",  weight = 0.8,  sensitivity = 0.6, direction = "both" },
    ch1_tilt =        { group = "timbral",  weight = 0.9,  sensitivity = 0.7, direction = "both" },
    ch1_spread =      { group = "timbral",  weight = 0.85, sensitivity = 0.5, direction = "both" },
    ch1_filter =      { group = "timbral",  weight = 1.0,  sensitivity = 0.8, direction = "both" },
    ch1_filter_q =    { group = "timbral",  weight = 0.7,  sensitivity = 0.5, direction = "both" },
    ch1_amp =         { group = "timbral",  weight = 0.3,  sensitivity = 0.3, direction = "both" },
    ch1_decay =       { group = "rhythmic", weight = 0.6,  sensitivity = 0.5, direction = "both" },
    ch1_delay_send =  { group = "timbral",  weight = 0.6,  sensitivity = 0.4, direction = "both" },
    ch1_pan =         { group = "timbral",  weight = 0.2,  sensitivity = 0.3, direction = "both" },

    -- channel 2 (bass walk)
    ch2_partials =    { group = "timbral",  weight = 0.7,  sensitivity = 0.5, direction = "both" },
    ch2_tilt =        { group = "timbral",  weight = 0.8,  sensitivity = 0.6, direction = "both" },
    ch2_spread =      { group = "timbral",  weight = 0.5,  sensitivity = 0.3, direction = "up",
                        range_hi = 0.04 }, -- keep bass focused
    ch2_filter =      { group = "timbral",  weight = 0.9,  sensitivity = 0.7, direction = "both" },
    ch2_filter_q =    { group = "timbral",  weight = 0.6,  sensitivity = 0.4, direction = "both" },
    ch2_amp =         { group = "timbral",  weight = 0.3,  sensitivity = 0.2, direction = "both" },
    ch2_decay =       { group = "rhythmic", weight = 0.5,  sensitivity = 0.4, direction = "both" },
    ch2_delay_send =  { group = "timbral",  weight = 0.4,  sensitivity = 0.3, direction = "both",
                        range_hi = 0.5 }, -- don't drown bass in delay

    -- channel 3 (sub pulse)
    ch3_partials =    { group = "timbral",  weight = 0.5,  sensitivity = 0.3, direction = "down",
                        range_lo = 2 }, -- keep sub simple
    ch3_tilt =        { group = "timbral",  weight = 0.6,  sensitivity = 0.4, direction = "up" },
    ch3_filter =      { group = "timbral",  weight = 0.7,  sensitivity = 0.5, direction = "both",
                        range_lo = 200, range_hi = 4000 },
    ch3_decay =       { group = "rhythmic", weight = 0.6,  sensitivity = 0.5, direction = "both" },
    ch3_amp =         { group = "timbral",  weight = 0.3,  sensitivity = 0.2, direction = "both" },
    ch3_delay_send =  { group = "timbral",  weight = 0.2,  sensitivity = 0.15, direction = "both",
                        range_hi = 0.3 }, -- sub stays dry

    -- channel 4 (melody, drunk walk)
    ch4_partials =    { group = "timbral",  weight = 0.85, sensitivity = 0.7, direction = "both" },
    ch4_tilt =        { group = "timbral",  weight = 0.9,  sensitivity = 0.7, direction = "both" },
    ch4_spread =      { group = "timbral",  weight = 0.9,  sensitivity = 0.6, direction = "both" },
    ch4_filter =      { group = "timbral",  weight = 1.0,  sensitivity = 0.8, direction = "both" },
    ch4_filter_q =    { group = "timbral",  weight = 0.7,  sensitivity = 0.5, direction = "both" },
    ch4_amp =         { group = "timbral",  weight = 0.3,  sensitivity = 0.3, direction = "both" },
    ch4_decay =       { group = "rhythmic", weight = 0.65, sensitivity = 0.5, direction = "both" },
    ch4_delay_send =  { group = "timbral",  weight = 0.7,  sensitivity = 0.5, direction = "both" },
    ch4_pan =         { group = "timbral",  weight = 0.3,  sensitivity = 0.3, direction = "both" },

    -----------------------------------------------------------
    -- SPATIAL: delay and reverb — the room
    -----------------------------------------------------------
    delay_time =      { group = "timbral",  weight = 0.7,  sensitivity = 0.5, direction = "both" },
    delay_feedback =  { group = "timbral",  weight = 0.6,  sensitivity = 0.4, direction = "both",
                        range_hi = 0.85 }, -- don't self-oscillate
    delay_color =     { group = "timbral",  weight = 0.8,  sensitivity = 0.6, direction = "both" },
    delay_mix =       { group = "timbral",  weight = 0.6,  sensitivity = 0.4, direction = "both" },
    halo =            { group = "timbral",  weight = 0.85, sensitivity = 0.6, direction = "both" },
    reverb_mix =      { group = "timbral",  weight = 0.5,  sensitivity = 0.35, direction = "both" },
    reverb_size =     { group = "timbral",  weight = 0.5,  sensitivity = 0.3, direction = "both" },
  },
}
