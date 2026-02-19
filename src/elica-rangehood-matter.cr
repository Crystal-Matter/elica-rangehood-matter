module Elica::Rangehood
  VERSION = "0.1.0"

  SPI_DEVICE   = ENV["SPI_DEVICE"]? || "/dev/spidev0.0"
  SPI_SPEED_HZ = ENV["SPI_SPEED_HZ"]?.try(&.to_u32) || 50_000_u32
end

require "./elica-rangehood-matter/*"

spi = SpiDevice.new(Elica::Rangehood::SPI_DEVICE, Elica::Rangehood::SPI_SPEED_HZ)
at_exit { spi.close }

radio = CC1101.new(spi)
radio.reset
radio.configure_ook_433

controller = Elica::Rangehood::Control.new(WavePlayer.new(radio))
controller.toggle_light
