# mpv-sync

Synchronize multiple mpv instances via UDP broadcast. One master player controls any number of slave players simultaneously.

## Features

- **UDP Broadcast**: One master syncs unlimited slaves at once
- **Dual Backend**: Supports lua-socket AND socat (with automatic fallback)
- **Adaptive Speed Adjustment**: Progressive synchronization without oscillation
- **Manual Offset Adjustment**: Fine-tuning in 5ms steps
- **Hard Seeking**: Automatic jump on large time differences (>5s)
- **OSD Display**: Live sync info directly in player

## Installation

### Prerequisites

**Option A: lua-socket** (works on Debian 13, faster)
```bash
sudo apt install lua-socket
```

**Option B: socat** (works on Debian 11, 12, 13)
```bash
sudo apt install socat
```

**Recommendation**: Install both, script automatically chooses the best backend!

### Install Script

```bash
# System-wide (all users):
sudo cp mpv-sync.lua /usr/share/mpv/scripts/

# Or per user:
mkdir -p ~/.config/mpv/scripts
cp mpv-sync.lua ~/.config/mpv/scripts/
```

## Usage

### Basic Usage (recommended)

**Master** (1x):
```bash
mpv --script-opts=sync-role=master,sync-target=192.168.10.255:12345 video.mp4
```

**Slaves** (any number):
```bash
mpv --script-opts=sync-role=slave,sync-target=192.168.10.255:12345 video.mp4
```

- Master sends commands via UDP broadcast
- All slaves on the same network receive automatically
- Backend is chosen automatically (lua-socket or socat)

### Explicit Backend Selection

```bash
# Use only lua-socket:
mpv --script-opts=sync-role=master,sync-backend=socket,sync-target=192.168.10.255:12345 video.mp4

# Use only socat:
mpv --script-opts=sync-role=master,sync-backend=socat,sync-target=192.168.10.255:12345 video.mp4

# Auto mode (default - tries socket, then socat):
mpv --script-opts=sync-role=master,sync-backend=auto,sync-target=192.168.10.255:12345 video.mp4
```

### Mixed Backends

**Works seamlessly!** UDP packets are identical regardless of backend:

```bash
# Master with lua-socket (Debian 13):
mpv --script-opts=sync-role=master,sync-backend=socket video.mp4

# Slave with socat (Debian 12):
mpv --script-opts=sync-role=slave,sync-backend=socat video.mp4
```

## Configuration

All options via `--script-opts=sync-OPTION=VALUE`:

| Option | Default | Description |
|--------|---------|-------------|
| `role` | `master` | `master` or `slave` |
| `target` | `192.168.10.255:12345` | Broadcast address:port (adjust for your network!) |
| `backend` | `auto` | `auto`, `socket` or `socat` |
| `sync_interval` | `0.5` | Seconds between position updates |
| `seek_threshold` | `5.0` | Seconds difference for hard seek |
| `speed_adjust_threshold` | `0.02` | Seconds - below 20ms = "in sync" |
| `max_speed_adjust` | `0.5` | Maximum speed change (50%) |
| `initial_offset` | `0.015` | Initial offset in seconds (15ms) |
| `show_osd` | `true` | Show sync info on screen |

### Permanent Configuration

Create `~/.config/mpv/script-opts/sync.conf`:

```ini
role=slave
target=192.168.10.255:12345
backend=auto
initial_offset=0.020
show_osd=yes
```

## Key Bindings (Slave only)

- **[**: Offset +5ms (slave runs later)
- **]**: Offset -5ms (slave runs earlier)

Useful for audio/video lip sync or when different hardware has different latency.

## Finding Your Broadcast Address

```bash
# Show all network interfaces with broadcast addresses:
ip addr show | grep -E "inet.*brd"

# Typical broadcast addresses:
# 192.168.1.255 for network 192.168.1.0/24
# 192.168.10.255 for network 192.168.10.0/24
# 10.0.0.255 for network 10.0.0.0/24
```

