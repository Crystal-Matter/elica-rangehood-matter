# Prerequisites:
#   sudo apt install pigpio
#   sudo systemctl enable pigpiod
#   sudo systemctl start pigpiod
@[Link("pigpiod_if2")]
lib Pigpiod
  struct GpioPulse
    gpio_on : UInt32
    gpio_off : UInt32
    us_delay : UInt32
  end

  # Connection
  fun pigpio_start(addr : UInt8*, port : UInt8*) : Int32
  fun pigpio_stop(pi : Int32) : Void

  # GPIO
  fun set_mode(pi : Int32, gpio : UInt32, mode : UInt32) : Int32
  fun gpio_write(pi : Int32, gpio : UInt32, level : UInt32) : Int32

  # Waveform / DMA
  fun wave_clear(pi : Int32) : Int32
  fun wave_add_generic(pi : Int32, num_pulses : Int32, pulses : Pointer(GpioPulse)) : Int32
  fun wave_create(pi : Int32) : Int32
  fun wave_send_once(pi : Int32, wave_id : Int32) : Int32
  fun wave_send_repeat(pi : Int32, wave_id : Int32) : Int32
  fun wave_tx_busy(pi : Int32) : Int32
  fun wave_delete(pi : Int32, wave_id : Int32) : Int32
  fun wave_chain(pi : Int32, buf : Pointer(UInt8), buf_size : Int32) : Int32

  PI_OUTPUT = 1_u32
end

# Daemon connection wrapper
class PigpioDaemon
  getter pi : Int32

  # Connect to pigpiod. Pass nil for localhost:8888 (default).
  def initialize(host : String? = nil, port : String? = nil)
    host_ptr = host.try(&.to_unsafe) || Pointer(UInt8).null
    port_ptr = port.try(&.to_unsafe) || Pointer(UInt8).null
    @pi = Pigpiod.pigpio_start(host_ptr, port_ptr)
    raise "Failed to connect to pigpiod at #{host || "localhost"}:#{port || "8888"} (code #{@pi})" if @pi < 0
  end

  def close
    Pigpiod.pigpio_stop(@pi)
  end

  def check(rc : Int32, context : String) : Int32
    raise "pigpiod error in #{context}: code #{rc}" if rc < 0
    rc
  end
end
