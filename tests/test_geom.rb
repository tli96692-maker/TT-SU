# 几何核心单元测试：三角带放样（最短对角线启发）+ 版本外轮廓提取逻辑
$LOAD_PATH.unshift(File.expand_path('../src/hub', __dir__))
require 'geom'

# ---- Point3d / Entities mock ----
class P
  attr_reader :x, :y, :z
  def initialize(x, y, z)
    @x = x; @y = y; @z = z
  end
  def distance(o)
    Math.sqrt((@x - o.x)**2 + (@y - o.y)**2 + (@z - o.z)**2)
  end
end

class FakeFace
  def edges; []; end
end

class FakeEnts
  attr_reader :faces
  def initialize
    @faces = []
  end
  def add_face(p, q, r)
    @faces << [p, q, r]
    FakeFace.new
  end
end

# 两条平行方形环（闭合）
a = [P.new(0, 0, 0), P.new(4, 0, 0), P.new(4, 4, 0), P.new(0, 4, 0)]
b = [P.new(0, 0, 2), P.new(4, 0, 2), P.new(4, 4, 2), P.new(0, 4, 2)]
ents = FakeEnts.new
faces = SUHub::Geom.loft(ents, a, b, closed: true)
# 闭合环 + 复制首点 → 每环 5 点 → 三角带应生成 8 个三角面（2n）
raise "闭合放样面数错误：#{faces.size}" unless faces.size == 8

# 开放曲线：不同点数（5 vs 3）
c = [P.new(0, 0, 0), P.new(1, 1, 0), P.new(2, 1, 0), P.new(3, 0, 0), P.new(4, 0, 0)]
d = [P.new(0, 0, 1), P.new(2, 1, 1), P.new(4, 0, 1)]
ents2 = FakeEnts.new
faces2 = SUHub::Geom.loft(ents2, c, d, closed: false)
# 面数 = (n-1) + (m-1) = 4 + 2 = 6
raise "开放放样面数错误：#{faces2.size}" unless faces2.size == 6

# 反向对齐：d 起点离 c 终点更近，应自动反转
e = [P.new(0, 0, 0), P.new(10, 0, 0)]
f = [P.new(10, 0, 1), P.new(0, 0, 1)]
aa, bb = SUHub::Geom.align_loops(e, f, false)
raise '开放曲线未自动反向对齐' unless bb.first.x < bb.last.x

puts 'GEOM TESTS PASSED'

# Explicit units stay independent of the SketchUp document unit settings.
{ '25.4' => 1.0, '25.4mm' => 1.0, '2.54cm' => 1.0, '0.0254m' => 1.0,
  '1in' => 1.0, '-2ft' => -24.0, '1e2 mm' => 100.0 / 25.4 }.each do |input, inches|
  raise "单位解析失败 #{input}" unless (SUHub::Geom.parse_mm(input) - inches).abs < 1.0e-9
end
['', 'NaN', 'Infinity', '10abc', '1e999', '1/0'].each do |input|
  begin
    SUHub::Geom.parse_mm(input)
    raise "未拒绝无效长度 #{input.inspect}"
  rescue ArgumentError
  end
end

# A repeated seam and opposite winding must be normalized before lofting.
aa, bb = SUHub::Geom.align_loops(a + [a.first], b.reverse + [b.last], true)
raise '闭合重复端点未去除' unless aa.size == 4 && bb.size == 4
raise '相反绕向未校正' unless aa.zip(bb).all? { |p, q| (p.x - q.x).abs < 1.0e-9 && (p.y - q.y).abs < 1.0e-9 }
ents3 = FakeEnts.new
SUHub::Geom.loft(ents3, a + [a.first], b.reverse + [b.last], closed: true)
raise '重复端点导致多余放样面' unless ents3.faces.size == 8

# A failed creation must be surfaced so callers abort the operation.
bad_ents = Object.new
def bad_ents.add_face(*); nil; end
begin
  SUHub::Geom.loft(bad_ents, e, f)
  raise '创建失败未上报'
rescue RuntimeError => error
  raise if error.message == '创建失败未上报'
end

class OperationRecorder
  attr_reader :events
  def initialize; @events = []; end
  def start_operation(name, _disable); @events << [:start, name]; true; end
  def commit_operation; @events << :commit; true; end
  def abort_operation; @events << :abort; true; end
end
recorder = OperationRecorder.new
SUHub::Geom.operation(recorder, 'outer') { SUHub::Geom.operation(recorder, 'inner') { 3 } }
raise '嵌套操作错误地提交外层操作' unless recorder.events == [[:start, 'outer'], :commit]
begin
  SUHub::Geom.operation(recorder, 'failure') { raise ArgumentError, 'expected failure' }
rescue ArgumentError
end
raise '异常未回滚' unless recorder.events.last == :abort
SUHub::Geom.operation(recorder, 'verify', rollback: true) { true }
raise '验证事务没有回滚' unless recorder.events.last == :abort

class ContourVertex
  attr_reader :position
  def initialize(x, y); @position = P.new(x, y, 0); end
end
class ContourEdge
  attr_reader :start, :end
  def initialize(a, b); @start, @end = a, b; end
  def vertices; [@start, @end]; end
  def other_vertex(v); v == @start ? @end : @start; end
end
v0, v1, v2, v3 = [ContourVertex.new(0, 0), ContourVertex.new(1, 0), ContourVertex.new(2, 0), ContourVertex.new(1, 1)]
chain = [ContourEdge.new(v0, v1), ContourEdge.new(v1, v2)]
closed, open = SUHub::Geom.extract_contours(chain.reverse)
raise '开放链未完整提取' unless closed.empty? && open.size == 1 && open.first.size == 3
begin
  SUHub::Geom.extract_contours(chain + [ContourEdge.new(v1, v3)])
  raise '没有拒绝分叉轮廓'
rescue ArgumentError
end
puts 'GEOM VALIDATION AND ROLLBACK TESTS PASSED'

# Real SketchUp Length comparisons include model tolerance. Numeric epsilon
# checks must use Float; 0.to_l < a tiny Float is false in SU 2024.
class TolerantTestLength
  def initialize(value); @value = value; end
  def to_f; @value; end
  def <(_other); false; end
end
length_point = Object.new
def length_point.distance(_other); TolerantTestLength.new(0.0); end
raise 'SketchUp Length容差导致重合点误判' unless SUHub::Geom.same_point?(length_point, length_point)
