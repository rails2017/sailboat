require "active_support/all"
require "aws-sdk"
require "git"
require "thor/group"

module Shiprails
  class Ship < Thor
    class Deploy < Thor::Group
      include Thor::Actions

      class_option "path",
        aliases: ["-p"],
        default: ".",
        desc: "Specify a configuration path"

      def check_git_status
        if git.status.added.any? or git.status.changed.any? or git.status.deleted.any?
          say "You have uncommitted changes. Commit and try again.", :red
          # exit
        end
      end

      def build_docker_images
        say "Building images..."
        run "docker-compose build"
        say "Build complete", :green
      end

      def tag_docker_images
        say "Tagging images..."
        commands = []
        configuration[:services].each do |service_name, service|
          image_name = "#{project_name}_#{service[:image]}"
          service[:regions].each do |region, values|
            repository_url = values[:repository_url]
            commands << "docker tag #{image_name} #{repository_url}:#{git_sha}"
          end
        end
        commands.uniq!
        commands.each { |c| run c }
        say "Tagging complete.", :green
      end

      def push_docker_images
        say "Pushing images..."
        repository_urls_to_regions = {}
        configuration[:services].each do |service_name, service|
          image_name = "#{project_name}_#{service[:image]}"
          service[:regions].each do |region, values|
            repository_urls_to_regions[values[:repository_url]] = region
          end
        end
        repository_urls_to_regions.each do |repository_url, region|
          run "`aws ecr get-login --region #{region}`"
          run "docker push #{repository_url}:#{git_sha}"
        end
        say "Push complete.", :green
      end

      def update_ecs_services
        say "Updating ECS services..."
        configuration[:services].each do |service_name, service|
          image_name = "#{project_name}_#{service_name}"
          service[:regions].each do |region_name, region|
            ecs = Aws::ECS::Client.new(region: region_name.to_s)
            region[:environments].each do |environment_name|
              cluster_name = "#{project_name}_#{environment_name}"
              task_name = "#{image_name}_#{environment_name}"
              image_name = "#{region[:repository_url]}/#{image_name}:#{git_sha}"
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
              task_definition[:container_definitions][0][:cpu] = service[:resources][:cpu_units]
              task_definition[:container_definitions][0][:image] = image_name
              task_definition[:container_definitions][0][:memory] = service[:resources][:memory_units]
              config_s3_version = task_definition[:container_definitions][0][:environment].find{|e| e[:name] == "S3_CONFIG_VERSION" }[:value]
              task_definition[:container_definitions][0][:environment] = [
                { name: "GIT_SHA", value: git_sha },
                { name: "RACK_ENV", value: environment_name },
                { name: "S3_CONFIG_BUCKET", value: config_s3_bucket },
                { name: "S3_CONFIG_VERSION", value: config_s3_version }
              ]
              task_definition_response = ecs.register_task_definition(task_definition)
              begin
                service_response = ecs.update_service({
                  cluster: cluster_name,
                  service: service_name,
                  task_definition: task_definition_response.task_definition.task_definition_arn
                })
                say "Updated #{service_name}.", :green
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
        say "Deploy complete!", :green
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

      def git
        @_git ||= Git.open(Dir.getwd)
      end

      def git_sha
        @_git_sha ||= git.object('HEAD').sha
      end

      def project_name
        configuration[:project_name]
      end

      def config_s3_bucket
        configuration[:config_s3_bucket]
      end

    end
  end
end