**For local testing:**
```bash
sync-target=127.0.0.1:12345
```

## Synchronization Algorithm

### Progressive Speed Adjustment

The script uses adaptive speed adjustment without oscillation:

| Time Difference | Adjustment | Description |
|-----------------|------------|-------------|
| < 20ms | Normal Speed | **IN SYNC** - no adjustment |
| 20-50ms | ±5% | Ultra-fine adjustment |
| 50-200ms | ±10% | Fine adjustment |
| 200ms-1s | ±32% | Moderate adjustment |
| > 1s | ±50% (max) | Larger adjustment |
| > 5s | Hard Seek | Immediate jump |

**Advantage**: Smooth convergence to sync point without overshoot.

### How It Works

1. **Master sends** position every 0.5s via UDP broadcast
2. **Slaves receive** and compare with their own position
3. **Small difference** (< 5s): Adjust speed
4. **Large difference** (> 5s): Hard seek to master position
5. **In sync** (< 20ms): Normal speed

## Troubleshooting

### "No backend available!"

```bash
# Install at least one:
sudo apt install lua-socket  # Debian 13
sudo apt install socat       # Debian 11, 12, 13
```

### lua-socket: "unexpected symbol near char(127)"

Known issue on Debian 12 - mpv's built-in Lua isn't compatible with the lua-socket binary.

**Solution**: Script automatically uses socat as fallback!

### Slaves Not Receiving Messages

**Check firewall:**
```bash
# Open UDP port (e.g., 12345):
sudo ufw allow 12345/udp
```

**Check broadcast address:**
```bash
ip addr show
# Look for: inet 192.168.10.50/24 brd 192.168.10.255
#                                     ^^^^^^^^^^^^^^ <- Your broadcast address!
```

**Test with socat:**
```bash
# Terminal 1 (receiver):
socat UDP4-RECVFROM:12345,broadcast,fork STDOUT

# Terminal 2 (sender):
echo "test" | socat - UDP4-DATAGRAM:192.168.10.255:12345,broadcast

# Terminal 1 should show "test"
```

## Example Setups

### Setup 1: One Master, 120 Slaves in LAN

```bash
# Master (Debian 13 with lua-socket):
mpv --script-opts=sync-role=master,sync-target=192.168.1.255:12345 video.mp4

# All slaves (mixed Debian versions):
for i in {1..120}; do
    ssh slave$i "mpv --script-opts=sync-role=slave,sync-target=192.168.1.255:12345 video.mp4" &
done
```

### Setup 2: Two Projectors, Perfect Sync

```bash
# Projector 1 (Master):
mpv --script-opts=sync-role=master --fs video.mp4

# Projector 2 (Slave with 25ms offset for hardware latency):
mpv --script-opts=sync-role=slave,sync-initial_offset=0.025 --fs video.mp4
```

## Performance

### lua-socket vs socat

| Backend | CPU | Latency | Compatibility |
|---------|-----|---------|---------------|
| lua-socket | ~0.1% | ~1ms | Debian 13 ✓, Debian 12 ✗ |
| socat | ~0.5% | ~5ms | Debian 11/12/13 ✓ |

**Recommendation**: Use `backend=auto` - script chooses the best automatically!

### Network Traffic

- **Master**: ~20 bytes/s (position updates every 0.5s)
- **Per Slave**: ~0 bytes/s sent, ~20 bytes/s received
- **120 Slaves**: Still only ~20 bytes/s from master (broadcast!)

## Technical Details

### Message Format

Simple text format over UDP:

```
play                    # Play
pause                   # Pause
seek|123.45             # Seek to 123.45 seconds
position|123.45         # Master position (every 0.5s)
speed|1.5               # Speed changed
```

### Port Usage

- **Master**: Binds to random port (send only)
- **Slaves**: Bind to configured port (e.g., 12345) for receiving
- **Broadcast**: All slaves on the network receive simultaneously

## License

MIT License - free for private and commercial use.
