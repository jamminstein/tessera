// Engine_Tessera v8 — Unified Voice: Single SynthDef, 4 voices
// voiceMode crossfade: 0.0=analog (MoogFF), 1.0=spectral (dual BPF)
// CPU fix: 4 voices instead of 8, ~80 UGens instead of ~160
//
// Global: tape delay w/ halo diffusion, plate reverb

Engine_Tessera : CroneEngine {
  var voices;
  var channelAmps;
  var delayBus, reverbBus;
  var delaySynth, reverbSynth;

  *new { arg context, doneCallback;
    ^super.new(context, doneCallback);
  }

  alloc {
    delayBus = Bus.audio(context.server, 2);
    reverbBus = Bus.audio(context.server, 2);
    channelAmps = Array.fill(4, { 0.7 });

    // ── UNIFIED VOICE (analog + spectral crossfade) ──────
    SynthDef(\tessera_voice, {
      arg out=0, delayOut=0,
          freq=220, amp=0.7, t_gate=0, accent=1,
          atk=0.005, dec=0.5, rel=0.3,
          voiceMode=0.0,
          // analog osc
          sawLvl=0.9, pulseLvl=0.0, subLvl=0.2, noiseLvl=0.0,
          detune=0.15, pulseWidth=0.5,
          // spectral osc
          partials=4, tilt=1.0, spread=0.3, t_freeze=0,
          // shared
          drive=1.0,
          cutoff=800, res=0.8, envMod=1.0,
          peak1=800, peak2=2400, peakSpread=0,
          drift=0.2,
          slewTime=0.05,
          pan=0, delaySend=0.25;

      var sig, env, envFilt, portFreq;
      var driftLfo1, driftLfo2;
      var saw1, saw2, sub;
      var analogUpper, spectralUpper, upperSig;
      var pulse, noise;
      var partialSig, partialFreq, partialAmp, partialDrift;
      var partialSaw, partialSin, partialMix;
      var driveGain;
      var analogFilt, spectralFilt, filtSig;
      var cutEnv, resScaled;
      var peakLfo1, peakLfo2, peak1Freq, peak2Freq;
      var cutEnv1, cutEnv2, resScaledBPF;
      var filt1, filt2, stereoSpec;
      var freezeFlag;
      var vm;

      vm = voiceMode.clip(0, 1);
      portFreq = Lag.kr(freq, slewTime);

      // freeze latch for spectral mode
      freezeFlag = Latch.kr(portFreq, t_freeze + Impulse.kr(0));
      portFreq = Select.kr(t_freeze > 0, [portFreq, freezeFlag]);

      // drift LFOs
      driftLfo1 = LFNoise2.kr(0.25) * drift;
      driftLfo2 = LFNoise2.kr(0.31) * drift;

      // amplitude envelope
      env = EnvGen.kr(
        Env.perc(atk, dec + rel),
        t_gate
      ) * accent;

      // filter envelope
      envFilt = EnvGen.kr(
        Env.perc(atk * 0.3, dec * 0.5),
        t_gate
      );

      // ── SHARED OSCILLATORS (both modes use these) ──
      saw1 = Saw.ar(portFreq * (1 + (detune * 0.01) + (driftLfo1 * 0.004)));
      saw2 = Saw.ar(portFreq * (1 - (detune * 0.01) + (driftLfo2 * 0.004)));
      sub = SinOsc.ar(portFreq * 0.5);

      // ── ANALOG UPPER: pulse + filtered noise ──
      pulse = Pulse.ar(portFreq * (1 + (driftLfo1 * 0.002)), pulseWidth);
      noise = LPF.ar(PinkNoise.ar, portFreq * 4);
      analogUpper = (pulse * pulseLvl) + (noise * noiseLvl);

      // ── SPECTRAL UPPER: 4 partials (saw+sine, individually saturated) ──
      spectralUpper = Mix.fill(4, { arg i;
        partialAmp = (1 / ((i + 1) ** (tilt * 0.5))).clip(0.05, 1.0);
        partialAmp = partialAmp * (i < partials).asInteger;
        partialDrift = LFNoise2.kr(0.2 + (i * 0.07)) * spread * 0.01;
        partialFreq = portFreq * (i + 1) * (1 + partialDrift + (driftLfo1 * 0.003));
        partialSaw = Saw.ar(partialFreq * (1 + (LFNoise2.kr(0.4 + (i * 0.1)) * 0.003)));
        partialSin = SinOsc.ar(partialFreq);
        partialMix = (partialSaw * 0.6) + (partialSin * 0.4);
        partialMix = (partialMix * 1.5).tanh;
        partialMix * partialAmp;
      }) * 0.35;

      // ── CROSSFADE UPPER HARMONICS ──
      upperSig = (analogUpper * (1 - vm)) + (spectralUpper * vm);

      // ── MIX ALL OSCILLATORS ──
      sig = ((saw1 + saw2) * 0.5 * sawLvl) + (sub * subLvl) + upperSig;

      // ── PRE-FILTER SATURATION ──
      driveGain = 1 + (drive * 3);
      sig = (sig * driveGain).tanh * (1 / driveGain.sqrt);

      // ── FILTER SECTION: mode-selectable ──

      // analog: MoogFF ladder filter
      cutEnv = cutoff * (1 + (envFilt * envMod * 4) + (driftLfo1 * 0.03));
      cutEnv = cutEnv.clip(40, 18000);
      resScaled = res.linlin(0, 1, 0, 2.8);
      analogFilt = MoogFF.ar(sig, cutEnv, resScaled);
      analogFilt = (analogFilt * 3.0).tanh; // boost THEN limit — loud but safe
      analogFilt = Pan2.ar(analogFilt, pan + (driftLfo1 * 0.06));

      // spectral: dual BPF peaks (QPAS-style)
      peakLfo1 = LFNoise2.kr(0.13).range(-0.12, 0.12);
      peakLfo2 = LFNoise2.kr(0.09).range(-0.12, 0.12);
      peak1Freq = peak1 * (1 + peakLfo1) * (2 ** (peakSpread * -0.5));
      peak2Freq = peak2 * (1 + peakLfo2) * (2 ** (peakSpread * 0.5));
      cutEnv1 = peak1Freq * (1 + (envFilt * envMod * 3.5) + (driftLfo1 * 0.03));
      cutEnv2 = peak2Freq * (1 + (envFilt * envMod * 2.5) + (driftLfo2 * 0.03));
      cutEnv1 = cutEnv1.clip(60, 16000);
      cutEnv2 = cutEnv2.clip(60, 16000);
      resScaledBPF = res.linlin(0, 1, 0.5, 0.06);
      filt1 = BPF.ar(sig, cutEnv1, resScaledBPF) * (2 + (res * 7));
      filt2 = BPF.ar(sig, cutEnv2, resScaledBPF) * (2 + (res * 7));
      stereoSpec = [
        (filt1 * 0.7) + (filt2 * 0.3),
        (filt1 * 0.3) + (filt2 * 0.7)
      ];
      stereoSpec = (stereoSpec * 2.0).tanh; // boost THEN limit
      spectralFilt = Balance2.ar(stereoSpec[0], stereoSpec[1], pan + (driftLfo1 * 0.06));

      // ── CROSSFADE FILTER OUTPUTS ──
      filtSig = (analogFilt * (1 - vm)) + (spectralFilt * vm);

      // ── OUTPUT ──
      filtSig = filtSig * env * amp;

      Out.ar(out, filtSig);
      Out.ar(delayOut, filtSig * delaySend);
    }).add;

    // ── TAPE DELAY (Mimeophon-inspired) ─────────────
    SynthDef(\tessera_delay, {
      arg in=0, out=0,
          time=0.375, feedback=0.45, color=3500,
          mix=0.3, halo=0.25;
      var sig, delayed, haloSig;

      sig = In.ar(in, 2);

      delayed = CombC.ar(sig, 2.0, time.clip(0.01, 2.0), feedback * 4);
      delayed = delayed.tanh * 0.7; // gentler saturation
      delayed = LPF.ar(delayed, color.clip(200, 12000));
      delayed = HPF.ar(delayed, 60);

      haloSig = delayed;
      4.do { arg i;
        haloSig = AllpassC.ar(haloSig, 0.15,
          LFNoise1.kr(0.1 + (i * 0.04)).range(0.01, 0.05 + (i * 0.015)),
          halo * 2.5);
      };

      Out.ar(out, haloSig * mix);
    }).add;

    // ── REVERB ──────────────────────────────────────
    SynthDef(\tessera_reverb, {
      arg in=0, out=0, mix=0.2, size=0.8, damp=0.4;
      var sig, dry, wet;

      sig = In.ar(in, 2);
      dry = sig;

      wet = DelayN.ar(sig, 0.05, 0.02);
      wet = FreeVerb2.ar(wet[0], wet[1], 1, size, damp);
      wet = HPF.ar(wet, 100);
      wet = LPF.ar(wet, 9000);

      Out.ar(out, dry + (wet * mix));
    }).add;

    context.server.sync;

    // instantiate 4 unified voices (was 8 — half the CPU!)
    voices = Array.fill(4, {
      Synth(\tessera_voice, [
        \out, reverbBus, \delayOut, delayBus, \amp, 0
      ], context.xg);
    });

    delaySynth = Synth.after(voices.last, \tessera_delay, [
      \in, delayBus, \out, reverbBus
    ]);

    reverbSynth = Synth.after(delaySynth, \tessera_reverb, [
      \in, reverbBus, \out, context.out_b
    ]);

    // ── MODE COMMAND ──────────────────────────────────
    // mode(index, value): 0.0=analog, 1.0=spectral (continuous crossfade)
    this.addCommand("mode", "if", { |msg|
      var idx, val;
      idx = msg[1].asInteger;
      val = msg[2].asFloat;
      voices[idx].set(\voiceMode, val);
    });

    // ── VOICE COMMANDS (single voice array) ──────────
    this.addCommand("hz", "if", { |msg|
      voices[msg[1].asInteger].set(\freq, msg[2]);
    });
    this.addCommand("gate", "ii", { |msg|
      voices[msg[1].asInteger].set(\t_gate, msg[2]);
    });
    this.addCommand("accent", "if", { |msg|
      voices[msg[1].asInteger].set(\accent, msg[2]);
    });
    this.addCommand("slew", "if", { |msg|
      voices[msg[1].asInteger].set(\slewTime, msg[2]);
    });
    this.addCommand("pan", "if", { |msg|
      voices[msg[1].asInteger].set(\pan, msg[2]);
    });
    this.addCommand("delay_send", "if", { |msg|
      voices[msg[1].asInteger].set(\delaySend, msg[2]);
    });
    this.addCommand("amp", "if", { |msg|
      var idx, val;
      idx = msg[1].asInteger;
      val = msg[2];
      channelAmps[idx] = val;
      voices[idx].set(\amp, val);
    });
    this.addCommand("atk", "if", { |msg|
      voices[msg[1].asInteger].set(\atk, msg[2]);
    });
    this.addCommand("dec", "if", { |msg|
      voices[msg[1].asInteger].set(\dec, msg[2]);
    });
    this.addCommand("rel", "if", { |msg|
      voices[msg[1].asInteger].set(\rel, msg[2]);
    });
    this.addCommand("drive", "if", { |msg|
      voices[msg[1].asInteger].set(\drive, msg[2]);
    });
    this.addCommand("drift", "if", { |msg|
      voices[msg[1].asInteger].set(\drift, msg[2]);
    });
    this.addCommand("env_mod", "if", { |msg|
      voices[msg[1].asInteger].set(\envMod, msg[2]);
    });
    this.addCommand("res", "if", { |msg|
      voices[msg[1].asInteger].set(\res, msg[2]);
    });

    // ── ANALOG-ORIENTED COMMANDS ──────────────────────
    this.addCommand("saw",    "if", { |msg| voices[msg[1].asInteger].set(\sawLvl, msg[2]) });
    this.addCommand("pulse",  "if", { |msg| voices[msg[1].asInteger].set(\pulseLvl, msg[2]) });
    this.addCommand("sub",    "if", { |msg| voices[msg[1].asInteger].set(\subLvl, msg[2]) });
    this.addCommand("noise",  "if", { |msg| voices[msg[1].asInteger].set(\noiseLvl, msg[2]) });
    this.addCommand("detune", "if", { |msg| voices[msg[1].asInteger].set(\detune, msg[2]) });
    this.addCommand("pw",     "if", { |msg| voices[msg[1].asInteger].set(\pulseWidth, msg[2]) });
    this.addCommand("cutoff", "if", { |msg| voices[msg[1].asInteger].set(\cutoff, msg[2]) });

    // ── SPECTRAL-ORIENTED COMMANDS ────────────────────
    this.addCommand("partials",    "if", { |msg| voices[msg[1].asInteger].set(\partials, msg[2]) });
    this.addCommand("tilt",        "if", { |msg| voices[msg[1].asInteger].set(\tilt, msg[2]) });
    this.addCommand("spread",      "if", { |msg| voices[msg[1].asInteger].set(\spread, msg[2]) });
    this.addCommand("freeze",      "ii", { |msg| voices[msg[1].asInteger].set(\t_freeze, msg[2]) });
    this.addCommand("peak1",       "if", { |msg| voices[msg[1].asInteger].set(\peak1, msg[2]) });
    this.addCommand("peak2",       "if", { |msg| voices[msg[1].asInteger].set(\peak2, msg[2]) });
    this.addCommand("peak_spread", "if", { |msg| voices[msg[1].asInteger].set(\peakSpread, msg[2]) });

    // ── FX COMMANDS ─────────────────────────────────
    this.addCommand("delay_time",     "f", { |msg| delaySynth.set(\time, msg[1]) });
    this.addCommand("delay_feedback", "f", { |msg| delaySynth.set(\feedback, msg[1]) });
    this.addCommand("delay_color",    "f", { |msg| delaySynth.set(\color, msg[1]) });
    this.addCommand("delay_mix",      "f", { |msg| delaySynth.set(\mix, msg[1]) });
    this.addCommand("halo",           "f", { |msg| delaySynth.set(\halo, msg[1]) });
    this.addCommand("reverb_mix",     "f", { |msg| reverbSynth.set(\mix, msg[1]) });
    this.addCommand("reverb_size",    "f", { |msg| reverbSynth.set(\size, msg[1]) });
    this.addCommand("reverb_damp",    "f", { |msg| reverbSynth.set(\damp, msg[1]) });
  }

  free {
    voices.do(_.free);
    delaySynth.free;
    reverbSynth.free;
    delayBus.free;
    reverbBus.free;
  }
}
