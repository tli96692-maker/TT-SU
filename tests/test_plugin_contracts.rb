# These checks test units/validation and report structure, without replacing
# SketchUp geometry behavior. Real geometry is tested by verify_tools_in_sketchup.
require 'tmpdir'
require 'json'
require_relative 'test_host_boot' unless defined?(Sketchup::Face)
raise '缩放插件加载失败' unless defined?(SuScale) || SUHub.load_plugin('su-scale')
raise '统计插件加载失败' unless defined?(SuModelStats) || SUHub.load_plugin('su-demo-stats')

factors = SuScale.factors_for(['2', '', '0.5'], [1, 2, 3], target: false)
raise '三轴倍率或留空行为错误' unless factors == [2.0, 1.0, 0.5]
targets = SuScale.factors_for(['50.8', '', '76.2mm'], [1, 0, 1], target: true)
raise '目标毫米尺寸换算错误' unless targets.zip([2.0, 1.0, 3.0]).all? { |a, b| (a - b).abs < 1.0e-9 }
[
  [['0', '', ''], [1, 1, 1], false],
  [['-1', '', ''], [1, 1, 1], false],
  [['not-a-number', '', ''], [1, 1, 1], false],
  [['1', '', ''], [0, 1, 1], true],
  [['1e308m', '', ''], [1, 1, 1], true]
].each do |values, dimensions, target|
  begin
    SuScale.factors_for(values, dimensions, target: target)
    raise "没有拒绝无效缩放输入 #{values.inspect}"
  rescue ArgumentError
  end
end

# Instance-expanded counts must count two placements twice, while guarding
# recursive definitions. Group and component counts remain separate.
class StatsTestGroup < Sketchup::Group
  attr_reader :definition
  def initialize(definition); @definition = definition; end
end
class StatsTestComponent < Sketchup::ComponentInstance
  attr_reader :definition
  def initialize(definition); @definition = definition; end
end
definition = Struct.new(:entities).new([Sketchup::Edge.new, Sketchup::Face.new])
entities = [StatsTestGroup.new(definition), StatsTestComponent.new(definition), Sketchup::Edge.new]
counts = SuModelStats.count(entities, recursive: true)
raise "嵌套实例统计错误 #{counts}" unless counts == { edges: 3, faces: 2, groups: 1, components: 1 }
direct = SuModelStats.count(entities)
raise '当前层级统计不应展开实例' unless direct[:faces] == 0 && direct[:edges] == 1
recursive_definition = Struct.new(:entities).new([])
recursive_definition.entities << StatsTestComponent.new(recursive_definition)
cycle = SuModelStats.count(recursive_definition.entities, recursive: true)
raise '循环定义保护错误' unless cycle[:components] == 2

report = {
  schema: 'su-zhongshu/model-stats/1', generated_at: '2026-10-18T00:00:00+08:00',
  model_title: '中文,模型', scope: '包含隐藏对象与嵌套实例',
  current_context: direct, entire_model: counts
}
Dir.mktmpdir('suhub-report-test-') do |directory|
  csv_path = File.join(directory, '中文.csv')
  json_path = File.join(directory, '中文.json')
  SuModelStats.export(report, csv_path)
  SuModelStats.export(report, json_path)
  csv = File.read(csv_path, encoding: 'UTF-8')
  raise 'CSV需要UTF-8 BOM以兼容Excel中文' unless csv.start_with?("\uFEFF")
  rows = CSV.parse(csv.delete_prefix("\uFEFF"))
  raise 'CSV未正确引用包含逗号的模型名' unless rows.first[1] == '中文,模型'
  raise 'CSV嵌套统计值错误' unless rows.last == ['整个模型（包含嵌套实例）', '3', '2', '1', '1']
  raise 'JSON报告结构错误' unless JSON.parse(File.read(json_path))['entire_model']['faces'] == 2
end
puts 'PLUGIN VALIDATION AND EXPORT TESTS PASSED'
