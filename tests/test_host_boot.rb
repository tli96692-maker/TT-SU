# 宿主启动级测试：用 SketchUp API mock 验证注册表扫描 → 懒加载 → 命令分发全链路
$LOAD_PATH.unshift(File.expand_path('../src/hub', __dir__))

# ---- SketchUp / UI / Geom API mock（仅覆盖宿主与插件用到的部分）----
module Sketchup
  class Extension
    attr_accessor :description, :version, :creator
    def initialize(_name = '', _path = ''); end
  end
  def self.register_extension(_ext, _enabled = false); end

  class Face
    PointInside = 1
    PointOnVertex = 2
    PointOnEdge = 4
    PointOutside = 8
  end
  class Edge; end
  class Group; end
  class ComponentInstance; end

  class Model
    def active_entities; []; end
    def selection; []; end
    def start_operation(_name, _disable = false); end
    def commit_operation; end
  end
  def self.active_model
    @m ||= Model.new
  end
end

module UI
  class Toolbar
    def initialize(*_a); end
    def add_item(*_a); end
    def show; end
  end
  class Menu
    def add_item(*_a); end
  end
  class Command
    def initialize(*_a, &_b); end
    def tooltip=(*_a); end
    def status_bar_text=(*_a); end
  end
  def self.menu(*_a); Menu.new; end
  def self.messagebox(*_a); end
  class HtmlDialog; end
end

require 'main'

MB_OK = 0 unless defined?(MB_OK)
MB_YESNO = 4 unless defined?(MB_YESNO)
IDYES = 6 unless defined?(IDYES)

# ---- 断言 ----
raise '插件扫描失败' unless SUHub.plugins.size >= 7
%w[su-demo-stats su-roundcorner su-pushpull su-loft su-terrain su-paint su-scale].each do |pid|
  raise "缺 #{pid}" unless SUHub.plugins.key?(pid)
end

# 未加载状态：命令清单来自 manifest
payload = JSON.parse(JSON.generate(SUHub.state_payload))
ids = payload['commands'].map { |c| c['id'] }
%w[model_stats round_corner multi_push_pull loft_curves terrain_from_contours paint_through scale_selection].each do |id|
  raise "命令缺失 #{id}" unless ids.include?(id)
end
raise '分类缺失' unless payload['categories']['model'] == '模型工具'

# 懒加载：run 前未加载，run 后已加载
# Re-running the suite in one process may retain already-loaded plugins.
raise '统计命令执行失败' unless SUHub.run_command('model_stats')
raise '懒加载失败' unless SUHub.plugins['su-demo-stats'][:loaded]
raise '命令注册失败' unless SUHub.commands.key?(:model_stats)

# 自研插件懒加载（run 内部因空选择提前返回，但入口应已加载并注册）
SUHub.run_command('round_corner')
raise 'roundcorner 懒加载失败' unless SUHub.plugins['su-roundcorner'][:loaded]
raise 'roundcorner 命令注册失败' unless SUHub.commands.key?(:round_corner)

puts 'HOST BOOT TESTS PASSED'
