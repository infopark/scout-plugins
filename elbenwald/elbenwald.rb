require 'scout'

class Elbenwald < Scout::Plugin
  OPTIONS = <<-EOS
  elb_name:
    name: ELB name
    notes: Name of the ELB
  aws_credentials_path:
    name: AWS credentials path
    notes: Full path to a YAML file with AWS credentials
    default: ~/elbenwald.yml
  error_log_path:
    name: Error log path
    notes: Full path to error log file
    default: ~/elbenwald.error.log
  EOS

  needs 'aws-sdk'
  needs 'yaml'

  def build_report
    @elb_name = option(:elb_name).to_s.strip
    @aws_credentials_path = option(:aws_credentials_path).to_s.strip
    @error_log_path = option(:error_log_path).to_s.strip

    return error('Please provide name of the ELB') if @elb_name.empty?
    return error('Please provide a path to AWS configuration') if @aws_credentials_path.empty?
    return error('Please provide a path error log') if @error_log_path.empty?

    configure

    report(statistic)
  end

  private

  def configure
    AWS.config(YAML.load_file(File.expand_path(@aws_credentials_path)))
  end

  def statistic
    healthy_count = Hash.new(0)

    AWS::ELB.new.load_balancers[@elb_name].instances.health.each do |health|
      instance, state = health[:instance], health[:state]
      zone =
        begin
          instance.availability_zone
        rescue AWS::ELB::Errors::AccessDenied, AWS::EC2::Errors::UnauthorizedOperation
          nil
        end
      healthy = state == 'InService' or log_unhealthy(zone, instance.id, health[:description])
      healthy_count[zone] += healthy ? 1 : 0
    end

    total_healthy_count = healthy_count.values.reduce(:+)
    zone_count = healthy_count.size
    healthy_zone_count = healthy_count.select {|k, v| v > 0}.size

    statistic = healthy_count.dup
    # See AccessDenied
    statistic.delete(nil)
    statistic.merge({
      :total => total_healthy_count,
      :zones => zone_count,
      :healthy_zones => healthy_zone_count,
      :unhealthy_zones => zone_count - healthy_zone_count,
      :minimum => healthy_count.values.min,
      :average => zone_count > 0 ? total_healthy_count / zone_count.to_f : 0
    })
  end

  def log_unhealthy(zone, instance, description)
    File.open(File.expand_path(@error_log_path), 'a') do |f|
      f.puts("[#{Time.now}] [#{@elb_name}] [#{zone}] [#{instance}] [#{description}]")
    end
  end
end
