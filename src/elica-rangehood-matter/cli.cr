require "option_parser"
require "log"

class Elica::Rangehood::CLI
  Log = ::Log.for("elica_rangehood.cli")

  private struct Config
    property spi_device : String
    property spi_speed_hz : UInt32
    property repeats : Int32
    property code_bits : Int32
    property toggle_light : String
    property fan_up : String
    property fan_down : String
    property fan_off : String
    property storage_file : String
    property log_level : String

    def initialize
      @spi_device = env_string("SPI_DEVICE", "/dev/spidev0.0")
      @spi_speed_hz = env_u32("SPI_SPEED_HZ", 50_000_u32)
      @repeats = env_int("REPEATS", 5)
      @code_bits = env_int("CODE_BITS", 18)
      @toggle_light = env_string("TOGGLE_LIGHT", "00 00 00 00 00 01 FE B5")
      @fan_up = env_string("FAN_UP", "00 00 00 00 00 01 FE 97")
      @fan_down = env_string("FAN_DOWN", "00 00 00 00 00 01 FE 90")
      @fan_off = env_string("FAN_OFF", "00 00 00 00 00 01 FE 95")
      @storage_file = env_string("MATTER_STORAGE_FILE", Elica::Rangehood::MatterDevice::STORAGE_FILE_DEFAULT)
      @log_level = env_string("LOG_LEVEL", "info")
    end

    private def env_string(name : String, default : String) : String
      ENV[name]? || default
    end

    private def env_int(name : String, default : Int32) : Int32
      ENV[name]?.try(&.to_i?) || default
    end

    private def env_u32(name : String, default : UInt32) : UInt32
      ENV[name]?.try(&.to_u32?) || default
    end
  end

  def self.run : Nil
    config = Config.new

    OptionParser.parse do |opts|
      opts.banner = "Usage: elica-rangehood-matter [options]"
      opts.on("--spi-device=PATH", "SPI device path (default #{config.spi_device})") { |value| config.spi_device = value }
      opts.on("--spi-speed=HZ", "SPI speed in Hz (default #{config.spi_speed_hz})") do |value|
        parsed = value.to_u32?
        raise OptionParser::InvalidOption.new("--spi-speed must be a positive integer") unless parsed && parsed > 0
        config.spi_speed_hz = parsed
      end
      opts.on("--repeats=COUNT", "RF repeat count (default #{config.repeats})") do |value|
        parsed = value.to_i?
        raise OptionParser::InvalidOption.new("--repeats must be >= 1") unless parsed && parsed > 0
        config.repeats = parsed
      end
      opts.on("--code-bits=BITS", "CAME key width in bits (default #{config.code_bits})") do |value|
        parsed = value.to_i?
        raise OptionParser::InvalidOption.new("--code-bits must be between 1 and 64") unless parsed && (1..64).includes?(parsed)
        config.code_bits = parsed
      end
      opts.on("--toggle-light=HEX", "CAME key for light toggle") { |value| config.toggle_light = value }
      opts.on("--fan-up=HEX", "CAME key for fan up") { |value| config.fan_up = value }
      opts.on("--fan-down=HEX", "CAME key for fan down") { |value| config.fan_down = value }
      opts.on("--fan-off=HEX", "CAME key for fan off") { |value| config.fan_off = value }
      opts.on("--storage=PATH", "Matter storage path (default #{config.storage_file})") { |value| config.storage_file = value }
      opts.on("--log-level=LEVEL", "Log level: debug|info|warn|error (default #{config.log_level})") { |value| config.log_level = value.downcase }
      opts.on("-h", "--help", "Show help") do
        puts opts
        exit 0
      end
    end

    configure_logging(config.log_level)
    Log.info do
      "starting service spi_device=#{config.spi_device} spi_speed_hz=#{config.spi_speed_hz} " \
      "repeats=#{config.repeats} code_bits=#{config.code_bits} storage=#{config.storage_file}"
    end

    spi = SpiDevice.new(config.spi_device, config.spi_speed_hz)
    begin
      radio = CC1101.new(spi)
      radio.reset
      radio.configure_ook_433

      control = Elica::Rangehood::Control.new(
        WavePlayer.new(radio),
        repeats: config.repeats,
        code_bits: config.code_bits,
        toggle_light_hex: config.toggle_light,
        fan_up_hex: config.fan_up,
        fan_down_hex: config.fan_down,
        fan_off_hex: config.fan_off
      )

      device = Elica::Rangehood::MatterDevice.new(
        control: control,
        storage_file: config.storage_file,
        port: 0
      )

      Process.on_terminate do
        device.shutdown!
      end

      device.start
      device.await_shutdown
    ensure
      spi.close
    end
  end

  private def self.configure_logging(log_level : String) : Nil
    severity = case log_level
               when "debug" then ::Log::Severity::Debug
               when "warn"  then ::Log::Severity::Warn
               when "error" then ::Log::Severity::Error
               else
                 ::Log::Severity::Info
               end

    ::Log.setup(severity, ::Log::IOBackend.new)
  end
end
