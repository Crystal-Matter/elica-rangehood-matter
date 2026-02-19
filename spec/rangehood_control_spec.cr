require "./spec_helper"

private class FakeRadioForControl
  include RadioTransmitter

  getter packets = [] of Bytes

  def transmit(data : Slice(UInt8))
    packet = Bytes.new(data.size)
    data.copy_to(packet)
    @packets << packet
  end
end

describe Elica::Rangehood::Control do
  it "transmits the selected action and rejects unknown actions" do
    radio = FakeRadioForControl.new
    player = WavePlayer.new(radio)

    control = Elica::Rangehood::Control.new(
      player,
      repeats: 1,
      code_bits: 4,
      toggle_light_hex: "1",
      fan_up_hex: "2",
      fan_down_hex: "3",
      fan_off_hex: "4"
    )

    control.perform("fan_up")
    radio.packets.empty?.should be_false

    expect_raises(Exception, /unknown action/) do
      control.perform("invalid")
    end
  end
end
