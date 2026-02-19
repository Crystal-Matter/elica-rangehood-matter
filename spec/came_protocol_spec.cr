require "./spec_helper"

describe CAME do
  describe ".parse_key" do
    it "parses hex with spaces and masks to the requested bit length" do
      CAME.parse_key("FF FF", 8).should eq(0xFF_u32)
      CAME.parse_key("FF FF", 4).should eq(0x0F_u32)
    end

    it "ignores surrounding whitespace" do
      CAME.parse_key("  0A  ", 8).should eq(0x0A_u32)
    end
  end

  describe ".encode" do
    it "generates the expected pulse sequence for mixed bits (MSB first)" do
      pulses = CAME.encode(0b10_u32, 2)

      pulses.size.should eq(6)
      pulses[0].should eq(Pulse.new(level: false, us: CAME::GAP_US))
      pulses[1].should eq(Pulse.new(level: true, us: CAME::T_US))

      # bit 1 => LOW 2T, HIGH 1T
      pulses[2].should eq(Pulse.new(level: false, us: CAME::T_US * 2))
      pulses[3].should eq(Pulse.new(level: true, us: CAME::T_US))

      # bit 0 => LOW 1T, HIGH 2T
      pulses[4].should eq(Pulse.new(level: false, us: CAME::T_US))
      pulses[5].should eq(Pulse.new(level: true, us: CAME::T_US * 2))
    end

    it "includes gap + start + 2 pulses per data bit" do
      num_bits = 5
      pulses = CAME.encode(0_u32, num_bits)

      pulses.size.should eq(2 + (num_bits * 2))
      pulses[0].should eq(Pulse.new(level: false, us: CAME::GAP_US))
      pulses[1].should eq(Pulse.new(level: true, us: CAME::T_US))
    end
  end

  describe CAME::Frame do
    it "stores metadata and precomputes pulses from key + bit count" do
      frame = CAME::Frame.new("0F", 4)

      frame.key_hex.should eq("0F")
      frame.num_bits.should eq(4)
      frame.pulses.should eq(CAME.encode(0x0F_u32, 4))
      frame.size.should eq(10)
    end
  end
end
