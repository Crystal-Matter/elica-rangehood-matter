require "option_parser"
require "log"

class Elica::Rangehood::CLI
  Log = ::Log.for("elica_rangehood.cli")

  private struct Config
    enum BitOrderSetting
      Msb
      Lsb
    end

    property spi_device : String
    property spi_speed_hz : UInt32
    property rf_frequency_hz : UInt32
    property rf_symbol_us : UInt32
    property rf_bit_order : BitOrderSetting
    property rf_carrier_test_seconds : Int32
    property repeats : Int32
    property code_bits : Int32
    property toggle_light : String
    property fan_up : String
    property fan_down : String
    property fan_off : String
    property storage_file : String
    property log_level : String
    property? hardware_test : Bool
    property? invert_waveform : Bool

    def initialize
      @spi_device = env_string("SPI_DEVICE", "/dev/spidev0.0")
      @spi_speed_hz = env_u32("SPI_SPEED_HZ", 50_000_u32)
      @rf_frequency_hz = env_u32("RF_FREQUENCY_HZ", CC1101::DEFAULT_FREQUENCY_HZ)
      @rf_symbol_us = env_u32("RF_SYMBOL_US", WavePlayer::DEFAULT_SYMBOL_US)
      @rf_bit_order = env_bit_order("RF_BIT_ORDER", BitOrderSetting::Msb)
      @rf_carrier_test_seconds = env_int("RF_CARRIER_TEST_SECONDS", 0)
      @repeats = env_int("REPEATS", 5)
      @code_bits = env_int("CODE_BITS", 18)
      @toggle_light = env_string("TOGGLE_LIGHT", "00 00 00 00 00 01 FE B5")
      @fan_up = env_string("FAN_UP", "00 00 00 00 00 01 FE 97")
      @fan_down = env_string("FAN_DOWN", "00 00 00 00 00 01 FE 90")
      @fan_off = env_string("FAN_OFF", "00 00 00 00 00 01 FE 95")
      @storage_file = env_string("MATTER_STORAGE_FILE", Elica::Rangehood::MatterDevice::STORAGE_FILE_DEFAULT)
      @log_level = env_string("LOG_LEVEL", "info")
      @hardware_test = false
      @invert_waveform = env_bool("INVERT_WAVEFORM", false)
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

    private def env_bool(name : String, default : Bool) : Bool
      value = ENV[name]?
      return default unless value

      case value.downcase
      when "1", "true", "yes", "on"
        true
      when "0", "false", "no", "off"
        false
      else
        default
      end
    end

    private def env_bit_order(name : String, default : BitOrderSetting) : BitOrderSetting
      value = ENV[name]?
      return default unless value

      parse_bit_order(value) || default
    end

    private def parse_bit_order(value : String) : BitOrderSetting?
      case value.downcase
      when "msb", "msb-first", "msb_first"
        BitOrderSetting::Msb
      when "lsb", "lsb-first", "lsb_first"
        BitOrderSetting::Lsb
      else
        nil
      end
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
      opts.on("--rf-frequency=HZ", "RF carrier frequency in Hz (default #{config.rf_frequency_hz})") do |value|
        parsed = value.to_u32?
        raise OptionParser::InvalidOption.new("--rf-frequency must be a positive integer") unless parsed && parsed > 0
        config.rf_frequency_hz = parsed
      end
      opts.on("--rf-symbol-us=MICROS", "Waveform symbol duration in microseconds (default #{config.rf_symbol_us})") do |value|
        parsed = value.to_u32?
        raise OptionParser::InvalidOption.new("--rf-symbol-us must be a positive integer") unless parsed && parsed > 0
        config.rf_symbol_us = parsed
      end
      opts.on("--rf-bit-order=ORDER", "RF packet bit order: msb|lsb (default #{config.rf_bit_order.to_s.downcase})") do |value|
        parsed = parse_bit_order(value)
        raise OptionParser::InvalidOption.new("--rf-bit-order must be one of: msb, lsb") unless parsed
        config.rf_bit_order = parsed
      end
      opts.on("--rf-carrier-test-seconds=SECONDS", "Transmit high-duty RF carrier packets for N seconds and exit") do |value|
        parsed = value.to_i?
        raise OptionParser::InvalidOption.new("--rf-carrier-test-seconds must be >= 1") unless parsed && parsed > 0
        config.rf_carrier_test_seconds = parsed
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
      opts.on("--invert-waveform", "Invert waveform levels before RF transmit") { config.invert_waveform = true }
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
    if config.rf_carrier_test_seconds > 0
      run_rf_carrier_test(config)
      return
    end

    Log.info do
      "starting service spi_device=#{config.spi_device} spi_speed_hz=#{config.spi_speed_hz} " \
      "rf_frequency_hz=#{config.rf_frequency_hz} " \
      "rf_symbol_us=#{config.rf_symbol_us} rf_bit_order=#{config.rf_bit_order.to_s.downcase} " \
      "repeats=#{config.repeats} code_bits=#{config.code_bits} storage=#{config.storage_file} " \
      "waveform_polarity=#{waveform_polarity(config).to_s.downcase}"
    end

    run_service(config)
  end

  private def self.run_service(config : Config) : Nil
    spi = SpiDevice.new(config.spi_device, config.spi_speed_hz)
    begin
      radio = CC1101.new(spi)
      radio.reset
      radio.configure_ook(config.rf_frequency_hz, config.rf_symbol_us)

      wave_player = WavePlayer.new(
        radio,
        waveform_polarity(config),
        waveform_bit_order(config),
        config.rf_symbol_us
      )
      control = Elica::Rangehood::Control.new(
        wave_player,
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
    puts "RF frequency (Hz): #{config.rf_frequency_hz}"
    puts "RF symbol (us): #{config.rf_symbol_us}"
    puts "RF bit order: #{config.rf_bit_order.to_s.downcase}"
    puts "Waveform polarity: #{waveform_polarity(config).to_s.downcase}"
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

      radio.configure_ook(config.rf_frequency_hz, config.rf_symbol_us)
      puts "[5/8] CC1101 configured for OOK at #{config.rf_frequency_hz} Hz"

      expected_freq2, expected_freq1, expected_freq0 = frequency_register_values(config.rf_frequency_hz)
      expected_mdmcfg4, expected_mdmcfg3 = data_rate_register_values(config.rf_symbol_us)

      assert_register(radio, CC1101::FREQ2, expected_freq2, "FREQ2")
      assert_register(radio, CC1101::FREQ1, expected_freq1, "FREQ1")
      assert_register(radio, CC1101::FREQ0, expected_freq0, "FREQ0")
      assert_register(radio, CC1101::MDMCFG4, expected_mdmcfg4, "MDMCFG4")
      assert_register(radio, CC1101::MDMCFG3, expected_mdmcfg3, "MDMCFG3")
      assert_register(radio, CC1101::MDMCFG2, 0x30_u8, "MDMCFG2")
      assert_register(radio, CC1101::MDMCFG1, 0x00_u8, "MDMCFG1")
      assert_register(radio, CC1101::PKTCTRL1, 0x00_u8, "PKTCTRL1")
      assert_register(radio, CC1101::PKTCTRL0, 0x00_u8, "PKTCTRL0")
      assert_register(radio, CC1101::FSCTRL1, 0x06_u8, "FSCTRL1")
      assert_register(radio, CC1101::MCSM0, 0x18_u8, "MCSM0")
      assert_register(radio, CC1101::MCSM1, 0x30_u8, "MCSM1")
      assert_register(radio, CC1101::FREND0, 0x11_u8, "FREND0")
      assert_register(radio, CC1101::DEVIATN, 0x00_u8, "DEVIATN")
      puts "[6/8] CC1101 register readback passed"

      validate_came_config("toggle-light", config.toggle_light, config.code_bits)
      validate_came_config("fan-up", config.fan_up, config.code_bits)
      validate_came_config("fan-down", config.fan_down, config.code_bits)
      validate_came_config("fan-off", config.fan_off, config.code_bits)
      puts "[7/8] CAME frame parsing/encoding passed"

      wave_player = WavePlayer.new(
        radio,
        waveform_polarity(config),
        waveform_bit_order(config),
        config.rf_symbol_us
      )

      # Send a square wave test pattern: alternating 0xAA bytes = alternating ON/OFF
      # at the configured data rate. Easy to verify on Flipper:
      # expect equal-length ON/OFF pulses of symbol_us duration.
      puts "       Sending square wave test (0xAA * 8 bytes)..."
      square_wave = Bytes.new(8, 0xAA_u8)
      radio.transmit(square_wave)
      sleep 50.milliseconds

      # Send actual CAME toggle-light frame
      puts "       Sending CAME toggle-light frame..."
      frame = CAME::Frame.new(config.toggle_light, config.code_bits)
      wave_player.play(frame.pulses, 1)
      puts "[8/8] RF test packets sent (square wave + CAME frame)"

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

  private def self.run_rf_carrier_test(config : Config) : Nil
    puts "RF carrier test mode enabled"
    puts "SPI device: #{config.spi_device}"
    puts "SPI speed (Hz): #{config.spi_speed_hz}"
    puts "RF frequency (Hz): #{config.rf_frequency_hz}"
    puts "RF symbol (us): #{config.rf_symbol_us}"
    puts "Duration (s): #{config.rf_carrier_test_seconds}"
    puts ""

    started_at = Time.instant
    spi = SpiDevice.new(config.spi_device, config.spi_speed_hz)
    begin
      radio = CC1101.new(spi)
      radio.reset
      radio.configure_ook(config.rf_frequency_hz, config.rf_symbol_us)

      packet = Bytes.new(64, 0xFF_u8)
      deadline = Time.instant + config.rf_carrier_test_seconds.seconds
      packets_sent = 0

      while Time.instant < deadline
        radio.transmit(packet)
        packets_sent += 1
      end

      elapsed_s = (Time.instant - started_at).total_seconds
      puts "[PASS] Sent #{packets_sent} high-carrier packets in #{elapsed_s.round(2)} s"
    rescue ex
      puts "[FAIL] RF carrier test failed: #{ex.message}"
      if trace = ex.backtrace?
        trace.first(8).each { |line| puts "  #{line}" }
      end
      exit 1
    ensure
      spi.close
      puts "SPI device closed"
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

  private def self.waveform_polarity(config : Config) : WavePlayer::Polarity
    config.invert_waveform? ? WavePlayer::Polarity::Inverted : WavePlayer::Polarity::Normal
  end

  private def self.waveform_bit_order(config : Config) : WavePlayer::BitOrder
    config.rf_bit_order.lsb? ? WavePlayer::BitOrder::LsbFirst : WavePlayer::BitOrder::MsbFirst
  end

  private def self.frequency_register_values(frequency_hz : UInt32) : Tuple(UInt8, UInt8, UInt8)
    fxosc_hz = 26_000_000_u64
    word = (((frequency_hz.to_u64 * (1_u64 << 16)) + (fxosc_hz // 2)) // fxosc_hz).to_u32
    {
      ((word >> 16) & 0xFF).to_u8,
      ((word >> 8) & 0xFF).to_u8,
      (word & 0xFF).to_u8,
    }
  end

  private def self.data_rate_register_values(symbol_us : UInt32) : Tuple(UInt8, UInt8)
    target_baud = 1_000_000.0 / symbol_us

    best_error = Float64::INFINITY
    best_mdmcfg4 = 0_u8
    best_mdmcfg3 = 0_u8

    0_u8.upto(15_u8) do |drate_e|
      0_u8.upto(255_u8) do |drate_m|
        actual_baud = ((256.0 + drate_m) * (2.0 ** drate_e) * 26_000_000.0) / (2.0 ** 28)
        error = (actual_baud - target_baud).abs
        next unless error < best_error

        best_error = error
        best_mdmcfg4 = drate_e
        best_mdmcfg3 = drate_m
      end
    end

    {best_mdmcfg4, best_mdmcfg3}
  end

  private def self.parse_bit_order(value : String) : Config::BitOrderSetting?
    case value.downcase
    when "msb", "msb-first", "msb_first"
      Config::BitOrderSetting::Msb
    when "lsb", "lsb-first", "lsb_first"
      Config::BitOrderSetting::Lsb
    else
      nil
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
