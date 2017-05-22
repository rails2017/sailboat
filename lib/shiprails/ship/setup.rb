require "active_support/all"
require "aws-sdk"
require "base64"
require "fileutils"
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

      def create_vpcs
        say "Creating VPCs..."
        created_vpcs = []
        configuration[:services].each do |service_name, service|
          service[:regions].each do |region_name, region|
            ec2 = Aws::EC2::Client.new region: region_name.to_s
            region[:environments].each do |environment_name|
              vpc_name = "#{project_name}_#{environment_name}"
              unless created_vpcs.include? vpc_name
                begin
                  vpcs = ec2.describe_vpcs.vpcs
                  vpc = vpcs.find{ |v| v.tags.find{|t| t.key == "Name" }.try(:value) == vpc_name }
                  unless vpc.nil?
                    say "Found #{vpc_name}."
                    next
                  end
                  say "Setting up #{vpc_name}."
                  vpc_cidr_block = "10.0.0.0/16"
                  vpc = ec2.create_vpc({
                    amazon_provided_ipv_6_cidr_block: true,
                    cidr_block: vpc_cidr_block,
                  }).vpc
                  vpc = Aws::EC2::Vpc.new client: ec2, id: vpc.vpc_id
                  vpc.modify_attribute({
                    enable_dns_support: { value: true }
                  })
                  vpc.create_tags({ tags: [{ key: 'Name', value: vpc_name }]})
                  availability_zones = ec2.describe_availability_zones({
                    filters: [{
                      name: "state",
                      values: ["available"]
                    }]
                  }).availability_zones
                  say "Creating #{availability_zones.length} availability zones."
                  bits = 16
                  while true
                    begin
                      NetAddr::CIDR.create(vpc_cidr_block).subnet(:Bits => bits, :NumSubnets => availability_zones.count)
                    rescue
                      bits += 1
                      retry if bits <= 32
                    end
                    break
                  end
                  cidr_blocks = NetAddr::CIDR.create(vpc_cidr_block).subnet(:Bits => bits, :NumSubnets => availability_zones.count)
                  v6_cidr_blocks = NetAddr::CIDR.create(vpc.ipv_6_cidr_block_association_set.first.ipv_6_cidr_block).subnet(:Bits => 64, :NumSubnets => availability_zones.count)
                  availability_zones.each_with_index do |zone, idx|
                    ec2.create_subnet({
                      vpc_id: vpc.vpc_id,
                      cidr_block: cidr_blocks[idx],
                      ipv_6_cidr_block: v6_cidr_blocks[idx],
                      availability_zone: zone.zone_name,
                    })
                    say "Created subnet for #{zone.zone_name} availability zone (#{vpc_name})."
                  end
                  ig = ec2.create_internet_gateway.internet_gateway
                  ec2.attach_internet_gateway({
                    internet_gateway_id: ig.internet_gateway_id,
                    vpc_id: vpc.vpc_id,
                  })
                  say "Created internet gateway for #{vpc_name}."
                  route_table = ec2.create_route_table({
                    vpc_id: vpc.vpc_id,
                  }).route_table
                  say "Created route table for #{vpc_name}."
                  ec2.create_route({
                    destination_cidr_block: "0.0.0.0/0",
                    gateway_id: ig.internet_gateway_id,
                    route_table_id: route_table.route_table_id,
                  })
                  ec2.create_route({
                    destination_cidr_block: "::/0",
                    gateway_id: ig.internet_gateway_id,
                    route_table_id: route_table.route_table_id,
                  })
                # rescue Aws::IAM::Errors::EntityAlreadyExists => err
                end
                say "Created #{vpc_name} VPC."
                created_vpcs << vpc_name
              end
            end
          end
        end
        say "Created VPCs.", :green
      end

      def create_security_groups
        say "Creating security groups..."
        completed_vpcs = []
        configuration[:services].each do |service_name, service|
          service[:regions].each do |region_name, region|
            ec2 = Aws::EC2::Client.new region: region_name.to_s
            region[:environments].each do |environment_name|
              vpc_name = "#{project_name}_#{environment_name}"
              unless completed_vpcs.include? vpc_name
                begin
                  vpcs = ec2.describe_vpcs.vpcs
                  vpc = vpcs.find{ |v| v.tags.find{|t| t.key == "Name" }.try(:value) == vpc_name }
                  ecs_security_group_id = ec2.create_security_group({
                    group_name: "ecs-#{vpc_name}",
                    description: "ECS cluster instances",
                    vpc_id: vpc.vpc_id
                  }).group_id
                  ecs_security_group = Aws::EC2::SecurityGroup.new(client: ec2, id: ecs_security_group_id)
                  elb_security_group_id = ec2.create_security_group({
                    group_name: "elb-#{vpc_name}",
                    description: "ELB instances",
                    vpc_id: vpc.vpc_id
                  }).group_id
                  elb_security_group = Aws::EC2::SecurityGroup.new(client: ec2, id: elb_security_group_id)
                  public_web_security_group_id = ec2.create_security_group({
                    group_name: "public-web-#{vpc_name}",
                    description: "Public web ingress",
                    vpc_id: vpc.vpc_id
                  }).group_id
                  public_web_security_group = Aws::EC2::SecurityGroup.new(client: ec2, id: public_web_security_group_id)
                  datastores_security_group_id = ec2.create_security_group({
                    group_name: "datastores-#{vpc_name}",
                    description: "RDS, ElastiCache, etc. instances",
                    vpc_id: vpc.vpc_id
                  }).group_id
                  datastores_security_group = Aws::EC2::SecurityGroup.new(client: ec2, id: datastores_security_group_id)
                  team_access_security_group_id = ec2.create_security_group({
                    group_name: "team-access-#{vpc_name}",
                    description: "Ingress for team members",
                    vpc_id: vpc.vpc_id
                  }).group_id
                  team_access_security_group = Aws::EC2::SecurityGroup.new(client: ec2, id: team_access_security_group_id)
                  # allow ECS instances to receive traffic from ELBs
                  ecs_security_group.authorize_ingress({
                    ip_permissions: [
                      {
                        from_port: "-1",
                        to_port: "-1",
                        ip_protocol: "-1",
                        user_id_group_pairs: [{
                          group_id: elb_security_group.id,
                          vpc_id: vpc.vpc_id,
                        }],
                      }
                    ]
                  })
                  # allow public web group to receive traffic from the web
                  ec2.authorize_security_group_ingress({
                    group_id: public_web_security_group_id,
                    ip_permissions: [
                      {
                        from_port: "80",
                        ip_ranges: [{
                          cidr_ip: "0.0.0.0/0"
                        }],
                        to_port: "80",
                        ip_protocol: "tcp",
                        ipv_6_ranges: [{
                          cidr_ipv_6: "::/0"
                        }]
                      },
                      {
                        from_port: "443",
                        ip_ranges: [{
                          cidr_ip: "0.0.0.0/0"
                        }],
                        to_port: "443",
                        ip_protocol: "-1",
                        ipv_6_ranges: [{
                          cidr_ipv_6: "::/0"
                        }]
                      },
                    ]
                  })
                  # allow datastore instances to receive traffic from ECS instances
                  current_ip_address = open('http://whatismyip.akamai.com').read
                  ec2.authorize_security_group_ingress({
                    group_id: team_access_security_group_id,
                    ip_permissions: [
                      {
                        from_port: "-1",
                        ip_ranges: [{
                          cidr_ip: "#{current_ip_address}/32"
                        }],
                        to_port: "-1",
                        ip_protocol: "-1",
                      },
                    ]
                  })
                  # allow ELBs to access ECS instances
                  elb_security_group.authorize_egress({
                    ip_permissions: [
                      {
                        from_port: "-1",
                        to_port: "-1",
                        ip_protocol: "-1",
                        user_id_group_pairs: [{
                          group_id: ecs_security_group.id,
                          vpc_id: vpc.vpc_id,
                        }],
                      }
                    ]
                  })
                rescue Aws::EC2::Errors::InvalidGroupDuplicate => err
                  say "Security groups for #{vpc_name} VPC already setup."
                end
                say "Created security groups for #{vpc_name} VPC."
                completed_vpcs << vpc_name
              end
            end
          end
        end
        say "Created security groups..", :green
      end

      def create_key_pairs
        say "Creating EC2 key pairs..."
        created_key_pairs = []
        configuration[:services].each do |service_name, service|
          service[:regions].each do |region_name, region|
            region[:environments].each do |environment_name|
              key_pair_name = "#{project_name}"
              unless created_key_pairs.include? key_pair_name
                begin
                  ec2 = Aws::EC2::Client.new(region: region_name.to_s)
                  key_pair = ec2.create_key_pair({
                    key_name: key_pair_name
                  })
                  File.open("#{project_name}.pem", 'w') { |file| file.write(key_pair.key_material) }
                  FileUtils.chmod 0600, "#{project_name}.pem"
                rescue Aws::EC2::Errors::InvalidKeyPairDuplicate => err
                  say "Key pair #{project_name} already exists."
                end
                created_key_pairs << key_pair_name
              end
            end
          end
        end
        say "Created EC2 key pairs.", :green
      end

      def create_ecs_autoscale_role
        say "Creating ECS AutoScaling IAM roles..."
        iam = Aws::IAM::Client.new
        created_roles = []
        configuration[:services].each do |service_name, service|
          service[:regions].each do |region_name, region|
            region[:environments].each do |environment_name|
              role_name = "#{project_name}_#{environment_name}-ecsAutoScaling"
              unless created_roles.include? role_name
                begin
                  role = iam.create_role({
                    assume_role_policy_document: "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":[\"application-autoscaling.amazonaws.com\"]},\"Action\":[\"sts:AssumeRole\"]}]}",
                    path: "/",
                    role_name: role_name,
                  })
                  iam.attach_role_policy({
                    policy_arn: "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceAutoscaleRole",
                    role_name: role_name,
                  })
                rescue Aws::IAM::Errors::EntityAlreadyExists => err
                end
                say "Created #{role_name} IAM role."
                created_roles << role_name
              end
            end
          end
        end
        say "Created ECS AutoScaling IAM roles.", :green
      end

      def create_ecs_instance_role
        say "Creating ECS EC2 Instance IAM roles..."
        iam = Aws::IAM::Client.new
        created_roles = []
        configuration[:services].each do |service_name, service|
          service[:regions].each do |region_name, region|
            region[:environments].each do |environment_name|
              role_name = "#{project_name}_#{environment_name}-ecsInstanceRole"
              unless created_roles.include? role_name
                begin
                  role = iam.create_role({
                    assume_role_policy_document: "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":[\"ec2.amazonaws.com\"]},\"Action\":[\"sts:AssumeRole\"]}]}",
                    path: "/",
                    role_name: role_name,
                  })
                  iam.create_instance_profile({
                    instance_profile_name: role_name,
                  })
                  iam.add_role_to_instance_profile({
                    instance_profile_name: role_name,
                    role_name: role_name,
                  })
                  iam.attach_role_policy({
                    policy_arn: "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role",
                    role_name: role_name,
                  })
                  iam.put_role_policy({
                    policy_document: "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:DescribeLogGroups\",\"logs:DescribeLogStreams\",\"logs:PutLogEvents\"],\"Effect\":\"Allow\",\"Resource\":\"arn:aws:logs:#{region_name.to_s}:#{aws_account_number}:log-group:#{project_name}_#{environment_name}\"}]}",
                    policy_name: "ecs-cloudwatch-logs",
                    role_name: role_name,
                  })
                  iam.put_role_policy({
                    policy_document: "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"ecs:DescribeTasks\",\"ecs:ListContainerInstances\",\"ecs:ListTasks\",\"ecs:StartTask\",\"ecs:StopTask\"],\"Resource\":\"arn:aws:ecs:#{region_name.to_s}:#{aws_account_number}:cluster/#{project_name}_#{environment_name}\"}]}",
                    policy_name: "ecs-tasks",
                    role_name: role_name,
                  })
                  iam.put_role_policy({
                    policy_document: "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"Stmt1492034037000\",\"Effect\":\"Allow\",\"Action\":[\"s3:Get*\"],\"Resource\":[\"arn:aws:s3:::#{project_name}-config/#{environment_name}/*\"]}]}",
                    policy_name: "read-config-from-s3",
                    role_name: role_name,
                  })
                rescue Aws::IAM::Errors::EntityAlreadyExists => err
                end
                say "Created #{role_name} IAM role."
                created_roles << role_name
              end
            end
          end
        end
        say "Created ECS EC2 Instance IAM roles.", :green
      end

      def create_ecs_task_role
        say "Creating ECS Task IAM roles..."
        iam = Aws::IAM::Client.new
        created_roles = []
        configuration[:services].each do |service_name, service|
          service[:regions].each do |region_name, region|
            region[:environments].each do |environment_name|
              role_name = "#{project_name}_#{environment_name}-ecs-task"
              unless created_roles.include? role_name
                begin
                  role = iam.create_role({
                    assume_role_policy_document: "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":[\"ecs-tasks.amazonaws.com\"]},\"Action\":[\"sts:AssumeRole\"]}]}",
                    path: "/",
                    role_name: role_name,
                  })
                  iam.put_role_policy({
                    policy_document: "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"Stmt1492034037000\",\"Effect\":\"Allow\",\"Action\":[\"s3:Get*\"],\"Resource\":[\"arn:aws:s3:::#{project_name}-config/#{environment_name}/*\"]}]}",
                    policy_name: "read-config-from-s3",
                    role_name: role_name,
                  })
                rescue Aws::IAM::Errors::EntityAlreadyExists => err
                end
                say "Created #{role_name} IAM role."
                created_roles << role_name
              end
            end
          end
        end
        say "Created ECS Task IAM roles.", :green
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
                      command: [service[:command]],
                      cpu: service[:resources][:cpu_units],
                      essential: true,
                      environment: [
                        { name: "AWS_REGION", value: region_name.to_s },
                        { name: "RACK_ENV", value: environment_name },
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
                      }
                    }
                  ],
                  family: task_name,
                  task_role_arn: "arn:aws:iam::#{aws_account_number}:role/#{project_name}_#{environment_name}-ecs-task"
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
        say "Creating EC2 LaunchConfigurations..."
        autoscaling = Aws::AutoScaling::Client.new
        created_launch_configurations = []
        configuration[:services].each do |service_name, service|
          service[:regions].each do |region_name, region|
            region[:environments].each do |environment_name|
              launch_configuration_name = "#{project_name}_#{environment_name}-v1"
              unless created_launch_configurations.include? launch_configuration_name
                begin
                  ec2 = Aws::EC2::Client.new(region: region_name.to_s)
                  images = ec2.describe_images({
                    filters: [
                      {
                        name: 'name',
                        values: ['amzn-ami-201*-amazon-ecs-optimized']
                      },
                      {
                        name: 'owner-alias',
                        values: ['amazon']
                      },
                      {
                        name: 'state',
                        values: ['available']
                      },
                    ],
                  }).images
                  image = images.sort_by(&:name).last # get the newest version
                  vpcs = ec2.describe_vpcs.vpcs
                  vpc = vpcs.find{ |v| v.tags.find{|t| t.key == "Name" }.try(:value) == "#{project_name}_#{environment_name}" }
                  security_groups = ec2.describe_security_groups({
                    filters: [
                      {
                        name: "vpc-id",
                        values: [
                          vpc.vpc_id
                        ],
                      },
                    ],
                  }).security_groups
                  security_group = security_groups.find{ |group| group.group_name == "ecs-#{project_name}_#{environment_name}" }
                  autoscaling.create_launch_configuration({
                    block_device_mappings: [
                      {
                        device_name: "/dev/xvdcz",
                        ebs: {
                          delete_on_termination: true,
                          encrypted: false,
                          volume_size: 22,
                          volume_type: "gp2",
                        },
                      },
                    ],
                    iam_instance_profile: "#{project_name}_#{environment_name}-ecsInstanceRole",
                    image_id: image.image_id,
                    instance_type: "t2.small",
                    key_name: "#{project_name}",
                    launch_configuration_name: launch_configuration_name,
                    security_groups: [ security_group.group_id ],
                    user_data: Base64.encode64("#!/bin/bash
echo ECS_CLUSTER=#{project_name}_#{environment_name} >> /etc/ecs/ecs.config"),
                  })
                rescue Aws::AutoScaling::Errors::AlreadyExists
                  say "TODO: update LaunchConfiguration with latest stuff.", :blue
                end
                created_launch_configurations << launch_configuration_name
              end
            end
          end
        end
        say "Created EC2 LaunchConfigurations!", :green
      end

      def create_ec2_autoscaling_groups
        say "Creating EC2 AutoScaling Groups..."
        autoscaling = Aws::AutoScaling::Client.new
        created_auto_scaling_groups = []
        configuration[:services].each do |service_name, service|
          service[:regions].each do |region_name, region|
            region[:environments].each do |environment_name|
              group_name = "#{project_name}_#{environment_name}"
              unless created_auto_scaling_groups.include? group_name
                ec2 = Aws::EC2::Client.new region: region_name.to_s
                vpcs = ec2.describe_vpcs.vpcs
                vpc = vpcs.find{ |v| v.tags.find{|t| t.key == "Name" }.try(:value) == "#{project_name}_#{environment_name}" }
                subnets = ec2.describe_subnets({
                  filters: [
                    {
                      name: "vpc-id",
                      values: [
                        vpc.vpc_id
                      ],
                    },
                  ],
                }).subnets
                zones_in_region = subnets.map(&:availability_zone)
                subnets_in_region = subnets.map(&:subnet_id)
                begin
                  autoscaling.create_auto_scaling_group({
                    auto_scaling_group_name: group_name,
                    availability_zones: zones_in_region,
                    default_cooldown: 300,
                    health_check_grace_period: 300,
                    health_check_type: "EC2",
                    launch_configuration_name: "#{project_name}_#{environment_name}-v1",
                    max_size: 10,
                    min_size: 1,
                    vpc_zone_identifier: subnets_in_region.join(',')
                  })
                rescue Aws::AutoScaling::Errors::AlreadyExists
                  say "TODO: update AutoScaling Group with latest stuff like LaunchConfiguration name.", :blue
                end
                created_auto_scaling_groups << group_name
              end
            end
          end
        end
        say "Created EC2 LaunchConfigurations!", :green
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

      def create_cloudwatch_ecs_alarms
        say "TODO: create cloudwatch alarms for cluster memory", :blue
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

      def aws_account_number
        @aws_account_number ||= Aws::STS::Client.new().get_caller_identity.account
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
