# Protocol-agnostic waveform player
require "./cc1101"
require "./waveform_pulse"

class WavePlayer
  # CC1101 transmit data rate is configured to ~25 kbps, so each data bit is ~40us.
  SYMBOL_US        = 40_u32
  MAX_PACKET_BYTES =     64

  def initialize(@radio : RadioTransmitter)
  end

  def play(pulses : Array(Pulse), repeats : Int32 = 1)
    raise "empty pulse sequence" if pulses.empty?
    raise "repeats must be >= 1" if repeats < 1

    packets = encode_packets(pulses)
    repeats.times do
      packets.each do |packet|
        @radio.transmit(packet)
      end
    end
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
      count = ((pulse.us + (SYMBOL_US // 2)) // SYMBOL_US).to_i
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
      bit_index = 7 - (index % 8)
      data[byte_index] |= (1_u8 << bit_index)
    end

    data
  end
end
