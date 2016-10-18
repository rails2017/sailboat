require "active_support/all"
require "aws-sdk"
require "git"
require "netaddr"
require "thor/group"

module Shiprails
  class Ship < Thor
    class Setup < Thor::Group
      include Thor::Actions

      class_option "path",
        aliases: ["-p"],
        default: ".",
        desc: "Specify a configuration path"
      class_option "ami-name",
        aliases: ["-ami"],
        default: "amzn-ami-2016.03.i-amazon-ecs-optimized",
        desc: "Specify an AWS EC2 AMI name"

      def create_vpc
        say "Creating VPCs..."
        cluster_names = []
        configuration[:services].each do |service_name, service|
          image_name = "#{project_name}_#{service_name}"
          service[:regions].each do |region_name, region|
            region[:environments].each do |environment_name|
              cluster_name = "#{project_name}_#{environment_name}"
              next if cluster_names.include? cluster_name
              cluster_names << cluster_name
              client = Aws::EC2::Client.new(region: region_name.to_s)
              vpcs = client.describe_vpcs({
                filters: [
                  {
                    name: "tag-key",
                    values: ["Name"]
                  },
                  {
                    name: "tag-value",
                    values: [cluster_name]
                  }
                ]
              }).vpcs
              if vpcs.empty?
                cidr = NetAddr::CIDR.create("10.0.0.0/16")
                vpc = client.create_vpc({
                  cidr_block: cidr.to_s
                }).vpc
                vpc = Aws::EC2::Vpc.new(vpc.vpc_id)
                vpc.create_tags({
                  tags: [
                    {
                      key: "Name",
                      value: cluster_name
                    }
                  ]
                })
                availability_zones = client.describe_availability_zones.availability_zones
                count = availability_zones.count.to_f
                count = (count / 4.0).ceil.to_i * 4 # need multiples of 4 for CIDR math, I guess?
                subnets = cidr.subnet IPCount: (cidr.size / count)
                availability_zones.each_with_index do |availability_zone, i|
                  next unless availability_zone.state == "available"
                  subnet = vpc.create_subnet({
                    cidr_block: subnets[i],
                    availability_zone: availability_zone.zone_name
                  })
                  subnet = Aws::EC2::Subnet.new(subnet.id)
                  subnet.create_tags({
                    tags: [
                      {
                        key: "Name",
                        value: "#{cluster_name}-#{availability_zone.zone_name}"
                      }
                    ]
                  })
                end
                internet_gateway = client.create_internet_gateway().internet_gateway
                vpc.attach_internet_gateway({
                  internet_gateway_id: internet_gateway.internet_gateway_id
                })
                internet_gateway = Aws::EC2::InternetGateway.new internet_gateway.internet_gateway_id
                internet_gateway.create_tags({
                  tags: [
                    {
                      key: "Name",
                      value: cluster_name
                    }
                  ]
                })
                say "Created VPC (#{cluster_name})."
              end
            end
          end
        end
        say "Created VPCs.", :green
      end

      def create_security_groups
        say "Creating Security Groups..."
        cluster_names = []
        configuration[:services].each do |service_name, service|
          image_name = "#{project_name}_#{service_name}"
          service[:regions].each do |region_name, region|
            region[:environments].each do |environment_name|
              cluster_name = "#{project_name}_#{environment_name}"
              next if cluster_names.include? cluster_name
              cluster_names << cluster_name
              client = Aws::EC2::Client.new(region: region_name.to_s)
              vpcs = client.describe_vpcs({
                filters: [
                  {
                    name: "tag-key",
                    values: ["Name"]
                  },
                  {
                    name: "tag-value",
                    values: [cluster_name]
                  }
                ]
              }).vpcs
              vpc = vpcs.first
              begin
                app_security_group = client.create_security_group({
                  group_name: "#{cluster_name}_app",
                  description: "The app group for #{cluster_name} (Shiprails managed)",
                  vpc_id: vpc.vpc_id
                })
                puts app_security_group.inspect
              rescue Aws::EC2::Errors::InvalidGroupDuplicate => err
                app_security_group = client.describe_security_groups({
                  filters: [
                    {
                      name: "vpc-id",
                      values: [vpc.vpc_id]
                    }
                  ],
                  group_names: ["#{cluster_name}_app"]
                }).security_groups.first
              end
              app_security_group = Aws::EC2::SecurityGroup.new(app_security_group.group_id)
              begin
                services_security_group = client.create_security_group({
                  group_name: "#{cluster_name}_services",
                  description: "The services (cache, database, search, etc.) group for #{cluster_name} (Shiprails managed)",
                  vpc_id: vpc.vpc_id
                })
              rescue Aws::EC2::Errors::InvalidGroupDuplicate => err
                services_security_group = client.describe_security_groups({
                  filters: [
                    {
                      name: "vpc-id",
                      values: [vpc.vpc_id]
                    }
                  ],
                  group_names: ["#{cluster_name}_services"]
                }).security_groups.first
              end
              services_security_group = Aws::EC2::SecurityGroup.new(services_security_group.group_id)
              begin
                web_security_group = client.create_security_group({
                  group_name: "#{cluster_name}_web",
                  description: "The database group for #{cluster_name} (Shiprails managed)",
                  vpc_id: vpc.vpc_id
                })
              rescue Aws::EC2::Errors::InvalidGroupDuplicate => err
                web_security_group = client.describe_security_groups({
                  filters: [
                    {
                      name: "vpc-id",
                      values: [vpc.vpc_id]
                    }
                  ],
                  group_names: ["#{cluster_name}_web"]
                }).security_groups.first
              end
              web_security_group = Aws::EC2::SecurityGroup.new(web_security_group.group_id)
              app_security_group.authorize_ingress({
                ip_protocol: "all",
                source_security_group_name: web_security_group.group_id,
                source_security_group_owner_id: web_security_group.owner_id,
              })
              services_security_group.authorize_ingress({
                ip_protocol: "all",
                source_security_group_name: app_security_group.group_id,
                source_security_group_owner_id: app_security_group.owner_id,
              })
              web_security_group.authorize_ingress({
                from_port: 80,
                ip_protocol: "tcp",
                source_security_group_name: "amazon-elb-sg",
                source_security_group_owner_id: "amazon-elb",
                to_port: 80
              })
              web_security_group.authorize_ingress({
                from_port: 443,
                ip_protocol: "tcp",
                source_security_group_name: "amazon-elb-sg",
                source_security_group_owner_id: "amazon-elb",
                to_port: 443
              })
              # TODO: outbound from web to app?
              say "Created security group (#{cluster_name})."
            end
          end
        end
        say "Created Security Groups.", :green


        exit
      end

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

      def create_ecs_tasks
        say "Creating ECS tasks..."
        configuration[:services].each do |service_name, service|
          image_name = "#{project_name}_#{service_name}"
          service[:regions].each do |region_name, region|
            ecs = Aws::ECS::Client.new(region: region_name.to_s)
            region[:environments].each do |environment_name|
              cluster_name = "#{project_name}_#{environment_name}"
              task_name = "#{image_name}_#{environment_name}"
              begin
                task_definition_description = ecs.describe_task_definition({task_definition: task_name})
                task_definition = task_definition_description.task_definition.to_hash
                task_definition.delete :task_definition_arn
                task_definition.delete :revision
                task_definition.delete :status
                task_definition.delete :requires_attributes
                say "Updating ECS task (#{task_name})."
              rescue Aws::ECS::Errors::ClientException => e
                task_definition = {
                  container_definitions: [
                    {
                      command: service[:command].split(' '),
                      cpu: service[:resources][:cpu_units],
                      essential: true,
                      environment: [
                        { name: "AWS_REGION", value: region_name.to_s },
                        { name: "RACK_ENV", value: environment_name },
                        { name: "S3_CONFIG_BUCKET", value: config_s3_bucket },
                        { name: "S3_CONFIG_REVISION", value: "0" }
                      ],
                      image: "#{region[:repository_url]}:latest",
                      log_configuration: {
                        log_driver: "awslogs",
                        options: {
                          "awslog-group" => cluster_name,
                          "awslogs-region" => region_name.to_s,
                          "awslogs-stream-prefix" => ""
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
                      }
                    }
                  ],
                  family: task_name
                }
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
        say "Creating Auto-Scaling Launch Configuration..."
        cluster_names = []
        configuration[:services].each do |service_name, service|
          image_name = "#{project_name}_#{service_name}"
          service[:regions].each do |region_name, region|
            region[:environments].each do |environment_name|
              cluster_name = "#{project_name}_#{environment_name}"
              next if cluster_names.include? cluster_name
              cluster_names << cluster_name
              client = Aws::AutoScaling::Client.new(region: region_name.to_s)
              launch_configurations = client.describe_launch_configurations.launch_configurations.select{|config| config.launch_configuration_name.include? cluster_name }
              ec2_client = Aws::EC2::Client.new(region: region_name.to_s)
              image = ec2_client.describe_images({
                filters: [
                  {
                    name: "name",
                    values: [options['ami-name']]
                  },
                  {
                    name: "virtualization-type",
                    values: ["hvm"]
                  }
                ]
              }).images.first
              new_launch_configuration = {
                launch_configuration_name: "#{cluster_name}-v#{launch_configurations.count}",
                image_id: image.image_id
              }
              puts new_launch_configuration.inspect
              # TODO: if new_launch_configuration != launch_configurations.last.to_h, then name and create_launch_configuration
              # TODO: ask user for SSH key or create new key pair and store in shiprails.pem
              exit
            end
          end
        end
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
                if yes? "Should port #{port} for #{image_name} be load balanced?"
                  ecs_service[:role] = "ecsServiceRole"
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

      def create_iam_groups
        say "TODO: create cloudwatch logs read group", :blue
        say "TODO: create scale group", :blue
        say "TODO: create deploy IAM group", :blue
        say "TODO: create run task IAM group", :blue
        say "TODO: create exec interactive IAM group", :blue
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
