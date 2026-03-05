# elica-rangehood-matter

`elica-rangehood-matter` emulates a 433MHz remote control for Elica range hoods.
It transmits OOK/ASK RF packets through a CC1101 connected to Raspberry Pi SPI and is designed to be exposed through Matter for iOS/Home control.

## Hardware

- Raspberry Pi 5
- CC1101 transceiver module (433MHz variant recommended)
- Compatible Elica range hood that uses the matching remote protocol (you can capture codes for your device using a flipper zero)

## Wiring (example)

Example wiring for CC1101 on Raspberry Pi SPI0 (`/dev/spidev0.0`):

| Signal | CC1101 pin | Raspberry Pi pin |
|---|---|---|
| Ground | 1 `GND` | `GND` (physical pin `6`) |
| Power | 2 `VCC` | `3.3V` (physical pin `1`) |
| Optional GPIO | 3 `GDO0` | `GPIO25` (physical pin `22`) |
| Chip Select | 4 `CSN` | `GPIO8` (CE0, physical pin `24`) |
| SPI Clock | 5 `SCK` | `GPIO11` (SCLK, physical pin `23`) |
| SPI MOSI | 6 `MOSI` | `GPIO10` (MOSI, physical pin `19`) |
| SPI MISO | 7 `MISO` | `GPIO9` (MISO, physical pin `21`) |

Notes:

- CC1101 is `3.3V` only. Do not power it from `5V`.
- Keep wiring short and ground shared.
- A short wire antenna (about `17.3 cm`, quarter-wave at 433MHz) often improves range.
- Part no. E07-M1101D (433M V2.0)
- Runtime defaults in this project are tuned for E07-M1101D (CC1101 + 26MHz crystal) on `433.920MHz` OOK.

## Prerequisites

Enable SPI on Raspberry Pi:

```bash
sudo raspi-config nonint do_spi 0
sudo reboot
```

Verify SPI device is present after reboot:

```bash
ls -l /dev/spidev0.0
```

## Build

```bash
shards install
shards build --production --release --error-trace
```

The executable will be at `./bin/rangehood`.
Replay tool executable: `./bin/replay_toggle`.

## Usage

This will launch the matter service

```bash
./bin/rangehood
```

Run hardware diagnostics and exit:

```bash
./bin/rangehood --hardware-test
```

Send inverted waveform polarity (for RF A/B testing):

```bash
./bin/rangehood --invert-waveform
```

Override RF carrier frequency (Hz):

```bash
./bin/rangehood --rf-frequency=433657070
```

Override waveform symbol duration and packet bit order (for TX A/B testing):

```bash
./bin/rangehood --rf-symbol-us=80 --rf-bit-order=msb
```

Transmit high-duty RF carrier packets for sniffer verification and exit:

```bash
./bin/rangehood --rf-carrier-test-seconds=10
```

Replay the reference working toggle frames extracted from capture files:

```bash
./bin/replay_toggle
```

Replay options:

```bash
./bin/replay_toggle --rf-frequency=433920000 --rf-symbol-us=333 --rf-bit-order=msb --replay-count=2
```

By default this tool reads:

- `captures/Raw_light_toggle.sub` (raw source frames)
- `captures/Light_toggle.sub` (decoded CAME key/bit width used to select matching frames)

The hardware test prints each initialization step, verifies CC1101 chip identity (`PARTNUM`/`VERSION`), validates CC1101 register readback, validates CAME frame parsing, sends a short diagnostic RF packet, and exits with:

- `0` on success (`[PASS]`)
- `1` on failure (`[FAIL]` with stack trace lines)

## Configuration

Environment variables:

- `SPI_DEVICE` (default: `/dev/spidev0.0`)
- `SPI_SPEED_HZ` (default: `50000`)
- `RF_FREQUENCY_HZ` (default: `433920000`)
- `RF_SYMBOL_US` (default: `333`)
- `RF_BIT_ORDER` (default: `msb`, supported: `msb`, `lsb`)
- `RF_CARRIER_TEST_SECONDS` (default: `0`, disabled)
- `REFERENCE_RAW_CAPTURE` (default: `captures/Raw_light_toggle.sub`, replay tool only)
- `REFERENCE_KEY_CAPTURE` (default: `captures/Light_toggle.sub`, replay tool only)
- `REPLAY_COUNT` (default: `1`, replay tool only)
- `REPEATS` (default: `5`)
- `CODE_BITS` (default: `18`)
- `TOGGLE_LIGHT` (default: `00 00 00 00 00 01 FE B5`)
- `FAN_UP` (default: `00 00 00 00 00 01 FE 97`)
- `FAN_DOWN` (default: `00 00 00 00 00 01 FE 90`)
- `FAN_OFF` (default: `00 00 00 00 00 01 FE 95`)
- `MATTER_STORAGE_FILE` (default: `data/elica_rangehood_matter_storage.json`)
- `LOG_LEVEL` (default: `info`)
- `INVERT_WAVEFORM` (default: `false`)

Use `LOG_LEVEL=debug` when troubleshooting RF transmission to see packet-level logs from `Control`, `WavePlayer`, and `CC1101`.
Action logs include `polarity=normal|inverted` for each Matter-triggered transmit.

Example:

```bash
SPI_DEVICE=/dev/spidev0.0 SPI_SPEED_HZ=50000 REPEATS=6 ./bin/rangehood
```

Practical RF tuning matrix (one toggle capture per row):

```bash
RF_FREQUENCY_HZ=433920000 RF_SYMBOL_US=333 RF_BIT_ORDER=msb ./bin/rangehood
RF_FREQUENCY_HZ=433920000 RF_SYMBOL_US=333 RF_BIT_ORDER=lsb ./bin/rangehood
RF_FREQUENCY_HZ=433920000 RF_SYMBOL_US=111 RF_BIT_ORDER=msb ./bin/rangehood
RF_FREQUENCY_HZ=433657070 RF_SYMBOL_US=333 RF_BIT_ORDER=msb ./bin/rangehood
```

## Docker

Build the image:

```bash
docker build -t elica-rangehood-matter .
# OR
docker buildx build --platform linux/arm64 --tag stakach/rangehood:latest --push .
```

Run the container:

```bash
docker run --rm \
  --network host \
  --device /dev/spidev0.0:/dev/spidev0.0 \
  -v "$(pwd)/data:/data" \
  -e MATTER_STORAGE_FILE=/data/elica_rangehood_matter_storage.json \
  elica-rangehood-matter
```

Run only the hardware diagnostics in Docker (recommended first when debugging startup):

```bash
docker run --rm \
  --network host \
  --device /dev/spidev0.0:/dev/spidev0.0 \
  -v "$(pwd)/data:/data" \
  -e MATTER_STORAGE_FILE=/data/elica_rangehood_matter_storage.json \
  -e LOG_LEVEL=debug \
  elica-rangehood-matter --hardware-test
```

If the container exits immediately, this mode will show which initialization step failed.

Or with compose:

```bash
docker compose up -d
```

## Development

Run tests:

```bash
crystal spec
```

Run linter:

```bash
./bin/ameba
```

## Contributing

1. Fork it (<https://github.com/Crystal-Matter/elica-rangehood-matter/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Stephen von Takach](https://github.com/stakach) - creator and maintainer
