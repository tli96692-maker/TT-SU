require_relative '../../hub/geom'
require_relative '../../hub/result'

module SuLoft
  def self.apply(model, edges)
    closed, open = SUHub::Geom.extract_contours(edges)
    curves = closed + open
    raise ArgumentError, "需要恰好两条轮廓，当前为 #{curves.size} 条。" unless curves.size == 2
    raise ArgumentError, '两条轮廓须同时闭合或同时开放。' if closed.size == 1
    SUHub::Geom.operation(model, '中枢放样') do
      group = model.active_entities.add_group
      group.name = '中枢放样'
      faces = SUHub::Geom.loft(group.entities, *curves, closed: closed.size == 2)
      # A separate group preserves source contours and makes the generated
      # surface independently selectable and removable.
      [group, faces.size]
    end
  end

  def self.run
    model = Sketchup.active_model
    group, count = apply(model, model.selection.grep(Sketchup::Edge))
    model.selection.clear
    model.selection.add(group)
    UI.messagebox("放样完成：#{count} 个三角面，已编组；原轮廓保留。")
    SUHub::Result.completed(message: "放样完成：#{count} 个三角面，已编组；原轮廓保留。", changed: true,
      data: { faceCount: count, groupId: group.respond_to?(:persistent_id) ? group.persistent_id : nil })
  rescue StandardError => error
    UI.messagebox("中枢放样：#{error.message}")
    SUHub::Result.from_error(error)
  end

  if defined?(SUHub) && SUHub.respond_to?(:register_command)
    SUHub.register_command(id: :loft_curves, title: '中枢放样', category: :model,
      keywords: %w[放样 fangyang loft 蒙皮 mengpi 曲面 qumian], shortcut: 'Alt+L') { run }
  elsif defined?(Sketchup) && !file_loaded?(__FILE__)
    UI.menu('Extensions').add_item('中枢放样') { run }
    file_loaded(__FILE__)
  end
end
