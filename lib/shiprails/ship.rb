require "active_support/all"
require "thor"

module Shiprails
  class Ship < Thor
    # ship install

    desc "install", "Install Shiprails"

    method_option "path",
      aliases: ["-p"],
      default: ".shiprails.yml",
      desc: "Specify a configuration file path"

    def install
      require "shiprails/ship/install"
      Install.start
    end

    # ship config

    desc "config", "Configure services"

    method_option "path",
      aliases: ["-p"],
      default: ".shiprails.yml",
      desc: "Specify a configuration file path"

    def config(*command)
      command_string = command.join ' '
      result = `S3_CONFIG_BUCKET=#{configuration[:config_s3_bucket]} bundle exec config #{command_string}`
      puts result
      if version = result.match(/Use version: v([0-9]+)/)[1] rescue false
        say "TODO: update ECS service + task definitions to use config v#{version}"
      end
    end

    # ship deploy

    desc "deploy", "Deploy services"

    method_option "path",
      aliases: ["-p"],
      default: ".shiprails.yml",
      desc: "Specify a configuration file path"

    def deploy
      require "shiprails/ship/deploy"
      Deploy.start
    end

    # ship logs

    desc "logs", "Fetch logs"

    method_option "path",
      aliases: ["-p"],
      default: ".shiprails.yml",
      desc: "Specify a configuration file path"

    def logs
      say "TODO: fetch logs"
    end

    # ship run

    desc "exec", "Execute one off commands"

    method_option "path",
      aliases: ["-p"],
      default: ".shiprails.yml",
      desc: "Specify a configuration file path"

    def exec(*command)
      require "shiprails/ship/exec"
      Exec.new.run_command command.join(' ')
    end

    # ship scale

    desc "scale", "Change minimum/maximum service instances"

    method_option "path",
      aliases: ["-p"],
      default: ".shiprails.yml",
      desc: "Specify a configuration file path"

    def scale
      say "TODO: change service scale"
    end

    private

    def configuration
      YAML.load(File.read(".shiprails.yml")).deep_symbolize_keys
    end

  end
end
