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

    def self.configuration
      YAML.load(File.read(".shiprails.yml")).deep_symbolize_keys rescue {}
    end

    if commands = configuration[:exec]
      commands.each do |name, command|
        desc name, "ship exec #{command}"
        method_option "path",
          aliases: ["-p"],
          default: ".",
          desc: "Specify a configuration path"
        method_option "environment",
          aliases: ["-e"],
          desc: "Specify the environment"
        method_option "region",
          aliases: ["-r"],
          default: "us-west-2",
          desc: "Specify the region"
        method_option "service",
          aliases: ["-a"],
          default: "app",
          desc: "Specify the service name"
        method_option "private-key",
          aliases: ["-pk"],
          desc: "Specify the AWS SSH private key path"
        define_method name.to_sym do |*command_args|
          require "shiprails/ship/exec"
          built_arguments = command.split(' ') + command_args
          built_options = options.map{|k,v| "--#{k} #{v}"}
          script = Exec.new built_arguments, built_options
          script.run_shorthand_command built_arguments, options
        end
      end
    end

  end
end
