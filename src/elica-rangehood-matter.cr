module Elica::Rangehood
  VERSION = "0.1.0"

  GPIO_PIN = ENV["GPIO_PIN"]?.try(&.to_u32) || 17_u32
end

require "./elica-rangehood-matter/*"

daemon = PigpioDaemon.new
at_exit { daemon.close }

controller = Elica::Rangehood::Control.new(daemon, Elica::Rangehood::GPIO_PIN)
controller.toggle_light
