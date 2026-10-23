require 'json'
require_relative 'test_host_boot'

def check_result(condition, message)
  raise message unless condition
end

class ResultDialog
  attr_reader :scripts, :callbacks
  def initialize; @scripts = []; @callbacks = {}; end
  def add_action_callback(name, &block); @callbacks[name] = block; end
  def execute_script(script); @scripts << script; end
  def close; end
end

SUHub.register_command(id: 'result_cancel', title: 'Cancel') { SUHub::Result.cancelled(changed: false) }
SUHub.register_command(id: 'result_done', title: 'Done') { SUHub::Result.completed(changed: true, data: { count: 2 }) }
SUHub.register_command(id: 'result_start', title: 'Start') do
  check_result(!SUHub.current_invocation_id.to_s.empty?, 'Missing interactive invocation token')
  SUHub::Result.started(changed: false)
end
SUHub.register_command(id: 'result_false', title: 'False') { false }
SUHub.register_command(id: 'result_nil', title: 'Legacy nil') { nil }
SUHub.register_command(id: 'result_true', title: 'Legacy true') { true }
SUHub.register_command(id: 'result_error', title: 'Error') { raise IOError, 'fixture io error' }
SUHub.register_command(id: 'result_input', title: 'Input') { raise ArgumentError, 'fixture invalid input' }

{
  'result_cancel' => ['cancelled', false], 'result_done' => ['completed', true],
  'result_start' => ['started', true], 'result_false' => ['failed', false],
  'result_nil' => ['started', true], 'result_true' => ['completed', true],
  'result_error' => ['failed', false], 'result_input' => ['unavailable', false],
  'unknown_result_command' => ['unavailable', false]
}.each do |id, (status, ok)|
  value = SUHub.run_command_result(id, request_id: 'fixture-request')
  check_result(value[:status] == status && value[:ok] == ok, "Wrong result for #{id}: #{value}")
  check_result(value[:commandId] == id && value[:requestId] == 'fixture-request', 'Missing result routing metadata')
  check_result(JSON.parse(JSON.generate(value))['status'] == status, 'Result not serializable')
  check_result(SUHub.current_invocation_id.nil?, 'Command context leaked')
end
check_result(SUHub.run_command_result('result_nil')[:code] == 'legacy_result_unconfirmed', 'Legacy nil was assumed complete')
check_result(SUHub.run_command('result_cancel') == false, 'Cancellation Boolean compatibility incorrect')
check_result(SUHub.run_command('result_start') == true, 'Interactive Boolean compatibility incorrect')
check_result(SUHub.run_command_result('result_error')[:data][:errorType] == 'IOError', 'Exception type lost')

dialog = ResultDialog.new
SUHub.instance_variable_set(:@panel, dialog)
SUHub.bind_callbacks(dialog)
dialog.callbacks.fetch('run_command').call(nil, 'result_start', 'bridge-start-1')
started = SUHub.state_payload[:commandResults].last
check_result(started[:status] == 'started' && started[:requestId] == 'bridge-start-1', 'Bridge request ID lost before asynchronous finish')
finished = SUHub.finish_command(started[:invocationId], status: :completed, changed: true, data: { paintedCount: 1 })
check_result(finished[:commandId] == 'result_start' && finished[:requestId] == 'bridge-start-1', 'Completion lost command/request routing')
check_result(dialog.scripts.any? { |s| s.include?('__onCommandResult') && s.include?('paintedCount') }, 'Missing terminal event')
count = dialog.scripts.size
check_result(SUHub.finish_command(started[:invocationId], status: :cancelled) == false, 'Terminal result overwritten')
check_result(dialog.scripts.size == count, 'Duplicate terminal event emitted')
check_result(SUHub.finish_command('unknown-invocation', status: :completed) == false, 'Unknown invocation accepted')

SUHub::Settings.save('shortcuts' => [{ 'id' => 'cancel-shortcut', 'title' => 'Cancel', 'type' => 'command', 'target' => 'result_cancel' }])
shortcut = SUHub.execute_shortcut('cancel-shortcut')
check_result(shortcut[:status] == 'cancelled' && shortcut[:commandId] == 'result_cancel', 'Shortcut overwrote command outcome')
dialog.callbacks.fetch('run_command').call(nil, 'result_cancel', 'bridge-cancel-1')
check_result(dialog.scripts.last.include?('"status":"cancelled"') && dialog.scripts.last.include?('bridge-cancel-1'), 'Bridge lost cancellation status')
SUHub.instance_variable_set(:@panel, nil)
puts 'COMMAND RESULTS, CANCELLATION, BRIDGE AND INTERACTIVE TERMINAL EVENTS PASSED'
