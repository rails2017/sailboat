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

  end
end
