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

  needs 'aws-sdk-v1'
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

  def compute_counts
    healths = AWS::ELB.new.load_balancers[@elb_name].instances.health
    healths.each_with_object([Hash.new(0), Hash.new(0)]) do |health, (healthy, transient)|
      instance, state = health[:instance], health[:state]
      zone = instance.availability_zone
      if state == 'InService'
        healthy[zone] += 1
      else
        description = health[:description]
        case description
        when /transient error/
          transient[zone] += 1
          healthy[zone] += 1
        else
          # enforce explicit entry for this zone
          healthy[zone] += 0
        end
        log_unhealthy(zone, instance.id, description)
      end
    end
  end

  def statistic
    healthy_counts, transient_counts = compute_counts
    total_healthy_count = healthy_counts.values.reduce(:+)
    zone_count = healthy_counts.size
    healthy_zone_count = healthy_counts.select {|k, v| v > 0}.size
    healthy_counts.merge({
      :total => total_healthy_count,
      :zones => zone_count,
      :healthy_zones => healthy_zone_count,
      :unhealthy_zones => zone_count - healthy_zone_count,
      :unknown_zones => transient_counts.size,
      :minimum => healthy_counts.values.min,
      :average => zone_count > 0 ? total_healthy_count / zone_count.to_f : 0
    })
  end

  def log_unhealthy(zone, instance, description)
    File.open(File.expand_path(@error_log_path), 'a') do |f|
      f.puts("[#{Time.now}] [#{@elb_name}] [#{zone}] [#{instance}] [#{description}]")
    end
  end
end
