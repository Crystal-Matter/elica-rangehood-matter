module Elica::Rangehood
  VERSION = "0.1.0"
end

require "./elica-rangehood-matter/*"

Elica::Rangehood::CLI.run
