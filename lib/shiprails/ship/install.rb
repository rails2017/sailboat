require "active_support/all"
require "aws-sdk"
require "thor/group"

module Shiprails
  class Ship < Thor
    class Install < Thor::Group
      include Thor::Actions

      class_option "path",
        aliases: ["-p"],
        default: ".",
        desc: "Specify a configuration path"

      def self.source_root
        File.expand_path("../install", __FILE__)
      end

      def application_host
        "#{project_name}.dev"
      end

      no_commands {
        def aws_access_key_id
          @aws_access_key_id ||= ask "AWS Access Key ID", default: ENV.fetch("AWS_ACCESS_KEY_ID")
        end

        def aws_access_key_secret
          @aws_access_key_secret ||= ask "AWS Access Key Secret", default: ENV.fetch("AWS_SECRET_ACCESS_KEY")
        end
      }

      def config_s3_bucket
        return @bucket_name unless @bucket_name.nil?
        @_s3_client ||= Aws::S3::Client.new(region: ENV.fetch("AWS_REGION", "us-west-2"), access_key_id: aws_access_key_id, secret_access_key: aws_access_key_secret)
        begin
          bucket_name = "#{project_name}-config"
          bucket_name = ask "S3 bucket name for configuration store", default: bucket_name
          resp = @_s3_client.create_bucket({
            bucket: bucket_name
          })
        rescue Aws::S3::Errors::BucketAlreadyExists
          error "'#{bucket_name}' already exists"
          retry
        rescue Aws::S3::Errors::BucketAlreadyOwnedByYou
        end
        @bucket_name = bucket_name
      end

      def ec2_ssh_private_key_path
        @ec2_ssh_private_key_path ||= ask "Where is your AWS EC2 SSH private key?", default: 'shiprails.pem'
      end

      def environments
        environments = Dir.entries("#{Dir.getwd}/config/environments").grep(/\.rb$/).map { |fname| fname.chomp!(".rb") }.select{ |e| !['development', 'test'].include? e } rescue ['production']
        environments ||= ['production']
        @regions ||= ask("Which regions?", default: 'us-west-2').split(',')
        environments.map do |environment|
          {
            name: environment,
            regions: @regions
          }
        end
      end

      no_commands {
      def services
        return @services unless @services.nil?
        docker_compose = YAML.load(File.read("#{options[:path]}/docker-compose.yml")).deep_symbolize_keys
        image_for_build = {}
        regions_for_build = {}
        @services = docker_compose[:services].map do |service_name, service|
          next if [:test].include? service_name
          if service[:image].nil?
            build_name = service[:build]
            build_name = "Dockerfile" if build_name == '.'
            unless image = image_for_build[build_name]
              image = service_name
              image_for_build[build_name] = image
            end
            unless regions = regions_for_build[build_name]
              regions = @regions.map do |region|
                [region, {
                  repository_url: repository_url_for_region(region, service_name)
                }]
              end
              regions_for_build[build_name] = regions
            end
            {
              command: service[:command],
              image: image,
              name: service_name.to_s,
              ports: (service[:ports] || []).map{ |port| port.split(":").last },
              regions: regions,
              resources: {
                cpu_units: 256,
                memory_units: 256
              }
            }
          end
        end.compact
      end

      def project_name
        @project_name ||= ask "What's your project called?", default: File.basename(Dir.getwd)
      end

      def ruby_version
        "#{RUBY_VERSION}"
      end
      }

      def create_dockerfile
        template("Dockerfile.erb", "#{options[:path]}/Dockerfile")
        template("Dockerfile.production.erb", "#{options[:path]}/Dockerfile.production")
      end

      def create_dot_env
        template(".env.erb", "#{options[:path]}/.env")
        template(".env.erb", "#{options[:path]}/.env.example")
      end

      def ignore_dot_env
        if File.exists?(".gitignore")
          append_to_file(".gitignore", <<-EOF)

# Ignore Docker ENV
/.env
EOF
        end
      end

      def create_docker_compose
        template("docker-compose.yml.erb", "#{options[:path]}/docker-compose.yml")
      end

      def create_configuration
        template("shiprails.yml.erb", "#{options[:path]}/.shiprails.yml")
      end

      private

      def repository_url_for_region(region, service_name)
        @_ecr_client ||= Aws::ECR::Client.new(region: region, access_key_id: aws_access_key_id, secret_access_key: aws_access_key_secret)
        resp = @_ecr_client.describe_repositories({}).to_h
        say "Amazon EC2 Container Registry (ECR) for #{project_name}_#{service_name}?"
        choices = ["CREATE NEW REGISTRY"] + resp[:repositories].map{|r| "#{r[:repository_name]} (#{r[:repository_uri]})" }
        choices = choices.map.with_index{ |a, i| [i+1, *a]}
        print_table choices
        selection = ask("Pick one:").to_i
        if selection == 1
          resp = @_ecr_client.create_repository({
            repository_name: "#{project_name}/#{service_name}",
          }).to_h
          resp[:repository][:repository_uri]
        else
          resp[:repositories][selection - 2][:repository_uri]
        end
      end

    end
  end
end
