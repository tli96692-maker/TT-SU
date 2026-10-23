require_relative '../../hub/geom'
require_relative '../../hub/result'

# Numeric free-box/axis scaling. Existing instances keep their definitions,
# materials and axes; local coordinates follow the selected instance's axes.
module SuScale
  def self.instance?(entity)
    entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
  end

  def self.frame_for(entities, local)
    return Geom::Transformation.new unless local
    raise ArgumentError, '局部坐标模式需要只选择一个组或组件实例。' unless entities.size == 1 && instance?(entities.first)
    transform = entities.first.transformation
    axes = [transform.xaxis, transform.yaxis, transform.zaxis]
    raise ArgumentError, '对象包含零缩放，不能建立局部坐标。' if axes.any? { |axis| axis.length.to_f < 1.0e-8 }
    axes.each(&:normalize!)
    raise ArgumentError, '此对象包含斜切，请先使用当前编辑坐标模式。' if axes.combination(2).any? { |a, b| a.dot(b).abs > 1.0e-6 }
    Geom::Transformation.axes(transform.origin, *axes)
  end

  def self.bounds_in_frame(entities, frame)
    inverse = frame.inverse
    box = Geom::BoundingBox.new
    entities.each do |entity|
      if instance?(entity)
        bounds = entity.definition.bounds
        8.times { |index| box.add(bounds.corner(index).transform(entity.transformation).transform(inverse)) }
      elsif entity.respond_to?(:vertices)
        entity.vertices.each { |vertex| box.add(vertex.position.transform(inverse)) }
      else
        raise ArgumentError, '仅支持边线、面、组与组件实例。'
      end
    end
    raise ArgumentError, '所选对象没有有效几何。' if box.empty?
    box
  end

  def self.factors_for(values, dimensions, target:)
    values.each_with_index.map do |value, index|
      next 1.0 if value.to_s.strip.empty?
      number = target ? SUHub::Geom.parse_mm(value) : Float(value)
      raise ArgumentError, '倍率或目标尺寸必须大于 0，且为有限数值。' unless number.finite? && number > 0
      if target
        dimension = dimensions[index].to_f
        raise ArgumentError, "#{'XYZ'[index]} 方向原尺寸为 0，无法设置目标尺寸；该轴请留空。" if dimension < 1.0e-7
        factor = number / dimension
        raise ArgumentError, '目标尺寸超出可计算范围。' unless factor.finite?
        factor
      else
        number
      end
    end
  rescue TypeError
    raise ArgumentError, '请输入有效数值。'
  end

  def self.physical_dimensions(model, bounds, frame)
    world_frame = model.edit_transform * frame
    [bounds.width, bounds.height, bounds.depth].zip([world_frame.xaxis, world_frame.yaxis, world_frame.zaxis]).map do |size, axis|
      size * axis.length
    end
  end

  def self.apply(model, entities, values, target: false, local: false, center: true)
    entities = entities.uniq
    raise ArgumentError, '请先选择边线、面、组或组件。' if entities.empty?
    raise ArgumentError, '需要 X、Y、Z 三个输入值（留空表示不变）。' unless values.size == 3
    raise ArgumentError, '选择包含锁定对象，请先解锁。' if entities.any? { |entity| entity.respond_to?(:locked?) && entity.locked? }
    raise ArgumentError, '所选对象必须位于当前编辑层级。' if entities.any? { |entity| !entity.valid? || entity.parent != model.active_entities.parent }
    frame = frame_for(entities, local)
    bounds = bounds_in_frame(entities, frame)
    # A parent being edited can itself be scaled. Millimetre target sizes are
    # actual model lengths along the chosen box axes, including that scale.
    factors = factors_for(values, physical_dimensions(model, bounds, frame), target: target)
    anchor = center ? bounds.center : bounds.min
    transform = frame * Geom::Transformation.scaling(anchor, *factors) * frame.inverse
    # transform_entities interprets active-context transformations in WORLD
    # coordinates, including when a rotated/scaled parent is open for editing.
    edit = model.edit_transform
    world_transform = edit * transform * edit.inverse
    SUHub::Geom.operation(model, '中枢缩放') do
      raise 'SketchUp 未能完成缩放。' unless model.active_entities.transform_entities(world_transform, entities)
    end
    factors
  end

  def self.run
    model = Sketchup.active_model
    entities = model.selection.to_a
    raise ArgumentError, '请先选择边线、面、组或组件。' if entities.empty?
    local_default = entities.size == 1 && instance?(entities.first) ? '对象局部坐标' : '当前编辑坐标'
    settings = UI.inputbox(['输入方式', '坐标系', '固定锚点'],
      ['倍率', local_default, '包围盒中心'],
      ['倍率|目标尺寸(mm)', '当前编辑坐标|对象局部坐标', '包围盒中心|包围盒最小角'], '中枢缩放 · 自由盒/轴向')
    return SUHub::Result.cancelled(message: '已取消缩放操作', changed: false) unless settings
    target = settings[0].start_with?('目标')
    local = settings[1] == '对象局部坐标'
    frame = frame_for(entities, local)
    bounds = bounds_in_frame(entities, frame)
    dimensions = physical_dimensions(model, bounds, frame)
    defaults = target ? dimensions.map { |size| size < 1.0e-7 ? '' : (size * 25.4).round(4).to_s } : ['1', '1', '1']
    unit = target ? '目标尺寸，默认 mm' : '倍率'
    values = UI.inputbox(['X ' + unit, 'Y ' + unit, 'Z ' + unit], defaults, '留空轴保持不变')
    return SUHub::Result.cancelled(message: '已取消缩放操作', changed: false) unless values
    factors = apply(model, entities, values, target: target, local: local, center: settings[2] == '包围盒中心')
    Sketchup.status_text = '中枢缩放完成；可一次撤销。'
    SUHub::Result.completed(message: '中枢缩放完成；可一次撤销。',
      changed: factors.any? { |factor| (factor - 1.0).abs > 1.0e-10 }, data: { factors: factors })
  rescue StandardError => error
    UI.messagebox("中枢缩放：#{error.message}")
    SUHub::Result.from_error(error)
  end

  if defined?(SUHub) && SUHub.respond_to?(:register_command)
    SUHub.register_command(id: :scale_selection, title: '中枢缩放', category: :model,
      keywords: %w[缩放 suofang scale 自由盒 ziyouhe 轴向 局部 尺寸], shortcut: nil) { run }
  elsif defined?(Sketchup) && !file_loaded?(__FILE__)
    UI.menu('Extensions').add_item('中枢缩放') { run }
    file_loaded(__FILE__)
  end
end
