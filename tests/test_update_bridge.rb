require 'thread'
module SUHub
  VERSION = '0.2.3-beta.1'
  class << self
    attr_accessor :deliveries
    def push(dialog, name, result, request_id)
      raise 'UI call off main thread' unless Thread.current == Thread.main
      raise 'Closed HtmlDialog' if dialog == :closed
      deliveries << [dialog, name, result, request_id]
    end
  end
  self.deliveries = []
  module Updates
    class << self
      attr_accessor :ready, :calls, :release, :gate
      def configuration
        {ok: true, status: ready ? 'ready' : 'unconfigured', currentVersion: SUHub::VERSION,
         repository: ready ? 'test/tt-su-hub' : '', channel: 'preview'}
      end
      def check(**env)
        raise 'Network ran on UI thread' if Thread.current == Thread.main
        raise 'Wrong captured environment' unless env == {sketchup_version: '24.0.484', platform: 'windows'}
        self.calls += 1
        gate.pop
        release
      end
    end
    self.ready, self.calls = false, 0
  end
end
module Sketchup
  def self.version
    raise 'SketchUp API off main thread' unless Thread.current == Thread.main
    '24.0.484'
  end
  def self.platform
    raise 'SketchUp API off main thread' unless Thread.current == Thread.main
    :platform_win
  end
end
module UI
  class << self
    attr_accessor :timer
    def start_timer(_delay, _repeat, &block); self.timer = block; 7; end
    def stop_timer(id); raise 'Wrong timer' unless id == 7; self.timer = nil; end
  end
end
require_relative '../src/hub/update_bridge'
bridge = SUHub::UpdateBridge
def assert(value, message); raise message unless value; end
def drain
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
  while UI.timer && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    UI.timer.call
    sleep 0.005
  end
  assert(UI.timer.nil?, 'Polling did not finish')
end

bridge.request(:first, 'unconfigured')
assert(SUHub::Updates.calls == 0 && UI.timer.nil?, 'Unconfigured request started network')
assert(SUHub.deliveries.last[2][:status] == 'unconfigured', 'Missing unconfigured response')
SUHub::Updates.ready = true
SUHub::Updates.gate = Queue.new
SUHub::Updates.release = {ok: true, status: 'available', version: '0.2.4'}
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
bridge.request(:closed, 'closed-request')
bridge.request(:second, 'one')
bridge.request(:second, 'two')
assert(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < 0.5, 'Request blocked UI thread')
assert(SUHub.deliveries.length == 1, 'Request completed before worker')
SUHub::Updates.gate << true
drain
assert(SUHub::Updates.calls == 1, 'Concurrent requests started duplicate network calls')
assert(SUHub.deliveries.last(2).map(&:last) == %w[one two], 'Lost request correlation after closed dialog')
bridge.request(:reopened, 'cached')
assert(SUHub::Updates.calls == 1 && SUHub.deliveries.last.last == 'cached', 'Reopened dialog missed cached result')

bridge.instance_variable_set(:@cache, nil)
SUHub::Updates.gate = Queue.new
SUHub::Updates.release = {ok: false, status: 'rate_limited', message: 'retry later'}
bridge.request(:third, 'error')
SUHub::Updates.gate << true
drain
assert(SUHub.deliveries.last[2][:status] == 'rate_limited', 'Failure became up-to-date')
assert(bridge.instance_variable_get(:@cache)[:expires] - bridge.now <= 30, 'Error cached too long')

bridge.instance_variable_set(:@cache, nil)
SUHub::Updates.gate = Queue.new
bridge.request(:fourth, 'timeout')
bridge.instance_variable_set(:@started, bridge.now - 36)
UI.timer.call
assert(UI.timer.nil? && SUHub.deliveries.last[2][:status] == 'offline', 'Deadline leaked timer or worker')
assert(bridge.instance_variable_get(:@worker).nil?, 'Deadline did not release worker')
puts 'UPDATE BRIDGE PASSED: nonblocking, main-thread delivery, coalescing, closed dialog, cache, error and deadline'
