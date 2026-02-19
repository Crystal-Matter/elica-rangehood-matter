require "./spec_helper"

private class FakeSpi
  include SpiTransport

  getter requests = [] of Bytes
  @responses = [] of Bytes

  def queue_response(response : Bytes)
    @responses << response
  end

  def transfer(tx : Slice(UInt8)) : Bytes
    request = Bytes.new(tx.size)
    tx.copy_to(request)
    @requests << request

    @responses.shift? || Bytes.new(tx.size)
  end
end

describe CC1101 do
  it "sends expected register read and write commands" do
    spi = FakeSpi.new
    spi.queue_response(Bytes[0_u8, 0_u8])
    spi.queue_response(Bytes[0_u8, 0xAB_u8])
    radio = CC1101.new(spi)

    radio.write_reg(CC1101::FREQ2, 0x10_u8)
    radio.read_reg(CC1101::FREQ1).should eq(0xAB_u8)

    spi.requests[0].should eq(Bytes[CC1101::FREQ2, 0x10_u8])
    spi.requests[1].should eq(Bytes[CC1101::FREQ1 | 0x80_u8, 0x00_u8])
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

    # idle() before transmit
    spi.queue_response(Bytes[0_u8])                         # SIDLE strobe
    spi.queue_response(Bytes[0_u8, CC1101::MARCSTATE_IDLE]) # read state

    # SFTX/write length/write payload/STX
    spi.queue_response(Bytes[0_u8])        # SFTX strobe
    spi.queue_response(Bytes[0_u8, 0_u8])  # write PKTLEN
    spi.queue_response(Bytes.new(5, 0_u8)) # write burst
    spi.queue_response(Bytes[0_u8])        # STX strobe

    # state poll after STX returns IDLE
    spi.queue_response(Bytes[0_u8, CC1101::MARCSTATE_IDLE])

    radio = CC1101.new(spi)
    radio.transmit(Bytes[0xAA_u8, 0x55_u8, 0x00_u8, 0xFF_u8])

    spi.requests[0].should eq(Bytes[CC1101::SIDLE])
    spi.requests[2].should eq(Bytes[CC1101::SFTX])
    spi.requests[3].should eq(Bytes[CC1101::PKTLEN, 4_u8])
    spi.requests[5].should eq(Bytes[CC1101::STX])
  end
end
