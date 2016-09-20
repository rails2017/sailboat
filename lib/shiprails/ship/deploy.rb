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

      def build_docker_images
        run "docker-compose build"
      end

      def check_git_status
        if git.status.added.any? or git.status.changed.any? or git.status.deleted.any?
          error "You have uncommitted changes. Commit and try again."
          exit
        end
      end

      def tag_docker_images
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
      end

      def push_docker_images
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
      end

      def update_ecs_services
        configuration[:services].each do |service_name, service|
          service[:regions].each do |region, values|
            say "TODO: update ECS task #{service_name} in #{region}"
            say "TODO: update ECS service #{service_name} in #{region}"
          end
        end
      end

      no_commands {
        def aws_access_key_id
          @aws_access_key_id ||= ask "AWS Access Key ID", default: ENV.fetch("AWS_ACCESS_KEY_ID")
        end

        def aws_access_key_secret
          @aws_access_key_secret ||= ask "AWS Access Key Secret", default: ENV.fetch("AWS_SECRET_ACCESS_KEY")
        end
      }

      private

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

    end
  end
end
