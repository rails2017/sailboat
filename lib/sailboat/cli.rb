require "active_support/all"
require "thor"

module Sailboat
  class CLI < Thor
    # sailboat install

    desc "install", "Install Sailboat"

    method_option "path",
      aliases: ["-p"],
      default: ".sailboat.yml",
      desc: "Specify a configuration file path"

    def install
      require "sailboat/cli/install"
      Install.start
    end

    # sailboat config

    desc "config", "Configure services"

    method_option "path",
      aliases: ["-p"],
      default: ".sailboat.yml",
      desc: "Specify a configuration file path"

    def config(*command)
      command_string = command.join ' '
      result = `S3_CONFIG_BUCKET=#{configuration[:config_s3_bucket]} bundle exec config #{command_string}`
      puts result
      if version = result.match(/Use version: v([0-9]+)/)[1] rescue false
        say "TODO: update ECS service + task definitions to use config v#{version}"
      end
    end

    # sailboat deploy

    desc "deploy", "Deploy services"

    method_option "path",
      aliases: ["-p"],
      default: ".sailboat.yml",
      desc: "Specify a configuration file path"

    def deploy
      require "sailboat/cli/deploy"
      Deploy.start
    end

    # sailboat logs

    desc "logs", "Fetch logs"

    method_option "path",
      aliases: ["-p"],
      default: ".sailboat.yml",
      desc: "Specify a configuration file path"

    def logs
      say "TODO: fetch logs"
    end

    # sailboat run

    desc "exec", "Execute one off commands"

    method_option "path",
      aliases: ["-p"],
      default: ".sailboat.yml",
      desc: "Specify a configuration file path"

    def exec(*command)
      require "sailboat/cli/exec"
      Exec.new.run_command command.join(' ')
    end

    # sailboat scale

    desc "scale", "Change minimum/maximum service instances"

    method_option "path",
      aliases: ["-p"],
      default: ".sailboat.yml",
      desc: "Specify a configuration file path"

    def scale
      say "TODO: change service scale"
    end

    private

    def configuration
      YAML.load(File.read(".sailboat.yml")).deep_symbolize_keys
    end

  end
end
