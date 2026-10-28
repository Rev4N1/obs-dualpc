# OBS Dual-PC over NDI — 1080p60 to Twitch or YouTube

Two machines, one Ethernet cable, no capture card. The gaming PC sends its desktop as an NDI source
using **NDI Screen Capture** and runs nothing else. The stream PC receives that source in **OBS** and
does all the encoding, scenes, overlays and streaming.

```
Gaming PC ── NDI Screen Capture ──NDI──▶ Stream PC ── OBS ──▶ Twitch / YouTube
```

**Only settings that differ from the defaults are listed.** Everything else stays as it is — e.g. audio
stays on Track 1, as it arrives from the NDI source.

---

## 1. Install

### Gaming PC — NDI Screen Capture only

Run the included script. It downloads the newest NDI Tools, installs **only** Screen Capture, adds its
firewall rules and Start Menu / Desktop shortcuts. No OBS, no plugin, nothing else from NDI Tools.

```powershell
.\Install-NDIScreenCapture.ps1
```

Switches: `-IncludeHX` (also install Screen Capture HX), `-AllowPublic`, `-NoDesktopShortcut`,
`-KeepInstaller`, `-Uninstall`.

### Stream PC — OBS + NDI plugin

```powershell
winget install --exact --id DistroAV.DistroAV
```

That pulls OBS, the DistroAV plugin and the NDI runtime it depends on. Already running OBS? Install the
runtime on its own with `winget install --exact --id NDI.NDIRuntime`, then install DistroAV from
[its releases](https://github.com/DistroAV/DistroAV/releases).

> Screen Capture is a standalone app and does **not** register the NDI runtime. The plugin on the
> stream PC needs the runtime separately — `winget` above handles it.

## 2. Network (both PCs)

- Wired Ethernet on the same subnet. Full-quality NDI is heavy on the wire (well over 100 Mbps for
  1080p60), so a gigabit link and no Wi-Fi, no VPN on that path.
- Windows network profile must be **Private** (Settings → Network & internet → Ethernet → Private). The
  script's firewall rules only apply on Private/Domain unless you pass `-AllowPublic`.
- Allow **OBS** through Windows Firewall on the stream PC. The script already allows Screen Capture on
  the gaming PC.

## 3. Gaming PC — NDI Screen Capture

Start Screen Capture from the Start Menu, then right-click its tray icon:

| Setting | Value |
|---|---|
| Frame rate | **60** |
| Audio Source | **System Audio** (or the playback device your audio comes out of) |

Leave it running while you play. That is the whole setup on this machine.

- **Mic on this PC:** Screen Capture sends a single audio source. Either route mic + system audio through
  a virtual device (VB-CABLE, VoiceMeeter) and select that as the audio source, or plug the mic into the
  stream PC instead.
- Exclusive fullscreen can come through black in a desktop capture — switch that application to
  borderless / windowed mode if it does.
- If the network can't keep up with full-quality NDI, install the HX build (`-IncludeHX`) and use that
  instead — it encodes on the GPU at a fraction of the bitrate.

## 4. Stream PC — all the work happens here

Pick your platform — **Stream** and **Output → Streaming** have a column for each. Everything else is
the same for both. Assumes an NVIDIA GPU (NVENC).

### Settings → Stream

| Setting | Twitch | YouTube |
|---|---|---|
| Service | **Twitch** | **YouTube - RTMPS** |
| Account | Connect account or paste the stream key | Connect account or paste the stream key |

### Settings → Output

Output Mode: **Advanced**

**Streaming**

| Setting | Twitch | YouTube |
|---|---|---|
| Video Encoder | **NVIDIA NVENC H.264** | **NVIDIA NVENC HEVC** (or **NVIDIA NVENC AV1** if listed) |
| Bitrate | **6000 Kbps** | **12000 Kbps** |
| Keyframe Interval | **2 s** | **2 s** |
| Preset | **P7: Slowest (Best Quality)** | **P7: Slowest (Best Quality)** |
| Multipass Mode | **Two Passes (Full Resolution)** | **Two Passes (Full Resolution)** |

**Recording**

| Setting | Value |
|---|---|
| Audio Encoder | **Use stream encoder** |

**Replay Buffer** (optional)

| Setting | Value |
|---|---|
| Enable Replay Buffer | **ON** |
| Maximum Replay Time | **120 s** |

### Settings → General (only with the Replay Buffer)

- Output → **Automatically start replay buffer when streaming: ON**
- Output → **Keep replay buffer active when stream stops: ON**

### Settings → Audio

- Global Audio Devices → **Desktop Audio: Disabled** — otherwise stream-PC system and alert sounds are
  mixed in on top of the NDI audio.
- Mic plugged into the stream PC: Global Audio Devices → **Mic/Auxiliary Audio** → that mic.

### Settings → Video

| Setting | Value |
|---|---|
| Base (Canvas) Resolution | **1920x1080** |
| Output (Scaled) Resolution | **1920x1080** |
| Common FPS Values | **60** |

### Settings → Hotkeys

- Replay Buffer → **Save Replay: F9** (or any free key; only with the Replay Buffer)

### Settings → Advanced

- Network → **Dynamically change bitrate to manage congestion: ON**

### Sources

- Add **NDI Source** → Source name: the gaming PC, shown as `<COMPUTER-NAME> (Screen 1)`.
- Desktop not 1920x1080? Right-click the NDI source → **Transform → Fit to screen** (or **Stretch to
  screen** for a stretched 4:3 picture).
- Audio from the gaming PC already arrives in sync inside the NDI source — do **not** add it again.
- A mic on the stream PC may need a *Sync Offset*: Edit → **Advanced Audio Properties**.
- Overlays, alerts, chat and browser sources all live on this PC.
