# iConsole Bike → MyWhoosh Bridge

This app helps MyWhoosh read data from your spinning bike.

## Important notices

- **BETA software:** this project is still in beta.
- **Do not use for official races:** this bridge is intended for testing/training only.
- **Calibration warning:** changing speed/power/grade calibration can misrepresent performance data. Using this in official races can get you disqualified or banned.
- **Supported platform:** **macOS only**.

## Supported bike (current beta scope)

This project currently supports only:

- **Abilica Stream SB-X (iConsole+075)**

## Why

Some bikes are not directly supported by MyWhoosh.  
This app acts like a translator between your bike and MyWhoosh.

## What it does

- Reads bike data (speed, cadence, watts, resistance)
- Sends that data to MyWhoosh as a compatible Bluetooth fitness device
- Lets MyWhoosh control bike actions (start/stop/resistance), including hill simulation via FTMS grade commands

## How to use (simple steps)

### Step 1: Build once

Open Terminal and run:

```bash
cd /Users/mortenstensgaard/git/iconsole
swiftc *.swift -o iconsole_ftms
```

### Step 2: Start the bridge

In Terminal:

```bash
cd /Users/mortenstensgaard/git/iconsole
ICONSOLE_BIKE_MAC=8c-de-52-21-9e-15 ./iconsole_ftms
```

Replace `ICONSOLE_BIKE_MAC` with your own bike MAC address.

Keep this Terminal window open while training.

### Step 3: Connect in MyWhoosh

1. Open MyWhoosh
2. Search for Bluetooth devices
3. Select **iConsole FTMS**
4. Start pedaling

You should now see live values in MyWhoosh.

## If it does not work

Try this:

1. Remove/forget the bike device in MyWhoosh
2. Close MyWhoosh
3. Stop and restart `./iconsole_ftms`
4. Open MyWhoosh and connect again

## Find your bike MAC address (macOS)

1. Turn on your bike.
2. Pair the bike in macOS Bluetooth settings (if not already paired).
3. Run:

```bash
system_profiler SPBluetoothDataType
```

4. Find your bike in the output and copy its `Address` value.
5. Start the app with that address:

```bash
ICONSOLE_BIKE_MAC=xx-xx-xx-xx-xx-xx ./iconsole_ftms
```

## Optional: Extra debug logs

If you want more detailed logs in Terminal:

```bash
cd /Users/mortenstensgaard/git/iconsole
ICONSOLE_BIKE_MAC=8c-de-52-21-9e-15 ICONSOLE_VERBOSE=1 ./iconsole_ftms
```

## Optional: Speed calibration

If MyWhoosh speed looks too low/high compared to your bridge output, you can apply a speed factor.

Example (around km/h vs mph difference):

```bash
cd /Users/mortenstensgaard/git/iconsole
ICONSOLE_BIKE_MAC=8c-de-52-21-9e-15 ICONSOLE_SPEED_FACTOR=1.60934 ./iconsole_ftms
```

Tips:
- Start with `1.0` (default)
- Increase factor if MyWhoosh is too slow
- Decrease factor if MyWhoosh is too fast

## Important: In-game speed in MyWhoosh

MyWhoosh in-game speed is mostly calculated from **power** (plus things like gradient/drafting/weight), not only from the raw bike speed value.

So if your bike sends low watts, the avatar can still move slower than your bike console speed.

## Optional: Power calibration

If MyWhoosh in-game speed is too low, try increasing transmitted power:

```bash
cd /Users/mortenstensgaard/git/iconsole
ICONSOLE_BIKE_MAC=8c-de-52-21-9e-15 ICONSOLE_POWER_FACTOR=1.50 ./iconsole_ftms
```

You can combine both:

```bash
cd /Users/mortenstensgaard/git/iconsole
ICONSOLE_BIKE_MAC=8c-de-52-21-9e-15 ICONSOLE_SPEED_FACTOR=1.60934 ICONSOLE_POWER_FACTOR=1.50 ./iconsole_ftms
```

## Optional: Hill resistance calibration (MyWhoosh gradients)

`iconsole_ftms` handles FTMS "Indoor Bike Simulation Parameters" (grade).  
Uphill grade increases resistance and downhill grade reduces it again.

Calibrate sensitivity with:

```bash
cd /Users/mortenstensgaard/git/iconsole
ICONSOLE_BIKE_MAC=8c-de-52-21-9e-15 ICONSOLE_GRADE_SCALE_UP=1.2 ICONSOLE_GRADE_SCALE_DOWN=0.8 ./iconsole_ftms
```

Optional deadband (ignore tiny grade jitter):

