require "active_support/all"
require "aws-sdk"
require "git"
require "json"
require "thor/group"

module Shiprails
  class Ship < Thor
    class Setup < Thor::Group
      include Thor::Actions

      class_option "path",
        aliases: ["-p"],
        default: ".",
        desc: "Specify a configuration path"

      def create_cloudwatch_logs_group
        say "Creating CloudWatch Log groups..."
        created_groups = []
        configuration[:services].each do |service_name, service|
          service[:regions].each do |region_name, region|
            client = Aws::CloudWatchLogs::Client.new(region: region_name.to_s)
            region[:environments].each do |environment_name|
              cluster_name = "#{project_name}_#{environment_name}"
              unless created_groups.include? cluster_name
                begin
                  client.create_log_group({ log_group_name: cluster_name })
                rescue Aws::CloudWatchLogs::Errors::ResourceAlreadyExistsException => err
                end
                say "Created #{cluster_name} log group."
                created_groups << cluster_name
              end
            end
          end
        end
        say "Created CloudWatch Log groups.", :green
      end

      def create_iam_roles
        iam = Aws::IAM::Client.new
        configuration[:services].each do |service_name, service|
          service[:regions].each do |region_name, region|
            region[:environments].each do |environment_name|
              begin
                role_name = "#{project_name}_#{environment_name}-ecs-task"
                role = iam.create_role({
                  path: "/",
                  role_name: role_name,
                })
                iam.put_role_policy({
                  policy_document: JSON.generate({
                      "Version": "2012-10-17",
                      "Statement": [
                          {
                              "Sid": "Stmt1492034037000",
                              "Effect": "Allow",
                              "Action": [
                                  "s3:GetObject"
                              ],
                              "Resource": [
                                  "arn:aws:s3:::#{config_s3_bucket}/#{environment_name}/*",
                              ]
                          }
                      ]
                  }),
                  policy_name: "#{role_name}-read-s3-config",
                  role_name: role_name,
                })
                say "Created ECS task role..."

                say "TODO: create cloudwatch logs read role", :blue
                say "TODO: create scale role", :blue
                say "TODO: create deploy IAM role", :blue
                say "TODO: create run task IAM role", :blue
                say "TODO: create exec interactive IAM role", :blue

              rescue Aws::IAM::Errors::EntityAlreadyExists => err
                say "ECS task role exists..."
              end
            end
          end
        end
      end

      def create_vpc
        iam = Aws::IAM::Client.new
        configuration[:services].each do |service_name, service|
          service[:regions].each do |region_name, region|
            region[:environments].each do |environment_name|
              begin
                name = "#{project_name}_#{environment_name}-ecs-task"

                say "TODO: create vpc", :blue

                say "TODO: create vpc subnets", :blue

                say "TODO: create security groups", :blue

              rescue Aws::IAM::Errors::EntityAlreadyExists => err
                say "ECS task role exists..."
              end
            end
          end
        end
      end

      def create_ecs_tasks
        say "Creating ECS tasks..."
        iam = Aws::IAM::Client.new
        iam_roles = iam.list_roles
        configuration[:services].each do |service_name, service|
          image_name = "#{project_name}_#{service_name}"
          service[:regions].each do |region_name, region|
            ecs = Aws::ECS::Client.new(region: region_name.to_s)
            region[:environments].each do |environment_name|
              cluster_name = "#{project_name}_#{environment_name}"
              task_name = "#{image_name}_#{environment_name}"
              ecs_task_role = iam_roles.find{ |role| role[:role_name] == "#{project_name}_#{environment_name}-ecs-task" }
              task_definition = {
                container_definitions: [
                  {
                    command: [service[:command]],
                    cpu: service[:resources][:cpu_units],
                    essential: true,
                    environment: [
                      { name: "AWS_REGION", value: region_name.to_s },
                      { name: "S3_CONFIG_BUCKET", value: config_s3_bucket },
                      { name: "S3_CONFIG_ENVIRONMENT", value: environment_name },
                      { name: "S3_CONFIG_REVISION", value: "0" }
                    ],
                    image: "#{region[:repository_url]}:latest",
                    log_configuration: {
                      log_driver: "awslogs",
                      options: {
                        "awslogs-group" => cluster_name,
                        "awslogs-region" => region_name.to_s,
                        "awslogs-stream-prefix" => service_name
                      }
                    },
                    memory: service[:resources][:memory_units],
                    name: service_name,
                    port_mappings: (service[:ports] || []).map { |port|
                      {
                        container_port: port,
                        host_port: 0,
                        protocol: "tcp"
                      }
                    },
                    task_role_arn: ecs_task_role.arn
                  }
                ],
                family: task_name
              }
              begin
                task_definition_description = ecs.describe_task_definition({task_definition: task_name})
                task_definition = task_definition_description.task_definition.to_hash
                task_definition.delete :task_definition_arn
                task_definition.delete :revision
                task_definition.delete :status
                task_definition.delete :requires_attributes
                say "Updating ECS task (#{task_name})."
              rescue Aws::ECS::Errors::ClientException => e
                say "Creating new ECS task (#{task_name})!"
              end
              task_definition_response = ecs.register_task_definition(task_definition)
            end
          end
        end
        say "Created ECS tasks!", :green
      end

      def create_ecs_clusters
        say "Creating ECS clusters..."
        cluster_names = []
        configuration[:services].each do |service_name, service|
          image_name = "#{project_name}_#{service_name}"
          service[:regions].each do |region_name, region|
            ecs = Aws::ECS::Client.new(region: region_name.to_s)
            region[:environments].each do |environment_name|
              cluster_name = "#{project_name}_#{environment_name}"
              next if cluster_names.include? cluster_name
              cluster_names << cluster_name
              ecs.create_cluster({
                cluster_name: cluster_name
              })
              say "Created ECS cluster (#{cluster_name})!"
            end
          end
        end
        say "Created ECS clusters!", :green
      end

      def create_ec2_launch_configurations
        say "Creating EC2 Launch Configurations..."
        launch_configuration_names = []
        configuration[:services].each do |service_name, service|
          image_name = "#{project_name}_#{service_name}"
          service[:regions].each do |region_name, region|

            # TODO: find the ami for this region
            ami_id = "ami-62d35c02"

            autoscaling = Aws::AutoScaling::Client.new(region: region_name.to_s)
            region[:environments].each do |environment_name|
              launch_configuration_name = "#{project_name}_#{environment_name}-v1"
              next if launch_configuration_names.include? launch_configuration_name
              launch_configuration_names << launch_configuration_name
              begin
                autoscaling.create_launch_configuration({
                  launch_configuration_name: launch_configuration_name,
                  image_id: ami_id,
                  key_name: configuration[:key_pair_name],
                  security_groups: ["XmlString"],
                  classic_link_vpc_id: "XmlStringMaxLen255",
                  classic_link_vpc_security_groups: ["XmlStringMaxLen255"],
                  user_data: "XmlStringUserData",
                  instance_id: "XmlStringMaxLen19",
                  instance_type: "XmlStringMaxLen255",
                  kernel_id: "XmlStringMaxLen255",
                  ramdisk_id: "XmlStringMaxLen255",
                  block_device_mappings: [
                    {
                      virtual_name: "XmlStringMaxLen255",
                      device_name: "XmlStringMaxLen255", # required
                      ebs: {
                        snapshot_id: "XmlStringMaxLen255",
                        volume_size: 1,
                        volume_type: "BlockDeviceEbsVolumeType",
                        delete_on_termination: false,
                        iops: 1,
                        encrypted: false,
                      },
                      no_device: false,
                    },
                  ],
                  instance_monitoring: {
                    enabled: false,
                  },
                  spot_price: "SpotPrice",
                  iam_instance_profile: "XmlStringMaxLen1600",
                  ebs_optimized: false,
                  associate_public_ip_address: false,
                  placement_tenancy: "XmlStringMaxLen64",
                })
              rescue
              end
              say "Created EC2 Launch Configuration (#{launch_configuration_name})!"
            end
          end
        end
        say "Created EC2 Launch Configurations!", :green


        say "TODO: create cluster launch config", :blue
      end

      def create_ec2_autoscaling_groups
        say "TODO: create cluster group", :blue
      end

      def create_cloudwatch_ecs_alarms
        say "TODO: create cloudwatch alarms for cluster memory", :blue
      end

      def create_ecs_services
        say "Creating ECS services..."
        configuration[:services].each do |service_name, service|
          image_name = "#{project_name}_#{service_name}"
          service[:regions].each do |region_name, region|
            ecs = Aws::ECS::Client.new(region: region_name.to_s)
            elb = Aws::ElasticLoadBalancingV2::Client.new(region: region_name.to_s)
            region[:environments].each do |environment_name|
              role_name = "#{project_name}_#{environment_name}-ecsServiceRole"
              iam = Aws::IAM::Client.new
              begin
                role = iam.create_role({
                  assume_role_policy_document: "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":[\"ecs.amazonaws.com\"]},\"Action\":[\"sts:AssumeRole\"]}]}",
                  path: "/",
                  role_name: role_name,
                })
                iam.attach_role_policy({
                  policy_arn: "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceRole",
                  role_name: role_name,
                })
                say "Created ECS Service role..."
              rescue Aws::IAM::Errors::EntityAlreadyExists => err
              end

              cluster_name = "#{project_name}_#{environment_name}"
              task_name = "#{image_name}_#{environment_name}"
              task_definition_response = ecs.describe_task_definition({task_definition: task_name})
              task_definition = task_definition_response.task_definition.to_hash
              ecs_service = {
                cluster: cluster_name,
                deployment_configuration: {
                  maximum_percent: 200,
                  minimum_healthy_percent: 50,
                },
                desired_count: 0,
                service_name: service_name,
                task_definition: task_definition_response.task_definition.task_definition_arn
              }
              (service[:ports] || []).each do |port|
                if yes? "Should port #{port} for #{image_name} be load balanced in #{environment_name}?"
                  ecs_service[:role] = role_name
                  load_balancers = elb.describe_load_balancers.to_h
                  say "EC2 Load Balancers"
                  choices = ["CREATE NEW ELB"] + load_balancers[:load_balancers].map{|lb| "#{lb[:load_balancer_name]} (#{lb[:load_balancer_arn]})" }
                  choices = choices.map.with_index{ |a, i| [i+1, *a]}
                  print_table choices
                  selection = ask("Pick one:").to_i
                  if selection == 1
                    say "Creating new ELB not yet supported.", :red
                    say "Create a new ELB in your console.", :red
                    say "Then, run `ship setup` again.", :red
                    exit
                  else
                    load_balancer = load_balancers[:load_balancers][selection - 2]
                  end
                  say "Selected: #{load_balancer[:load_balancer_name]}"
                  target_group_name = "#{project_name}-#{service_name}-#{environment_name}"
                  target_group_resp = elb.create_target_group({
                    name: target_group_name,
                    port: port,
                    protocol: "HTTP",
                    vpc_id: load_balancer[:vpc_id]
                  }).to_h
                  target_group_arn = target_group_resp[:target_groups][0][:target_group_arn]
                  say "Created target group: #{target_group_name}."
                  ecs_service[:load_balancers] = [
                    {
                      container_name: service_name,
                      container_port: port,
                      target_group_arn: target_group_arn
                    }
                  ]
                end
              end
              begin
                service_response = ecs.create_service(ecs_service)
                say "Created ECS service (#{service_name})!"
              rescue Aws::ECS::Errors::InvalidParameterException => e
                case e.message
                when "Creation of service was not idempotent."
                  say "Service #{service_name} already exists.", :yellow
                  say "If you've changed load balancers setup, you must delete the existing service.", :yellow
                when /The target group with targetGroupArn ([^\s\\]+) does not have an associated load balancer./
                  say "Link Target Group to Load Balancer", :red
                  say "Visit `https://#{region_name}.console.aws.amazon.com/ec2/v2/home?region=#{region_name}#LoadBalancers:`", :red
                  say "Add listener for Target Group (#{$1})", :red
                else
                  raise e
                end
              end
            end
          end
        end
        say "Created ECS services!", :green
      end

      def create_cloudwatch_elb_alarms
        say "TODO: create cloudwatch alarms for elb latency / service units", :blue
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

      def config_s3_bucket
        configuration[:config_s3_bucket]
      end

    end
  end
end
