plugin_source_file = __FILE__.sub("_spec", "")
require_relative plugin_source_file.sub(".rb", "")
plugin_source_code = File.read(plugin_source_file)

plugin_source_code.scan(/needs ["'](.*?)["']/).flatten.each do |lib|
  require lib
end

describe SwfTasks do
  def build_execution(task_list, id, event_types)
    events = event_types.each_with_index.map do |type, index|
      mock("Event #{task_list} #{id} ##{index + 1}", event_type: type)
    end
    mock("execution #{task_list} #{id}", history_events: events, task_list: task_list)
  end

  let(:plugin_config_from_cloud_or_app_config) {
    Hash.new {|h, k| raise "Unexpected /home/scout/swf_tasks.yml config access: #{k}"}
  }

  let(:aws_swf) {
    mock(AWS::SimpleWorkflow, domains: Hash.new {|h, k| raise "Unexpected domain #{k}"}).tap {|swf|
      swf.domains["swf_dom"] = aws_domain
    }
  }

  let(:aws_domain) {mock(AWS::SimpleWorkflow::Domain, workflow_executions: workflow_executions)}
  let(:workflow_executions) {mock(AWS::SimpleWorkflow::WorkflowExecutionCollection)}

  let(:executions) {[
    build_execution("webcrm-tasklist", "1", %w[WorkflowExecutionStarted ActivityTaskScheduled]),
    build_execution("webcrm-tasklist", "2", %w[WorkflowExecutionStarted]),
    build_execution("webcrm-tasklist", "3", %w[WorkflowExecutionStarted ActivityTaskScheduled]),
    build_execution("changed-crm", "4", %w[WorkflowExecutionStarted ActivityTaskScheduled]),
    build_execution("cms", "5", %w[WorkflowExecutionStarted ActivityTaskScheduled]),
    # nothing for console
  ]}
  let(:last_run) {nil}
  let(:memory) {Hash.new}
  let(:options) {
    options_as_string = Scout::Plugin.extract_options_yaml_from_code(plugin_source_code)
    parsed_options = Scout::PluginOptions.from_yaml(options_as_string)
    parsed_options.select {|opt| opt.has_default?}.inject({}) do |memo, opt|
      memo[opt.name.to_sym] = opt.default; memo
    end
  }
  let(:plugin) {SwfTasks.new(last_run, memory, options)}
  let(:reports) {plugin.run[:reports]}
  let(:report) {reports.first}

  before do
    plugin_config_from_cloud_or_app_config["simple_workflow_access_key_id"] = "aki"
    plugin_config_from_cloud_or_app_config["simple_workflow_secret_access_key"] = "sak"
    plugin_config_from_cloud_or_app_config["simple_workflow_endpoint"] = "swf_ep"
    plugin_config_from_cloud_or_app_config["simple_workflow_domain"] = "swf_dom"

    YAML.should_receive(:load_file).with("/home/scout/swf_tasks.yml").
        and_return(plugin_config_from_cloud_or_app_config)
    AWS::SimpleWorkflow.should_receive(:new).with({
      access_key_id: "aki",
      secret_access_key: "sak",
      simple_workflow_endpoint: "swf_ep",
      use_ssl: true,
    }).and_return(aws_swf)


    aws_swf.domains["swf_dom"] = aws_domain

    executions.each do |execution|
      class << execution.history_events
        alias reverse_order reverse
      end
    end

    workflow_executions.should_receive(:with_status).with(:open).and_return(executions.each)
  end

  it "reports one report" do
    reports.should have(1).report
  end

  it "reports open tasks for every configured application (regardless of occurence)" do
    report.keys.should =~ %w[console_waiting_tasks crm_waiting_tasks cms_waiting_tasks]
    report["console_waiting_tasks"].should eq(0)
  end

  it "counts the number of open tasks per application" do
    report["console_waiting_tasks"].should eq(0)
    report["cms_waiting_tasks"].should eq(1)
  end

  it "auto-guesses the application from the task list name" do
    report.should_not have_key("changed-crm_waiting_tasks")
    report.should_not have_key("unknown_waiting_tasks")
    report["crm_waiting_tasks"].should eq(2 + 1)
  end
end
