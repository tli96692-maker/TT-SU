require 'json'
require 'csv'
require 'time'
require_relative '../../hub/result'

module SuModelStats
  LABELS = { edges: '边线', faces: '面', groups: '组', components: '组件实例' }.freeze unless const_defined?(:LABELS, false)

  def self.count(entities, recursive: false, ancestry: [])
    result = { edges: 0, faces: 0, groups: 0, components: 0 }
    entities.each do |entity|
      key = case entity
      when Sketchup::Edge then :edges
      when Sketchup::Face then :faces
      when Sketchup::Group then :groups
      when Sketchup::ComponentInstance then :components
      end
      result[key] += 1 if key
      next unless recursive && [:groups, :components].include?(key)
      definition = entity.definition
      # Count each placed instance, while protecting against recursive definitions.
      next if ancestry.include?(definition)
      children = count(definition.entities, recursive: true, ancestry: ancestry + [definition])
      children.each { |name, number| result[name] += number }
    end
    result
  end

  def self.report(model)
    {
      schema: 'su-zhongshu/model-stats/1',
      generated_at: Time.now.iso8601,
      model_title: model.respond_to?(:title) ? model.title.to_s : '',
      model_path: model.respond_to?(:path) ? model.path.to_s : '',
      scope: '包含隐藏对象；嵌套统计按每个实际放置的实例展开，非唯一组件定义数',
      current_context: count(model.active_entities),
      entire_model: count(model.respond_to?(:entities) ? model.entities : model.active_entities, recursive: true)
    }
  end

  def self.export(report, path, format: nil)
    format ||= File.extname(path).downcase == '.json' ? 'json' : 'csv'
    data = if format == 'json'
      JSON.pretty_generate(report)
    elsif format == 'csv'
      "\uFEFF" + CSV.generate do |csv|
        csv << ['SU 中枢模型统计', report[:model_title]]
        csv << ['生成时间', report[:generated_at]]
        csv << ['统计口径', report[:scope]]
        csv << ['范围', *LABELS.values]
        csv << ['当前编辑层级', *LABELS.keys.map { |key| report[:current_context][key] }]
        csv << ['整个模型（包含嵌套实例）', *LABELS.keys.map { |key| report[:entire_model][key] }]
      end
    else
      raise ArgumentError, '仅支持 csv 或 json 格式。'
    end
    File.open(path, 'w:UTF-8') { |file| file.write(data) }
    path
  end

  def self.run
    result = report(Sketchup.active_model)
    lines = LABELS.map { |key, label| "#{label}：#{result[:current_context][key]} / #{result[:entire_model][key]}" }
    answer = UI.messagebox("当前层级 / 整个模型（含嵌套实例）\n#{lines.join("\n")}\n\n是否导出报告（CSV / JSON）？", MB_YESNO)
    return SUHub::Result.completed(message: '模型统计已显示，未导出报告。', changed: false,
      data: { report: result }) unless answer == IDYES
    choice = UI.inputbox(['报告格式'], ['CSV'], ['CSV|JSON'], '导出模型统计')
    return SUHub::Result.cancelled(message: '已取消统计报告导出', changed: false) unless choice
    format = choice.first.downcase
    path = UI.savepanel('导出模型统计', nil, "模型统计.#{format}")
    return SUHub::Result.cancelled(message: '已取消统计报告导出', changed: false) unless path
    path += ".#{format}" unless File.extname(path).downcase == ".#{format}"
    export(result, path, format: format)
    UI.messagebox("报告已导出：\n#{path}")
    SUHub::Result.completed(message: '统计报告已导出', changed: false,
      data: { path: path, format: format, report: result })
  rescue StandardError => error
    UI.messagebox("模型统计：#{error.message}")
    SUHub::Result.from_error(error)
  end

  if defined?(SUHub) && SUHub.respond_to?(:register_command)
    SUHub.register_command(id: :model_stats, title: '模型统计', category: :script,
      keywords: %w[统计 tongji stats 导出 daochu CSV JSON], shortcut: 'Alt+S') { run }
  elsif defined?(Sketchup) && !file_loaded?(__FILE__)
    UI.menu('Extensions').add_item('模型统计') { run }
    file_loaded(__FILE__)
  end
end

# Compatibility for existing scripts that used the original demo entry point.
def su_demo_stats_run
  SuModelStats.run
end
