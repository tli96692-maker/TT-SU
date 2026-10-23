# SU 中枢 · SketchUp 扩展加载器。发布包只在 Plugins 根目录放这一个入口。
require 'sketchup.rb'
require 'extensions.rb'

module SUHub
  VERSION = '0.2.3-beta.1' unless const_defined?(:VERSION, false)

  unless file_loaded?(__FILE__)
    # Source checkout supports direct development; built RBZ always uses the namespace.
    packaged = File.join(__dir__, 'su_zhongshu', 'hub', 'main.rb')
    entry = File.file?(packaged) ? packaged : File.join(__dir__, 'hub', 'main.rb')
    extension = SketchupExtension.new('SU 中枢', entry)
    extension.description = '命令面板、离线插件市场、懒加载、快捷入口与独立建模工具'
    extension.version = VERSION
    extension.creator = 'SU 中枢团队'
    Sketchup.register_extension(extension, true)
    file_loaded(__FILE__)
  end
end
