require "./spi_device"

module RadioTransmitter
  abstract def transmit(data : Slice(UInt8))
end

# Minimal CC1101 driver for OOK transmission on 433.92 MHz.
class CC1101
  include RadioTransmitter

  # Strobe commands
  SRES  = 0x30_u8
  STX   = 0x35_u8
  SIDLE = 0x36_u8
  SFTX  = 0x3B_u8

  # Configuration registers
  IOCFG0   = 0x02_u8
  PKTLEN   = 0x06_u8
  PKTCTRL0 = 0x08_u8
  FREQ2    = 0x0D_u8
  FREQ1    = 0x0E_u8
  FREQ0    = 0x0F_u8
  MDMCFG4  = 0x10_u8
  MDMCFG3  = 0x11_u8
  MDMCFG2  = 0x12_u8
  DEVIATN  = 0x15_u8
  FREND0   = 0x22_u8
  FSCAL3   = 0x23_u8
  FSCAL2   = 0x24_u8
  FSCAL1   = 0x25_u8
  FSCAL0   = 0x26_u8

  # Special addresses
  PATABLE = 0x3E_u8

  # Status register (read via burst bit)
  MARCSTATE = 0xF5_u8 # 0xC0 (status) | 0x35

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
    strobe(SRES)
    sleep 5.milliseconds
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

  # Configure for 433.92 MHz OOK transmission at 25 kBaud.
  # Each FIFO bit maps to ~40us of RF output.
  def configure_ook_433
    idle

    # Carrier frequency: 433.92 MHz (0x10B071 @ 26MHz crystal)
    write_reg(FREQ2, 0x10_u8)
    write_reg(FREQ1, 0xB0_u8)
    write_reg(FREQ0, 0x71_u8)

    # ASK/OOK, no sync word, no preamble
    write_reg(MDMCFG2, 0x30_u8)

    # Data rate: ~24.8 kBaud (near 25 kBaud)
    write_reg(MDMCFG4, 0x0A_u8)
    write_reg(MDMCFG3, 0x3B_u8)

    # Fixed length, no CRC, no whitening
    write_reg(PKTCTRL0, 0x00_u8)

    # OOK front-end configuration
    write_reg(DEVIATN, 0x00_u8)
    write_reg(FREND0, 0x11_u8)

    # PA table: index 0 off, index 1 on (~10 dBm)
    write_burst(PATABLE, Bytes[0x00_u8, 0xC0_u8])

    # GDO0 asserts on packet TX complete
    write_reg(IOCFG0, 0x06_u8)

    # Frequency synthesizer calibration values
    write_reg(FSCAL3, 0xE9_u8)
    write_reg(FSCAL2, 0x2A_u8)
    write_reg(FSCAL1, 0x00_u8)
    write_reg(FSCAL0, 0x1F_u8)
  end

  # Transmit a single packet from TX FIFO. Data must be <= 64 bytes.
  def transmit(data : Slice(UInt8))
    raise "TX data too large: #{data.size} bytes (max 64)" if data.size > 64

    idle
    strobe(SFTX)

    write_reg(PKTLEN, data.size.to_u8)
    write_burst(0x3F_u8, data)

    strobe(STX)

    500.times do
      sleep 200.microseconds
      current = state
      return if current == MARCSTATE_IDLE
      if current == MARCSTATE_TXFIFO_UNDERFLOW
        strobe(SFTX)
        raise "TX FIFO underflow"
      end
    end

    raise "TX timeout"
  end
end
