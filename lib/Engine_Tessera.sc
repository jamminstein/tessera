// Engine_Tessera v7 — Dual Mode: Analog + Spectral
// 4 channels x 2 voices each (8 total, only active mode sounds)
//
// Analog: MoogFF subtractive — 2 detuned saws + pulse + sub + noise
// Spectral: Resynthesizer — 6 partials, dual BPF peaks, spectral freeze
// Global: tape delay w/ halo diffusion, plate reverb

Engine_Tessera : CroneEngine {
  var analogVoices, spectralVoices;
  var channelModes; // 0=analog, 1=spectral
  var channelAmps;
  var delayBus, reverbBus;
  var delaySynth, reverbSynth;

  *new { arg context, doneCallback;
    ^super.new(context, doneCallback);
  }

  alloc {
    delayBus = Bus.audio(context.server, 2);
    reverbBus = Bus.audio(context.server, 2);
    channelModes = Array.fill(4, { 0 });
    channelAmps = Array.fill(4, { 0.7 });

    // ── ANALOG VOICE (MoogFF subtractive) ─────────────
    SynthDef(\tessera_analog, {
      arg out=0, delayOut=0,
          freq=220, amp=0.7, t_gate=0, accent=1,
          atk=0.005, dec=0.5, rel=0.3,
          sawLvl=0.9, pulseLvl=0.0, subLvl=0.2, noiseLvl=0.0,
          detune=0.15, pulseWidth=0.5,
          drive=1.0,
          cutoff=800, res=0.8, envMod=1.0,
          drift=0.2,
          slewTime=0.05,
          pan=0, delaySend=0.25;

      var sig, env, envFilt, portFreq;
      var driftLfo1, driftLfo2;
      var saw1, saw2, pulse, sub, noise;
      var driveGain, cutEnv, resScaled;

      portFreq = Lag.kr(freq, slewTime);

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

      // ── OSCILLATORS ──
      // two detuned saws
      saw1 = Saw.ar(portFreq * (1 + (detune * 0.01) + (driftLfo1 * 0.004)));
      saw2 = Saw.ar(portFreq * (1 - (detune * 0.01) + (driftLfo2 * 0.004)));
      // pulse
      pulse = Pulse.ar(portFreq * (1 + (driftLfo1 * 0.002)), pulseWidth);
      // sub sine one octave down
      sub = SinOsc.ar(portFreq * 0.5);
      // filtered pink noise
      noise = LPF.ar(PinkNoise.ar, portFreq * 4);

      sig = (saw1 + saw2) * 0.5 * sawLvl;
      sig = sig + (pulse * pulseLvl);
      sig = sig + (sub * subLvl);
      sig = sig + (noise * noiseLvl);

      // ── PRE-FILTER SATURATION ──
      driveGain = 1 + (drive * 3);
      sig = (sig * driveGain).tanh * (1 / driveGain.sqrt);

      // ── MoogFF LADDER FILTER ──
      cutEnv = cutoff * (1 + (envFilt * envMod * 4) + (driftLfo1 * 0.03));
      cutEnv = cutEnv.clip(40, 18000);
      resScaled = res.linlin(0, 1, 0, 3.5);

      sig = MoogFF.ar(sig, cutEnv, resScaled);

      // ── OUTPUT — boost + Pan2 for proper stereo ──
      sig = sig * 2.5;
      sig = sig * env * amp;
      sig = Pan2.ar(sig, pan + (driftLfo1 * 0.06));

      Out.ar(out, sig);
      Out.ar(delayOut, sig * delaySend);
    }).add;

    // ── SPECTRAL VOICE (Resynthesizer) ────────────────
    SynthDef(\tessera_spectral, {
      arg out=0, delayOut=0,
          freq=220, amp=0.7, t_gate=0, accent=1,
          atk=0.005, dec=0.5, rel=0.3,
          partials=6, tilt=1.0,
          spread=0.3, t_freeze=0,
          drive=0.5,
          peak1=800, peak2=2400, peakSpread=0,
          res=0.5, envMod=0.5,
          drift=0.2,
          slewTime=0.05,
          pan=0, delaySend=0.25;

      var sig, env, envFilt, portFreq;
      var driftLfo1, driftLfo2, peakLfo1, peakLfo2;
      var peak1Freq, peak2Freq, filt1, filt2;
      var partialSig, partialFreq, partialAmp, partialDrift;
      var partialSaw, partialSin, partialMix;
      var driveGain, freezeFlag;
      var cutEnv1, cutEnv2, resScaled;
      var stereoSig;

      portFreq = Lag.kr(freq, slewTime);

      // freeze latch: holds freq when freeze engaged
      freezeFlag = Latch.kr(portFreq, t_freeze + Impulse.kr(0));
      portFreq = Select.kr(t_freeze > 0, [portFreq, freezeFlag]);

      // drift LFOs
      driftLfo1 = LFNoise2.kr(0.25) * drift;
      driftLfo2 = LFNoise2.kr(0.31) * drift;

      // filter peak LFOs
      peakLfo1 = LFNoise2.kr(0.13).range(-0.15, 0.15);
      peakLfo2 = LFNoise2.kr(0.09).range(-0.15, 0.15);

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

      // ── SPECTRAL OSCILLATOR ──
      sig = Mix.fill(6, { arg i;
        partialAmp = (1 / ((i + 1) ** (tilt * 0.5))).clip(0.05, 1.0);
        partialAmp = partialAmp * (i < partials).asInteger;
        partialDrift = LFNoise2.kr(0.2 + (i * 0.07)) * spread * 0.01;
        partialFreq = portFreq * (i + 1) * (1 + partialDrift + (driftLfo1 * 0.003));
        partialSaw = Saw.ar(partialFreq * (1 + (LFNoise2.kr(0.4 + (i * 0.1)) * 0.003)));
        partialSin = SinOsc.ar(partialFreq);
        partialMix = (partialSaw * 0.6) + (partialSin * 0.4);
        partialMix = (partialMix * 1.5).tanh;
        partialMix * partialAmp;
      });

      sig = sig * 0.35;

      // fundamental body
      sig = sig + (Saw.ar(portFreq * (1 + (driftLfo1 * 0.004))) * 0.4);
      sig = sig + (Saw.ar(portFreq * (1 - (driftLfo2 * 0.004))) * 0.4);

      // ── PRE-FILTER SATURATION ──
      driveGain = 1 + (drive * 3);
      sig = (sig * driveGain).tanh * (1 / driveGain.sqrt);

      // ── DUAL RESONANT FILTER (QPAS-inspired) ──
      peak1Freq = peak1 * (1 + peakLfo1) * (2 ** (peakSpread * -0.5));
      peak2Freq = peak2 * (1 + peakLfo2) * (2 ** (peakSpread * 0.5));

      cutEnv1 = peak1Freq * (1 + (envFilt * envMod * 4) + (driftLfo1 * 0.03));
      cutEnv2 = peak2Freq * (1 + (envFilt * envMod * 3) + (driftLfo2 * 0.03));
      cutEnv1 = cutEnv1.clip(40, 18000);
      cutEnv2 = cutEnv2.clip(40, 18000);

      resScaled = res.linlin(0, 1, 0.8, 0.03);

      filt1 = BPF.ar(sig, cutEnv1, resScaled);
      filt2 = BPF.ar(sig, cutEnv2, resScaled);

      // boost BPF output (BPF is very quiet by nature)
      filt1 = filt1 * (2 + (res * 10));
      filt2 = filt2 * (2 + (res * 10));

      // stereo spread: peak1 left, peak2 right
      stereoSig = [
        (filt1 * 0.7) + (filt2 * 0.3),
        (filt1 * 0.3) + (filt2 * 0.7)
      ];

      // ── POST-FILTER SATURATION ──
      stereoSig = (stereoSig * 1.5).tanh;

      // ── OUTPUT — boost + Balance2 for stereo ──
      stereoSig = stereoSig * 2.0;
      stereoSig = stereoSig * env * amp;
      stereoSig = Balance2.ar(stereoSig[0], stereoSig[1], pan + (driftLfo1 * 0.06));

      Out.ar(out, stereoSig);
      Out.ar(delayOut, stereoSig * delaySend);
    }).add;

    // ── TAPE DELAY (Mimeophon-inspired) ─────────────
    SynthDef(\tessera_delay, {
      arg in=0, out=0,
          time=0.375, feedback=0.45, color=3500,
          mix=0.3, halo=0.25;
      var sig, delayed, haloSig;

      sig = In.ar(in, 2);

      delayed = CombC.ar(sig, 2.0, time.clip(0.01, 2.0), feedback * 6);
      delayed = (delayed * 1.3).tanh * 0.8;
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

    // instantiate 4 analog + 4 spectral voices
    // IMPORTANT: start with amp=0, mode command sets correct voice live
    analogVoices = Array.fill(4, {
      Synth(\tessera_analog, [
        \out, reverbBus, \delayOut, delayBus, \amp, 0
      ], context.xg);
    });

    spectralVoices = Array.fill(4, {
      Synth(\tessera_spectral, [
        \out, reverbBus, \delayOut, delayBus, \amp, 0
      ], context.xg);
    });

    delaySynth = Synth.after(spectralVoices.last, \tessera_delay, [
      \in, delayBus, \out, reverbBus
    ]);

    reverbSynth = Synth.after(delaySynth, \tessera_reverb, [
      \in, reverbBus, \out, context.out_b
    ]);

    // ── MODE COMMAND ──────────────────────────────────
    // mode(index, value): 0=analog, 1=spectral
    this.addCommand("mode", "ii", { |msg|
      var idx, val, ampVal;
      idx = msg[1].asInteger;
      val = msg[2].asInteger;
      ampVal = channelAmps[idx];
      channelModes[idx] = val;
      if(val == 0, {
        analogVoices[idx].set(\amp, ampVal);
        spectralVoices[idx].set(\amp, 0);
      }, {
        analogVoices[idx].set(\amp, 0);
        spectralVoices[idx].set(\amp, ampVal);
      });
    });

    // ── SHARED VOICE COMMANDS (sent to BOTH) ─────────
    this.addCommand("hz", "if", { |msg|
      var idx; idx = msg[1].asInteger;
      analogVoices[idx].set(\freq, msg[2]);
      spectralVoices[idx].set(\freq, msg[2]);
    });
    this.addCommand("gate", "ii", { |msg|
      var idx; idx = msg[1].asInteger;
      analogVoices[idx].set(\t_gate, msg[2]);
      spectralVoices[idx].set(\t_gate, msg[2]);
    });
    this.addCommand("accent", "if", { |msg|
      var idx; idx = msg[1].asInteger;
      analogVoices[idx].set(\accent, msg[2]);
      spectralVoices[idx].set(\accent, msg[2]);
    });
    this.addCommand("slew", "if", { |msg|
      var idx; idx = msg[1].asInteger;
      analogVoices[idx].set(\slewTime, msg[2]);
      spectralVoices[idx].set(\slewTime, msg[2]);
    });
    this.addCommand("pan", "if", { |msg|
      var idx; idx = msg[1].asInteger;
      analogVoices[idx].set(\pan, msg[2]);
      spectralVoices[idx].set(\pan, msg[2]);
    });
    this.addCommand("delay_send", "if", { |msg|
      var idx; idx = msg[1].asInteger;
      analogVoices[idx].set(\delaySend, msg[2]);
      spectralVoices[idx].set(\delaySend, msg[2]);
    });
    this.addCommand("amp", "if", { |msg|
      var idx, val;
      idx = msg[1].asInteger;
      val = msg[2];
      channelAmps[idx] = val;
      if(channelModes[idx] == 0, {
        analogVoices[idx].set(\amp, val);
        spectralVoices[idx].set(\amp, 0);
      }, {
        analogVoices[idx].set(\amp, 0);
        spectralVoices[idx].set(\amp, val);
      });
    });
    this.addCommand("atk", "if", { |msg|
      var idx; idx = msg[1].asInteger;
      analogVoices[idx].set(\atk, msg[2]);
      spectralVoices[idx].set(\atk, msg[2]);
    });
    this.addCommand("dec", "if", { |msg|
      var idx; idx = msg[1].asInteger;
      analogVoices[idx].set(\dec, msg[2]);
      spectralVoices[idx].set(\dec, msg[2]);
    });
    this.addCommand("rel", "if", { |msg|
      var idx; idx = msg[1].asInteger;
      analogVoices[idx].set(\rel, msg[2]);
      spectralVoices[idx].set(\rel, msg[2]);
    });
    this.addCommand("drive", "if", { |msg|
      var idx; idx = msg[1].asInteger;
      analogVoices[idx].set(\drive, msg[2]);
      spectralVoices[idx].set(\drive, msg[2]);
    });
    this.addCommand("drift", "if", { |msg|
      var idx; idx = msg[1].asInteger;
      analogVoices[idx].set(\drift, msg[2]);
      spectralVoices[idx].set(\drift, msg[2]);
    });
    this.addCommand("env_mod", "if", { |msg|
      var idx; idx = msg[1].asInteger;
      analogVoices[idx].set(\envMod, msg[2]);
      spectralVoices[idx].set(\envMod, msg[2]);
    });
    this.addCommand("res", "if", { |msg|
      var idx; idx = msg[1].asInteger;
      analogVoices[idx].set(\res, msg[2]);
      spectralVoices[idx].set(\res, msg[2]);
    });

    // ── ANALOG-ONLY COMMANDS ─────────────────────────
    this.addCommand("saw",    "if", { |msg| analogVoices[msg[1].asInteger].set(\sawLvl, msg[2]) });
    this.addCommand("pulse",  "if", { |msg| analogVoices[msg[1].asInteger].set(\pulseLvl, msg[2]) });
    this.addCommand("sub",    "if", { |msg| analogVoices[msg[1].asInteger].set(\subLvl, msg[2]) });
    this.addCommand("noise",  "if", { |msg| analogVoices[msg[1].asInteger].set(\noiseLvl, msg[2]) });
    this.addCommand("detune", "if", { |msg| analogVoices[msg[1].asInteger].set(\detune, msg[2]) });
    this.addCommand("pw",     "if", { |msg| analogVoices[msg[1].asInteger].set(\pulseWidth, msg[2]) });
    this.addCommand("cutoff", "if", { |msg| analogVoices[msg[1].asInteger].set(\cutoff, msg[2]) });

    // ── SPECTRAL-ONLY COMMANDS ───────────────────────
    this.addCommand("partials",    "if", { |msg| spectralVoices[msg[1].asInteger].set(\partials, msg[2]) });
    this.addCommand("tilt",        "if", { |msg| spectralVoices[msg[1].asInteger].set(\tilt, msg[2]) });
    this.addCommand("spread",      "if", { |msg| spectralVoices[msg[1].asInteger].set(\spread, msg[2]) });
    this.addCommand("freeze",      "ii", { |msg| spectralVoices[msg[1].asInteger].set(\t_freeze, msg[2]) });
    this.addCommand("peak1",       "if", { |msg| spectralVoices[msg[1].asInteger].set(\peak1, msg[2]) });
    this.addCommand("peak2",       "if", { |msg| spectralVoices[msg[1].asInteger].set(\peak2, msg[2]) });
    this.addCommand("peak_spread", "if", { |msg| spectralVoices[msg[1].asInteger].set(\peakSpread, msg[2]) });

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
    analogVoices.do(_.free);
    spectralVoices.do(_.free);
    delaySynth.free;
    reverbSynth.free;
    delayBus.free;
    reverbBus.free;
  }
}
