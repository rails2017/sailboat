require "aws-sdk"
require "erb"
require "yaml"

module Sailboat
  class Application

    def initialize(options = {})
      @options = options.inject({}) { |m, (k, v)| m[k.to_sym] = v; m }
    end

  end
end
