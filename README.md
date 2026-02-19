# elica-rangehood-matter

`elica-rangehood-matter` emulates a 433MHz remote control for Elica range hoods.
It generates RF pulse trains on a Raspberry Pi via `pigpiod_if2` and is designed to be exposed through Matter for iOS/Home control.

## Hardware

- Raspberry Pi with accessible GPIO
- 433MHz ASK/OOK transmitter connected to GPIO (default: `GPIO17`)
- Compatible Elica range hood that uses the matching remote protocol

## Wiring (example)

Example wiring for a common 433MHz transmitter module (e.g. FS1000A-style):

| Signal | Transmitter pin | Raspberry Pi pin |
|---|---|---|
| Power | `VCC` | `5V` (physical pin `2` or `4`) |
| Ground | `GND` | `GND` (physical pin `6`) |
| Data | `DATA` / `ATAD` | `GPIO17` (BCM `17`, physical pin `11`) |

Notes:

- Raspberry Pi GPIO is `3.3V` logic only. Do not feed `5V` into any GPIO pin.
- Keep ground shared between the Pi and transmitter.
- A short wire antenna (about `17.3 cm`, quarter-wave at 433MHz) often improves range.

## Prerequisites

Install pigpio and start the daemon:

```bash
sudo apt update
sudo apt install pigpio
sudo systemctl enable --now pigpiod
```

## Build

```bash
shards install
shards build --production --release --error-trace
```

The executable will be at `./bin/rangehood`.

## Configuration

Environment variables:

- `GPIO_PIN` (default: `17`)
- `REPEATS` (default: `5`)
- `TOGGLE_LIGHT` (default: `00 00 00 00 00 01 FE B5`)
- `FAN_UP` (default: `00 00 00 00 00 01 FE 97`)
- `FAN_DOWN` (default: `00 00 00 00 00 01 FE 90`)
- `FAN_OFF` (default: `00 00 00 00 00 01 FE 95`)

Example:

```bash
GPIO_PIN=17 REPEATS=6 ./bin/rangehood
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
docker run --rm --network host elica-rangehood-matter
```

Because the app connects to `pigpiod` at `localhost:8888`, use host networking on Linux (or run `pigpiod` in the same network namespace).

## Development

Run tests:

```bash
crystal spec
```

## Contributing

1. Fork it (<https://github.com/Crystal-Matter/elica-rangehood-matter/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Stephen von Takach](https://github.com/stakach) - creator and maintainer
