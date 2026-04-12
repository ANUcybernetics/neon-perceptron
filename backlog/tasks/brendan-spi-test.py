import spidev
import RPi.GPIO as GPIO
import time

# --- Configuration ---
# 24 channels * 12 bits per channel = 288 bits
# 288 bits / 8 bits per byte = 36 bytes per update
# If multiple chips are chained, multiply 36 by the number of chips.
NUM_CHANNELS = 24
PWM_MAX = 4096
BUFFER_SIZE = int(NUM_CHANNELS * 3 / 2)

# --- SPI Setup ---
spi = spidev.SpiDev()

#SPI 0
#LAT_PIN = 8 
#spi.open(0, 0) # Bus 0, Device 0 

#SPI 1
#LAT_PIN = 18
#spi.open(1, 0) # Bus 1, Device 0

#SPI 3
#LAT_PIN = 0
#spi.open(3, 0) # Bus 3, Device 0

#SPI 4
LAT_PIN = 4
spi.open(4, 0) # Bus 4, Device 0

#SPI 5
#LAT_PIN = 12
#spi.open(5, 0) # Bus 5, Device 0

spi.max_speed_hz = 10000000 # 10MHz
spi.mode = 0b00 # Clock Polarity 0, Phase 0

# --- GPIO Setup ---
GPIO.setmode(GPIO.BCM)
GPIO.setup(LAT_PIN, GPIO.OUT)
GPIO.output(LAT_PIN, GPIO.LOW)

def set_leds(led_array):

    buffer = [0] * BUFFER_SIZE
    byte_idx = BUFFER_SIZE - 1
    
    # Packing 12-bit values into 36 bytes (1.5 bytes per channel)
    for i in range(0, NUM_CHANNELS-1, 2):
        val1 = min(led_array[i], PWM_MAX)
        val2 = min(led_array[i+1], PWM_MAX)

        buffer[byte_idx]=(val1 & 0xFF)
        buffer[byte_idx-1]=((val1 >> 8) & 0x0F) | ((val2 << 4) & 0xF0)
        buffer[byte_idx-2]=(val2 >> 4) & 0xFF

        byte_idx = byte_idx-3
        
        pass
    
    # Write to SPI
    spi.xfer2(buffer)
    
    # Pulse Latch Pin
    GPIO.output(LAT_PIN, GPIO.HIGH)
    time.sleep(0.000001) # 1us
    GPIO.output(LAT_PIN, GPIO.LOW)

try:
    leds = [0] * NUM_CHANNELS

    Rpwm_value = 2048
    Gpwm_value = 2048
    Bpwm_value = 2048

    Rpwm_delta = 384
    Gpwm_delta = 221
    Bpwm_delta = 140

    while True:
        
        leds[23] = Rpwm_value
        leds[20] = 3800-Rpwm_value
        leds[22] = Gpwm_value
        leds[19] = 3800-Gpwm_value
        leds[21] = Bpwm_value
        leds[18] = 3800-Bpwm_value

        Rpwm_value = Rpwm_value + Rpwm_delta
        if ((Rpwm_value > 3700) or (Rpwm_value <400)):
                Rpwm_delta = -1 * Rpwm_delta

        Gpwm_value = Gpwm_value + Gpwm_delta
        if ((Gpwm_value > 3700) or (Gpwm_value <400)):
                Gpwm_delta = -1 * Gpwm_delta

        Bpwm_value = Bpwm_value + Bpwm_delta
        if ((Bpwm_value > 3700) or (Bpwm_value <400)):
                Bpwm_delta = -1 * Bpwm_delta

        set_leds(leds)

        time.sleep(0.1)
                
except KeyboardInterrupt:
    spi.close()
    GPIO.cleanup()
