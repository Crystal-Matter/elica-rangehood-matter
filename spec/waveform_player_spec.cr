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
    player = WavePlayer.new(radio, symbol_us: 333_u32)

    pulses = [
      Pulse.new(level: true, us: 333_u32),
      Pulse.new(level: false, us: 333_u32),
    ]

    player.play(pulses, 1)
    # 1 ON symbol + 1 OFF symbol = 2 symbols → 1 byte
    # MSB-first: bit7=1, bit6=0, rest=0 → 0x80
    radio.packets.should eq([Bytes[0x80_u8]])
  end

  it "retransmits the same packet sequence for each repeat" do
    radio = FakeRadio.new
    player = WavePlayer.new(radio, symbol_us: 333_u32)

    player.play([Pulse.new(level: true, us: 333_u32)], 3)
    radio.packets.should eq([Bytes[0x80_u8], Bytes[0x80_u8], Bytes[0x80_u8]])
  end

  it "can invert waveform levels before transmit" do
    radio = FakeRadio.new
    player = WavePlayer.new(radio, WavePlayer::Polarity::Inverted, symbol_us: 333_u32)

    pulses = [
      Pulse.new(level: true, us: 333_u32),
      Pulse.new(level: false, us: 333_u32),
    ]

    player.play(pulses, 1)
    # Inverted: OFF then ON → bit7=0, bit6=1, rest=0 → 0x40
    radio.packets.should eq([Bytes[0x40_u8]])
  end

  it "can pack waveform bits lsb-first for hardware A/B testing" do
    radio = FakeRadio.new
    player = WavePlayer.new(radio, bit_order: WavePlayer::BitOrder::LsbFirst, symbol_us: 333_u32)

    pulses = [
      Pulse.new(level: true, us: 333_u32),
      Pulse.new(level: false, us: 333_u32),
    ]

    player.play(pulses, 1)
    # LSB-first: symbol0=1 → bit0, symbol1=0 → bit1 → 0x01
    radio.packets.should eq([Bytes[0x01_u8]])
  end

  it "splits payloads into 64-byte packets for CC1101 FIFO limits" do
    radio = FakeRadio.new
    player = WavePlayer.new(radio, symbol_us: 333_u32)

    # 560 symbols of ON → 560/8 = 70 bytes → split into 64 + 6
    pulses = [Pulse.new(level: true, us: (333 * 560).to_u32)]

    player.play(pulses, 1)
    radio.packets.size.should eq(2)
    radio.packets[0].size.should eq(64)
    radio.packets[1].size.should eq(6)
  end

  it "fits a standard 18-bit CAME frame into a single packet" do
    radio = FakeRadio.new
    player = WavePlayer.new(radio, symbol_us: 333_u32)

    frame = CAME::Frame.new("00 00 00 00 00 01 FE B5", 18)
    player.play(frame.pulses, 1)

    # 48 gap symbols + 1 start + 54 data symbols = 103 symbols → 13 bytes
    radio.packets.size.should eq(1)
    radio.packets[0].size.should eq(13)
    # Verify the expected FIFO bytes match the hardware test output
    radio.packets[0].should eq(Bytes[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xB2, 0x49, 0x24, 0x96, 0x59, 0x2C, 0xB2])
  end
end
