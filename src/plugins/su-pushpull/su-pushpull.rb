require_relative '../../hub/geom'
require_relative '../../hub/result'

module SuPushPull
  def self.run
    model = Sketchup.active_model
    faces = model.selection.grep(Sketchup::Face)
    raise ArgumentError, '请先选择要推拉的面（可多选）。' if faces.empty?
    input = UI.inputbox(['距离（默认 mm，正值沿面法线，负值反向）'], ['100'], '中枢推拉')
    return SUHub::Result.cancelled(message: '已取消推拉操作', changed: false) unless input
    distance = SUHub::Geom.parse_mm(input[0])
    count = apply(model, faces, distance)
    UI.messagebox("已推拉 #{count} 个面；可一次撤销。")
    SUHub::Result.completed(message: "已推拉 #{count} 个面；可一次撤销。", changed: true,
      data: { faceCount: count, distanceMm: distance * 25.4 })
  rescue StandardError => error
    UI.messagebox("中枢推拉：#{error.message}")
    SUHub::Result.from_error(error)
  end

  def self.apply(model, faces, distance)
    raise ArgumentError, '距离必须为非零有限数值。' unless distance.finite? && distance.abs > 1.0e-6
    raise ArgumentError, '请至少选择一个当前编辑层级内的有效面。' if faces.empty? || faces.any? { |face| !face.valid? || face.parent != model.active_entities.parent }
    SUHub::Geom.operation(model, '中枢推拉') do
      # Work in the original context. Moving a face into a temporary group
      # changes a negative pull on a solid into a separate overlapping prism.
      working_faces = merge_coplanar(model.active_entities, faces)
      count = 0
      working_faces.each do |face|
        raise '相邻面的拓扑发生变化，已取消整次推拉。请分开选择这些面。' unless face.valid?
        face.pushpull(distance)
        count += 1
      end
      count
    end
  end

  def self.merge_coplanar(entities, selected_faces = entities.grep(Sketchup::Face))
    loop do
      selected_faces.select!(&:valid?)
      edge = selected_faces.flat_map(&:edges).uniq.find do |candidate|
        a, b = candidate.faces
        candidate.faces.size == 2 && selected_faces.include?(a) && selected_faces.include?(b) && a.normal.dot(b.normal) > 0.999999
      end
      break unless edge
      before = entities.grep(Sketchup::Face)
      edge.erase!
      # SketchUp may retain either wrapper or replace both with a new face.
      selected_faces = (selected_faces.select(&:valid?) + (entities.grep(Sketchup::Face) - before)).uniq
    end
    selected_faces
  end

  if defined?(SUHub) && SUHub.respond_to?(:register_command)
    SUHub.register_command(id: :multi_push_pull, title: '中枢推拉', category: :model,
      keywords: %w[推拉 tuila pushpull 挤出 jichu], shortcut: 'Alt+J') { run }
  elsif defined?(Sketchup) && !file_loaded?(__FILE__)
    UI.menu('Extensions').add_item('中枢推拉') { run }
    file_loaded(__FILE__)
  end
end
