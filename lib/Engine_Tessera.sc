// Engine_Tessera
// Spectral resynthesis engine — 4 voices
//
// Each voice: selectable waveform (sine/saw/pulse/noise-band additive),
// FM between partials, wavefolder, sub oscillator, noise layer,
// dual resonant filter (QPAS-inspired), proper ADSR
// Global: spectral delay w/ halo, resonant reverb

Engine_Tessera : CroneEngine {
  var voices;
  var delayBus, reverbBus;
  var delaySynth, reverbSynth;

  *new { arg context, doneCallback;
    ^super.new(context, doneCallback);
  }

  alloc {
    delayBus = Bus.audio(context.server, 2);
    reverbBus = Bus.audio(context.server, 2);

    // ── voice ────────────────────────────────────
    SynthDef(\tessera_voice, {
      arg out=0, delayOut=0,
          freq=220, amp=0.3, t_gate=0, accent=1,
          // envelope
          atk=0.003, dec=0.4, sus=0.0, rel=0.3,
          // timbre
          waveform=0,  // 0=sine 1=saw 2=pulse 3=noise-band
          partials=8, tilt=0.5, spread=0.008,
          fmDepth=0, fmRatio=1.5,
          fold=0, // wavefolder amount 0-5
          subAmp=0, subOct=1, // sub osc: 0=off, oct 1 or 2
          noiseAmp=0, noiseBW=200, // noise band layer
          // filter
          filterFreq=2000, filterQ=0.4,
          filterType=0, // 0=lpf 1=bpf 2=hpf
          filterEnv=0,  // envelope->filter mod depth (-1 to 1)
          // modulation
          freeze=0, smearRate=0.5,
          slewTime=0.05, pan=0, delaySend=0.3;

      var sig, env, envFilter, portFreq, sub, noise;

      portFreq = Lag.kr(freq, slewTime);

      // ADSR triggered by t_gate
      env = EnvGen.kr(
        Env.new([0, 1, sus.max(0.001), 0], [atk, dec, rel], [\lin, -3, -4]),
        t_gate
      ) * accent;

      // filter envelope follower
      envFilter = EnvGen.kr(
        Env.new([0, 1, 0.3, 0], [atk, dec * 0.5, rel], [\lin, -2, -4]),
        t_gate
      );

      // ── additive core ──────────────────────────
      sig = Mix.fill(16, { |i|
        var n = i + 1;
        var pFreq = portFreq * n;
        var pAmp = (1 / (n ** (1 + tilt.max(0)))) * (n <= partials);
        var drift = LFNoise1.kr(smearRate + (i * 0.07)) * spread * pFreq;
        drift = drift * (1 - freeze);

        // FM between partials
        var fmMod = SinOsc.ar(pFreq * fmRatio) * fmDepth * pFreq;

        // waveform selection per partial
        var osc = Select.ar(waveform, [
          SinOsc.ar(pFreq + drift + fmMod),                      // 0: sine
          LFSaw.ar(pFreq + drift + fmMod),                       // 1: saw
          Pulse.ar(pFreq + drift + fmMod, 0.5 - (i * 0.02)),    // 2: pulse (varying width)
          BPF.ar(WhiteNoise.ar, pFreq + drift, 0.02) * 20        // 3: noise bands
        ]);

        osc * pAmp;
      });

      // ── wavefolder (Buchla / Make Noise style) ─
      sig = Select.ar(fold > 0.01, [
        sig,
        (sig * (1 + (fold * 4))).fold2(1) * (1 / (1 + fold))
      ]);

      // ── sub oscillator ─────────────────────────
      sub = SinOsc.ar(portFreq / (2 ** subOct)) * subAmp;
      sig = sig + sub;

      // ── noise band layer ───────────────────────
      noise = BPF.ar(PinkNoise.ar, portFreq, noiseBW / portFreq.max(20)) * noiseAmp * 8;
      sig = sig + noise;

      // ── dual resonant filter (QPAS-inspired) ───
      // filter freq modulated by envelope
      {
        var fFreq = (filterFreq * (1 + (envFilter * filterEnv * 4))).clip(20, 18000);
        var q = filterQ.clip(0.05, 1);
        sig = Select.ar(filterType, [
          RLPF.ar(sig, fFreq, q),   // 0: LPF
          BPF.ar(sig, fFreq, q) * 3, // 1: BPF (makeup gain)
          RHPF.ar(sig, fFreq, q),    // 2: HPF
        ]);
      }.value;

      sig = sig * 2.5; // makeup gain

      sig = sig * env * amp;
      sig = Pan2.ar(sig, pan);

      Out.ar(out, sig);
      Out.ar(delayOut, sig * delaySend);
    }).add;

    // ── spectral delay (Mimeophon-inspired) ──────
    SynthDef(\tessera_delay, {
      arg in=0, out=0,
          time=0.3, feedback=0.5, color=4000,
          mix=0.4, halo=0.3;

      var sig, delayed, haloSig, fb;

      sig = In.ar(in, 2);

      // feedback with soft clip to prevent blowup
      delayed = CombL.ar(sig, 2.0, time.clip(0.01, 2.0), feedback * 6);
      delayed = delayed.tanh; // soft saturate feedback
      delayed = LPF.ar(delayed, color.clip(200, 16000));

      // halo: diffused allpass cloud
      haloSig = delayed;
      4.do { |i|
        haloSig = AllpassL.ar(haloSig, 0.5,
          LFNoise1.kr(0.05 + (i * 0.02)).range(0.02, 0.07 + (i * 0.02)),
          halo * 3);
      };

      Out.ar(out, haloSig * mix);
    }).add;

    // ── reverb (Erbe-Verb inspired: resonant, metallic) ──
    SynthDef(\tessera_reverb, {
      arg in=0, out=0, mix=0.3, size=0.85, damp=0.5, shimmer=0;

      var sig, wet, shim;
      sig = In.ar(in, 2);

      wet = FreeVerb2.ar(sig[0], sig[1], mix, size, damp);

      // shimmer: pitch-shifted reverb tail
      shim = PitchShift.ar(wet, 0.2, 2.0, 0.01, 0.05) * shimmer * 0.3;
      wet = wet + shim;

      Out.ar(out, wet);
    }).add;

    context.server.sync;

    // ── instantiate ──────────────────────────────
    voices = Array.fill(4, {
      Synth(\tessera_voice, [
        \out, reverbBus, \delayOut, delayBus
      ], context.xg);
    });

    delaySynth = Synth.after(voices.last, \tessera_delay, [
      \in, delayBus, \out, reverbBus
    ]);

    reverbSynth = Synth.after(delaySynth, \tessera_reverb, [
      \in, reverbBus, \out, context.out_b
    ]);

    // ── voice commands ───────────────────────────
    this.addCommand("hz",          "if", { |msg| voices[msg[1].asInteger].set(\freq, msg[2]) });
    this.addCommand("amp",         "if", { |msg| voices[msg[1].asInteger].set(\amp, msg[2]) });
    this.addCommand("gate",        "ii", { |msg| voices[msg[1].asInteger].set(\t_gate, msg[2]) });
    this.addCommand("atk",         "if", { |msg| voices[msg[1].asInteger].set(\atk, msg[2]) });
    this.addCommand("dec",         "if", { |msg| voices[msg[1].asInteger].set(\dec, msg[2]) });
    this.addCommand("sus",         "if", { |msg| voices[msg[1].asInteger].set(\sus, msg[2]) });
    this.addCommand("rel",         "if", { |msg| voices[msg[1].asInteger].set(\rel, msg[2]) });
    this.addCommand("waveform",    "if", { |msg| voices[msg[1].asInteger].set(\waveform, msg[2]) });
    this.addCommand("partials",    "if", { |msg| voices[msg[1].asInteger].set(\partials, msg[2]) });
    this.addCommand("tilt",        "if", { |msg| voices[msg[1].asInteger].set(\tilt, msg[2]) });
    this.addCommand("spread",      "if", { |msg| voices[msg[1].asInteger].set(\spread, msg[2]) });
    this.addCommand("fm_depth",    "if", { |msg| voices[msg[1].asInteger].set(\fmDepth, msg[2]) });
    this.addCommand("fm_ratio",    "if", { |msg| voices[msg[1].asInteger].set(\fmRatio, msg[2]) });
    this.addCommand("fold",        "if", { |msg| voices[msg[1].asInteger].set(\fold, msg[2]) });
    this.addCommand("sub_amp",     "if", { |msg| voices[msg[1].asInteger].set(\subAmp, msg[2]) });
    this.addCommand("sub_oct",     "if", { |msg| voices[msg[1].asInteger].set(\subOct, msg[2]) });
    this.addCommand("noise_amp",   "if", { |msg| voices[msg[1].asInteger].set(\noiseAmp, msg[2]) });
    this.addCommand("noise_bw",    "if", { |msg| voices[msg[1].asInteger].set(\noiseBW, msg[2]) });
    this.addCommand("filter_freq", "if", { |msg| voices[msg[1].asInteger].set(\filterFreq, msg[2]) });
    this.addCommand("filter_q",    "if", { |msg| voices[msg[1].asInteger].set(\filterQ, msg[2]) });
    this.addCommand("filter_type", "if", { |msg| voices[msg[1].asInteger].set(\filterType, msg[2]) });
    this.addCommand("filter_env",  "if", { |msg| voices[msg[1].asInteger].set(\filterEnv, msg[2]) });
    this.addCommand("delay_send",  "if", { |msg| voices[msg[1].asInteger].set(\delaySend, msg[2]) });
    this.addCommand("slew",        "if", { |msg| voices[msg[1].asInteger].set(\slewTime, msg[2]) });
    this.addCommand("freeze",      "if", { |msg| voices[msg[1].asInteger].set(\freeze, msg[2]) });
    this.addCommand("smear",       "if", { |msg| voices[msg[1].asInteger].set(\smearRate, msg[2]) });
    this.addCommand("pan",         "if", { |msg| voices[msg[1].asInteger].set(\pan, msg[2]) });
    this.addCommand("accent",      "if", { |msg| voices[msg[1].asInteger].set(\accent, msg[2]) });

    // ── global FX commands ───────────────────────
    this.addCommand("delay_time",     "f", { |msg| delaySynth.set(\time, msg[1]) });
    this.addCommand("delay_feedback", "f", { |msg| delaySynth.set(\feedback, msg[1]) });
    this.addCommand("delay_color",    "f", { |msg| delaySynth.set(\color, msg[1]) });
    this.addCommand("delay_mix",      "f", { |msg| delaySynth.set(\mix, msg[1]) });
    this.addCommand("halo",           "f", { |msg| delaySynth.set(\halo, msg[1]) });
    this.addCommand("reverb_mix",     "f", { |msg| reverbSynth.set(\mix, msg[1]) });
    this.addCommand("reverb_size",    "f", { |msg| reverbSynth.set(\size, msg[1]) });
    this.addCommand("reverb_damp",    "f", { |msg| reverbSynth.set(\damp, msg[1]) });
    this.addCommand("shimmer",        "f", { |msg| reverbSynth.set(\shimmer, msg[1]) });
  }

  free {
    voices.do(_.free);
    delaySynth.free;
    reverbSynth.free;
    delayBus.free;
    reverbBus.free;
  }
}
