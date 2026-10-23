require_relative '../../hub/geom'
require_relative '../../hub/result'

# Straight convex edges between two consistently oriented planar faces.
# Adjacent selected edges are rejected because they require a vertex blend.
module SuRoundCorner
  SEGS = 8 unless const_defined?(:SEGS, false)

  def self.on_face?(face, point)
    [Sketchup::Face::PointInside, Sketchup::Face::PointOnFace,
      Sketchup::Face::PointOnEdge, Sketchup::Face::PointOnVertex].include?(face.classify_point(point))
  end

  def self.offset_dir(edge, face)
    direction = edge.line[1].cross(face.normal)
    direction.normalize!
    midpoint = Geom.linear_combination(0.5, edge.start.position, 0.5, edge.end.position)
    probe_distance = [edge.length.to_f * 0.001, 0.001].min
    direction.reverse! unless on_face?(face, midpoint.offset(direction, probe_distance))
    direction
  end

  def self.plan(edge, radius, segments, mode)
    raise ArgumentError, '每条边须恰有两个相邻平面。' unless edge.valid? && edge.faces.size == 2
    fa, fb = edge.faces
    da = offset_dir(edge, fa)
    db = offset_dir(edge, fb)
    alpha = da.angle_between(db)
    raise ArgumentError, '平面内边、凹角或反向面不支持圆角；请统一面朝向后选择凸直边。' unless alpha > 0.01 && alpha < Math::PI - 0.01 && da.dot(fb.normal) < -1.0e-6 && db.dot(fa.normal) < -1.0e-6
    tangent = mode == :chamfer ? radius : radius / Math.tan(alpha / 2.0)
    p0, p1 = edge.vertices.map(&:position)
    a0, a1 = [p0, p1].map { |point| point.offset(da, tangent) }
    b0, b1 = [p0, p1].map { |point| point.offset(db, tangent) }
    [fa, fb].zip([[a0, a1], [b0, b1]]).each do |face, points|
      midpoint = Geom.linear_combination(0.5, points[0], 0.5, points[1])
      raise ArgumentError, '半径/距离超出相邻面的范围。' unless (points + [midpoint]).all? { |point| on_face?(face, point) }
    end
    edge.vertices.each_with_index do |vertex, index|
      caps = vertex.faces.reject { |face| face == fa || face == fb }
      raise ArgumentError, '端点交汇面复杂；请分开建模后圆角。' if caps.size > 1
      next if caps.empty?
      points = index.zero? ? [a0, b0] : [a1, b1]
      raise ArgumentError, '圆角端点超出封口面的范围。' unless points.all? { |point| on_face?(caps.first, point) }
    end
    normal = fa.normal + fb.normal
    if mode == :chamfer
      rows = [[a0, b0], [a1, b1]]
    else
      bisector = da + db
      bisector.normalize!
      center = p0.offset(bisector, radius / Math.sin(alpha / 2.0))
      ra = a0 - center
      rb = b0 - center
      angle = ra.angle_between(rb)
      sign = ra.cross(rb).dot(edge.line[1]) >= 0 ? 1.0 : -1.0
      first = (0..segments).map do |index|
        a0.transform(Geom::Transformation.rotation(center, edge.line[1], sign * angle * index / segments))
      end
      first[0] = a0
      first[-1] = b0
      translation = p1 - p0
      rows = [first, first.map { |point| point + translation }]
    end
    { edge: edge, points: [p0, p1], rows: rows, normal: normal,
      material: fa.material, back_material: fa.back_material, mode: mode }
  end

  def self.build(entities, data)
    edge = data[:edge]
    row_a, row_b = data[:rows]
    # Offset lines split off the two sharp-corner strips.
    entities.add_edges(row_a.first, row_b.first)
    entities.add_edges(row_a.last, row_b.last)
    boundary_edges = [entities.add_edges(*row_a), entities.add_edges(*row_b)]
    strips = edge.faces.dup
    raise '未能分离原尖角面，已回滚。' unless strips.size == 2 && strips.all? do |face|
      face.vertices.any? { |vertex| row_a.any? { |point| point.distance(vertex.position).to_f < 1.0e-6 } }
    end
    caps = boundary_edges.each_with_index.flat_map do |edges, index|
      corner = data[:points][index]
      edges.flat_map(&:faces).uniq.select do |face|
        !strips.include?(face) && face.vertices.any? { |vertex| vertex.position.distance(corner).to_f < 1.0e-6 }
      end
    end
    removed = (strips + caps).uniq
    orphan_candidates = removed.flat_map(&:edges).uniq
    entities.erase_entities(removed)
    orphans = orphan_candidates.select { |candidate| candidate.valid? && candidate.faces.empty? }
    entities.erase_entities(orphans) unless orphans.empty?
    faces = []
    (row_a.size - 1).times do |index|
      face = entities.add_face(row_a[index], row_a[index + 1], row_b[index + 1], row_b[index])
      raise '无法创建圆角面，整次操作已回滚。' unless face
      face.reverse! if face.normal.dot(data[:normal]) < 0
      face.material = data[:material]
      face.back_material = data[:back_material]
      faces << face
    end
    if data[:mode] == :fillet
      faces.flat_map(&:edges).uniq.each do |candidate|
        next unless candidate.faces.size == 2
        # Keep the end-cap arc hard; soften longitudinal cylinder seams only.
        vector = candidate.end.position - candidate.start.position
        next unless vector.parallel?(row_b.first - row_a.first)
        candidate.soft = candidate.smooth = true
      end
    end
    faces
  end

  def self.apply(model, edges, radius, segments: SEGS, mode: :fillet)
    raise ArgumentError, '请选择至少一条凸直边。' if edges.empty?
    raise ArgumentError, '半径/距离须大于 0。' unless radius.finite? && radius > 1.0e-6
    raise ArgumentError, '圆弧分段数须为 2–64 的整数。' unless segments.is_a?(Integer) && (2..64).cover?(segments)
    raise ArgumentError, '未知圆角模式。' unless [:fillet, :chamfer].include?(mode)
    vertices = edges.flat_map(&:vertices)
    raise ArgumentError, '多条选中边不能共用端点；请逐条处理交汇边。' unless vertices.uniq.size == vertices.size
    raise ArgumentError, '所选边须位于当前编辑层级。' if edges.any? { |edge| edge.parent != model.active_entities.parent }
    plans = edges.map { |edge| plan(edge, radius, segments, mode) }
    SUHub::Geom.operation(model, '中枢圆角') do
      plans.each { |data| build(model.active_entities, data) }
      plans.size
    end
  end

  def self.run
    model = Sketchup.active_model
    edges = model.selection.grep(Sketchup::Edge)
    raise ArgumentError, '请先选择凸直边；多条边不能共用端点。' if edges.empty?
    input = UI.inputbox(['模式', '圆角半径 / 倒角面内距离（默认 mm）', '圆弧分段数'],
      ['圆角', '10', SEGS.to_s], ['圆角|倒角', '', ''], '中枢圆角')
    return SUHub::Result.cancelled(message: '已取消圆角操作', changed: false) unless input
    count = apply(model, edges, SUHub::Geom.parse_mm(input[1]),
      segments: Integer(input[2]), mode: input[0] == '倒角' ? :chamfer : :fillet)
    UI.messagebox("完成 #{count} 条；可一次撤销。")
    SUHub::Result.completed(message: "完成 #{count} 条；可一次撤销。", changed: true,
      data: { edgeCount: count })
  rescue StandardError => error
    UI.messagebox("中枢圆角：#{error.message}")
    SUHub::Result.from_error(error)
  end

  if defined?(SUHub) && SUHub.respond_to?(:register_command)
    SUHub.register_command(id: :round_corner, title: '中枢圆角', category: :model,
      keywords: %w[圆角 yuanjiao fillet 倒角 daojiao chamfer], shortcut: 'Alt+R') { run }
  elsif defined?(Sketchup) && !file_loaded?(__FILE__)
    UI.menu('Extensions').add_item('中枢圆角') { run }
    file_loaded(__FILE__)
  end
end
