require "./spec_helper"

# FakeSpi that tracks register writes and returns correct values on reads.
# This avoids brittle index-based assertions and handles the full
# configure_ook flow (writes, PATABLE, verification, dump, calibration).
private class FakeSpi
  include SpiTransport

  getter requests = [] of Bytes
  @registers = Hash(UInt8, UInt8).new(0_u8)
  @patable = Bytes.new(8, 0xC6_u8) # CC1101 reset default
  @marcstate_sequence = [CC1101::MARCSTATE_IDLE] of UInt8
  @marcstate_index = 0
  @tx_fifo_bytes = 0_u8

  # Set a sequence of MARCSTATE values to return on successive reads.
  # Used to simulate TX state transitions (IDLE → TX → IDLE).
  def marcstate_sequence=(seq : Array(UInt8))
    @marcstate_sequence = seq
    @marcstate_index = 0
  end

  private def next_marcstate : UInt8
    value = @marcstate_sequence[@marcstate_index]
    @marcstate_index += 1 if @marcstate_index < @marcstate_sequence.size - 1
    value
  end

  def transfer(tx : Slice(UInt8)) : Bytes
    request = Bytes.new(tx.size)
    tx.copy_to(request)
    @requests << request

    rx = Bytes.new(tx.size)

    return rx if tx.empty?

    header = tx[0]

    if tx.size == 1
      # Strobe command — return status byte
      rx[0] = 0x0F_u8                                 # IDLE state in status byte
      @tx_fifo_bytes = 0_u8 if header == CC1101::SFTX # flush TX FIFO
      return rx
    end

    is_read = (header & 0x80_u8) != 0
    is_burst = (header & 0x40_u8) != 0
    addr = header & 0x3F_u8

    if addr == 0x3E_u8
      # PATABLE access
      if is_read && is_burst
        # Burst read PATABLE
        rx[0] = 0x0F_u8 # status
        8.times { |i| rx[i + 1] = @patable[i] if i + 1 < rx.size }
      elsif is_read && !is_burst
        # Single byte read PATABLE (always index 0)
        rx[1] = @patable[0]
      elsif !is_read && is_burst
        # Burst write PATABLE
        (tx.size - 1).times { |i| @patable[i] = tx[i + 1] if i < 8 }
      elsif !is_read && !is_burst
        # Single byte write PATABLE (always index 0)
        @patable[0] = tx[1] if tx.size >= 2
      end
      return rx
    end

    if addr == 0x3F_u8
      # TX FIFO — track bytes written
      @tx_fifo_bytes += (tx.size - 1).to_u8 unless is_read
      return rx
    end

    if is_read
      # Register or status register read
      real_addr = addr
      if addr >= 0x30_u8
        # Status register
        if addr == 0x31_u8
          rx[1] = 0x14_u8 # VERSION
        elsif addr == 0x35_u8
          rx[1] = next_marcstate
        elsif addr == 0x3A_u8
          rx[1] = @tx_fifo_bytes
        end
      else
        rx[1] = @registers[real_addr]
      end
    else
      # Register write
      @registers[addr] = tx[1] if tx.size >= 2
    end

    rx
  end
end

describe CC1101 do
  it "sends expected register read and write commands" do
    spi = FakeSpi.new
    radio = CC1101.new(spi)

    radio.write_reg(CC1101::FREQ2, 0x10_u8)
    radio.read_reg(CC1101::FREQ1).should eq(0x00_u8) # not written yet

    spi.requests[0].should eq(Bytes[CC1101::FREQ2, 0x10_u8])
    spi.requests[1].should eq(Bytes[CC1101::FREQ1 | 0x80_u8, 0x00_u8])
  end

  it "reads chip identity registers" do
    spi = FakeSpi.new
    radio = CC1101.new(spi)

    # PARTNUM and VERSION are status registers (0xF0, 0xF1) — FakeSpi returns 0
    radio.partnum.should eq(0x00_u8)
  end

  it "configures OOK with correct frequency and data rate registers" do
    spi = FakeSpi.new
    radio = CC1101.new(spi)

    radio.configure_ook(433_920_000_u32, 333_u32)

    # Verify key registers were written with correct values
    freq_requests = spi.requests.select { |req| req.size == 2 && req[0] == CC1101::FREQ2 }
    freq_requests.should_not be_empty
    freq_requests.last[1].should eq(0x10_u8)

    frend0_requests = spi.requests.select { |req| req.size == 2 && req[0] == CC1101::FREND0 }
    frend0_requests.should_not be_empty
    frend0_requests.last[1].should eq(0x11_u8) # PA_POWER=1

    mdmcfg2_requests = spi.requests.select { |req| req.size == 2 && req[0] == CC1101::MDMCFG2 }
    mdmcfg2_requests.should_not be_empty
    mdmcfg2_requests.last[1].should eq(0x30_u8) # OOK, no sync

    mdmcfg1_requests = spi.requests.select { |req| req.size == 2 && req[0] == CC1101::MDMCFG1 }
    mdmcfg1_requests.should_not be_empty
    mdmcfg1_requests.last[1].should eq(0x00_u8) # No preamble

    mcsm0_requests = spi.requests.select { |req| req.size == 2 && req[0] == CC1101::MCSM0 }
    mcsm0_requests.should_not be_empty
    mcsm0_requests.last[1].should eq(0x18_u8) # Auto-cal
  end

  it "writes PATABLE with off at index 0 and power at index 1" do
    spi = FakeSpi.new
    radio = CC1101.new(spi)

    radio.configure_ook(433_920_000_u32, 333_u32)

    # Burst PATABLE write (header = 0x3E | 0x40 = 0x7E) sets [0]=0x00, [1]=0xC0
    patable_burst = spi.requests.select { |req| req.size == 3 && req[0] == 0x7E_u8 }
    patable_burst.should_not be_empty
    patable_burst.last[1].should eq(0x00_u8) # PATABLE[0] = off (OOK logic '0')
    patable_burst.last[2].should eq(0xC0_u8) # PATABLE[1] = max power (OOK logic '1')
  end

  it "raises when packet exceeds 64 bytes" do
    spi = FakeSpi.new
    radio = CC1101.new(spi)

    expect_raises(Exception, /max 64/) do
      radio.transmit(Bytes.new(65, 0_u8))
    end
  end

  it "queues the expected command flow for a successful transmit" do
    spi = FakeSpi.new
    # idle() reads MARCSTATE once (IDLE), then transmit polls:
    # first poll sees TX state (0x13), second poll sees IDLE → complete
    spi.marcstate_sequence = [
      CC1101::MARCSTATE_IDLE, # idle() check
      0x13_u8,                # TX state after STX
      CC1101::MARCSTATE_IDLE, # TX complete
    ]
    radio = CC1101.new(spi)

    radio.transmit(Bytes[0xAA_u8, 0x55_u8, 0x00_u8, 0xFF_u8])

    # Check key commands were sent
    strobe_requests = spi.requests.select { |req| req.size == 1 }
    strobe_requests.map(&.[0]).should contain(CC1101::SIDLE)
    strobe_requests.map(&.[0]).should contain(CC1101::SFTX)
    strobe_requests.map(&.[0]).should contain(CC1101::STX)

    # Check PKTLEN was set
    pktlen_writes = spi.requests.select { |req| req.size == 2 && req[0] == CC1101::PKTLEN }
    pktlen_writes.should_not be_empty
    pktlen_writes.last[1].should eq(4_u8)
  end
end
