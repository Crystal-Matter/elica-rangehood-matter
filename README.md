# elica-rangehood-matter

`elica-rangehood-matter` emulates a 433MHz remote control for Elica range hoods.
It transmits OOK/ASK RF packets through a CC1101 connected to Raspberry Pi SPI and is designed to be exposed through Matter for iOS/Home control.

## Hardware

- Raspberry Pi 5
- CC1101 transceiver module (433MHz variant recommended)
- Compatible Elica range hood that uses the matching remote protocol

## Wiring (example)

Example wiring for CC1101 on Raspberry Pi SPI0 (`/dev/spidev0.0`):

| Signal | CC1101 pin | Raspberry Pi pin |
|---|---|---|
| Power | `VCC` | `3.3V` (physical pin `1`) |
| Ground | `GND` | `GND` (physical pin `6`) |
| SPI Clock | `SCK` | `GPIO11` (SCLK, physical pin `23`) |
| SPI MOSI | `MOSI` | `GPIO10` (MOSI, physical pin `19`) |
| SPI MISO | `MISO` | `GPIO9` (MISO, physical pin `21`) |
| Chip Select | `CSN` | `GPIO8` (CE0, physical pin `24`) |
| Optional GPIO | `GDO0` | `GPIO25` (physical pin `22`) |

Notes:

- CC1101 is `3.3V` only. Do not power it from `5V`.
- Keep wiring short and ground shared.
- A short wire antenna (about `17.3 cm`, quarter-wave at 433MHz) often improves range.

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

## Usage

This will launch the matter service

```bash
./bin/rangehood
```

## Configuration

Environment variables:

- `SPI_DEVICE` (default: `/dev/spidev0.0`)
- `SPI_SPEED_HZ` (default: `50000`)
- `REPEATS` (default: `5`)
- `CODE_BITS` (default: `18`)
- `TOGGLE_LIGHT` (default: `00 00 00 00 00 01 FE B5`)
- `FAN_UP` (default: `00 00 00 00 00 01 FE 97`)
- `FAN_DOWN` (default: `00 00 00 00 00 01 FE 90`)
- `FAN_OFF` (default: `00 00 00 00 00 01 FE 95`)

Example:

```bash
SPI_DEVICE=/dev/spidev0.0 SPI_SPEED_HZ=50000 REPEATS=6 ./bin/rangehood
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
  --user root \
  elica-rangehood-matter
```

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
