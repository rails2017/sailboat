require "active_support/all"
require "thor"

module Shiprails
  class Ship < Thor

    desc "install", "Install Shiprails"
    method_option "path",
      aliases: ["-p"],
      default: ".shiprails.yml",
      desc: "Specify a configuration file path"
    def install
      require "shiprails/ship/install"
      Install.start
    end

    desc "setup", "Setup a Shiprails environment"
    method_option "path",
      aliases: ["-p"],
      default: ".shiprails.yml",
      desc: "Specify a configuration file path"
    def setup
      require "shiprails/ship/setup"
      Setup.start
    end

    desc "config", "Configure services"
    method_option "path",
      aliases: ["-p"],
      default: ".shiprails.yml",
      desc: "Specify a configuration file path"
    def config(*command)
      require "shiprails/ship/config"
      Config.start command
    end

    desc "deploy", "Deploy services"
    method_option "path",
      aliases: ["-p"],
      default: ".shiprails.yml",
      desc: "Specify a configuration file path"
    def deploy
      require "shiprails/ship/deploy"
      Deploy.start
    end

    desc "logs", "Fetch logs"
    method_option "path",
      aliases: ["-p"],
      default: ".shiprails.yml",
      desc: "Specify a configuration file path"
    def logs
      say "TODO: fetch logs", :blue
    end

    desc "exec", "Execute one off commands"
    method_option "path",
      aliases: ["-p"],
      default: ".shiprails.yml",
      desc: "Specify a configuration file path"
    def exec(*command)
      require "shiprails/ship/exec"
      Exec.new.run_command command.join(' ')
    end

    desc "scale ENVIRONMENT SERVICE PROCESS_COUNT", "Change service instances"
    method_option "path",
      aliases: ["-p"],
      default: ".shiprails.yml",
      desc: "Specify a configuration file path"
    def scale(*args)
      require "shiprails/ship/scale"
      Scale.start
    end

    private

    def configuration
      YAML.load(File.read(".shiprails.yml")).deep_symbolize_keys
    end

  end
end
