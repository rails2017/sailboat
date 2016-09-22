require "active_support/all"
require "aws-sdk"
require "git"
require "thor/group"

module Shiprails
  class Ship < Thor
    class Config < Thor::Group
      include Thor::Actions

      class_option "path",
        aliases: ["-p"],
        default: ".",
        desc: "Specify a configuration path"

      def update_s3_config
        command_string = args.join ' '
        result = `S3_CONFIG_BUCKET=#{configuration[:config_s3_bucket]} bundle exec config #{command_string}`
        puts result
        @version = result.match(/New version: v([0-9]+)/)[1] rescue false
      end

      def update_ecs_tasks
        return unless @version
        say "Updating config version for ECS tasks..."
        configuration[:services].each do |service_name, service|
          service[:regions].each do |region_name, region|
            ecs = Aws::ECS::Client.new(region: region_name.to_s)
            region[:environments].each do |environment_name|
              cluster_name = "#{project_name}_#{environment_name}"
              task_name = "#{project_name}_#{service_name}_#{environment_name}"
              begin
                task_definition_description = ecs.describe_task_definition({task_definition: task_name})
                task_definition = task_definition_description.task_definition.to_hash
                task_definition.delete :task_definition_arn
                task_definition.delete :revision
                task_definition.delete :status
                task_definition.delete :requires_attributes
              rescue Aws::ECS::Errors::ClientException => e
                say "Missing ECS task for #{task_name}!", :red
                say "Run `ship setup`", :red
                exit
              end
              task_definition[:container_definitions][0][:environment].map! do |e|
                if e[:name] == "S3_CONFIG_VERSION"
                  e[:value] = "v#{@version}"
                end
                e
              end
              task_definition_response = ecs.register_task_definition(task_definition)
              say "Updated #{task_name} task."
            end
          end
        end
        say "ECS tasks updated.", :green
      end

      def update_ecs_services
        return unless @version
        say "Updating ECS services..."
        configuration[:services].each do |service_name, service|
          service[:regions].each do |region_name, region|
            ecs = Aws::ECS::Client.new(region: region_name.to_s)
            region[:environments].each do |environment_name|
              cluster_name = "#{project_name}_#{environment_name}"
              task_name = "#{project_name}_#{service_name}_#{environment_name}"
              begin
                task_definition_response = ecs.describe_task_definition({task_definition: task_name})
                task_definition = task_definition_response.task_definition.to_hash
              rescue Aws::ECS::Errors::ClientException => e
                say "Missing ECS task for #{task_name}!", :red
                say "Run `ship setup`", :red
                exit
              end
              begin
                service_response = ecs.update_service({
                  cluster: cluster_name,
                  service: service_name,
                  task_definition: task_definition_response.task_definition.task_definition_arn
                })
                say "Updated #{service_name} service."
              rescue Aws::ECS::Errors::ServiceNotFoundException, Aws::ECS::Errors::ServiceNotActiveException => e
                say "Missing ECS service for #{task_name}!", :red
                say "Run `ship setup`", :red
                exit
              end
            end
          end
        end
        say "ECS services updated.", :green
      end

      def done
        unless @version
          say "No config updates.", :green
        else
          say "Config update complete!", :green
        end
      end

      private

      def aws_access_key_id
        @aws_access_key_id ||= ask "AWS Access Key ID", default: ENV.fetch("AWS_ACCESS_KEY_ID")
      end

      def aws_access_key_secret
        @aws_access_key_secret ||= ask "AWS Access Key Secret", default: ENV.fetch("AWS_SECRET_ACCESS_KEY")
      end

      def configuration
        YAML.load(File.read("#{options[:path]}/.shiprails.yml")).deep_symbolize_keys
      end

      def project_name
        configuration[:project_name]
      end

    end
  end
end
