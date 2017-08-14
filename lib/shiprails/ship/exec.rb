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
        aliases: ["-e"],
        desc: "Specify the environment"
      class_option "region",
        aliases: ["-r"],
        default: "us-west-2",
        desc: "Specify the region"
      class_option "service",
        aliases: ["-a"],
        default: "app",
        desc: "Specify the service name"
      class_option "private-key",
        aliases: ["-pk"],
        desc: "Specify the AWS SSH private key path"
      class_option "task-arn",
        desc: "Specify the ECS task ARN"

      def run_command
        cluster_name = "#{project_name}_#{environment}"
        command_string = args.join ' '
        ssh_private_key_path = private_key
        ecs_exec(region, cluster_name, service, command_string, ssh_private_key_path)
      end

      no_commands do
        def run_shorthand_command(command_args=nil, opts=nil)
          options = opts unless opts.nil?
          cluster_name = "#{project_name}_#{environment}"
          command_string = command_args.join ' '
          ssh_private_key_path = private_key
          ecs_exec(region, cluster_name, service, command_string, ssh_private_key_path)
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

      def environment
        environment = options[:environment] || "production" # default production
        environments = configuration[:services][service.to_sym][:regions][region.to_sym][:environments]
        environments.include?(environment) ? environment : environments.first
      end

      def private_key
        options['private-key'] || configuration[:private_key_path] || "shiprails.pem"
      end

      def project_name
        configuration[:project_name]
      end

      def region
        options[:region]
      end

      def service
        options[:service]
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

        task_arn = options['task-arn']
        if task_arn.nil?
          task_definition_description = ecs.describe_task_definition({task_definition: task_definition_name})
        else
          task_definition_description = ecs.describe_task_definition({task_definition: task_arn})
        end

        say "Setting up EC2 instance for SSH..."
        # with the instance ARN let's grab the intance id
        ec2_instance_id = ecs.describe_container_instances({cluster: cluster, container_instances: [container_instance_arn]}).container_instances.first.ec2_instance_id
        ec2_instance = ec2.describe_instances({instance_ids: [ec2_instance_id]}).reservations.first.instances.first

        # get its current security groups to restory later
        security_group_ids = ec2_instance.security_groups.map(&:group_id)

        vpcs = ec2.describe_vpcs.vpcs
        vpc = vpcs.find{ |v| v.tags.find{|t| t.key == "Name" }.try(:value) == cluster }
        vpc_security_groups = ec2.describe_security_groups({
          filters: [
            {
              name: "vpc-id",
              values: [
                vpc.vpc_id
              ],
            },
          ],
        }).security_groups
        team_access_security_group = vpc_security_groups.find{ |group| group.group_name == "team-access-#{cluster}" }
        if team_access_security_group.nil?
          # create security group for us
          team_access_security_group = ec2.create_security_group({
            group_name: "team-access-#{cluster}",
            description: "Ingress for team members",
            vpc_id: vpc.vpc_id
          })
        end
        begin
          # get our public ip
          my_ip_address = open('http://whatismyip.akamai.com').read
          # authorize SSH access from our public ip
          ec2.authorize_security_group_ingress({
            group_id: team_access_security_group.group_id,
            ip_protocol: "tcp",
            from_port: 22,
            to_port: 22,
            cidr_ip: "#{my_ip_address}/32"
          })
        rescue Aws::EC2::Errors::InvalidPermissionDuplicate => e
        end
        # add ec2 instance to team access security group
        ec2.modify_instance_attribute({
          instance_id: ec2_instance_id,
          groups: security_group_ids + [team_access_security_group.group_id]
        })

        # build the command we'll run on the instance
        command_array = ["docker run -it --rm"]
        task_definition_description.task_definition.container_definitions.first.environment.each do |env|
          command_array << "-e #{env.name}='#{env.value}'"
        end
        # add AWS keys from local env if missing
        if task_definition_description.task_definition.container_definitions.first.environment.find{|env| env.name == "AWS_ACCESS_KEY_ID" }.nil?
          command_array << "-e AWS_ACCESS_KEY_ID='#{ENV.fetch('AWS_ACCESS_KEY_ID')}'"
        end
        if task_definition_description.task_definition.container_definitions.first.environment.find{|env| env.name == "AWS_SECRET_ACCESS_KEY" }.nil?
          command_array << "-e AWS_SECRET_ACCESS_KEY='#{ENV.fetch('AWS_SECRET_ACCESS_KEY')}'"
        end
        command_array << task_definition_description.task_definition.container_definitions.first.image
        command_array << command
        command_string = command_array.join ' '

        say "Waiting for AWS to setup networking..."
        # sleep 5 # AWS just needs a little bit to setup networking
        say "Connecting #{ssh_user}@#{ec2_instance.public_ip_address}..."
        say "Executing: $ #{command_string}"
        system "ssh -o ConnectTimeout=15 -o 'StrictHostKeyChecking no' -t -i #{ssh_private_key_path} #{ssh_user}@#{ec2_instance.public_ip_address} '`aws ecr get-login --region #{region}` && #{command_string}'"
      rescue => e
        puts e.inspect
        say "Error: #{e.message}", :red
      ensure
        say "Cleaning up SSH access..."
        # restore original security groups
        ec2.modify_instance_attribute({
          instance_id: ec2_instance_id,
          groups: security_group_ids
        }) rescue nil
        say "Done.", :green
      end

    end
  end
end
