# CallRecorder

A tiny macOS menu bar app that records your calls — **you and everyone else on the call** — into one audio file per
call. Zoom, Teams, Google Meet in the browser, Webex, Slack, FaceTime, WhatsApp and Telegram. No bots joining the
meeting, no cloud, no virtual audio drivers to install.

It's the recorder from [Jinnie](https://github.com/romadinov/Jinnie), my personal knowledge agent, pulled out on its own.
About 900 lines of Swift.

## What it does

- **Notices calls by itself.** When a call app starts using the microphone, CallRecorder records it (or asks first, if
  you prefer). When the call ends, it stops.
- **Records the other people cleanly.** It taps the call app's own audio with a Core Audio process tap (macOS 14.2+),
  not the speakers, so notification sounds and music from other apps stay out.
- **One file per call:** `~/Music/Call Recordings/2026-11-14 10.30 Zoom.m4a`.
- **Crash-safe.** Audio is written as it arrives, in a format that stays readable if the app or the Mac dies mid-call;
  unfinished recordings are finished at the next launch.
- **Follows your AirPods.** It records from the microphone the call uses and survives AirPods switching to call mode.
- **Messenger calls are always asked**, never recorded automatically: they're often personal.
- `⌃⌥R` starts or stops a recording by hand.

## Build

Needs macOS 15 and Xcode 16 (or its command line tools) on an Apple Silicon or Intel Mac.

```bash
git clone https://github.com/romadinov/CallRecorder.git
cd CallRecorder
./build.sh
open build/CallRecorder.app
```

The first time, macOS asks for **Microphone** and **System Audio Recording**. The build is signed ad hoc, so macOS asks
again after each rebuild; `SIGN_IDENTITY="Apple Development: …" ./build.sh` signs it with your certificate instead.

## Three things that went wrong, so you don't have to find them

1. **The tap can lie about its sample rate.** For a while every call came out at half speed: the tap declared one rate
   and delivered another. CallRecorder measures the real rate over the first 3 seconds and uses that.
2. **Stopping a tap on the wrong queue deadlocks.** `AudioDeviceStop` waits for the IO cycle in progress; called on the
   queue that delivers the audio, it waits forever. The recorder sat frozen for two days — alive, menu bar icon showing,
   recording nothing. Taps are now torn down on their own serial queue.
3. **A hang is worse than a crash.** Something restarts a crashed app; nothing restarts a hung one. A watchdog thread now
   restarts CallRecorder if its main thread stops answering for 2 minutes.

## Be fair to the people you record

Recording a call without telling the others is illegal in many places. The "Recording" panel has a **Copy notice for
others** button — paste it in the call chat.

## Credits

Process tap code adapted from [AudioCap](https://github.com/insidegui/AudioCap) by Guilherme Rambo (BSD 2-Clause).

## License

MIT, see [LICENSE](LICENSE). The AudioCap-derived parts of `SystemAudio.swift` keep their BSD 2-Clause notice.
