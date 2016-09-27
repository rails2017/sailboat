require "active_support/all"
require "aws-sdk"
require "thor/group"

module Shiprails
  class Ship < Thor
    class Exec < Thor::Group
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
      class_option "private-key",
        default: "~/.ssh/aws.pem",
        desc: "Specify the AWS SSH private key path"

      def run_command
        region = options['region']
        service = options['service']
        cluster_name = "#{project_name}_#{options['environment']}"
        command_string = args.join ' '
        ssh_private_key_path = options['private-key']
        ecs_exec(region, cluster_name, service, command_string, ssh_private_key_path)
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

      def ecs_exec(region, cluster, service, command, ssh_private_key_path, ssh_user: 'ec2-user')
        # we'll need to use both the ecs and ec2 apis
        ecs = Aws::ECS::Client.new(region: region)
        ec2 = Aws::EC2::Client.new(region: region)

        # first we get the ARN of the task managed by the service
        tasks_list = ecs.list_tasks({cluster: cluster, desired_status: 'RUNNING', service_name: service})
        task_arn = tasks_list.task_arns[0]

        # using the ARN of the task, we can get the ARN of the container instance where its being deployed
        task_descriptions = ecs.describe_tasks({cluster: cluster, tasks: [task_arn]})
        task_definition_arn = task_descriptions.tasks[0].task_definition_arn
        task_definition_name = task_definition_arn.split('/').last
        container_instance_arn = task_descriptions.tasks[0].container_instance_arn

        task_definition_description = ecs.describe_task_definition({task_definition: task_definition_name})

        # with the instance ARN let's grab the intance id
        ec2_instance_id = ecs.describe_container_instances({cluster: cluster, container_instances: [container_instance_arn]}).container_instances[0].ec2_instance_id

        say "Setting up EC2 instance for SSH..."

        # TODO: find security group for ship exec or create one
        # TODO: add our IP to security group with SSH port
        # TODO: add security group to instance ec2_instance_id
        # TODO: add public ip address to instance

        # we need to describe the instance with this id using the ec2 api
        instance = ec2.describe_instances({instance_ids: [ec2_instance_id]}).reservations[0].instances[0]
        ssh_host = instance.public_ip_address

        command_array = ["docker run -it --rm"]
        task_definition_description.task_definition.container_definitions[0].environment.each do |env|
          command_array << "-e #{env.name}='#{env.value}'"
        end
        command_array << task_definition_description.task_definition.container_definitions[0].image
        command_array << command

        command_string = command_array.join ' '
        say "Connecting to #{ec2_instance_id}..."
        say "Executing: `#{command_string}`..."
        system "ssh -t -i #{ssh_private_key_path} #{ssh_user}@#{ssh_host} '#{command_string}'"

        say "Tearing down EC2 instance SSH..."

        # TODO: remove our IP from security group with SSH port
        # TODO: remove security group from instance ec2_instance_id
        # TODO: remove public ip address from instance
        say "Done", :green
      end

    end
  end
end
