require "./waveform_player"

# CAME protocol encoder
module CAME
  T_US   =   320_u32 # Base timing unit
  GAP_US = 16500_u32 # Inter-frame gap (~52T, matches real capture)

  def self.parse_key(hex_key : String, num_bits : Int32) : UInt32
    clean = hex_key.gsub(" ", "").strip
    value = clean.to_u64(16)
    mask = (1_u64 << num_bits) - 1
    (value & mask).to_u32
  end

  # Encode a single CAME frame as a sequence of logical pulses.
  #
  # Real CAME waveform structure (verified against Flipper capture):
  #
  #   [inter-frame gap: LOW ~16.5ms]
  #   [start pulse:     HIGH 1T]
  #   [bit N-1 .. 0:    LOW xT, HIGH yT]
  #
  # Bit encoding (each bit is a LOW→HIGH pair):
  #   Bit 0: LOW 1T, HIGH 2T
  #   Bit 1: LOW 2T, HIGH 1T
  #
  # The frame ends HIGH after the last bit's HIGH phase. The receiver
  # sees the next frame's leading LOW gap as the delimiter.
  def self.encode(code : UInt32, num_bits : Int32) : Array(Pulse)
    pulses = [] of Pulse

    # Inter-frame gap (LOW). On the first frame this is a cold start;
    # on subsequent frames (via wave chaining) it separates repetitions.
    pulses << Pulse.new(level: false, us: GAP_US)

    # Start pulse: HIGH for 1T
    pulses << Pulse.new(level: true, us: T_US)

    # Data bits, MSB first. Each bit is (LOW, HIGH).
    (num_bits - 1).downto(0) do |i|
      if (code >> i) & 1 == 1
        # Bit 1: LOW 2T, HIGH 1T
        pulses << Pulse.new(level: false, us: T_US * 2)
        pulses << Pulse.new(level: true, us: T_US)
      else
        # Bit 0: LOW 1T, HIGH 2T
        pulses << Pulse.new(level: false, us: T_US)
        pulses << Pulse.new(level: true, us: T_US * 2)
      end
    end

    pulses
  end

  struct Frame
    getter key_hex : String
    getter num_bits : Int32
    getter pulses : Array(Pulse)

    def size
      pulses.size
    end

    def initialize(@key_hex, @num_bits)
      code = CAME.parse_key(@key_hex, @num_bits)
      @pulses = CAME.encode(code, @num_bits)
    end
  end
end
