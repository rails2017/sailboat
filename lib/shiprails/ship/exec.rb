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

        say "Setting up EC2 instance for SSH..."
        # with the instance ARN let's grab the intance id
        ec2_instance_id = ecs.describe_container_instances({cluster: cluster, container_instances: [container_instance_arn]}).container_instances.first.ec2_instance_id
        ec2_instance = ec2.describe_instances({instance_ids: [ec2_instance_id]}).reservations.first.instances.first

        # get its current security groups to restory later
        security_group_ids = ec2_instance.security_groups.map(&:group_id)

        # create new public ip
        elastic_ip = ec2.allocate_address({ domain: "vpc" })
        # link ip to ec2 instance
        associate_address_response = ec2.associate_address({
          allocation_id: elastic_ip.allocation_id,
          instance_id: ec2_instance_id
        })
        # create security group for us
        security_group_response = ec2.create_security_group({
          group_name: "shiprails-exec-#{cluster}-#{Time.now.to_i}",
          description: "SSH access to run interactive command (created by #{`whoami`.rstrip} via shiprails)",
          vpc_id: ec2_instance.vpc_id
        })
        # get our public ip
        my_ip_address = open('http://whatismyip.akamai.com').read
        # authorize SSH access from our public ip
        ec2.authorize_security_group_ingress({
          group_id: security_group_response.group_id,
          ip_protocol: "tcp",
          from_port: 22,
          to_port: 22,
          cidr_ip: "#{my_ip_address}/32"
        })
        # add ec2 instance to our new security group
        ec2.modify_instance_attribute({
          instance_id: ec2_instance_id,
          groups: security_group_ids + [security_group_response.group_id]
        })

        # build the command we'll run on the instance
        command_array = ["docker run -it --rm"]
        task_definition_description.task_definition.container_definitions.first.environment.each do |env|
          command_array << "-e #{env.name}='#{env.value}'"
        end
        command_array << task_definition_description.task_definition.container_definitions.first.image
        command_array << command
        command_string = command_array.join ' '

        say "Waiting for AWS to setup networking..."
        sleep 5 # AWS just needs a little bit to setup networking
        say "Connecting #{ssh_user}@#{elastic_ip.public_ip}..."
        say "Executing: $ #{command_string}"
        system "ssh -o ConnectTimeout=15 -o 'StrictHostKeyChecking no' -t -i #{ssh_private_key_path} #{ssh_user}@#{elastic_ip.public_ip} '#{command_string}'"
      rescue => e
        say "Error: #{e.message}", :red
      ensure
        say "Cleaning up SSH access..."
        # restore original security groups
        ec2.modify_instance_attribute({
          instance_id: ec2_instance_id,
          groups: security_group_ids
        }) rescue nil
        # remove our access security group
        ec2.delete_security_group({ group_id: security_group_response.group_id }) rescue nil
        # unlink ec2 instance from public ip
        ec2.disassociate_address({ association_id: associate_address_response.association_id }) rescue nil
        # release public ip address
        ec2.release_address({ allocation_id: elastic_ip.allocation_id }) rescue nil
        say "Done.", :green
      end

    end
  end
end
