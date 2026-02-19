require "./spec_helper"

private class FakeMatterActuator
  include Elica::Rangehood::Actuator

  getter calls = [] of String

  def toggle_light : Nil
    @calls << "toggle_light"
  end

  def fan_up : Nil
    @calls << "fan_up"
  end

  def fan_down : Nil
    @calls << "fan_down"
  end

  def fan_off : Nil
    @calls << "fan_off"
  end
end

private def build_device(actuator : FakeMatterActuator, storage_file : String) : Elica::Rangehood::MatterDevice
  File.delete?(storage_file)
  Elica::Rangehood::MatterDevice.new(
    control: actuator,
    storage_file: storage_file,
    ip_addresses: [Socket::IPAddress.new("127.0.0.1", 0)],
    port: 0
  )
end

describe Elica::Rangehood::MatterDevice do
  it "toggles the light only when the requested state changes" do
    actuator = FakeMatterActuator.new
    device = build_device(actuator, "/tmp/spec_elica_matter_light.json")

    begin
      device.light_on_off_cluster.on = false
      device.light_on_off_cluster.on = true
      device.light_on_off_cluster.on = true
      device.light_on_off_cluster.on = false

      actuator.calls.should eq(["toggle_light", "toggle_light"])
    ensure
      device.shutdown!
    end
  end

  it "maps fan percent changes to 25% step up/down commands and fan_off at 0%" do
    actuator = FakeMatterActuator.new
    device = build_device(actuator, "/tmp/spec_elica_matter_fan_percent.json")

    begin
      fan = device.fan_control_cluster
      fan.write_attribute(Matter::Cluster::FanControlCluster::ATTR_PERCENT_SETTING, Bytes[10_u8])
      fan.write_attribute(Matter::Cluster::FanControlCluster::ATTR_PERCENT_SETTING, Bytes[70_u8])
      fan.write_attribute(Matter::Cluster::FanControlCluster::ATTR_PERCENT_SETTING, Bytes[20_u8])
      fan.write_attribute(Matter::Cluster::FanControlCluster::ATTR_PERCENT_SETTING, Bytes[0_u8])
      fan.write_attribute(Matter::Cluster::FanControlCluster::ATTR_PERCENT_SETTING, Bytes[0_u8])

      actuator.calls.should eq(["fan_up", "fan_up", "fan_up", "fan_down", "fan_down", "fan_off"])
      device.fan_on_off_cluster.on?.should be_false
    ensure
      device.shutdown!
    end
  end

  it "restores the last non-zero fan step when turning the fan back on" do
    actuator = FakeMatterActuator.new
    device = build_device(actuator, "/tmp/spec_elica_matter_fan_on_off.json")

    begin
      fan = device.fan_control_cluster
      fan.write_attribute(Matter::Cluster::FanControlCluster::ATTR_PERCENT_SETTING, Bytes[70_u8])
      device.fan_on_off_cluster.on = false
      device.fan_on_off_cluster.on = true

      actuator.calls.should eq(["fan_up", "fan_up", "fan_up", "fan_off", "fan_up", "fan_up", "fan_up"])
      device.fan_on_off_cluster.on?.should be_true
      device.fan_control_cluster.percent_current.should eq(75_u8)
    ensure
      device.shutdown!
    end
  end
end
