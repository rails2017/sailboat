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

    desc "up", "Hoist app and services"
    def up
      run "docker-compose up"
    end

    desc "bundle", "Run bundler commands"
    def bundle(*command)
      command_string = command.join(' ')
      if command_string.start_with?("exec")
        run "docker-compose run --rm app bundle #{command_string}"
      else
        run "docker-compose run app bundle #{command_string}"
      end
    end

    desc "rails", "Run rails commands"
    def rails(*command)
      command_string = command.join(' ')
      run "docker-compose run --rm app bundle exec rails #{command_string}"
    end

    desc "bash", "Run bash commands"
    def bash(*command)
      command_string = command.join(' ')
      run "docker-compose run --rm app bash #{command_string}"
    end

    private

    def configuration
      YAML.load(File.read(".shiprails.yml")).deep_symbolize_keys
    end

  end
end
