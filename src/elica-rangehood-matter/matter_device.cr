require "matter"
require "goban"
require "file_utils"
require "log"

class Elica::Rangehood::MatterDevice < Matter::Device::Base
  Log = ::Log.for("elica_rangehood.matter")

  DEVICE_NAME = "Elica Rangehood"

  STORAGE_FILE_DEFAULT = "data/elica_rangehood_matter_storage.json"

  VENDOR_ID      = Matter::SetupPayload.test_vendor_id
  PRODUCT_ID     =     0xE101_u16
  DISCRIMINATOR  =     0x0E11_u16
  SETUP_PIN_CODE = 20_202_021_u32

  ENDPOINT_FAN   = 1_u16
  ENDPOINT_LIGHT = 2_u16

  @control : Elica::Rangehood::Actuator
  @storage_file : String
  @state : Elica::Rangehood::StateMachine
  @state_lock : Mutex = Mutex.new
  @suppress_callbacks : Atomic(Bool) = Atomic(Bool).new(false)

  @fan_on_off : Matter::Cluster::OnOffCluster? = nil
  @fan_control : Matter::Cluster::FanControlCluster? = nil
  @light_on_off : Matter::Cluster::OnOffCluster? = nil

  def initialize(
    @control : Elica::Rangehood::Actuator,
    @storage_file : String = STORAGE_FILE_DEFAULT,
    ip_addresses : Array(Socket::IPAddress)? = nil,
    port : Int32 = 0,
  )
    @state = Elica::Rangehood::StateMachine.new(@control)
    super(ip_addresses: ip_addresses, port: port)
  end

  def device_name : String
    DEVICE_NAME
  end

  def vendor_id : UInt16
    VENDOR_ID
  end

  def product_id : UInt16
    PRODUCT_ID
  end

  def discriminator : UInt16
    DISCRIMINATOR
  end

  def setup_pin : UInt32
    SETUP_PIN_CODE
  end

  def primary_device_type_id : UInt16
    Matter::DeviceTypes::FAN
  end

  def vendor_name : String
    "Spider-Gazelle"
  end

  def product_name : String
    device_name
  end

  def fan_on_off_cluster : Matter::Cluster::OnOffCluster
    @fan_on_off.as(Matter::Cluster::OnOffCluster)
  end

  def fan_control_cluster : Matter::Cluster::FanControlCluster
    @fan_control.as(Matter::Cluster::FanControlCluster)
  end

  def light_on_off_cluster : Matter::Cluster::OnOffCluster
    @light_on_off.as(Matter::Cluster::OnOffCluster)
  end

  protected def build_storage_manager : Matter::Storage::Manager
    directory = File.dirname(@storage_file)
    FileUtils.mkdir_p(directory) unless directory.empty?
    Matter::Storage::Manager.new(Matter::Storage::JsonFileBackend.new(@storage_file))
  end

  protected def endpoint_device_types : Hash(UInt16, UInt32)
    {
      ENDPOINT_FAN   => Matter::DeviceTypes::FAN.to_u32,
      ENDPOINT_LIGHT => Matter::DeviceTypes::ON_OFF_LIGHT.to_u32,
    } of UInt16 => UInt32
  end

  protected def device_clusters : Array(Matter::Cluster::Base)
    clusters = [] of Matter::Cluster::Base

    fan_endpoint = Matter::DataType::EndpointNumber.new(ENDPOINT_FAN)
    @fan_on_off = Matter::Cluster::OnOffCluster.new(fan_endpoint)
    @fan_control = Matter::Cluster::FanControlCluster.new(
      fan_endpoint,
      fan_mode: Matter::Cluster::FanControlCluster::FanMode::Off,
      fan_mode_sequence: Matter::Cluster::FanControlCluster::FanModeSequence::OffLowMedHigh,
      percent_setting: 0_u8,
      percent_current: 0_u8
    )
    fan_on_off_cluster.on_state_changed { |state| handle_fan_on_off(state) }
    fan_control_cluster.on_percent_changed { |_old_percent, new_percent| handle_fan_percent_change(new_percent.to_i) }
    fan_control_cluster.on_fan_mode_changed { |_old_mode, new_mode| handle_fan_mode_change(new_mode) }

    clusters.concat(
      [
        fan_on_off_cluster.as(Matter::Cluster::Base),
        fan_control_cluster.as(Matter::Cluster::Base),
        Matter::Cluster::IdentifyCluster.new(
          fan_endpoint,
          identify_type: Matter::Cluster::IdentifyCluster::IdentifyType::VisibleLight
        ).as(Matter::Cluster::Base),
        Matter::Cluster::FixedLabelCluster.new(
          fan_endpoint,
          [Matter::Cluster::LabelStruct.new("name", "Rangehood Fan")]
        ).as(Matter::Cluster::Base),
      ]
    )

    light_endpoint = Matter::DataType::EndpointNumber.new(ENDPOINT_LIGHT)
    @light_on_off = Matter::Cluster::OnOffCluster.new(
      light_endpoint,
      feature_map: Matter::Cluster::OnOffCluster::Feature::Lighting
    )
    light_on_off_cluster.on_state_changed { |state| handle_light_on_off(state) }

    clusters.concat(
      [
        light_on_off_cluster.as(Matter::Cluster::Base),
        Matter::Cluster::IdentifyCluster.new(
          light_endpoint,
          identify_type: Matter::Cluster::IdentifyCluster::IdentifyType::VisibleLight
        ).as(Matter::Cluster::Base),
        Matter::Cluster::FixedLabelCluster.new(
          light_endpoint,
          [Matter::Cluster::LabelStruct.new("name", "Rangehood Light")]
        ).as(Matter::Cluster::Base),
      ]
    )

    sync_clusters_from_state
    clusters
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

    @state_lock.synchronize do
      @state.fan_on = new_state
      sync_clusters_from_state
    end
  rescue ex
    Log.warn(exception: ex) { "failed to change fan power state to #{new_state}" }
    @state_lock.synchronize { sync_clusters_from_state }
  end

  private def handle_fan_percent_change(new_percent : Int32) : Nil
    return if @suppress_callbacks.get

    @state_lock.synchronize do
      @state.fan_percent = new_percent
      sync_clusters_from_state
    end
  rescue ex
    Log.warn(exception: ex) { "failed to change fan percent to #{new_percent}" }
    @state_lock.synchronize { sync_clusters_from_state }
  end

  private def handle_fan_mode_change(new_mode : Matter::Cluster::FanControlCluster::FanMode) : Nil
    return if @suppress_callbacks.get

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
      light_on_off_cluster.on = desired_light if light_on_off_cluster.on? != desired_light

      desired_fan_on = @state.fan_step > 0
      fan_on_off_cluster.on = desired_fan_on if fan_on_off_cluster.on? != desired_fan_on

      desired_percent = @state.fan_percent.to_u8
      fan_control_cluster.percent_setting = desired_percent
      fan_control_cluster.update_percent_current(desired_percent)
      fan_control_cluster.fan_mode = fan_mode_for_step(@state.fan_step)
    end
  end

  private def fan_mode_for_step(step : Int32) : Matter::Cluster::FanControlCluster::FanMode
    case step
    when 0
      Matter::Cluster::FanControlCluster::FanMode::Off
    when 1
      Matter::Cluster::FanControlCluster::FanMode::Low
    when 2
      Matter::Cluster::FanControlCluster::FanMode::Medium
    else
      Matter::Cluster::FanControlCluster::FanMode::High
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
