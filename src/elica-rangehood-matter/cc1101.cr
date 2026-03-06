require "./spi_device"
require "log"

module RadioTransmitter
  abstract def transmit(data : Slice(UInt8))
end

# Minimal CC1101 driver for OOK transmission on 433.92 MHz.
class CC1101
  include RadioTransmitter
  Log = ::Log.for("elica_rangehood.cc1101")

  FXOSC_HZ = 26_000_000_u64

  # Strobe commands
  SRES  = 0x30_u8
  SCAL  = 0x33_u8
  STX   = 0x35_u8
  SIDLE = 0x36_u8
  SFRX  = 0x3A_u8
  SFTX  = 0x3B_u8

  # Configuration registers
  IOCFG2   = 0x00_u8
  IOCFG0   = 0x02_u8
  FIFOTHR  = 0x03_u8
  PKTLEN   = 0x06_u8
  PKTCTRL1 = 0x07_u8
  PKTCTRL0 = 0x08_u8
  FSCTRL1  = 0x0B_u8
  FSCTRL0  = 0x0C_u8
  FREQ2    = 0x0D_u8
  FREQ1    = 0x0E_u8
  FREQ0    = 0x0F_u8
  MDMCFG4  = 0x10_u8
  MDMCFG3  = 0x11_u8
  MDMCFG2  = 0x12_u8
  MDMCFG1  = 0x13_u8
  MDMCFG0  = 0x14_u8
  DEVIATN  = 0x15_u8
  MCSM1    = 0x17_u8
  MCSM0    = 0x18_u8
  FOCCFG   = 0x19_u8
  AGCCTRL2 = 0x1B_u8
  AGCCTRL1 = 0x1C_u8
  AGCCTRL0 = 0x1D_u8
  FREND1   = 0x21_u8
  FREND0   = 0x22_u8
  FSCAL3   = 0x23_u8
  FSCAL2   = 0x24_u8
  FSCAL1   = 0x25_u8
  FSCAL0   = 0x26_u8

  # Special addresses
  PATABLE = 0x3E_u8

  # Status register (read via burst bit)
  PARTNUM   = 0xF0_u8
  VERSION   = 0xF1_u8
  MARCSTATE = 0xF5_u8 # 0xC0 (status) | 0x35

  EXPECTED_PARTNUM     =         0x00_u8
  DEFAULT_FREQUENCY_HZ = 433_920_000_u32
  DEFAULT_SYMBOL_US    =         333_u32

  # MARCSTATE values
  MARCSTATE_IDLE             = 0x01_u8
  MARCSTATE_TXFIFO_UNDERFLOW = 0x16_u8

  @spi : SpiTransport

  def initialize(@spi : SpiTransport)
  end

  def strobe(cmd : UInt8) : UInt8
    rx = @spi.transfer(Bytes[cmd])
    rx[0]
  end

  def write_reg(addr : UInt8, value : UInt8)
    @spi.transfer(Bytes[addr, value])
  end

  def read_reg(addr : UInt8) : UInt8
    rx = @spi.transfer(Bytes[addr | 0x80_u8, 0x00_u8])
    rx[1]
  end

  def write_burst(addr : UInt8, data : Slice(UInt8))
    buf = Bytes.new(data.size + 1)
    buf[0] = addr | 0x40_u8 # burst flag
    data.copy_to(buf.to_unsafe + 1, data.size)
    @spi.transfer(buf)
  end

  def reset
    # Toggle CS to signal the CC1101 (reference driver does this before SRES)
    @spi.transfer(Bytes[0x00])
    sleep 1.milliseconds

    strobe(SRES)
    sleep 10.milliseconds

    # Flush both FIFOs after reset
    strobe(SFTX)
    strobe(SFRX)
    sleep 1.milliseconds

    # Verify chip is alive: VERSION must be non-zero (typically 0x14)
    ver = version
    Log.info { "cc1101 reset complete version=0x#{ver.to_s(16).upcase.rjust(2, '0')}" }
    raise "CC1101 not responding after reset (VERSION=0x00, check SPI wiring)" if ver == 0
  end

  def idle
    strobe(SIDLE)
    100.times do
      return if state == MARCSTATE_IDLE
      sleep 100.microseconds
    end
    raise "CC1101 failed to enter IDLE state"
  end

  # Read the MARCSTATE to determine current radio state
  def state : UInt8
    read_reg(MARCSTATE) & 0x1F
  end

  def partnum : UInt8
    read_reg(PARTNUM)
  end

  def version : UInt8
    read_reg(VERSION)
  end

  # Configure OOK transmission at the requested carrier frequency and symbol timing.
  # Each FIFO bit maps to one symbol of approximately `symbol_us` microseconds.
  #
  # This sets ALL registers needed for reliable OOK TX, matching the approach
  # used by proven reference drivers (mengguang/cc1101-raspberrypi).
  def configure_ook(
    frequency_hz : UInt32 = DEFAULT_FREQUENCY_HZ,
    symbol_us : UInt32 = DEFAULT_SYMBOL_US,
  )
    raise "symbol_us must be >= 1" if symbol_us == 0

    idle

    freq_word = frequency_word(frequency_hz)
    freq2 = ((freq_word >> 16) & 0xFF).to_u8
    freq1 = ((freq_word >> 8) & 0xFF).to_u8
    freq0 = (freq_word & 0xFF).to_u8
    mdmcfg4, mdmcfg3, actual_baud = data_rate_register_values(symbol_us)

    # --- GDO pins ---
    write_reg(IOCFG2, 0x29_u8)  # GDO2: CHIP_RDYn (default)
    write_reg(IOCFG0, 0x06_u8)  # GDO0: asserts on sync/end-of-packet

    # --- FIFO threshold ---
    write_reg(FIFOTHR, 0x07_u8) # TX FIFO threshold: 33 bytes

    # --- Packet engine ---
    write_reg(PKTCTRL1, 0x00_u8) # No append status, no address check
    write_reg(PKTCTRL0, 0x00_u8) # Fixed length, no CRC, no whitening

    # --- Frequency synthesizer ---
    write_reg(FSCTRL1, 0x06_u8) # IF frequency
    write_reg(FSCTRL0, 0x00_u8) # Frequency offset

    # --- Carrier frequency ---
    write_reg(FREQ2, freq2)
    write_reg(FREQ1, freq1)
    write_reg(FREQ0, freq0)

    # --- Modem configuration ---
    write_reg(MDMCFG4, mdmcfg4)            # Channel BW + data rate exponent
    write_reg(MDMCFG3, mdmcfg3)            # Data rate mantissa
    write_reg(MDMCFG2, 0x30_u8)            # ASK/OOK, no sync word
    write_reg(MDMCFG1, 0x00_u8)            # No FEC, 0 preamble bytes
    write_reg(MDMCFG0, 0xF8_u8)            # Channel spacing (default)

    # --- Deviation (not used for OOK but set explicitly) ---
    write_reg(DEVIATN, 0x00_u8)

    # --- Main radio control state machine ---
    write_reg(MCSM1, 0x30_u8)   # CCA always, TX→IDLE after packet
    write_reg(MCSM0, 0x18_u8)   # Auto-calibrate on IDLE→RX/TX transition

    # --- Frequency offset compensation (RX, but set for completeness) ---
    write_reg(FOCCFG, 0x16_u8)

    # --- AGC (RX, but set explicitly to known values) ---
    write_reg(AGCCTRL2, 0x43_u8)
    write_reg(AGCCTRL1, 0x40_u8)
    write_reg(AGCCTRL0, 0x91_u8)

    # --- Front-end configuration ---
    write_reg(FREND1, 0x56_u8)  # RX front-end (default)
    write_reg(FREND0, 0x11_u8)  # TX OOK: use PA_POWER index 1

    # --- Frequency synthesizer calibration ---
    write_reg(FSCAL3, 0xE9_u8)
    write_reg(FSCAL2, 0x2A_u8)
    write_reg(FSCAL1, 0x00_u8)
    write_reg(FSCAL0, 0x1F_u8)

    # --- PA table: index 0 = off (0x00), index 1 = max power (0xC0, ~10 dBm) ---
    write_burst(PATABLE, Bytes[0x00_u8, 0xC0_u8])

    Log.info do
      symbol_rate = 1_000_000.0 / symbol_us
      "cc1101 configure_ook freq_hz=#{frequency_hz} symbol_us=#{symbol_us} " \
      "target_baud=#{symbol_rate.round(2)} actual_baud=#{actual_baud.round(2)} " \
      "mdmcfg4=0x#{hex8(mdmcfg4)} mdmcfg3=0x#{hex8(mdmcfg3)}"
    end

    # Verify critical registers were written correctly
    verify_register(MDMCFG4, mdmcfg4, "MDMCFG4")
    verify_register(MDMCFG3, mdmcfg3, "MDMCFG3")
    verify_register(MDMCFG2, 0x30_u8, "MDMCFG2")
    verify_register(MDMCFG1, 0x00_u8, "MDMCFG1")
    verify_register(PKTCTRL0, 0x00_u8, "PKTCTRL0")
    verify_register(FREND0, 0x11_u8, "FREND0")
    verify_register(MCSM0, 0x18_u8, "MCSM0")

    # Dump all config registers for diagnostics
    dump_registers

    strobe(SCAL)
    500.times do
      return if state == MARCSTATE_IDLE
      sleep 100.microseconds
    end
    raise "CC1101 calibration timeout"
  end

  # Read back and verify a register value matches expected
  private def verify_register(addr : UInt8, expected : UInt8, name : String)
    actual = read_reg(addr)
    if actual != expected
      Log.error { "cc1101 register MISMATCH #{name} expected=0x#{hex8(expected)} actual=0x#{hex8(actual)}" }
      raise "CC1101 register #{name} write failed: expected 0x#{hex8(expected)}, got 0x#{hex8(actual)}"
    end
  end

  # Log all critical register values for remote debugging
  def dump_registers
    regs = {
      "IOCFG2" => IOCFG2, "IOCFG0" => IOCFG0, "FIFOTHR" => FIFOTHR,
      "PKTLEN" => PKTLEN, "PKTCTRL1" => PKTCTRL1, "PKTCTRL0" => PKTCTRL0,
      "FSCTRL1" => FSCTRL1, "FSCTRL0" => FSCTRL0,
      "FREQ2" => FREQ2, "FREQ1" => FREQ1, "FREQ0" => FREQ0,
      "MDMCFG4" => MDMCFG4, "MDMCFG3" => MDMCFG3, "MDMCFG2" => MDMCFG2,
      "MDMCFG1" => MDMCFG1, "MDMCFG0" => MDMCFG0, "DEVIATN" => DEVIATN,
      "MCSM1" => MCSM1, "MCSM0" => MCSM0, "FOCCFG" => FOCCFG,
      "AGCCTRL2" => AGCCTRL2, "AGCCTRL1" => AGCCTRL1, "AGCCTRL0" => AGCCTRL0,
      "FREND1" => FREND1, "FREND0" => FREND0,
      "FSCAL3" => FSCAL3, "FSCAL2" => FSCAL2, "FSCAL1" => FSCAL1, "FSCAL0" => FSCAL0,
    }

    parts = regs.map { |name, addr| "#{name}=0x#{hex8(read_reg(addr))}" }
    Log.info { "cc1101 register dump: #{parts.join(' ')}" }
  end

  private def hex8(v : UInt8) : String
    v.to_s(16).upcase.rjust(2, '0')
  end

  private def frequency_word(frequency_hz : UInt32) : UInt32
    (((frequency_hz.to_u64 * (1_u64 << 16)) + (FXOSC_HZ // 2)) // FXOSC_HZ).to_u32
  end

  private def data_rate_register_values(symbol_us : UInt32) : Tuple(UInt8, UInt8, Float64)
    target_baud = 1_000_000.0 / symbol_us

    best_error = Float64::INFINITY
    best_mdmcfg4 = 0x08_u8
    best_mdmcfg3 = 0xF8_u8
    best_rate = 0.0

    0_u8.upto(15_u8) do |drate_e|
      0_u8.upto(255_u8) do |drate_m|
        actual_baud = ((256.0 + drate_m) * (2.0 ** drate_e) * FXOSC_HZ.to_f) / (2.0 ** 28)
        error = (actual_baud - target_baud).abs
        next unless error < best_error

        best_error = error
        # Keep CHANBW bits at 0 (highest bandwidth) and set DRATE_E in low nibble.
        best_mdmcfg4 = drate_e
        best_mdmcfg3 = drate_m
        best_rate = actual_baud
      end
    end

    {best_mdmcfg4, best_mdmcfg3, best_rate}
  end

  # Transmit a single packet from TX FIFO. Data must be <= 64 bytes.
  def transmit(data : Slice(UInt8))
    raise "TX data too large: #{data.size} bytes (max 64)" if data.size > 64

    Log.debug {
      hex = data.map { |b| b.to_s(16).upcase.rjust(2, '0') }.join(' ')
      "cc1101 tx start bytes=#{data.size} data=#{hex}"
    }

    idle
    strobe(SFTX)

    write_reg(PKTLEN, data.size.to_u8)
    write_burst(0x3F_u8, data)

    strobe(STX)

    completed = false
    saw_non_idle_state = false
    500.times do
      sleep 200.microseconds
      current = state
      if current == MARCSTATE_IDLE
        unless saw_non_idle_state
          Log.warn { "cc1101 tx never left IDLE bytes=#{data.size}" }
          raise "TX did not start (radio remained IDLE)"
        end
        completed = true
        break
      end

      saw_non_idle_state = true

      if current == MARCSTATE_TXFIFO_UNDERFLOW
        strobe(SFTX)
        Log.warn { "cc1101 tx fifo underflow bytes=#{data.size}" }
        raise "TX FIFO underflow"
      end
    end

    if completed
      Log.debug { "cc1101 tx complete bytes=#{data.size}" }
      return
    end

    Log.warn { "cc1101 tx timeout bytes=#{data.size}" }
    raise "TX timeout"
  end
end
