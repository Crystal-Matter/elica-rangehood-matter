require "./came_protocol"
require "./waveform_player"

class Elica::Rangehood::Control
  getter wave_player : WavePlayer
  getter repeats : Int32

  # the official controller sends 5 repeats
  REPEATS      = ENV["REPEATS"]?.try(&.to_i) || 5
  TOGGLE_LIGHT = CAME::Frame.new(ENV["TOGGLE_LIGHT"]? || "00 00 00 00 00 01 FE B5", REPEATS)
  FAN_UP       = CAME::Frame.new(ENV["FAN_UP"]? || "00 00 00 00 00 01 FE 97", REPEATS)
  FAN_DOWN     = CAME::Frame.new(ENV["FAN_DOWN"]? || "00 00 00 00 00 01 FE 90", REPEATS)
  FAN_OFF      = CAME::Frame.new(ENV["FAN_OFF"]? || "00 00 00 00 00 01 FE 95", REPEATS)

  def toggle_light
    wave_player.play(TOGGLE_LIGHT.pulses, repeats)
  end

  def fan_up
    wave_player.play(FAN_UP.pulses, repeats)
  end

  def fan_down
    wave_player.play(FAN_DOWN.pulses, repeats)
  end

  def fan_off
    wave_player.play(FAN_OFF.pulses, repeats)
  end

  def initialize(daemon : PigpioDaemon, gpio_pin : UInt32, @repeats : Int32 = 10)
    @wave_player = WavePlayer.new(daemon, gpio_pin)
  end
end
