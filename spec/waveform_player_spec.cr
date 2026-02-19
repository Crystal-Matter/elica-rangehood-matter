require "./spec_helper"

private class FakeRadio
  include RadioTransmitter

  getter packets = [] of Bytes

  def transmit(data : Slice(UInt8))
    packet = Bytes.new(data.size)
    data.copy_to(packet)
    @packets << packet
  end
end

describe WavePlayer do
  it "encodes pulse levels to packed symbols and transmits them" do
    radio = FakeRadio.new
    player = WavePlayer.new(radio)

    pulses = [
      Pulse.new(level: true, us: 320_u32),
      Pulse.new(level: false, us: 320_u32),
    ]

    player.play(pulses, 1)
    radio.packets.should eq([Bytes[0xFF_u8, 0x00_u8]])
  end

  it "retransmits the same packet sequence for each repeat" do
    radio = FakeRadio.new
    player = WavePlayer.new(radio)

    player.play([Pulse.new(level: true, us: 320_u32)], 3)
    radio.packets.should eq([Bytes[0xFF_u8], Bytes[0xFF_u8], Bytes[0xFF_u8]])
  end

  it "splits payloads into 64-byte packets for CC1101 FIFO limits" do
    radio = FakeRadio.new
    player = WavePlayer.new(radio)

    # 70 bytes of carrier-on symbols (560 bits at 40us each).
    pulses = [Pulse.new(level: true, us: 22_400_u32)]

    player.play(pulses, 1)
    radio.packets.size.should eq(2)
    radio.packets[0].size.should eq(64)
    radio.packets[1].size.should eq(6)
  end
end
