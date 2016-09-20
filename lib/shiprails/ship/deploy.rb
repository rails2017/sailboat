require "active_support/all"
require "aws-sdk"
require "thor/group"

module Shiprails
  class Ship < Thor
    class Deploy < Thor::Group
      include Thor::Actions

      class_option "path",
        aliases: ["-p"],
        default: ".",
        desc: "Specify a configuration path"

      def build_docker_images
        say "TODO: build docker images"
      end

      def push_docker_images
        say "TODO: push docker images"
      end

      def update_ecs_services
        say "TODO: update ECS task + service definitions"
      end

      no_commands {
        def aws_access_key_id
          @aws_access_key_id ||= ask "AWS Access Key ID", default: ENV.fetch("AWS_ACCESS_KEY_ID")
        end

        def aws_access_key_secret
          @aws_access_key_secret ||= ask "AWS Access Key Secret", default: ENV.fetch("AWS_ACCESS_KEY_SECRET")
        end
      }

      private

      def configuration
        YAML.load File.read "#{options[:path]}/.shiprails.yml"
      end

    end
  end
end
