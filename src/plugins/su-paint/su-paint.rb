require_relative '../../hub/geom'
require_relative '../../hub/result'

module SuPaint
  # One click is one undo step. Make only the picked instance unique, including
  # shared ancestors, so painting one component never repaints all of its copies.
  def self.paint_pick(model, ray, material)
    hit = model.raytest(ray, true)
    return unless hit && hit[1].last.is_a?(Sketchup::Face)
    path = hit[1]
    raise ArgumentError, '目标位于锁定的组或组件内。' if path.any? { |item| item.respond_to?(:locked?) && item.locked? }
    SUHub::Geom.operation(model, '中枢喷漆') do
      depth = 0
      while depth < path.size - 1
        instance = path[depth]
        if instance.respond_to?(:make_unique) && instance.definition.instances.size > 1
          instance.make_unique
          hit = model.raytest(ray, true)
          raise '组件独立后无法重新定位目标面。' unless hit && hit[1].last.is_a?(Sketchup::Face)
          path = hit[1]
        end
        depth += 1
      end
      face = path.last
      face.material = material
      face.back_material = material
      face
    end
  end

  class PaintTool
    def initialize(model)
      @model = model
      @invocation_id = SUHub.current_invocation_id if SUHub.respond_to?(:current_invocation_id)
      @painted_count = 0
      @failed_count = 0
      @last_error = nil
      @finished = false
    end
    def material
      @model.materials.current
    end
    def activate
      Sketchup.status_text = '中枢喷漆：单击刷正反面；共享组件将独立；Esc 结束。'
    end
    def onLButtonDown(_flags, x, y, view)
      raise ArgumentError, '请先选择当前材质。' unless material
      painted = SuPaint.paint_pick(@model, view.pickray(x, y), material)
      @painted_count += 1 if painted
      view.invalidate
    rescue StandardError => error
      @failed_count += 1
      @last_error = error
      UI.messagebox("中枢喷漆：#{error.message}")
    end
    def onMouseMove(_flags, _x, _y, _view)
      Sketchup.status_text = "当前材质：#{material&.display_name || '无'} ｜ 单击刷正反面，Esc 结束"
    end
    def onCancel(_reason, _view)
      finish_session
      @model.select_tool(nil)
    end
    def deactivate(view)
      finish_session
      Sketchup.status_text = ''
      view.invalidate
    end
    def resume(view)
      activate
      view.invalidate
    end

    # Deactivation also follows Esc. Publish one terminal result for the whole
    # session, while paint_pick keeps each successful click as one Undo step.
    def finish_session
      return if @finished
      @finished = true
      data = { paintedCount: @painted_count, failedCount: @failed_count }
      data[:lastError] = @last_error.message if @last_error
      options = if @painted_count.positive?
        message = "喷漆结束：完成 #{@painted_count} 次刷面。"
        message += " 另有 #{@failed_count} 次点击失败，请检查错误提示。" if @failed_count.positive?
        { status: :completed, message: message,
          changed: true, data: data }
      elsif @last_error
        { status: :failed, code: 'paint_failed', message: @last_error.message,
          changed: false, data: data }
      else
        { status: :cancelled, message: '已结束喷漆，未修改模型', changed: false, data: data }
      end
      SUHub.finish_command(@invocation_id, **options) if @invocation_id && SUHub.respond_to?(:finish_command)
    end
  end

  def self.run
    model = Sketchup.active_model
    unless model.materials.current
      UI.messagebox('请先在材质面板选择当前材质。')
      return SUHub::Result.unavailable(code: 'material_required',
        message: '请先在材质面板选择当前材质。', changed: false)
    end
    selected = model.select_tool(PaintTool.new(model))
    return SUHub::Result.failed(code: 'tool_activation_failed', message: '未能启动喷漆工具', changed: false) if selected == false
    SUHub::Result.started(code: 'paint_started', message: '喷漆工具已启动；单击刷面，Esc 结束', changed: false)
  rescue StandardError => error
    UI.messagebox("中枢喷漆：#{error.message}")
    SUHub::Result.from_error(error)
  end

  if defined?(SUHub) && SUHub.respond_to?(:register_command)
    SUHub.register_command(id: :paint_through, title: '中枢喷漆', category: :material,
      keywords: %w[喷漆 penqi paint 材质 caizhi material], shortcut: 'Alt+P') { run }
  elsif defined?(Sketchup) && !file_loaded?(__FILE__)
    UI.menu('Extensions').add_item('中枢喷漆') { run }
    file_loaded(__FILE__)
  end
end
