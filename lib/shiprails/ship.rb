require "active_support/all"
require "thor"

module Shiprails
  class Ship < Thor

    desc "install", "Install Shiprails"
    def install
      require "shiprails/ship/install"
      Install.start
    end

    desc "setup", "Setup a Shiprails environment"
    def setup
      require "shiprails/ship/setup"
      Setup.start
    end

    desc "config", "Configure services"
    def config(*command_args)
      require "shiprails/ship/config"
      Config.start command_args
    end

    desc "deploy", "Deploy services"
    def deploy(*command_args)
      require "shiprails/ship/deploy"
      Deploy.start command_args
    end

    desc "logs", "Fetch logs"
    def logs
      say "TODO: fetch logs", :blue
    end

    desc "task", "Run one off commands"
    def task(*command_args)
      require "shiprails/ship/task"
      Task.start command_args
    end

    desc "exec", "Run interactive commands"
    def exec(*command_args)
      require "shiprails/ship/exec"
      Exec.start command_args
    end

    desc "scale ENVIRONMENT SERVICE PROCESS_COUNT", "Change service instances"
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
