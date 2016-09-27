require "active_support/all"
require "aws-sdk"
require "thor/group"

module Shiprails
  class Ship < Thor
    class Task < Thor::Group
      include Thor::Actions
      class_option "path",
        aliases: ["-p"],
        default: ".",
        desc: "Specify a configuration path"
      class_option "environment",
        default: "production",
        desc: "Specify the environment"
      class_option "region",
        default: "us-west-2",
        desc: "Specify the region"
      class_option "service",
        default: "app",
        desc: "Specify the service name"

      def run_command
        command_string = args.join ' '
        cluster_name = "#{project_name}_#{options['environment']}"
        task_name = "#{project_name}_#{options['service']}_#{options['environment']}"
        ecs = Aws::ECS::Client.new(region: options['region'])
        task_definition_response = ecs.describe_task_definition({task_definition: task_name})
        task_definition_arn = task_definition_response.task_definition.task_definition_arn
        say "Running `#{command_string}` in #{options['environment']} #{options['service']} (#{options['region']})..."
        task_response = ecs.run_task({
          cluster: cluster_name,
          task_definition: task_definition_arn,
          overrides: {
            container_overrides: [{
              name: options['service'],
              command: command_string.split(' ')
            }]
          }
        })
        task_arn = task_response.tasks.first.task_arn
        resp = ecs.describe_tasks({ cluster: cluster_name, tasks: [task_arn] })
        while resp.tasks.first.containers.first.exit_code.nil?
          sleep 1
          resp = ecs.describe_tasks({ cluster: cluster_name, tasks: [task_arn] })
          say "."
        end
        if resp.tasks.first.containers.first.exit_code > 0
          say "Task exited other than 0: #{resp.tasks.first.containers.first.exit_code} (#{task_arn})", :red
        else
          say "Ran `#{command_string}` in #{options['environment']} #{options['service']} (#{options['region']}).", :green
        end
      end

      private

      def configuration
        YAML.load(File.read("#{options[:path]}/.shiprails.yml")).deep_symbolize_keys
      end

      def aws_access_key_id
        @aws_access_key_id ||= ask "AWS Access Key ID", default: ENV.fetch("AWS_ACCESS_KEY_ID")
      end

      def aws_access_key_secret
        @aws_access_key_secret ||= ask "AWS Access Key Secret", default: ENV.fetch("AWS_SECRET_ACCESS_KEY")
      end

      def project_name
        configuration[:project_name]
      end

    end
  end
end
