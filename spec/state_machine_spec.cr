require "./spec_helper"

private class FakeActuator
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

describe Elica::Rangehood::StateMachine do
  it "only toggles light when desired state changes" do
    actuator = FakeActuator.new
    state = Elica::Rangehood::StateMachine.new(actuator)

    state.light = false
    state.light = true
    state.light = true
    state.light = false

    actuator.calls.should eq(["toggle_light", "toggle_light"])
  end

  it "maps percentages to fan steps and uses up/down transitions" do
    actuator = FakeActuator.new
    state = Elica::Rangehood::StateMachine.new(actuator)

    state.fan_percent = 10 # step 1
    state.fan_step.should eq(1)

    state.fan_percent = 70 # step 3, +2
    state.fan_step.should eq(3)

    state.fan_percent = 20 # step 1, -2
    state.fan_step.should eq(1)

    actuator.calls.should eq(["fan_up", "fan_up", "fan_up", "fan_down", "fan_down"])
  end

  it "uses fan_off exactly once when transitioning to 0%" do
    actuator = FakeActuator.new
    state = Elica::Rangehood::StateMachine.new(actuator)

    state.fan_percent = 100 # step 4
    state.fan_percent = 0
    state.fan_percent = 0

    actuator.calls.count("fan_off").should eq(1)
    state.fan_step.should eq(0)
  end
end
