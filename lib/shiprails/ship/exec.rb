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
        task_arn = tasks_list.task_arns.first

        # using the ARN of the task, we can get the ARN of the container instance where its being deployed
        task_descriptions = ecs.describe_tasks({cluster: cluster, tasks: [task_arn]})
        task_definition_arn = task_descriptions.tasks.first.task_definition_arn
        task_definition_name = task_definition_arn.split('/').last
        container_instance_arn = task_descriptions.tasks.first.container_instance_arn

        task_definition_description = ecs.describe_task_definition({task_definition: task_definition_name})

        # with the instance ARN let's grab the intance id
        ec2_instance_id = ecs.describe_container_instances({cluster: cluster, container_instances: [container_instance_arn]}).container_instances.first.ec2_instance_id
        ec2_instance = ec2.describe_instances({instance_ids: [ec2_instance_id]}).reservations.first.instances.first

        elastic_ip = ec2.allocate_address({ domain: "vpc" })
        associate_address_response = ec2.associate_address({
          allocation_id: elastic_ip.allocation_id,
          instance_id: ec2_instance_id
        })

        security_group_response = ec2.create_security_group({
          group_name: "shiprails-exec-#{cluster}-#{Time.now.to_i}",
          description: "SSH access to run interactive command (created by `whoami`; shiprails)",
          vpc_id: ec2_instance.vpc_id
        })

        my_ip_address = open('http://whatismyip.akamai.com').read
        ec2.authorize_security_group_ingress({
          group_id: security_group_response.group_id,
          ip_protocol: "tcp",
          from_port: -1,
          to_port: "22",
          cidr_ip: "#{my_ip_address}/32"
        })
        # TODO: add security group to instance ec2_instance_id

        command_array = ["docker run -it --rm"]
        task_definition_description.task_definition.container_definitions.first.environment.each do |env|
          command_array << "-e #{env.name}='#{env.value}'"
        end
        command_array << task_definition_description.task_definition.container_definitions.first.image
        command_array << command

        command_string = command_array.join ' '
        say "Connecting to #{ec2_instance_id}..."
        say "Executing: $ #{command_string}"
        exec "ssh -o ConnectTimeout=5 -t -i #{ssh_private_key_path} #{ssh_user}@#{elastic_ip.public_ip} '#{command_string}'"
        say "Cleaning up..."
        # TODO: remove security group from instance ec2_instance_id
        ec2.delete_security_group({ group_id: security_group_response.group_id })
        ec2.disassociate_address({ association_id: associate_address_response.association_id })
        ec2.release_address({ allocation_id: elastic_ip.allocation_id })
        say "Done.", :green
      end

    end
  end
end
