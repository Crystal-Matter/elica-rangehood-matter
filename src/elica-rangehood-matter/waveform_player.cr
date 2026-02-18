# Protocol-agnostic waveform player
require "./lib_pigpiod"

record Pulse, level : Bool, us : UInt32

class WavePlayer
  @daemon : PigpioDaemon
  @gpio_pin : UInt32
  @gpio_mask : UInt32

  def initialize(@daemon : PigpioDaemon, @gpio_pin : UInt32)
    raise "gpio_pin must be < 32 (got #{@gpio_pin})" if @gpio_pin >= 32
    @gpio_mask = 1_u32 << @gpio_pin
    @daemon.check(
      Pigpiod.set_mode(@daemon.pi, @gpio_pin, Pigpiod::PI_OUTPUT),
      "set_mode"
    )
  end

  def play(pulses : Array(Pulse), repeats : Int32 = 1)
    raise "empty pulse sequence" if pulses.empty?
    raise "repeats must be >= 1" if repeats < 1

    pi = @daemon.pi
    raw = to_raw_pulses(pulses)

    @daemon.check(Pigpiod.wave_clear(pi), "wave_clear")
    @daemon.check(
      Pigpiod.wave_add_generic(pi, raw.size.to_i32, raw.to_unsafe),
      "wave_add_generic"
    )

    wave_id = @daemon.check(Pigpiod.wave_create(pi), "wave_create")

    begin
      if repeats == 1
        @daemon.check(Pigpiod.wave_send_once(pi, wave_id), "wave_send_once")
      else
        chain = build_chain(wave_id.to_u8, repeats)
        @daemon.check(
          Pigpiod.wave_chain(pi, chain.to_unsafe, chain.size.to_i32),
          "wave_chain"
        )
      end

      wait_tx_complete
    ensure
      Pigpiod.wave_delete(pi, wave_id)
    end

    Pigpiod.gpio_write(pi, @gpio_pin, 0_u32)
  end

  private def to_raw_pulses(pulses : Array(Pulse)) : Array(Pigpiod::GpioPulse)
    pulses.map do |pulse|
      if pulse.level
        Pigpiod::GpioPulse.new(gpio_on: @gpio_mask, gpio_off: 0_u32, us_delay: pulse.us)
      else
        Pigpiod::GpioPulse.new(gpio_on: 0_u32, gpio_off: @gpio_mask, us_delay: pulse.us)
      end
    end
  end

  private def build_chain(wave_id : UInt8, repeats : Int32) : Array(UInt8)
    raise "repeats must be <= 65535 for wave chaining" if repeats > 65535

    count_lo = (repeats & 0xFF).to_u8
    count_hi = ((repeats >> 8) & 0xFF).to_u8

    [
      255_u8, 0_u8,
      count_lo, count_hi,
      wave_id,
      255_u8, 1_u8,
    ]
  end

  private def wait_tx_complete
    while Pigpiod.wave_tx_busy(@daemon.pi) == 1
      sleep 5.milliseconds
    end
  end
end
