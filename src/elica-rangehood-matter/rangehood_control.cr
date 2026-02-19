require "./came_protocol"
require "./waveform_player"

module Elica::Rangehood::Actuator
  abstract def toggle_light : Nil
  abstract def fan_up : Nil
  abstract def fan_down : Nil
  abstract def fan_off : Nil
end

class Elica::Rangehood::Control
  include Elica::Rangehood::Actuator

  getter wave_player : WavePlayer
  getter repeats : Int32
  getter code_bits : Int32

  DEFAULT_REPEATS      = ENV["REPEATS"]?.try(&.to_i) || 5
  DEFAULT_CODE_BITS    = ENV["CODE_BITS"]?.try(&.to_i) || 18
  DEFAULT_TOGGLE_LIGHT = ENV["TOGGLE_LIGHT"]? || "00 00 00 00 00 01 FE B5"
  DEFAULT_FAN_UP       = ENV["FAN_UP"]? || "00 00 00 00 00 01 FE 97"
  DEFAULT_FAN_DOWN     = ENV["FAN_DOWN"]? || "00 00 00 00 00 01 FE 90"
  DEFAULT_FAN_OFF      = ENV["FAN_OFF"]? || "00 00 00 00 00 01 FE 95"

  @toggle_light : CAME::Frame
  @fan_up : CAME::Frame
  @fan_down : CAME::Frame
  @fan_off : CAME::Frame

  def initialize(
    @wave_player : WavePlayer,
    @repeats : Int32 = DEFAULT_REPEATS,
    @code_bits : Int32 = DEFAULT_CODE_BITS,
    toggle_light_hex : String = DEFAULT_TOGGLE_LIGHT,
    fan_up_hex : String = DEFAULT_FAN_UP,
    fan_down_hex : String = DEFAULT_FAN_DOWN,
    fan_off_hex : String = DEFAULT_FAN_OFF,
  )
    @toggle_light = CAME::Frame.new(toggle_light_hex, @code_bits)
    @fan_up = CAME::Frame.new(fan_up_hex, @code_bits)
    @fan_down = CAME::Frame.new(fan_down_hex, @code_bits)
    @fan_off = CAME::Frame.new(fan_off_hex, @code_bits)
  end

  def toggle_light : Nil
    wave_player.play(@toggle_light.pulses, repeats)
  end

  def fan_up : Nil
    wave_player.play(@fan_up.pulses, repeats)
  end

  def fan_down : Nil
    wave_player.play(@fan_down.pulses, repeats)
  end

  def fan_off : Nil
    wave_player.play(@fan_off.pulses, repeats)
  end

  def perform(action : String) : Nil
    case action
    when "toggle_light" then toggle_light
    when "fan_up"       then fan_up
    when "fan_down"     then fan_down
    when "fan_off"      then fan_off
    else
      raise "unknown action '#{action}', expected one of: toggle_light, fan_up, fan_down, fan_off"
    end
  end
end
