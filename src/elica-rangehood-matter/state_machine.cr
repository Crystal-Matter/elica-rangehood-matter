require "log"

class Elica::Rangehood::StateMachine
  Log = ::Log.for("elica_rangehood.state_machine")

  getter? light_on : Bool
  getter fan_step : Int32
  getter fan_last_non_zero_step : Int32

  def initialize(
    @actuator : Elica::Rangehood::Actuator,
    @light_on : Bool = false,
    initial_fan_step : Int32 = 0,
  )
    @fan_step = clamp_step(initial_fan_step)
    @fan_last_non_zero_step = @fan_step > 0 ? @fan_step : 1
  end

  def fan_percent : Int32
    step_to_percent(@fan_step)
  end

  def light=(desired_on : Bool) : Nil
    return if desired_on == @light_on

    @actuator.toggle_light
    @light_on = desired_on
  end

  def fan_on=(enabled : Bool) : Nil
    if enabled
      target = @fan_step > 0 ? @fan_step : @fan_last_non_zero_step
      self.fan_step = target
    else
      self.fan_step = 0
    end
  end

  def fan_percent=(percent : Int32) : Nil
    step = percent_to_step(percent)
    Log.info { "fan_percent=#{percent} -> step=#{step} (current=#{@fan_step})" }
    self.fan_step = step
  end

  def fan_step=(step : Int32) : Nil
    target = clamp_step(step)
    return if target == @fan_step

    if target == 0
      Log.info { "fan_step #{@fan_step} -> 0 (fan_off)" }
      @actuator.fan_off if @fan_step > 0
      @fan_step = 0
      return
    end

    delta = target - @fan_step
    if delta > 0
      Log.info { "fan_step #{@fan_step} -> #{target} (fan_up x#{delta})" }
      @actuator.fan_up(delta)
    else
      Log.info { "fan_step #{@fan_step} -> #{target} (fan_down x#{-delta})" }
      @actuator.fan_down(-delta)
    end

    @fan_step = target
    @fan_last_non_zero_step = target
  end

  private def percent_to_step(percent : Int32) : Int32
    clamped = percent.clamp(0, 100)
    return 0 if clamped == 0

    ((clamped - 1) // 25) + 1
  end

  private def step_to_percent(step : Int32) : Int32
    case clamp_step(step)
    when 0
      0
    when 1
      25
    when 2
      50
    when 3
      75
    else
      100
    end
  end

  private def clamp_step(step : Int32) : Int32
    step.clamp(0, 4)
  end
end
