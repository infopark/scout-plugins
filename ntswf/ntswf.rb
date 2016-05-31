require 'scout'


class Ntswf < Scout::Plugin
  needs 'aws-sdk-v1'
  needs 'yaml'
  needs 'json'

  UNIT_PATTERN_TO_APP = {
    /scrivitocom/ => "dashboard",
    /crm/ => "crm",
    /scriv.*cms/ => "backend",
    /demo/ => "demo",         # old
    /scrivito_app/ => "demo", # new
    /cms/ => "cms",           # ICE?
  }

  OPTIONS = <<-EOO
    applications:
      name: Application Names
      note: One or two from #{UNIT_PATTERN_TO_APP.values.sort}
      default: 'backend dashboard'
  EOO

  class LastEvent
    class Identity < Struct.new(:hostname, :pid, :stack_id)

      class << self
        def for(event)
          identity = event.attributes[:identity] or
              raise "Missing identity in event: attributes = #{event.attributes}"
          hostname, pid, stack_id = identity.split(":")
          raise "Unexpected identity #{identity} - cannot split by :" unless pid
          raise "Unexpected pid #{pid} from identity #{identity}" unless pid.to_i.to_s == pid
          new(hostname, pid, stack_id)
        end

        def hostname
          @hostname ||= `hostname`.strip
        end
      end
    end

    def initialize(execution, swf_config, reporter)
      @execution = execution
      @swf_config = swf_config
      @reporter = reporter
    end

    def event_type
      event.event_type
    end

    def zombie?
      if aws_expects_running_here? && !running?
        # the inspected event is still the last event of the execution
        if event.id == current_last_event_of_execution.id
          reporter.log("[#{Time.now}] Zombie | #{log_data.join(" | ")}")
          true
        end
      end
    end

    def running?
      File.exists?("/proc/#{identity.pid}")
    end

    def computed_app_name
      (@computed_app_name ||= [compute_app_name]).first
    end

    def app_name
      computed_app_name || "unknown"
    end

    def remember_waiting
      reporter.remember_waiting(app_name, log_data(false).join(" | "))
    end

    private

    attr_reader :execution, :swf_config, :reporter

    def first_event_attributes
      @first_event_attributes ||= execution.history_events.first.attributes
    end

    def compute_app_name
      input_as_json = first_event_attributes[:input]
      if input_as_json
        input = JSON(input_as_json)
        unit = input["unit"]
        match = UNIT_PATTERN_TO_APP.keys.detect {|pattern, app| unit =~ pattern}
        if match
          UNIT_PATTERN_TO_APP[match]
        end
      end
    end

    def aws_expects_running_here?
      identity.hostname == Identity.hostname && !foreign_stack?
    end

    # requires stack_id to be both configured via config and provided by event
    def foreign_stack?
      if identity.stack_id
        my_stack_id = swf_config["stack_id"]
        my_stack_id && identity.stack_id != my_stack_id
      end
    end

    def event
      @event ||= current_last_event_of_execution
    end

    def current_last_event_of_execution
      execution.history_events.reverse_order.first
    end

    def identity
      @identity ||= Identity.for(event)
    end

    def log_data(zombie = true)
      d = []
      if zombie
        d << "identity: #{identity.to_a}" # to_h prefered - Ruby 2.x
        d << "app: #{app_name}"
        d << "type: #{event_type}"
      end
      d << "execution: Rails.application.workflow.ntswf.domain.workflow_executions.at"\
          "(\"#{execution.workflow_id}\", \"#{execution.run_id}\")"
      d << "details: #{first_event_attributes.to_h}"
      d
    end
  end

  def waiting
    @waiting ||= Hash.new {|h, k| h[k] = []}
  end

  def remember_waiting(app, message)
    waiting[app] << message
  end

  def log(message)
    File.open("/var/log/scout/plugins/ntswf.log", "a") do |f|
      f.puts message
    end
  end

  def log_waiting(limit)
    waiting.each do |app, messages|
      next if messages.count < limit
      prefix = "[#{Time.now} Waiting]"
      continued = "\n ...#{" " * (prefix.length - 3)}"
      log "#{prefix} app: #{app} | count: #{messages.count}#{continued}#{messages.join(continued)}"
    end
  end

  def swf_config
    @swf_config ||= YAML.load_file("/etc/scout/plugins/ntswf.yml")
  end

  def metric_key(name, app_or_event)
    app =
        case app_or_event
        when String
          app_or_event
        else
          app_name = app_or_event.computed_app_name
          case app_name
          when nil
            "unknown"
          when *applications
            app_name
          else
            "other"
          end
        end
    "#{app}_#{name}_tasks"
  end

  def swf_domain
    domain = AWS::SimpleWorkflow.new({
      :access_key_id => swf_config["simple_workflow_access_key_id"],
      :secret_access_key => swf_config["simple_workflow_secret_access_key"],
      :simple_workflow_endpoint => swf_config["simple_workflow_endpoint"],
      :use_ssl => true,
    }).domains[swf_config["simple_workflow_domain"]]
  end

  def open_executions
    swf_domain.workflow_executions.with_status(:open)
  end

  def applications
    @applications ||= option(:applications).split(/[ ,]+/)
  end

  def statistics
    @statistics ||= begin
      statistics = Hash.new(0)
      %w[open waiting waiting_decision waiting_activity zombie].each do |type|
        (applications + %w[other unknown]).each do |app|
          statistics[metric_key(type, app)] = 0
        end
      end
      statistics
    end
  end

  def build_report
    open_executions.each do |execution|
      last_event = LastEvent.new(execution, swf_config, self)
      statistics[metric_key("open", last_event)] += 1
      case last_event.event_type
      when "DecisionTaskScheduled"
        last_event.remember_waiting
        statistics[metric_key("waiting", last_event)] += 1
        statistics[metric_key("waiting_decision", last_event)] += 1
      when "ActivityTaskScheduled"
        last_event.remember_waiting
        statistics[metric_key("waiting", last_event)] += 1
        statistics[metric_key("waiting_activity", last_event)] += 1
      when "ActivityTaskStarted", "DecisionTaskStarted"
        if last_event.zombie?
          statistics[metric_key("zombie", last_event)] += 1
        end
      end
    end
    log_waiting(3)
    report(statistics)
  end
end
