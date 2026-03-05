require "option_parser"
require "log"

require "./elica-rangehood-matter/spi_device"
require "./elica-rangehood-matter/cc1101"
require "./elica-rangehood-matter/waveform_player"
require "./elica-rangehood-matter/raw_capture"

private struct Config
  property spi_device : String
  property spi_speed_hz : UInt32
  property rf_frequency_hz : UInt32
  property rf_symbol_us : UInt32
  property rf_bit_order : WavePlayer::BitOrder
  property raw_capture_path : String
  property key_path : String
  property replay_count : Int32
  property log_level : String

  def initialize
    @spi_device = ENV["SPI_DEVICE"]? || "/dev/spidev0.0"
    @spi_speed_hz = ENV["SPI_SPEED_HZ"]?.try(&.to_u32?) || 50_000_u32
    @rf_frequency_hz = ENV["RF_FREQUENCY_HZ"]?.try(&.to_u32?) || CC1101::DEFAULT_FREQUENCY_HZ
    @rf_symbol_us = ENV["RF_SYMBOL_US"]?.try(&.to_u32?) || WavePlayer::DEFAULT_SYMBOL_US
    @rf_bit_order = parse_bit_order(ENV["RF_BIT_ORDER"]?) || WavePlayer::BitOrder::MsbFirst
    @raw_capture_path = ENV["REFERENCE_RAW_CAPTURE"]? || "captures/Raw_light_toggle.sub"
    @key_path = ENV["REFERENCE_KEY_CAPTURE"]? || "captures/Light_toggle.sub"
    @replay_count = ENV["REPLAY_COUNT"]?.try(&.to_i?) || 1
    @log_level = ENV["LOG_LEVEL"]? || "info"
  end

  private def parse_bit_order(value : String?) : WavePlayer::BitOrder?
    return nil unless value

    case value.downcase
    when "msb", "msb-first", "msb_first"
      WavePlayer::BitOrder::MsbFirst
    when "lsb", "lsb-first", "lsb_first"
      WavePlayer::BitOrder::LsbFirst
    else
      nil
    end
  end
end

private def configure_logging(log_level : String) : Nil
  severity = case log_level
             when "debug" then ::Log::Severity::Debug
             when "warn"  then ::Log::Severity::Warn
             when "error" then ::Log::Severity::Error
             else
               ::Log::Severity::Info
             end

  ::Log.setup(severity, ::Log::IOBackend.new)
end

private def bit_order_label(bit_order : WavePlayer::BitOrder) : String
  bit_order.lsb_first? ? "lsb" : "msb"
end

config = Config.new

OptionParser.parse do |opts|
  opts.banner = "Usage: replay_reference_toggle [options]"
  opts.on("--spi-device=PATH", "SPI device path (default #{config.spi_device})") { |value| config.spi_device = value }
  opts.on("--spi-speed=HZ", "SPI speed in Hz (default #{config.spi_speed_hz})") do |value|
    parsed = value.to_u32?
    raise OptionParser::InvalidOption.new("--spi-speed must be a positive integer") unless parsed && parsed > 0
    config.spi_speed_hz = parsed
  end
  opts.on("--rf-frequency=HZ", "RF frequency in Hz (default #{config.rf_frequency_hz})") do |value|
    parsed = value.to_u32?
    raise OptionParser::InvalidOption.new("--rf-frequency must be a positive integer") unless parsed && parsed > 0
    config.rf_frequency_hz = parsed
  end
  opts.on("--rf-symbol-us=MICROS", "RF symbol duration in microseconds (default #{config.rf_symbol_us})") do |value|
    parsed = value.to_u32?
    raise OptionParser::InvalidOption.new("--rf-symbol-us must be a positive integer") unless parsed && parsed > 0
    config.rf_symbol_us = parsed
  end
  opts.on("--rf-bit-order=ORDER", "RF bit order: msb|lsb (default #{bit_order_label(config.rf_bit_order)})") do |value|
    parsed = case value.downcase
             when "msb", "msb-first", "msb_first"
               WavePlayer::BitOrder::MsbFirst
             when "lsb", "lsb-first", "lsb_first"
               WavePlayer::BitOrder::LsbFirst
             else
               nil
             end
    raise OptionParser::InvalidOption.new("--rf-bit-order must be one of: msb, lsb") unless parsed
    config.rf_bit_order = parsed
  end
  opts.on("--raw-capture=PATH", "Path to RAW .sub capture (default #{config.raw_capture_path})") { |value| config.raw_capture_path = value }
  opts.on("--key-capture=PATH", "Path to decoded CAME key .sub (default #{config.key_path})") { |value| config.key_path = value }
  opts.on("--replay-count=N", "Number of times to replay selected frames (default #{config.replay_count})") do |value|
    parsed = value.to_i?
    raise OptionParser::InvalidOption.new("--replay-count must be >= 1") unless parsed && parsed > 0
    config.replay_count = parsed
  end
  opts.on("--log-level=LEVEL", "Log level: debug|info|warn|error (default #{config.log_level})") { |value| config.log_level = value.downcase }
  opts.on("-h", "--help", "Show help") do
    puts opts
    exit 0
  end
end

configure_logging(config.log_level)

puts "Replay reference toggle"
puts "SPI device: #{config.spi_device}"
puts "SPI speed (Hz): #{config.spi_speed_hz}"
puts "RF frequency (Hz): #{config.rf_frequency_hz}"
puts "RF symbol (us): #{config.rf_symbol_us}"
puts "RF bit order: #{bit_order_label(config.rf_bit_order)}"
puts "RAW capture: #{config.raw_capture_path}"
puts "Key capture: #{config.key_path}"
puts "Replay count: #{config.replay_count}"
puts ""

matching_frames, inverted = RawCapture.select_came_matching_frames(config.raw_capture_path, config.key_path)
puts "Selected #{matching_frames.size} reference frames (capture polarity: #{inverted ? "inverted" : "normal"})"

reference_pulses = [] of Pulse
matching_frames.each { |frame| reference_pulses.concat(RawCapture.samples_to_pulses(frame)) }
puts "Reference pulse count: #{reference_pulses.size}"

spi = SpiDevice.new(config.spi_device, config.spi_speed_hz)
begin
  radio = CC1101.new(spi)
  radio.reset
  radio.configure_ook(config.rf_frequency_hz, config.rf_symbol_us)

  player = WavePlayer.new(
    radio,
    WavePlayer::Polarity::Normal,
    config.rf_bit_order,
    config.rf_symbol_us
  )

  config.replay_count.times do |index|
    puts "Replay #{index + 1}/#{config.replay_count}"
    player.play(reference_pulses, 1)
  end

  puts "[PASS] replay complete"
rescue ex
  puts "[FAIL] replay failed: #{ex.message}"
  if trace = ex.backtrace?
    trace.first(8).each { |line| puts "  #{line}" }
  end
  exit 1
ensure
  spi.close
  puts "SPI device closed"
end
