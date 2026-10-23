# SU 中枢 · 宿主、插件注册、命令与 HtmlDialog 桥接。
require 'json'
require 'digest'
require_relative 'settings'
require_relative 'zipx'
require_relative 'market'
require_relative 'geom'
require_relative 'result'
require_relative 'updates'
require_relative 'update_bridge'

module SUHub
  VERSION = '0.2.3-beta.1' unless const_defined?(:VERSION, false)
  ROOT = File.expand_path('..', __dir__) unless const_defined?(:ROOT, false)
  PLUGINS_DIR = File.join(ROOT, 'plugins') unless const_defined?(:PLUGINS_DIR, false)
  UI_DIR = File.join(ROOT, 'ui') unless const_defined?(:UI_DIR, false)
  DEFAULT_CATALOG_URL = File.join(ROOT, 'market', 'catalog.json') unless const_defined?(:DEFAULT_CATALOG_URL, false)
  CATEGORIES = {
    'model' => '模型工具', 'material' => '材质', 'component' => '组件',
    'draw' => '绘图', 'arch' => '建筑', 'clean' => '清理',
    'render' => '渲染', 'import' => '导入导出', 'script' => '我的脚本'
  }.freeze

  class << self
    attr_reader :plugins, :commands, :panel, :palette, :current_invocation_id

    def log(message)
      File.open(File.join(Settings.dir, 'debug.log'), 'a', encoding: 'UTF-8') { |file| file.puts "[#{Time.now.strftime('%m-%d %H:%M:%S')}] #{message}" }
    rescue StandardError
      nil
    end

    def init
      return if @initialized
      @plugins = {}
      @commands = {}
      @plugin_errors = []
      scan_plugins
      create_toolbar
      @initialized = true
      log("init #{VERSION}: #{@plugins.size} plugins @ #{ROOT}")
    end

    def scan_plugins
      previous = @plugins || {}
      discovered = {}
      @plugin_errors = []
      Dir.glob('*/manifest.json', base: PLUGINS_DIR).sort.each do |relative|
        path = File.join(PLUGINS_DIR, relative)
        next if File.basename(File.dirname(path)).start_with?('_', '.')
        begin
          directory = File.dirname(path)
          manifest = JSON.parse(File.read(path, encoding: 'UTF-8').sub(/\A\uFEFF/, ''))
          Market.validate_manifest(manifest, directory, expected_id: File.basename(directory))
          id = manifest['id']
          fingerprint = Digest::SHA256.hexdigest(JSON.generate(manifest) + Digest::SHA256.file(File.join(directory, manifest['entry'])).hexdigest)
          old = previous[id]
          changed = old && old[:fingerprint] != fingerprint
          discovered[id] = {
            manifest: manifest, dir: directory, fingerprint: fingerprint,
            loaded: !!(old && old[:loaded]),
            pending_restart: !!(old && (old[:pending_restart] || (old[:loaded] && changed)))
          }
        rescue StandardError => error
          @plugin_errors << "#{path}: #{error.message}"
          log("scan: #{@plugin_errors.last}")
        end
      end
      @plugins = discovered
      @commands ||= {}
      @commands.delete_if { |_, command| command[:source] != 'runtime' && !@plugins.key?(command[:source]) }
      @plugins
    end

    def register_command(id:, title:, category: :model, keywords: [], shortcut: nil, &block)
      @commands ||= {}
      id = id.to_sym
      existing = @commands[id]
      owner = @loading_plugin || 'runtime'
      raise "命令 ID 与其他插件重复：#{id}" if existing && existing[:source] != owner
      @commands[id] = { id: id, title: title.to_s, category: category.to_s,
                        keywords: Array(keywords).map(&:to_s), shortcut: shortcut,
                        block: block, source: owner }
    end

    def plugin_enabled?(id)
      Settings.current['enabled'][id.to_s] != false
    end

    def load_plugin(id, chain = [])
      id = id.to_s
      old_owner = @loading_plugin
      plugin = @plugins[id]
      raise "未找到插件 #{id}" unless plugin
      raise "插件「#{plugin[:manifest]['name']}」已停用" unless plugin_enabled?(id)
      raise '插件已更新，请重启 SketchUp 后使用新版' if plugin[:pending_restart]
      return true if plugin[:loaded]
      raise "插件依赖循环：#{(chain + [id]).join(' → ')}" if chain.include?(id)
      problems = Market.compatibility_errors(plugin[:manifest])
      raise problems.join('；') unless problems.empty?
      Array(plugin[:manifest]['dependencies']).each do |dependency|
        if dependency.is_a?(String)
          raise(@last_error || '依赖加载失败') unless load_plugin(dependency, chain + [id])
        elsif dependency.is_a?(Hash)
          require dependency['require']
        end
      end
      before = @commands.dup
      @loading_plugin = id
      entry = File.join(plugin[:dir], plugin[:manifest]['entry'])
      if File.extname(entry).downcase != '.rb' && defined?(Sketchup) && Sketchup.respond_to?(:require)
        Sketchup.require(entry)
      else
        load entry
      end
      plugin[:loaded] = true
      true
    rescue StandardError, LoadError, SyntaxError => error
      @commands = before if before
      @last_error = "插件加载失败：#{error.message}"
      log("load #{id}: #{error.class}: #{error.message}")
      false
    ensure
      @loading_plugin = old_owner if defined?(old_owner)
    end

    # Boolean compatibility API for existing scripts. New UI callers use the
    # structured result so cancellation and tool activation remain distinct.
    def run_command(id)
      run_command_result(id)[:ok]
    end

    def run_command_result(id, request_id: nil)
      id = id.to_s
      request_id ||= @bridge_request_id
      @last_error = nil
      @command_sequence = (@command_sequence || 0) + 1
      @command_session ||= "#{Process.pid}-#{(Time.now.to_f * 1000).to_i}"
      invocation_id = "#{@command_session}-#{@command_sequence}"
      previous_invocation = @current_invocation_id
      @current_invocation_id = invocation_id
      plugin = @plugins.values.find { |item| item[:manifest].dig('command', 'id') == id }
      runtime = @commands[id.to_sym]
      plugin ||= @plugins[runtime[:source]] if runtime
      outcome = if plugin && !plugin_enabled?(plugin[:manifest]['id'])
        Result.unavailable(code: 'plugin_disabled', message: '插件已停用，请在设置中启用')
      elsif plugin && plugin[:pending_restart]
        Result.unavailable(code: 'restart_required', message: '插件已更新，请重启 SketchUp 后使用新版')
      elsif plugin && !(problems = Market.compatibility_errors(plugin[:manifest])).empty?
        Result.unavailable(code: 'dependency_unavailable', message: problems.join('；'))
      elsif plugin && !load_plugin(plugin[:manifest]['id'])
        Result.failed(code: 'plugin_load_failed', message: @last_error || '插件加载失败')
      else
        command = @commands[id.to_sym]
        if command && command[:block]
          command[:block].call
        elsif plugin && plugin[:loaded]
          Result.started(code: 'plugin_loaded', message: "插件「#{plugin[:manifest]['name']}」已加载，请使用其工具栏或菜单。")
        else
          Result.unavailable(code: 'command_not_found', message: '未找到该命令')
        end
      end
      result = Result.normalize(outcome, command_id: id, invocation_id: invocation_id, request_id: request_id)
      remember_command_result(result)
    rescue StandardError, LoadError, SyntaxError => error
      @last_error = "执行失败：#{error.message}"
      log("command #{id}: #{error.class}: #{error.message}")
      remember_command_result(Result.normalize(Result.from_error(error), command_id: id,
        invocation_id: invocation_id, request_id: request_id))
    ensure
      @current_invocation_id = previous_invocation
    end

    def remember_command_result(result)
      result = result.merge(recordedAt: (Time.now.to_f * 1000).to_i)
      @invocations ||= {}
      @invocations[result[:invocationId]] = result
      @invocations.shift while @invocations.size > 100
      @last_error = result[:message] if %w[failed unavailable].include?(result[:status])
      result
    end

    # An interactive tool reports its final outcome after the original bridge
    # callback returned. A terminal result cannot be overwritten or sent twice.
    def finish_command(invocation_id, status:, **options)
      previous = (@invocations || {})[invocation_id]
      return false unless previous && previous[:status] == 'started'
      raise ArgumentError, '结束事件需要终态' if status.to_s == 'started'
      result = Result.normalize(Result.build(status, **options), command_id: previous[:commandId],
        invocation_id: invocation_id, request_id: previous[:requestId])
      result = remember_command_result(result)
      [@panel, @palette].compact.each { |dialog| push(dialog, '__onCommandResult', result) }
      result
    rescue StandardError => error
      log("command completion #{invocation_id}: #{error.class}: #{error.message}")
      false
    end

    def commands_payload
      list = @commands.values.map do |command|
        plugin = @plugins[command[:source]] || @plugins.values.find { |item| item[:manifest].dig('command', 'id') == command[:id].to_s }
        { id: command[:id].to_s, title: command[:title], category: command[:category],
          keywords: command[:keywords], shortcut: command[:shortcut],
          fromPlugin: plugin && plugin[:manifest]['id'], enabled: !plugin || plugin_enabled?(plugin[:manifest]['id']) }
      end
      @plugins.each do |id, plugin|
        command = plugin[:manifest]['command']
        next unless command && !list.any? { |item| item[:id] == command['id'] }
        list << { id: command['id'], title: command['title'] || plugin[:manifest]['name'],
                  category: plugin[:manifest]['category'].to_s, keywords: Array(plugin[:manifest]['keywords']),
                  shortcut: plugin[:manifest]['shortcut'], fromPlugin: id, enabled: plugin_enabled?(id) }
      end
      list
    end

    def plugins_payload
      @plugins.map do |id, plugin|
        manifest = plugin[:manifest]
        { id: id, name: manifest['name'], version: manifest['version'], author: manifest['author'],
          license: manifest['license'], category: manifest['category'].to_s,
          description: manifest['description'], homepage: manifest['homepage'], loaded: plugin[:loaded],
          enabled: plugin_enabled?(id), restartRequired: !!plugin[:pending_restart],
          dependencyErrors: Market.compatibility_errors(manifest) }
      end
    end

    def state_payload
      settings = Settings.current
      diagnostics = Settings.diagnostics
      { version: VERSION, categories: CATEGORIES, plugins: plugins_payload, commands: commands_payload,
        settings: settings, sources: settings['sources'],
        errors: (@plugin_errors || []) + diagnostics.map { |item| item[:message] || item['message'] },
        settingsStorage: Settings.storage_status,
        panelContext: @panel_context || {},
        commandResults: (@invocations || {}).values.last(30) }
    end

    def settings_payload
      settings = Settings.current
      { ok: true, settings: settings, sources: settings['sources'],
        storage: Settings.storage_status, diagnostics: Settings.diagnostics }
    end

    def save_settings(input)
      data = input.is_a?(String) ? JSON.parse(input) : input
      Settings.validate(data)['shortcuts'].each do |shortcut|
        next unless shortcut['type'] == 'command'
        raise "快捷入口命令不存在：#{shortcut['target']}" unless commands_payload.any? { |item| item[:id] == shortcut['target'] }
      end
      Settings.save(data)
      settings_payload.merge(message: '设置已保存')
    rescue StandardError => error
      { ok: false, message: error.message }
    end

    def execute_shortcut(id)
      shortcut = Settings.current['shortcuts'].find { |item| item['id'] == id.to_s }
      return { ok: false, message: '快捷入口不存在' } unless shortcut
      return open_url(shortcut['target']) if shortcut['type'] == 'url'
      run_command_result(shortcut['target'])
    end

    def open_url(url)
      location = Settings.normalize_source(url)
      raise '只允许打开 HTTP(S) 网址' unless location.match?(/\Ahttps?:\/\//)
      result = UI.openURL(location)
      { ok: result != false, message: result == false ? '浏览器无法打开该网址' : '已在浏览器打开' }
    rescue StandardError => error
      { ok: false, message: error.message }
    end

    def push(dialog, name, data, request_id = nil)
      dialog.execute_script("window.#{name} && window.#{name}(#{JSON.generate(data)},#{JSON.generate(request_id)});")
    end

    def broadcast_state
      [@panel, @palette].compact.each { |dialog| push(dialog, '__onState', state_payload) }
    end

    def open_panel(options = nil)
      if options
        options = JSON.parse(options) if options.is_a?(String) && !options.empty?
        @panel_context = options.is_a?(Hash) ? options.slice('tab', 'query').merge('revision' => (@panel_context_revision = (@panel_context_revision || 0) + 1)) : {}
      end
      if @panel && @panel.visible?
        @panel.bring_to_front
        push(@panel, '__onState', state_payload)
        return @panel
      end
      @panel = UI::HtmlDialog.new(dialog_title: 'SU 中枢', width: 420, height: 720,
                                  resizable: true, style: UI::HtmlDialog::STYLE_UTILITY)
      @panel.set_file(File.join(UI_DIR, 'panel.html'))
      bind_callbacks(@panel)
      @panel.set_on_closed { @panel = nil }
      @panel.show
      @panel
    end

    def open_palette
      if @palette && @palette.visible?
        @palette.bring_to_front
        return @palette
      end
      @palette = UI::HtmlDialog.new(dialog_title: '命令', width: 700, height: 480,
                                    resizable: true, style: UI::HtmlDialog::STYLE_DIALOG)
      @palette.set_file(File.join(UI_DIR, 'palette.html'))
      bind_callbacks(@palette)
      @palette.set_on_closed { @palette = nil }
      @palette.show
      @palette.center
      @palette
    end

    def action(dialog, method, response, &handler)
      dialog.add_action_callback(method) do |_context, *args|
        request_id = args.length > handler.arity ? args.pop : nil
        previous_request = @bridge_request_id
        @bridge_request_id = request_id
        begin
          result = handler.call(*args)
          result = result.merge(requestId: request_id) if result.is_a?(Hash) && result[:status]
          push(dialog, response, result, request_id)
        rescue StandardError, LoadError, SyntaxError => error
          log("bridge #{method}: #{error.class}: #{error.message}")
          push(dialog, response, { ok: false, message: error.message }, request_id)
        ensure
          @bridge_request_id = previous_request
        end
        nil
      end
    end

    def bind_callbacks(dialog)
      action(dialog, 'get_state', '__onState') { state_payload }
      action(dialog, 'get_host_update_config', '__onHostUpdateConfig') { Updates.configuration }
      dialog.add_action_callback('check_host_update') do |_context, request_id|
        UpdateBridge.request(dialog, request_id)
        nil
      end
      action(dialog, 'get_market', '__onMarket') { Market.market_payload }
      action(dialog, 'get_settings', '__onSettings') { settings_payload }
      action(dialog, 'save_settings', '__onSaveSettings') do |input|
        result = save_settings(input)
        broadcast_state if result[:ok]
        result
      end
      action(dialog, 'run_command', '__onRun') do |id|
        result = run_command_result(id)
        broadcast_state
        result
      end
      action(dialog, 'execute_shortcut', '__onShortcut') { |id| execute_shortcut(id) }
      action(dialog, 'open_url', '__onOpenUrl') { |url| open_url(url) }
      action(dialog, 'open_panel', '__onOpenPanel') { |options| open_panel(options); { ok: true } }
      action(dialog, 'open_palette', '__onOpenPalette') { open_palette; { ok: true } }
      %w[install update].each do |verb|
        action(dialog, "#{verb}_plugin", verb == 'install' ? '__onInstall' : '__onUpdate') do |id|
          result = Market.install_plugin(id)
          broadcast_state if result[:ok]
          result
        end
      end
      action(dialog, 'add_source', '__onAddSource') do |url|
        Settings.add_source(url)
        broadcast_state
        settings_payload.merge(message: '插件源已添加')
      end
      dialog.add_action_callback('close_dialog') do |_context, request_id|
        push(dialog, '__onClose', { ok: true }, request_id)
        dialog.close
        nil
      end
      dialog.add_action_callback('js_log') { |_context, message| log("JS: #{message}") }
    end

    def create_toolbar
      @toolbar = UI::Toolbar.new('SU 中枢')
      command = UI::Command.new('SU 中枢') { open_panel }
      command.tooltip = '打开 SU 中枢面板'
      command.status_bar_text = '插件集成平台'
      @toolbar.add_item(command)
      @toolbar.show
      menu = UI.menu('Extensions')
      menu.add_item('SU 中枢 · 面板') { open_panel }
      menu.add_item('SU 中枢 · 命令') { open_palette }
    rescue StandardError => error
      log("toolbar: #{error.message}")
    end
  end
end

SUHub.init unless SUHub.instance_variable_get(:@initialized)
