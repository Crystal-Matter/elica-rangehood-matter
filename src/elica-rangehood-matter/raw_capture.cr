require "./came_protocol"
require "./waveform_pulse"

module RawCapture
  enum DurationClass
    Gap
    Short
    Long
  end

  record SignatureEntry, level : Bool, duration_class : DurationClass

  def self.parse_samples(path : String) : Array(Int32)
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

  def self.parse_came_key(path : String) : {String, Int32}
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

  def self.split_frames(samples : Array(Int32), gap_threshold_us : Int32 = 8_000) : Array(Array(Int32))
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

  def self.samples_to_pulses(samples : Array(Int32)) : Array(Pulse)
    samples.map { |sample| Pulse.new(level: sample > 0, us: sample.abs.to_u32) }
  end

  def self.signature(samples : Array(Int32), gap_threshold_us : Int32 = 8_000) : Array(SignatureEntry)
    samples.map do |sample|
      SignatureEntry.new(sample > 0, classify_duration(sample.abs, gap_threshold_us))
    end
  end

  def self.signature(pulses : Array(Pulse), gap_threshold_us : Int32 = 8_000) : Array(SignatureEntry)
    pulses.map do |pulse|
      SignatureEntry.new(pulse.level, classify_duration(pulse.us.to_i, gap_threshold_us))
    end
  end

  def self.invert_levels(signature : Array(SignatureEntry)) : Array(SignatureEntry)
    signature.map { |entry| SignatureEntry.new(!entry.level, entry.duration_class) }
  end

  def self.select_came_matching_frames(
    raw_path : String,
    key_path : String,
    gap_threshold_us : Int32 = 8_000,
  ) : {Array(Array(Int32)), Bool}
    key_hex, bits = parse_came_key(key_path)
    expected = signature(CAME::Frame.new(key_hex, bits).pulses, gap_threshold_us)
    expected_inverted = invert_levels(expected)

    frames = split_frames(parse_samples(raw_path), gap_threshold_us)
    candidate_frames = frames.select { |frame| frame.size == expected.size }
    raise "no candidate frames of size #{expected.size} in #{raw_path}" if candidate_frames.empty?

    normal_matches = candidate_frames.select { |frame| signature(frame, gap_threshold_us) == expected }
    inverted_matches = candidate_frames.select { |frame| signature(frame, gap_threshold_us) == expected_inverted }

    if normal_matches.empty? && inverted_matches.empty?
      raise "no frames matched expected CAME signature in #{raw_path}"
    end
    if !normal_matches.empty? && !inverted_matches.empty?
      raise "ambiguous polarity: both normal and inverted signatures matched in #{raw_path}"
    end

    if !normal_matches.empty?
      {normal_matches, false}
    else
      {inverted_matches, true}
    end
  end

  private def self.classify_duration(us : Int32, gap_threshold_us : Int32) : DurationClass
    return DurationClass::Gap if us >= gap_threshold_us
    return DurationClass::Long if us >= 500
    DurationClass::Short
  end
end
