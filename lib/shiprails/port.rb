require "active_support/all"
require "thor"

module Shiprails
  class Port < Thor
    include Thor::Actions

    desc "config", "Configure services"

    method_option "path",
      aliases: ["-p"],
      default: ".shiprails.yml",
      desc: "Specify a configuration file path"

    def config(*command)
      say "TODO: store development config vars"
    end

    desc "exec", "Run interactive commands"
    method_option "no-rm",
      default: false,
      desc: "Remove container changes after use",
      type: :boolean
    def exec(*command_args)
      build_command_args = ["docker-compose", "run"]
      build_command_args << "--rm" unless options['no-rm']
      build_command_args << "app"
      build_command_args += command_args
      command_string = build_command_args.join(' ')
      run command_string
    end

    desc "up", "Hoist app and services"
    def up
      run "docker-compose up"
    end

    def self.configuration
      YAML.load(File.read(".shiprails.yml")).deep_symbolize_keys rescue {}
    end

    if commands = configuration[:exec]
      commands.each do |name, command|
        desc name, "port exec #{command}"
        method_option "no-rm",
          default: false,
          desc: "Remove container changes after use",
          type: :boolean
        define_method name.to_sym do |*command_args|
          build_command_args = ["docker-compose", "run"]
          build_command_args << "--rm" unless options['no-rm']
          build_command_args << "app"
          build_command_args += command.split(' ') + command_args
          command_string = build_command_args.join(' ')
          run command_string
        end
      end
    end

  end
end
