require "./spec_helper"

private enum PulseDurationClass
  Gap
  Short
  Long
end

private struct PulseSignature
  getter? level : Bool
  getter duration_class : PulseDurationClass

  def initialize(@level : Bool, @duration_class : PulseDurationClass)
  end
end

private def parse_raw_capture(path : String) : Array(Int32)
  samples = [] of Int32

  File.each_line(path) do |line|
    next unless line.starts_with?("RAW_Data:")

    payload = line["RAW_Data:".size..-1]? || ""
    payload.split(/\s+/).each do |token|
      next if token.empty?
      samples << token.to_i
    end
  end

  samples
end

private def parse_came_key(path : String) : {String, Int32}
  key : String? = nil
  bits : Int32? = nil

  File.each_line(path) do |line|
    if line.starts_with?("Key:")
      key = (line["Key:".size..-1]? || "").strip
    elsif line.starts_with?("Bit:")
      bits = (line["Bit:".size..-1]? || "").strip.to_i
    end
  end

  parsed_key = key || raise "missing Key field in #{path}"
  parsed_bits = bits || raise "missing Bit field in #{path}"
  {parsed_key, parsed_bits}
end

private def split_frames(samples : Array(Int32), gap_threshold_us : Int32 = 8_000) : Array(Array(Int32))
  frames = [] of Array(Int32)

  i = 0
  while i < samples.size
    if samples[i].abs >= gap_threshold_us
      frame = [] of Int32
      frame << samples[i]
      i += 1

      while i < samples.size && samples[i].abs < gap_threshold_us
        frame << samples[i]
        i += 1
      end

      frames << frame
    else
      i += 1
    end
  end

  frames
end

private def classify_duration(us : Int32) : PulseDurationClass
  return PulseDurationClass::Gap if us >= 8_000
  return PulseDurationClass::Long if us >= 500
  PulseDurationClass::Short
end

private def to_signature(samples : Array(Int32)) : Array(PulseSignature)
  samples.map do |sample|
    PulseSignature.new(sample > 0, classify_duration(sample.abs))
  end
end

private def to_signature(pulses : Array(Pulse)) : Array(PulseSignature)
  pulses.map do |pulse|
    PulseSignature.new(pulse.level, classify_duration(pulse.us.to_i))
  end
end

private def invert_levels(signature : Array(PulseSignature)) : Array(PulseSignature)
  signature.map { |entry| PulseSignature.new(!entry.level?, entry.duration_class) }
end

describe "raw capture waveform compatibility" do
  {
    "captures/Raw_light_toggle.sub" => "captures/Light_toggle.sub",
    "captures/Raw_fan_up.sub"       => "captures/Fan_up.sub",
    "captures/Raw_fan_down.sub"     => "captures/Fan_down.sub",
  }.each do |raw_path, key_path|
    it "matches generated CAME pulse signature for #{raw_path}" do
      key_hex, bits = parse_came_key(key_path)
      expected = to_signature(CAME::Frame.new(key_hex, bits).pulses)
      expected_inverted = invert_levels(expected)

      frames = split_frames(parse_raw_capture(raw_path))
      candidate_frames = frames.select { |frame| frame.size == expected.size }
      candidate_frames.empty?.should be_false

      candidate_signatures = candidate_frames.map { |frame| to_signature(frame) }
      matched_expected = candidate_signatures.any? { |actual| actual == expected }
      matched_inverted = candidate_signatures.any? { |actual| actual == expected_inverted }

      matched_expected.should be_true
      matched_inverted.should be_false
    end
  end
end
