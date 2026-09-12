require "matter"
require "goban"
require "file_utils"
require "log"

class Elica::Rangehood::MatterDevice < Matter::Device
  Log = ::Log.for("elica_rangehood.matter")

  STORAGE_FILE_DEFAULT = "data/elica_rangehood_matter_storage.yml"

  ENDPOINT_FAN   = 1_u16
  ENDPOINT_LIGHT = 2_u16

  FAN_SPEED_MAX = 4_u8

  identity vendor: "Spider-Gazelle", product: "Elica Rangehood",
    vendor_id: Matter::SetupPayload.test_vendor_id,
    product_id: 0xE101_u16,
    discriminator: 0x0E11_u16,
    pin: 20_202_021_u32,
    device_type: Matter::DeviceType::FAN

  endpoint ENDPOINT_FAN, device_type: Matter::DeviceType::FAN do
    cluster Matter::Cluster::OnOff, as: :fan_on_off
    cluster Matter::Cluster::FanControl,
      fan_mode: Matter::Cluster::FanControl::FanMode::Off,
      fan_mode_sequence: Matter::Cluster::FanControl::FanModeSequence::OffLowMedHigh,
      percent_setting: 0_u8,
      percent_current: 0_u8,
      speed_max: FAN_SPEED_MAX,
      feature_map: Matter::Cluster::FanControl::Feature::Step,
      as: :fan_control
    cluster Matter::Cluster::Identify, identify_type: :visible_light
    # The Fan device type requires Groups; the endpoint is rejected without it.
    cluster Matter::Cluster::Groups
    cluster Matter::Cluster::FixedLabel, [Matter::Cluster::LabelStruct.new("name", "Rangehood Fan")]
  end

  endpoint ENDPOINT_LIGHT, device_type: Matter::DeviceType::ON_OFF_LIGHT do
    cluster Matter::Cluster::OnOff, feature_map: :lighting, as: :light_on_off
    cluster Matter::Cluster::Identify, identify_type: :visible_light
    cluster Matter::Cluster::Groups
    cluster Matter::Cluster::FixedLabel, [Matter::Cluster::LabelStruct.new("name", "Rangehood Light")]
  end

  on(:fan_on_off, :state_changed) { |state| handle_fan_on_off(state) }
  # A null percent setting means "no explicit speed"; the rangehood treats that as off.
  on(:fan_control, :percent_setting_changed) { |old_percent, new_percent| handle_fan_percent_change(old_percent, (new_percent || 0).to_i) }
  on(:fan_control, :fan_mode_changed) { |_old_mode, new_mode| handle_fan_mode_change(new_mode) }
  on(:fan_control, :speed_setting_changed) { |old_speed, new_speed| Log.info { "fan speed changed: #{old_speed} -> #{new_speed}" } }
  on(:light_on_off, :state_changed) { |state| handle_light_on_off(state) }

  @control : Elica::Rangehood::Actuator
  @state : Elica::Rangehood::StateMachine
  @state_lock : Mutex = Mutex.new
  @suppress_callbacks : Atomic(Bool) = Atomic(Bool).new(false)

  def initialize(
    @control : Elica::Rangehood::Actuator,
    storage_file : String = STORAGE_FILE_DEFAULT,
    ip_addresses : Array(Socket::IPAddress)? = nil,
    port : Int32 = Matter::Device::DEFAULT_PORT,
  )
    @state = Elica::Rangehood::StateMachine.new(@control)

    directory = File.dirname(storage_file)
    FileUtils.mkdir_p(directory) unless directory.empty?

    super(Matter::Storage::YamlFile.new(storage_file), ip_addresses: ip_addresses, port: port)

    sync_clusters_from_state
  end

  protected def started_commissioning_mode : Nil
    puts "Starting in Commissioning Mode"
    puts "The device is ready to be paired with a Matter controller."
    puts ""
    puts "mDNS Advertisement Active:"
    puts "  Service: _matterc._udp.local"
    puts "  Instance: #{responder.commissioning_instance_name || "<pending>"}"
    puts "  Hostname: #{hostname}"
    puts "  Port: #{port}"
    puts "  Discriminator: #{discriminator}"
    puts ""

    print_qr_code

    manual_code = setup_code
    puts "Setup PIN: #{setup_pin}"
    puts "Manual pairing code: #{manual_code}"
    puts "chip-tool pairing command:"
    puts "  chip-tool pairing code 1 #{manual_code}"
    puts ""
  end

  protected def started_operational_mode : Nil
    puts "Starting in Operational Mode"
    puts "The device is commissioned and ready for use."
    puts ""
  end

  protected def on_started : Nil
    Log.info { "matter device started on UDP port #{port}" }
  end

  protected def on_shutdown : Nil
    Log.info { "matter device stopped" }
  end

  protected def default_ip_addresses : Array(Socket::IPAddress)
    ips = [] of Socket::IPAddress

    begin
      socket = UDPSocket.new(:inet6)
      socket.connect("2606:4700:4700::1111", 53)
      addr = socket.local_address
      socket.close
      ips << Socket::IPAddress.new(addr.address, 0)
    rescue
    end

    begin
      socket = UDPSocket.new(:inet)
      socket.connect("8.8.8.8", 80)
      addr = socket.local_address
      socket.close
      ips << Socket::IPAddress.new(addr.address, 0)
    rescue
    end

    ips << Socket::IPAddress.new("127.0.0.1", 0) if ips.empty?
    ips
  end

  private def handle_light_on_off(new_state : Bool) : Nil
    return if @suppress_callbacks.get

    @state_lock.synchronize do
      @state.light = new_state
      sync_clusters_from_state
    end
  rescue ex
    Log.warn(exception: ex) { "failed to change light state to #{new_state}" }
    @state_lock.synchronize { sync_clusters_from_state }
  end

  private def handle_fan_on_off(new_state : Bool) : Nil
    return if @suppress_callbacks.get

    Log.info { "fan on/off change: new_state=#{new_state} current_step=#{@state.fan_step} last_non_zero=#{@state.fan_last_non_zero_step}" }
    @state_lock.synchronize do
      @state.fan_on = new_state
      sync_clusters_from_state
    end
  rescue ex
    Log.warn(exception: ex) { "failed to change fan power state to #{new_state}" }
    @state_lock.synchronize { sync_clusters_from_state }
  end

  private def handle_fan_percent_change(old_percent : UInt8?, new_percent : Int32) : Nil
    if @suppress_callbacks.get
      Log.debug { "fan percent change suppressed: #{old_percent} -> #{new_percent}" }
      return
    end

    Log.info { "fan percent change: #{old_percent} -> #{new_percent} current_step=#{@state.fan_step}" }
    @state_lock.synchronize do
      @state.fan_percent = new_percent
      Log.info { "fan percent applied: step=#{@state.fan_step} percent=#{@state.fan_percent}" }
      sync_clusters_from_state
    end
  rescue ex
    Log.warn(exception: ex) { "failed to change fan percent to #{new_percent}" }
    @state_lock.synchronize { sync_clusters_from_state }
  end

  private def handle_fan_mode_change(new_mode : Matter::Cluster::FanControl::FanMode) : Nil
    if @suppress_callbacks.get
      Log.debug { "fan mode change suppressed: #{new_mode}" }
      return
    end

    Log.info { "fan mode change: new_mode=#{new_mode} current_step=#{@state.fan_step}" }
    target_step = case new_mode
                  when .off?
                    0
                  when .low?
                    1
                  when .medium?
                    2
                  when .high?
                    4
                  else
                    @state.fan_step > 0 ? @state.fan_step : @state.fan_last_non_zero_step
                  end

    @state_lock.synchronize do
      @state.fan_step = target_step
      sync_clusters_from_state
    end
  rescue ex
    Log.warn(exception: ex) { "failed to change fan mode to #{new_mode}" }
    @state_lock.synchronize { sync_clusters_from_state }
  end

  private def with_suppressed_callbacks(& : -> Nil) : Nil
    @suppress_callbacks.set(true)
    yield
  ensure
    @suppress_callbacks.set(false)
  end

  private def sync_clusters_from_state : Nil
    with_suppressed_callbacks do
      desired_light = @state.light_on?
      light_on_off.on = desired_light if light_on_off.on? != desired_light

      desired_fan_on = @state.fan_step > 0
      fan_on_off.on = desired_fan_on if fan_on_off.on? != desired_fan_on

      desired_percent = @state.fan_percent.to_u8
      fan_control.percent_setting = desired_percent
      fan_control.update_percent_current(desired_percent)
      # Sync speed from percent (speed_max steps mapped to 0-100%)
      desired_speed = (desired_percent.to_f / 100.0 * fan_control.speed_max).round.to_u8
      fan_control.speed_setting = desired_speed
      fan_control.speed_current = desired_speed
      fan_control.fan_mode = fan_mode_for_step(@state.fan_step)
    end
  end

  private def fan_mode_for_step(step : Int32) : Matter::Cluster::FanControl::FanMode
    case step
    when 0
      Matter::Cluster::FanControl::FanMode::Off
    when 1
      Matter::Cluster::FanControl::FanMode::Low
    when 2
      Matter::Cluster::FanControl::FanMode::Medium
    else
      Matter::Cluster::FanControl::FanMode::High
    end
  end

  private def setup_code : String
    Matter::SetupPayload.generate_manual_code(discriminator, setup_pin)
  end

  private def qr_code_payload : String
    Matter::SetupPayload::QRCode.generate_qr_code(
      discriminator: discriminator,
      pin: setup_pin,
      vendor_id: vendor_id,
      product_id: product_id,
      flow: Matter::SetupPayload::QRCode::CommissionFlow::Standard,
      capabilities: Matter::SetupPayload::QRCode::DiscoveryCapability::BLE
    )
  end

  private def print_qr_code : Nil
    payload = qr_code_payload
    qr = Goban::QR.encode_string(payload, Goban::ECC::Level::Low)
    puts "Scan this QR code with your Matter controller app:"
    puts ""
    qr.print_to_console
    puts ""
  rescue ex
    puts "Failed to generate QR code: #{ex.message}"
  end
end
