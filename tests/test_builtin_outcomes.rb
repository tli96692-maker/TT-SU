# Wrapper and interactive-session contracts only. Geometry is tested in SketchUp.
require 'json'
require 'tmpdir'

module Sketchup
  class Edge; end
  class Face; end
  class Group; end
  class ComponentInstance; end
  class << self
    attr_accessor :active_model, :status_text
  end
end

module UI
  class << self
    attr_accessor :inputs, :save_paths, :message_answers, :messages
    def reset
      self.inputs, self.save_paths, self.message_answers, self.messages = [], [], [], []
    end
    def inputbox(*_args); inputs.shift; end
    def savepanel(*_args); save_paths.shift; end
    def messagebox(message, *_args)
      messages << message
      message_answers.empty? ? 1 : message_answers.shift
    end
  end
end

module SUHub
  class << self
    attr_accessor :finished
    def register_command(**_args, &_block); end
    def current_invocation_id; 'test-session'; end
    def finish_command(id, **result); finished << result.merge(invocationId: id); end
  end
end

MB_YESNO = 4
IDYES = 6

class OutcomeSelection < Array
  def add(item); self << item; end
end

class OutcomeModel
  attr_accessor :selection, :materials, :tool
  def initialize
    @selection = OutcomeSelection.new
    @materials = Struct.new(:current).new(nil)
  end
  def active_entities; []; end
  def entities; []; end
  def title; '测试模型'; end
  def path; ''; end
  def select_tool(tool)
    @tool = tool
    tool.activate if tool
    nil # SketchUp tools need not return a success Boolean.
  end
end

class OutcomeView
  attr_reader :invalidations
  def initialize; @invalidations = 0; end
  def invalidate; @invalidations += 1; end
  def pickray(x, y); [x, y]; end
end

%w[su-demo-stats su-roundcorner su-pushpull su-loft su-terrain su-paint su-scale].each do |id|
  require_relative "../src/plugins/#{id}/#{id}"
end

def assert_outcome(result, expected, changed: nil)
  raise "Expected #{expected}, got #{result.inspect}" unless result.is_a?(Hash) && result[:status] == expected
  raise 'Result not serializable' unless JSON.parse(JSON.generate(result)).is_a?(Hash)
  raise 'Unexpected changed value' unless changed.nil? || result[:changed] == changed
end

def replace_methods(target, methods)
  original = methods.to_h { |name, _block| [name, target.method(name)] }
  methods.each { |name, block| target.define_singleton_method(name, &block) }
  yield
ensure
  original.each { |name, method| target.define_singleton_method(name, method) } if original
end

def reset_model
  UI.reset
  SUHub.finished = []
  Sketchup.active_model = OutcomeModel.new
end

# Cancelled dialogs must not invoke model-changing implementations.
reset_model
Sketchup.active_model.selection << Sketchup::Edge.new
replace_methods(SuRoundCorner, apply: ->(*) { raise 'Cancelled roundcorner applied geometry' }) do
  UI.inputs = [nil]
  assert_outcome(SuRoundCorner.run, 'cancelled', changed: false)
end
reset_model
Sketchup.active_model.selection << Sketchup::Face.new
replace_methods(SuPushPull, apply: ->(*) { raise 'Cancelled pushpull applied geometry' }) do
  UI.inputs = [nil]
  assert_outcome(SuPushPull.run, 'cancelled', changed: false)
end
reset_model
Sketchup.active_model.selection << Sketchup::Edge.new
replace_methods(SuScale, apply: ->(*) { raise 'Cancelled scale applied geometry' }) do
  UI.inputs = [nil]
  assert_outcome(SuScale.run, 'cancelled', changed: false)
end
replace_methods(SuScale, frame_for: ->(*) { :frame }, bounds_in_frame: ->(*) { :bounds }, physical_dimensions: ->(*) { [1, 1, 1] }, apply: ->(*) { raise 'Second cancellation applied geometry' }) do
  UI.inputs = [['倍率', '当前编辑坐标', '包围盒中心'], nil]
  assert_outcome(SuScale.run, 'cancelled', changed: false)
end

# A caught exception must survive the message box's integer return value.
reset_model
assert_outcome(SuRoundCorner.run, 'unavailable')
assert_outcome(SuPushPull.run, 'unavailable')
assert_outcome(SuScale.run, 'unavailable')
replace_methods(SuLoft, apply: ->(*) { raise 'loft operation failed' }) do
  result = SuLoft.run
  assert_outcome(result, 'failed')
  raise 'Error was lost' unless result[:message] == 'loft operation failed'
end
replace_methods(SuTerrain, apply: ->(*) { raise ArgumentError, 'terrain input invalid' }) do
  assert_outcome(SuTerrain.run, 'unavailable')
end

# Completed results carry only serializable identifiers/counts, not SU objects.
group = Struct.new(:persistent_id).new(77)
replace_methods(SuLoft, apply: ->(*) { [group, 8] }) do
  result = SuLoft.run
  assert_outcome(result, 'completed', changed: true)
  raise 'Loft result count or ID missing' unless result[:data] == { faceCount: 8, groupId: 77 }
