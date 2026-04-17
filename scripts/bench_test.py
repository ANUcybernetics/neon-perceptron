import spidev
import RPi.GPIO as GPIO
import time
import sys

# ── Chain configuration ──────────────────────────────────────────────
CHAINS = {
    "input_left": {"bus": 0, "dev": 0, "chips": 2,  "lat": 8},
    "main":       {"bus": 1, "dev": 0, "chips": 9,  "lat": 18},
}

# ── Parse args ───────────────────────────────────────────────────────
usage = "Usage: sudo python3 bench_test.py <input_left|main> [blink]"

if len(sys.argv) < 2 or sys.argv[1] not in CHAINS:
    print(usage)
    print("Chains: " + ", ".join(CHAINS.keys()))
    sys.exit(1)

chain = CHAINS[sys.argv[1]]
blink = len(sys.argv) > 2 and sys.argv[2] == "blink"

SPI_BUS = chain["bus"]
SPI_DEV = chain["dev"]
NUM_CHIPS = chain["chips"]
LAT_PIN = chain["lat"]

# ── Constants ────────────────────────────────────────────────────────
CHANNELS_PER_CHIP = 24
BYTES_PER_CHIP = CHANNELS_PER_CHIP * 12 // 8  # 36

# ── Helpers ──────────────────────────────────────────────────────────
def make_frame(num_chips, pwm=0):
    """Build a frame buffer. pwm=0 is dark, pwm=4095 is full bright."""
    chip = []
    for i in range(0, CHANNELS_PER_CHIP, 2):
        a = pwm & 0xFFF
        b = pwm & 0xFFF
        chip.append((a >> 4) & 0xFF)
        chip.append(((a & 0xF) << 4) | ((b >> 8) & 0xF))
        chip.append(b & 0xFF)
    return chip * num_chips


def send(spi, frame):
    """Transfer frame over SPI and pulse XLAT (if manual)."""
    spi.xfer2(frame)
    if LAT_PIN is not None:
        GPIO.output(LAT_PIN, GPIO.HIGH)
        GPIO.output(LAT_PIN, GPIO.LOW)


# ── Setup ────────────────────────────────────────────────────────────
if LAT_PIN is not None:
    GPIO.setmode(GPIO.BCM)
    GPIO.setup(LAT_PIN, GPIO.OUT, initial=GPIO.LOW)

spi = spidev.SpiDev()
spi.open(SPI_BUS, SPI_DEV)
spi.max_speed_hz = 1_000_000  # 1 MHz (conservative; TLC5947 max 30 MHz)
spi.mode = 0

xlat_desc = "manual XLAT GPIO " + str(LAT_PIN) if LAT_PIN is not None else "kernel CE"
print(sys.argv[1] + ": SPI" + str(SPI_BUS) + "." + str(SPI_DEV) +
      "  chips=" + str(NUM_CHIPS) +
      "  bytes/frame=" + str(BYTES_PER_CHIP * NUM_CHIPS) +
      "  " + xlat_desc)

# ── Test sequence ────────────────────────────────────────────────────
try:
    if blink:
        print("Blinking (Ctrl-C to stop)...")
        while True:
            send(spi, make_frame(NUM_CHIPS, 4095))
            time.sleep(0.5)
            send(spi, make_frame(NUM_CHIPS, 0))
            time.sleep(0.5)
    else:
        for label, pwm, pause in [
            ("ALL ON",  4095, 3),
            ("ALL OFF", 0,    3),
            ("ALL ON",  4095, 3),
            ("ALL OFF", 0,    0),
        ]:
            print(label + "...")
            send(spi, make_frame(NUM_CHIPS, pwm))
            if pause:
                time.sleep(pause)
        print("Done.")

except KeyboardInterrupt:
    send(spi, make_frame(NUM_CHIPS, 0))
    print("\nInterrupted -- LEDs off.")

finally:
    spi.close()
    if LAT_PIN is not None:
        GPIO.cleanup()
