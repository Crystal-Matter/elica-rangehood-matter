# Linux SPI ioctl interface
lib LibC
  fun ioctl(fd : Int32, request : UInt64, argp : Void*) : Int32
end

@[Packed]
record SpiIocTransfer,
  tx_buf : UInt64,
  rx_buf : UInt64,
  len : UInt32,
  speed_hz : UInt32,
  delay_usecs : UInt16,
  bits_per_word : UInt8,
  cs_change : UInt8,
  tx_nbits : UInt8,
  rx_nbits : UInt8,
  word_delay_usecs : UInt8,
  pad : UInt8

module LinuxSPI
  # SPI_IOC_MESSAGE(1) on aarch64 Linux:
  # _IOC(_IOC_WRITE, 'k', 0, sizeof(spi_ioc_transfer))
  # = (1 << 30) | (32 << 16) | (0x6B << 8) | 0
  SPI_IOC_MESSAGE_1 = 0x40206B00_u64

  # SPI mode and configuration ioctls
  SPI_IOC_WR_MODE          = 0x40016B01_u64
  SPI_IOC_WR_BITS_PER_WORD = 0x40016B03_u64
  SPI_IOC_WR_MAX_SPEED_HZ  = 0x40046B04_u64
  SPI_IOC_RD_MODE          = 0x80016B01_u64
end

module SpiTransport
  abstract def transfer(tx : Slice(UInt8)) : Bytes
end

# SPI device wrapper
class SpiDevice
  include SpiTransport

  @fd : Int32
  @speed : UInt32
  @io : File

  def initialize(device : String = "/dev/spidev0.0", @speed : UInt32 = 50_000_u32)
    @io = File.open(device, "r+")
    @fd = @io.fd

    # Force SPI mode 0 (CPOL=0, CPHA=0) — required by CC1101
    mode = 0_u8
    rc = LibC.ioctl(@fd, LinuxSPI::SPI_IOC_WR_MODE, pointerof(mode).as(Void*))
    raise "SPI set mode 0 failed (ioctl returned #{rc})" if rc < 0

    # Force 8 bits per word
    bpw = 8_u8
    rc = LibC.ioctl(@fd, LinuxSPI::SPI_IOC_WR_BITS_PER_WORD, pointerof(bpw).as(Void*))
    raise "SPI set bits_per_word failed (ioctl returned #{rc})" if rc < 0

    # Set max speed
    rc = LibC.ioctl(@fd, LinuxSPI::SPI_IOC_WR_MAX_SPEED_HZ, pointerof(@speed).as(Void*))
    raise "SPI set max speed failed (ioctl returned #{rc})" if rc < 0
  end

  def close
    @io.close unless @io.closed?
  end

  # Full-duplex SPI transfer. Returns the rx buffer.
  def transfer(tx : Slice(UInt8)) : Bytes
    rx = Bytes.new(tx.size)

    xfer = SpiIocTransfer.new(
      tx_buf: tx.to_unsafe.address.to_u64,
      rx_buf: rx.to_unsafe.address.to_u64,
      len: tx.size.to_u32,
      speed_hz: @speed,
      delay_usecs: 0_u16,
      bits_per_word: 8_u8,
      cs_change: 0_u8,
      tx_nbits: 0_u8,
      rx_nbits: 0_u8,
      word_delay_usecs: 0_u8,
      pad: 0_u8,
    )

    rc = LibC.ioctl(@fd, LinuxSPI::SPI_IOC_MESSAGE_1, pointerof(xfer).as(Void*))
    raise "SPI transfer failed (ioctl returned #{rc})" if rc < 0
    rx
  end
end
