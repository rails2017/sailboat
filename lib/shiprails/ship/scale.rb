require "active_support/all"
require "aws-sdk"
require "git"
require "thor/group"

module Shiprails
  class Ship < Thor
    class Scale < Thor::Group
      include Thor::Actions

      argument :method_name, type: :string
      argument :environment, type: :string
      argument :service, type: :string
      argument :scale, type: :string

      class_option "region",
        desc: "Specify region"
      def update_ecs_services
        say "Setting ECS service #{service} scale=#{scale} in #{environment}..."
        configuration[:services].each do |service_name, service|
          next unless service_name.to_s == self.service
          image_name = "#{project_name}_#{service_name}"
          service[:regions].each do |region_name, region|
            next unless options["region"].nil? or options["region"] == region_name.to_s
            ecs = Aws::ECS::Client.new(region: region_name.to_s)
            region[:environments].each do |environment_name|
              next unless environment_name == self.environment
              cluster_name = "#{project_name}_#{environment_name}"
              task_name = "#{image_name}_#{environment_name}"
              begin
                task_definition_description = ecs.describe_task_definition({task_definition: task_name})
                task_definition = task_definition_description.task_definition.to_hash
              rescue Aws::ECS::Errors::ClientException => e
                say "Missing ECS task for #{task_name}!", :red
                say "Run `ship setup`", :red
                exit
              end
              begin
                service_response = ecs.update_service({
                  cluster: cluster_name,
                  service: service_name,
                  desired_count: scale
                })
                say "Set ECS service #{service_name} scale=#{scale} in #{environment} (#{region_name})...", :green
              rescue Aws::ECS::Errors::ServiceNotFoundException, Aws::ECS::Errors::ServiceNotActiveException => e
                say "Missing ECS service for #{task_name}!", :red
                say "Run `ship setup`", :red
                exit
              end
            end
          end
        end
        say "ECS service updated.", :green
      end

      private

      def aws_access_key_id
        @aws_access_key_id ||= ask "AWS Access Key ID", default: ENV.fetch("AWS_ACCESS_KEY_ID")
      end

      def aws_access_key_secret
        @aws_access_key_secret ||= ask "AWS Access Key Secret", default: ENV.fetch("AWS_SECRET_ACCESS_KEY")
      end

      def configuration
        YAML.load(File.read(".shiprails.yml")).deep_symbolize_keys
      end

      def project_name
        configuration[:project_name]
      end

    end
  end
end