```bash
cd /Users/mortenstensgaard/git/iconsole
ICONSOLE_BIKE_MAC=8c-de-52-21-9e-15 ICONSOLE_GRADE_DEADBAND_PERCENT=0.15 ./iconsole_ftms
```

## Manual resistance override while riding

While `iconsole_ftms` is running, you can manually override resistance from Terminal:

- `+` / `=` increase one step
- `-` / `_` decrease one step
- `1`..`9` set level directly
- `s` / `S` speed factor up/down (live)
- `p` / `P` power factor up/down (live)
- `g` / `G` grade scale up/down (live)
- `v` print current calibration values
- `q` quit cleanly

The bridge shows a live dashboard with bike data (left) and FTMS/app data (right).

## Fair calibration guidance

If you want realistic/fair online behavior:

- Keep `ICONSOLE_POWER_FACTOR=1.0` (do not inflate watts).
- Keep `ICONSOLE_SPEED_FACTOR=1.0` unless you are correcting a clear unit/device mismatch.
- Use grade scaling (`ICONSOLE_GRADE_SCALE_UP` / `ICONSOLE_GRADE_SCALE_DOWN`) for trainer feel, not race advantage.

## Notes about resistance levels

- This setup uses resistance level range **1..30**.
- Bike starts at level **1** on startup.

## Optional: target power to resistance sensitivity

If MyWhoosh sends target-power commands, bridge maps power delta to resistance steps.
Tune with:

```bash
cd /Users/mortenstensgaard/git/iconsole
ICONSOLE_BIKE_MAC=8c-de-52-21-9e-15 ICONSOLE_POWER_WATTS_PER_LEVEL=20 ./iconsole_ftms
```

If MyWhoosh sends both grade and power, grade is prioritized by default:

```bash
cd /Users/mortenstensgaard/git/iconsole
ICONSOLE_BIKE_MAC=8c-de-52-21-9e-15 ICONSOLE_PREFER_GRADE_OVER_POWER=1 ICONSOLE_TARGET_POWER_SUPPRESS_SECONDS=8 ./iconsole_ftms
```

## All runtime options (environment variables)

`iconsole_ftms` does not use CLI flags.  
Configuration is done with environment variables before `./iconsole_ftms`.

### Behavior and calibration

- `ICONSOLE_BIKE_MAC`  
  Bike Bluetooth MAC address used for RFCOMM connection.  
  Required (no default).

- `ICONSOLE_VERBOSE`  
  `1` enables verbose debug logs.  
  Default: `off`

- `ICONSOLE_SPEED_FACTOR`  
  Scales transmitted speed.  
  Default: `1.0`

- `ICONSOLE_POWER_FACTOR`  
  Scales transmitted power.  
  Default: `1.0`

- `ICONSOLE_GRADE_SCALE_UP`  
  Grade->resistance scale for uphill (`+grade`).  
  Default: `1.0`

- `ICONSOLE_GRADE_SCALE_DOWN`  
  Grade->resistance scale for downhill (`-grade`).  
  Default: `1.0`

- `ICONSOLE_GRADE_DEADBAND_PERCENT`  
  Ignores tiny grade changes below this threshold.  
  Default: `0.10`

- `ICONSOLE_POWER_WATTS_PER_LEVEL`  
  Power-delta to resistance-level mapping (when target power is used).  
  Default: `25.0`

- `ICONSOLE_PREFER_GRADE_OVER_POWER`  
  `1/true/yes/on` prioritizes recent grade commands over target power.  
  Default: `true`

- `ICONSOLE_TARGET_POWER_SUPPRESS_SECONDS`  
  Ignore target power for this many seconds after grade command.  
  Default: `8.0`

### Example with multiple options

```bash
cd /Users/mortenstensgaard/git/iconsole
ICONSOLE_BIKE_MAC=8c-de-52-21-9e-15 \
ICONSOLE_SPEED_FACTOR=1.0 \
ICONSOLE_POWER_FACTOR=1.0 \
ICONSOLE_GRADE_SCALE_UP=2.0 \
ICONSOLE_GRADE_SCALE_DOWN=2.0 \
./iconsole_ftms
```

## Live calibration changes (while running)

During runtime you can calibrate values directly from keyboard:

- `s` increase speed factor
- `S` decrease speed factor
- `p` increase power factor
- `P` decrease power factor
- `g` increase both grade scales (up/down)
- `G` decrease both grade scales (up/down)
- `v` show current calibration values in status line

These live changes affect current session only (they are not persisted).

## Race safety warning for calibration features

Speed/power/grade calibration controls are for private testing and trainer feel only.  
Do not use calibrated values in official races. You risk disqualification or account bans if reported values are considered manipulated.
