require "active_support/all"
require "aws-sdk"
require "thor/group"

module Shiprails
  class Ship < Thor
    class Exec < Thor::Group
      include Thor::Actions

      class_option "path",
        aliases: ["-p"],
        default: ".",
        desc: "Specify a configuration path"

      def run_command(command)
        say "TODO: run one-off: #{command}"
      end

      private

      def configuration
        YAML.load File.read "#{options[:path]}/.shiprails.yml"
      end

      def aws_access_key_id
        @aws_access_key_id ||= ask "AWS Access Key ID", default: ENV.fetch("AWS_ACCESS_KEY_ID")
      end

      def aws_access_key_secret
        @aws_access_key_secret ||= ask "AWS Access Key Secret", default: ENV.fetch("AWS_SECRET_ACCESS_KEY")
      end

    end
  end
end
