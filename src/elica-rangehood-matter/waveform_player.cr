# Protocol-agnostic waveform player
require "./cc1101"
require "./waveform_pulse"
require "log"

class WavePlayer
  Log = ::Log.for("elica_rangehood.wave_player")

  enum Polarity
    Normal
    Inverted
  end

  enum BitOrder
    MsbFirst
    LsbFirst
  end

  DEFAULT_SYMBOL_US = 333_u32
  MAX_PACKET_BYTES  =     64

  getter polarity : Polarity
  getter bit_order : BitOrder
  getter symbol_us : UInt32

  def initialize(
    @radio : RadioTransmitter,
    @polarity : Polarity = Polarity::Normal,
    @bit_order : BitOrder = BitOrder::MsbFirst,
    @symbol_us : UInt32 = DEFAULT_SYMBOL_US,
  )
    raise "symbol_us must be >= 1" if @symbol_us == 0
  end

  def play(pulses : Array(Pulse), repeats : Int32 = 1)
    raise "empty pulse sequence" if pulses.empty?
    raise "repeats must be >= 1" if repeats < 1

    effective_pulses = polarity.inverted? ? invert_pulses(pulses) : pulses
    packets = encode_packets(effective_pulses)
    total_bytes = packets.sum(0, &.size)
    Log.debug do
      "encoded waveform pulses=#{effective_pulses.size} packets=#{packets.size} packet_bytes=#{total_bytes} " \
      "repeats=#{repeats} polarity=#{polarity.to_s.downcase} bit_order=#{bit_order_label} symbol_us=#{symbol_us}"
    end

    repeats.times do |repeat_index|
      packets.each_with_index do |packet, packet_index|
        Log.debug do
          "tx packet repeat=#{repeat_index + 1}/#{repeats} packet=#{packet_index + 1}/#{packets.size} bytes=#{packet.size}"
        end
        @radio.transmit(packet)
      end
    end

    Log.debug { "waveform playback complete repeats=#{repeats} polarity=#{polarity.to_s.downcase}" }
  end

  private def invert_pulses(pulses : Array(Pulse)) : Array(Pulse)
    pulses.map { |pulse| Pulse.new(level: !pulse.level, us: pulse.us) }
  end

  private def encode_packets(pulses : Array(Pulse)) : Array(Bytes)
    symbols = pulse_symbols(pulses)
    packed = pack_symbols(symbols)

    packets = [] of Bytes
    index = 0
    while index < packed.size
      chunk_size = MAX_PACKET_BYTES
      remaining = packed.size - index
      chunk_size = remaining if remaining < chunk_size

      packet = Bytes.new(chunk_size)
      packed[index, chunk_size].copy_to(packet)
      packets << packet

      index += chunk_size
    end
    packets
  end

  private def pulse_symbols(pulses : Array(Pulse)) : Array(UInt8)
    symbols = [] of UInt8

    pulses.each do |pulse|
      count = ((pulse.us + (symbol_us // 2)) // symbol_us).to_i
      count = 1 if count < 1

      value = pulse.level ? 1_u8 : 0_u8
      count.times { symbols << value }
    end

    symbols
  end

  private def pack_symbols(symbols : Array(UInt8)) : Bytes
    data = Bytes.new((symbols.size + 7) // 8)

    symbols.each_with_index do |symbol, index|
      next if symbol == 0_u8

      byte_index = index // 8
      bit_index = if bit_order.lsb_first?
                    index % 8
                  else
                    7 - (index % 8)
                  end
      data[byte_index] |= (1_u8 << bit_index)
    end

    data
  end

  private def bit_order_label : String
    bit_order.lsb_first? ? "lsb" : "msb"
  end
end
