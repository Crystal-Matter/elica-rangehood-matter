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
  IOCFG1   = 0x01_u8
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

  # Status registers (read via burst bit: addr | 0xC0)
  PARTNUM   = 0xF0_u8
  VERSION   = 0xF1_u8
  MARCSTATE = 0xF5_u8 # 0xC0 | 0x35
  TXBYTES   = 0xFA_u8 # 0xC0 | 0x3A

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

  def read_burst(addr : UInt8, length : Int32) : Bytes
    buf = Bytes.new(length + 1)
    buf[0] = addr | 0xC0_u8 # read + burst flags
    rx = @spi.transfer(buf)
    rx[1, length]
  end

  def reset
    # Retry reset sequence — SPI with jumper wires can be flaky
    5.times do |attempt|
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
      # Read VERSION multiple times to handle flaky reads
      ver = 0_u8
      3.times do
        ver = version
        break if ver != 0
        sleep 1.milliseconds
      end

      if ver != 0
        Log.info { "cc1101 reset complete version=0x#{ver.to_s(16).upcase.rjust(2, '0')} attempt=#{attempt + 1}" }
        return
      end

      Log.warn { "cc1101 reset attempt #{attempt + 1}: VERSION=0x00, retrying..." }
      sleep 50.milliseconds
    end

    raise "CC1101 not responding after reset (VERSION=0x00, check SPI wiring and power)"
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
  # Every register write is individually verified and retried to handle SPI
  # signal integrity issues common with jumper-wire connections.
  def configure_ook(
    frequency_hz : UInt32 = DEFAULT_FREQUENCY_HZ,
    symbol_us : UInt32 = DEFAULT_SYMBOL_US,
  )
    raise "symbol_us must be >= 1" if symbol_us == 0

    freq_word = frequency_word(frequency_hz)
    freq2 = ((freq_word >> 16) & 0xFF).to_u8
    freq1 = ((freq_word >> 8) & 0xFF).to_u8
    freq0 = (freq_word & 0xFF).to_u8
    mdmcfg4, mdmcfg3, actual_baud = data_rate_register_values(symbol_us)

    # Build register map: address → value
    config = {
      IOCFG2   => 0x06_u8, # GDO2: sync/EOP (reference OOK default)
      IOCFG1   => 0x2E_u8, # GDO1: high impedance (tri-state)
      IOCFG0   => 0x06_u8, # GDO0: sync/EOP
      FIFOTHR  => 0x07_u8, # TX FIFO threshold: 33 bytes
      PKTCTRL1 => 0x00_u8, # No append status, no address check
      PKTCTRL0 => 0x00_u8, # Fixed length, no CRC, no whitening
      FSCTRL1  => 0x06_u8, # IF frequency
      FSCTRL0  => 0x00_u8, # Frequency offset
      FREQ2    => freq2,
      FREQ1    => freq1,
      FREQ0    => freq0,
      MDMCFG4  => mdmcfg4, # Channel BW + data rate exponent
      MDMCFG3  => mdmcfg3, # Data rate mantissa
      MDMCFG2  => 0x30_u8, # ASK/OOK, no sync word
      MDMCFG1  => 0x00_u8, # No FEC, 0 preamble bytes
      MDMCFG0  => 0xF8_u8, # Channel spacing (default)
      DEVIATN  => 0x00_u8, # Not used for OOK
      MCSM1    => 0x30_u8, # CCA always, TX→IDLE after packet
      MCSM0    => 0x18_u8, # Auto-calibrate on IDLE→RX/TX transition
      FOCCFG   => 0x16_u8, # Frequency offset compensation
      AGCCTRL2 => 0x43_u8, # AGC
      AGCCTRL1 => 0x40_u8,
      AGCCTRL0 => 0x91_u8,
      FREND1   => 0x56_u8, # RX front-end (default)
      FREND0   => 0x11_u8, # TX OOK: PA_POWER=1 (PATABLE[1] for logic '1')
      FSCAL3   => 0xE9_u8, # Frequency synthesizer cal
      FSCAL2   => 0x2A_u8,
      FSCAL1   => 0x00_u8,
      FSCAL0   => 0x1F_u8,
    }

    idle

    # Write each register with individual verify+retry.
    # SPI signal integrity with jumper wires can cause random bit errors;
    # retrying individual writes is much faster than retrying the whole sequence.
    config.each do |addr, value|
      write_verified(addr, value)
    end

    Log.info { "cc1101 all #{config.size} config registers written and verified" }

    # --- PA table (burst write required for OOK modulation) ---
    # OOK: logic '0' uses PATABLE[0], logic '1' uses PATABLE[PA_POWER=1].
    # PATABLE[0]=0x00 (PA off for '0'), PATABLE[1]=0xC0 (max power for '1').
    # Burst write needed to reach index 1. Retry if verification fails.
    write_patable(Bytes[0x00_u8, 0xC0_u8])

    Log.info do
      symbol_rate = 1_000_000.0 / symbol_us
      "cc1101 configure_ook freq_hz=#{frequency_hz} symbol_us=#{symbol_us} " \
      "target_baud=#{symbol_rate.round(2)} actual_baud=#{actual_baud.round(2)} " \
      "mdmcfg4=0x#{hex8(mdmcfg4)} mdmcfg3=0x#{hex8(mdmcfg3)}"
    end

    dump_registers

    # Calibrate and wait for IDLE
    strobe(SCAL)
    500.times do
      return if state == MARCSTATE_IDLE
      sleep 100.microseconds
    end
    raise "CC1101 calibration timeout"
  end

  # Write a register with readback verification and retry.
  # Retries up to 10 times with increasing delays to handle SPI bit errors.
  private def write_verified(addr : UInt8, value : UInt8)
    10.times do |attempt|
      write_reg(addr, value)
      sleep 100.microseconds
      actual = read_reg(addr)
      return if actual == value

      Log.warn { "cc1101 write_verified 0x#{hex8(addr)}=0x#{hex8(value)} readback=0x#{hex8(actual)} attempt=#{attempt + 1}" }
      sleep (1 + attempt).milliseconds # increasing backoff
    end

    actual = read_reg(addr)
    raise "CC1101 register 0x#{hex8(addr)} write failed after 10 attempts: expected 0x#{hex8(value)}, got 0x#{hex8(actual)}"
  end

  # Write PATABLE entries via burst write with readback verification.
  # Retries up to 10 times since burst writes can be flaky over jumper wires.
  private def write_patable(data : Bytes)
    10.times do |attempt|
      write_burst(PATABLE, data)
      sleep 100.microseconds
      readback = read_burst(PATABLE, data.size)

      if readback == data
        hex = data.map { |byte| "0x#{hex8(byte)}" }.join(' ')
        Log.info { "cc1101 PATABLE written and verified: #{hex}" }
        return
      end

      hex_expected = data.map { |byte| "0x#{hex8(byte)}" }.join(' ')
      hex_actual = readback.map { |byte| "0x#{hex8(byte)}" }.join(' ')
      Log.warn { "cc1101 PATABLE write attempt #{attempt + 1}: expected [#{hex_expected}] got [#{hex_actual}]" }
      sleep (1 + attempt).milliseconds
    end

    raise "CC1101 PATABLE write failed after 10 attempts"
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
      "IOCFG2" => IOCFG2, "IOCFG1" => IOCFG1, "IOCFG0" => IOCFG0, "FIFOTHR" => FIFOTHR,
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
      hex = data.map(&.to_s(16).upcase.rjust(2, '0')).join(' ')
      "cc1101 tx start bytes=#{data.size} data=#{hex}"
    }

    idle
    strobe(SFTX)

    write_verified(PKTLEN, data.size.to_u8)

    # Write data to TX FIFO — try burst first, fall back to single-byte writes
    write_burst(0x3F_u8, data)

    txbytes = read_reg(TXBYTES) & 0x7F
    if txbytes != data.size
      Log.warn { "cc1101 tx fifo burst write incomplete: txbytes=#{txbytes} expected=#{data.size}, retrying with single-byte writes" }
      strobe(SFTX) # flush and retry
      data.each do |byte|
        write_reg(0x3F_u8, byte)
      end
      txbytes = read_reg(TXBYTES) & 0x7F
      Log.debug { "cc1101 tx fifo after single-byte writes: txbytes=#{txbytes} expected=#{data.size}" }
      raise "TX FIFO write failed: txbytes=#{txbytes} expected=#{data.size}" if txbytes != data.size
    else
      Log.debug { "cc1101 tx fifo burst write ok: txbytes=#{txbytes}" }
    end

    strobe(STX)

    # Calculate timeout: each byte = 8 bits at symbol_us per bit, plus margin.
    # At 3000 baud, 64 bytes = 170ms. Use 2x expected time + 100ms safety.
    # Default: assume worst case of ~3ms per byte (8 bits × 333µs).
    expected_ms = (data.size * 8 * 0.333) + 100
    poll_count = (expected_ms / 0.2).to_i.clamp(500, 10_000)

    completed = false
    saw_non_idle_state = false
    poll_count.times do
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
