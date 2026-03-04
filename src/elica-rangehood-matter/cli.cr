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
    property? hardware_test : Bool

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
      @hardware_test = false
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
      opts.on("--hardware-test", "Run hardware diagnostics and exit") { config.hardware_test = true }
      opts.on("-h", "--help", "Show help") do
        puts opts
        exit 0
      end
    end

    configure_logging(config.log_level)
    if config.hardware_test?
      run_hardware_test(config)
      return
    end

    Log.info do
      "starting service spi_device=#{config.spi_device} spi_speed_hz=#{config.spi_speed_hz} " \
      "repeats=#{config.repeats} code_bits=#{config.code_bits} storage=#{config.storage_file}"
    end

    run_service(config)
  end

  private def self.run_service(config : Config) : Nil
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

  private def self.run_hardware_test(config : Config) : Nil
    puts "Hardware test mode enabled"
    puts "SPI device: #{config.spi_device}"
    puts "SPI speed (Hz): #{config.spi_speed_hz}"
    puts ""

    started_at = Time.instant
    spi : SpiDevice? = nil
    begin
      spi = SpiDevice.new(config.spi_device, config.spi_speed_hz)
      spi_device = spi.as(SpiDevice)
      puts "[1/8] SPI device opened"

      radio = CC1101.new(spi_device)
      puts "[2/8] CC1101 driver initialized"

      radio.reset
      puts "[3/8] CC1101 reset command sent"

      partnum = radio.partnum
      raise "unexpected PARTNUM 0x#{hex_u8(partnum)} (expected 0x#{hex_u8(CC1101::EXPECTED_PARTNUM)})" if partnum != CC1101::EXPECTED_PARTNUM

      version = radio.version
      current_state = radio.state
      puts "[4/8] CC1101 detected (PARTNUM=0x#{hex_u8(partnum)}, VERSION=0x#{hex_u8(version)}, state=0x#{hex_u8(current_state)})"

      radio.configure_ook_433
      puts "[5/8] CC1101 configured for OOK 433.92MHz"

      assert_register(radio, CC1101::FREQ2, 0x10_u8, "FREQ2")
      assert_register(radio, CC1101::FREQ1, 0xB0_u8, "FREQ1")
      assert_register(radio, CC1101::FREQ0, 0x71_u8, "FREQ0")
      assert_register(radio, CC1101::MDMCFG2, 0x30_u8, "MDMCFG2")
      puts "[6/8] CC1101 register readback passed"

      validate_came_config("toggle-light", config.toggle_light, config.code_bits)
      validate_came_config("fan-up", config.fan_up, config.code_bits)
      validate_came_config("fan-down", config.fan_down, config.code_bits)
      validate_came_config("fan-off", config.fan_off, config.code_bits)
      puts "[7/8] CAME frame parsing/encoding passed"

      wave_player = WavePlayer.new(radio)
      diagnostic_pulses = [
        Pulse.new(level: false, us: CAME::T_US),
        Pulse.new(level: true, us: CAME::T_US),
        Pulse.new(level: false, us: CAME::T_US * 2),
        Pulse.new(level: true, us: CAME::T_US),
        Pulse.new(level: false, us: CAME::GAP_US),
      ]
      wave_player.play(diagnostic_pulses, 1)
      puts "[8/8] Waveform encoding/transmit test packet sent"

      elapsed_ms = (Time.instant - started_at).total_milliseconds
      puts ""
      puts "[PASS] Hardware diagnostics completed in #{elapsed_ms.round(1)} ms"
    rescue ex
      puts ""
      puts "[FAIL] Hardware diagnostics failed: #{ex.message}"
      if trace = ex.backtrace?
        trace.first(8).each { |line| puts "  #{line}" }
      end
      exit 1
    ensure
      spi.try &.close
      puts "SPI device closed" if spi
    end
  end

  private def self.validate_came_config(label : String, key : String, code_bits : Int32) : Nil
    frame = CAME::Frame.new(key, code_bits)
    raise "#{label} CAME pulse sequence is empty" if frame.pulses.empty?
  end

  private def self.assert_register(radio : CC1101, address : UInt8, expected : UInt8, name : String) : Nil
    actual = radio.read_reg(address)
    return if actual == expected

    raise "#{name} readback mismatch: expected 0x#{hex_u8(expected)}, got 0x#{hex_u8(actual)}"
  end

  private def self.hex_u8(value : UInt8) : String
    value.to_s(16).upcase.rjust(2, '0')
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
