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
          exit
        end
      end

      def build_docker_images
        say "Building images..."
        s3_config_bucket = configuration[:config_s3_bucket].to_s
        commands = []
        configuration[:services].each do |service_name, service|
          image_name = "#{compose_project_name}_#{service[:image]}"
          service[:regions].each do |region_name, region|
            aws_region = region_name.to_s
            region[:environments].each do |environment_name|
              result = `S3_CONFIG_BUCKET=#{s3_config_bucket} bundle exec config list #{environment_name}`
              s3_config_revision = result.match(/#{environment_name} \(v([0-9]+)\)/)[1] rescue 0
              commands << "docker build -t #{image_name}_#{environment_name} --build-arg AWS_ACCESS_KEY_ID='#{aws_access_key_id}' --build-arg AWS_SECRET_ACCESS_KEY='#{aws_access_key_secret}' --build-arg AWS_REGION='#{aws_region}' --build-arg S3_CONFIG_BUCKET='#{s3_config_bucket}' --build-arg S3_CONFIG_REVISION='#{s3_config_revision}' -f Dockerfile.production ."
            end
          end
        end
        commands.uniq!
        commands.each { |c| run c } # TODO: check that this succeeded
        say "Build complete", :green
      end

      def tag_docker_images
        say "Tagging images..."
        commands = []
        configuration[:services].each do |service_name, service|
          image_name = "#{compose_project_name}_#{service[:image]}"
          service[:regions].each do |region_name, region|
            repository_url = region[:repository_url]
            region[:environments].each do |environment_name|
              commands << "docker tag #{image_name}_#{environment_name} #{repository_url}:#{git_sha}"
            end
          end
        end
        commands.uniq!
        commands.each { |c| run c } # TODO: check that this succeeded
        say "Tagging complete.", :green
      end

      def push_docker_images
        say "Pushing images..."
        repository_urls_to_regions = {}
        configuration[:services].each do |service_name, service|
          service[:regions].each do |region, values|
            repository_urls_to_regions[values[:repository_url]] = region
          end
        end
        repository_urls_to_regions.each do |repository_url, region|
          run "`aws ecr get-login --region #{region}`"
          run "docker push #{repository_url}:#{git_sha}" # TODO: check that this succeeded
        end
        say "Push complete.", :green
      end

      def update_ecs_tasks
        say "Updating ECS tasks..."
        configuration[:services].each do |service_name, service|
          image_name = "#{project_name}_#{service_name}"
          service[:regions].each do |region_name, region|
            ecs = Aws::ECS::Client.new(region: region_name.to_s)
            region[:environments].each do |environment_name|
              cluster_name = "#{project_name}_#{environment_name}"
              task_name = "#{project_name}_#{service_name}_#{environment_name}"
              image_name = "#{region[:repository_url]}:#{git_sha}"
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
              if container = task_definition[:container_definitions].find{ |container| container[:name] == service_name.to_s }
                container[:cpu] = service[:resources][:cpu_units]
                container[:image] = image_name
                container[:memory] = service[:resources][:memory_units]
                config_s3_version = container[:environment].find{|e| e[:name] == "S3_CONFIG_REVISION" }[:value]
                container[:environment] = [
                  { name: "AWS_REGION", value: region_name.to_s },
                  { name: "GIT_SHA", value: git_sha },
                  { name: "RACK_ENV", value: environment_name },
                  { name: "S3_CONFIG_BUCKET", value: config_s3_bucket },
                  { name: "S3_CONFIG_REVISION", value: config_s3_version }
                ]
                say "Updated #{service_name} container (#{image_name})."
              end
              task_definition_response = ecs.register_task_definition(task_definition)
              say "Updated #{task_name}.", :green
            end
          end
        end
        say "ECS tasks updated.", :green
      end

      def update_ecs_services
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
        @aws_access_key_id ||= ENV.fetch("AWS_ACCESS_KEY_ID") { ask "AWS Access Key ID" }
      end

      def aws_access_key_secret
        @aws_access_key_secret ||= ENV.fetch("AWS_SECRET_ACCESS_KEY") { ask "AWS Access Key Secret" }
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

      def compose_project_name
        project_name.gsub /[^0-9a-zA-Z]/i, ''
      end

      def config_s3_bucket
        configuration[:config_s3_bucket]
      end

    end
  end
end
