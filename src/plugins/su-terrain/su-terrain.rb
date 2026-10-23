require_relative '../../hub/geom'
require_relative '../../hub/result'

module SuTerrain
  def self.apply(model, edges)
    closed, open = SUHub::Geom.extract_contours(edges)
    raise ArgumentError, '等高线须全部闭合或全部开放，不能混用。' unless closed.empty? || open.empty?
    curves = (closed + open).sort_by { |curve| SUHub::Geom.clean_loop(curve).sum(&:z) / SUHub::Geom.clean_loop(curve).size }
    raise ArgumentError, '请至少选择两条不相连的等高线。' if curves.size < 2
    heights = curves.map do |curve|
      zs = curve.map(&:z)
      raise ArgumentError, '等高线须位于当前编辑坐标系的水平面。' if zs.max - zs.min > 1.0e-5
      zs.first
    end
    raise ArgumentError, '每条等高线需要不同的高度。' if heights.each_cons(2).any? { |a, b| (a - b).abs < 1.0e-5 }
    SUHub::Geom.operation(model, '中枢地形') do
      group = model.active_entities.add_group
      group.name = '中枢等高线地形'
      total = curves.each_cons(2).sum do |a, b|
        faces = SUHub::Geom.loft(group.entities, a, b, closed: open.empty?)
        faces.each { |face| face.reverse! if face.normal.z < 0 }
        faces.size
      end
      [group, total, curves.size]
    end
  end

  def self.run
    model = Sketchup.active_model
    group, total, count = apply(model, model.selection.grep(Sketchup::Edge))
    model.selection.clear
    model.selection.add(group)
    UI.messagebox("地形完成：#{count} 条等高线 → #{total} 个三角面，已编组。")
    SUHub::Result.completed(message: "地形完成：#{count} 条等高线 → #{total} 个三角面，已编组。", changed: true,
      data: { contourCount: count, faceCount: total,
        groupId: group.respond_to?(:persistent_id) ? group.persistent_id : nil })
  rescue StandardError => error
    UI.messagebox("中枢地形：#{error.message}")
    SUHub::Result.from_error(error)
  end

  if defined?(SUHub) && SUHub.respond_to?(:register_command)
    SUHub.register_command(id: :terrain_from_contours, title: '中枢地形', category: :model,
      keywords: %w[地形 dixing terrain 等高线 denggaoxian contour 沙盒 shahe], shortcut: 'Alt+T') { run }
  elsif defined?(Sketchup) && !file_loaded?(__FILE__)
    UI.menu('Extensions').add_item('中枢地形') { run }
    file_loaded(__FILE__)
  end
end