end
replace_methods(SuTerrain, apply: ->(*) { [group, 16, 3] }) do
  result = SuTerrain.run
  assert_outcome(result, 'completed', changed: true)
  raise 'Terrain result count missing' unless result[:data][:contourCount] == 3
end
reset_model
Sketchup.active_model.selection << Sketchup::Edge.new
UI.inputs = [['圆角', '5', '8']]
replace_methods(SuRoundCorner, apply: ->(*) { 1 }) { assert_outcome(SuRoundCorner.run, 'completed', changed: true) }
reset_model
Sketchup.active_model.selection << Sketchup::Face.new
UI.inputs = [['25.4']]
replace_methods(SuPushPull, apply: ->(*) { 1 }) { assert_outcome(SuPushPull.run, 'completed', changed: true) }
reset_model
Sketchup.active_model.selection << Sketchup::Edge.new
replace_methods(SuScale, frame_for: ->(*) { :frame }, bounds_in_frame: ->(*) { :bounds }, physical_dimensions: ->(*) { [1, 1, 1] }, apply: ->(*) { [2, 1, 1] }) do
  UI.inputs = [['倍率', '当前编辑坐标', '包围盒中心'], ['2', '1', '1']]
  assert_outcome(SuScale.run, 'completed', changed: true)
end

# Viewing stats is complete. Cancelling a requested export is cancelled.
reset_model
UI.message_answers = [7]
assert_outcome(SuModelStats.run, 'completed', changed: false)
UI.message_answers = [IDYES]
UI.inputs = [nil]
assert_outcome(SuModelStats.run, 'cancelled', changed: false)
UI.message_answers = [IDYES]
UI.inputs = [['JSON']]
UI.save_paths = [nil]
assert_outcome(SuModelStats.run, 'cancelled', changed: false)
Dir.mktmpdir('suhub-outcome-') do |directory|
  output = File.join(directory, '统计.json')
  UI.message_answers = [IDYES]
  UI.inputs = [['JSON']]
  UI.save_paths = [output]
  result = SuModelStats.run
  assert_outcome(result, 'completed', changed: false)
  raise 'Export output not returned' unless result[:data][:path] == output
  raise 'Export output invalid' unless JSON.parse(File.read(output))['schema'] == 'su-zhongshu/model-stats/1'
end
replace_methods(SuModelStats, export: ->(*) { raise IOError, 'disk failure' }) do
  UI.message_answers = [IDYES]
  UI.inputs = [['CSV']]
  UI.save_paths = ['ignored.csv']
  assert_outcome(SuModelStats.run, 'failed')
end

# Paint activation alone is not a model change; missed clicks are not strokes.
reset_model
assert_outcome(SuPaint.run, 'unavailable', changed: false)
Sketchup.active_model.materials.current = Object.new
assert_outcome(SuPaint.run, 'started', changed: false)
tool = Sketchup.active_model.tool
view = OutcomeView.new
replace_methods(SuPaint, paint_pick: ->(*) { nil }) { tool.onLButtonDown(0, 1, 2, view) }
tool.onCancel(0, view)
tool.deactivate(view)
raise 'Paint cancellation should publish once' unless SUHub.finished.length == 1
raise 'Missed click counted as paint' unless SUHub.finished.first[:status] == :cancelled && SUHub.finished.first[:data][:paintedCount] == 0

reset_model
Sketchup.active_model.materials.current = Object.new
SuPaint.run
tool = Sketchup.active_model.tool
replace_methods(SuPaint, paint_pick: ->(*) { Object.new }) do
  2.times { tool.onLButtonDown(0, 1, 2, view) }
end
tool.deactivate(view)
tool.onCancel(0, view)
raise 'Paint completion should publish once' unless SUHub.finished.length == 1
raise 'Paint completion missing strokes' unless SUHub.finished.first[:status] == :completed && SUHub.finished.first[:data][:paintedCount] == 2 && SUHub.finished.first[:changed]

reset_model
Sketchup.active_model.materials.current = Object.new
SuPaint.run
tool = Sketchup.active_model.tool
replace_methods(SuPaint, paint_pick: ->(*) { raise 'paint target unavailable' }) { tool.onLButtonDown(0, 1, 2, view) }
tool.deactivate(view)
raise 'Paint error was reported as cancellation/success' unless SUHub.finished.first[:status] == :failed
raise 'Paint failure lost cause' unless SUHub.finished.first[:data][:lastError] == 'paint target unavailable'

reset_model
Sketchup.active_model.materials.current = Object.new
SuPaint.run
tool = Sketchup.active_model.tool
replace_methods(SuPaint, paint_pick: ->(*) { Object.new }) { tool.onLButtonDown(0, 1, 2, view) }
replace_methods(SuPaint, paint_pick: ->(*) { raise 'second click failed' }) { tool.onLButtonDown(0, 1, 2, view) }
tool.deactivate(view)
partial = SUHub.finished.first
raise 'Successful stroke was lost' unless partial[:status] == :completed && partial[:changed]
raise 'Failed stroke was hidden' unless partial[:data][:failedCount] == 1 && partial[:message].include?('点击失败')

puts 'BUILTIN COMMAND OUTCOMES AND PAINT SESSION TESTS PASSED'
