require 'scout'

class SwfTasks < Scout::Plugin
  needs 'aws-sdk'
  needs 'yaml'

  def workflow_list_mapping
    {
      "webcrm-tasklist" => "crm",
      "cms" => "cms",
      "console" => "console"
    }
  end

  def app_name_for_task_list(real_task_list)
    case real_task_list
    when /cms/
      "cms"
    when /crm/
      "crm"
    when /console/
      "console"
    else
      "unknown"
    end
  end

  def metric_for_app(app)
    "#{app}_waiting_tasks"
  end

  def swf_domain
    config = YAML.load_file("/home/scout/swf_tasks.yml")
    domain = AWS::SimpleWorkflow.new({
      :access_key_id => config["simple_workflow_access_key_id"],
      :secret_access_key => config["simple_workflow_secret_access_key"],
      :simple_workflow_endpoint => config["simple_workflow_endpoint"],
      :use_ssl => true,
    }).domains[config["simple_workflow_domain"]]
  end

  def open_executions
    swf_domain.workflow_executions.with_status(:open)
  end

  def statistics
    @statistics ||= begin
      statistics = Hash.new(0)
      workflow_list_mapping.values.each {|app| statistics[metric_for_app(app)] = 0}
      statistics
    end
  end

  def build_report
    open_executions.each do |ex|
      last_event = ex.history_events.reverse_order.first
      case last_event.event_type
      when "ActivityTaskScheduled"
        app = app_name_for_task_list(ex.task_list)
        statistics[metric_for_app(app)] += 1
      end
    end
    report(statistics)
  end
end
