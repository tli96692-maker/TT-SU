# Integration contracts with an actual ZIP, isolated settings and SketchUp API mocks.
require 'tmpdir'
require 'fileutils'
require 'json'
require 'zlib'
require_relative 'test_host_boot'

module BackendContract
  module_function
  def assert(condition, message)
    raise message unless condition
  end

  def zip(path, entries, descriptor: false, corrupt_crc: false)
    body = ''.b
    central = ''.b
    entries.each do |name, content|
      name, content = name.b, content.b
      offset = body.bytesize
      crc = Zlib.crc32(content)
      crc ^= 1 if corrupt_crc
      flags = descriptor ? 8 : 0
      body << [0x04034b50, 20, flags, 0, 0, 0, descriptor ? 0 : crc,
               descriptor ? 0 : content.bytesize, descriptor ? 0 : content.bytesize,
               name.bytesize, 0].pack('VvvvvvVVVvv') << name << content
      body << [0x08074b50, crc, content.bytesize, content.bytesize].pack('VVVV') if descriptor
      central << [0x02014b50, 20, 20, flags, 0, 0, 0, crc, content.bytesize,
                  content.bytesize, name.bytesize, 0, 0, 0, 0, 0, offset].pack('VvvvvvvVVVvvvvvVV') << name
    end
    offset = body.bytesize
    File.binwrite(path, body + central + [0x06054b50, 0, 0, entries.size, entries.size, central.bytesize, offset, 0].pack('VvvvvVVv'))
  end

  def manifest(id, version)
    { 'id' => id, 'version' => version, 'name' => 'Contract fixture', 'category' => 'script',
      'entry' => 'run.rb', 'command' => { 'id' => 'fixture_command', 'title' => 'Fixture' } }
  end

  def package(path, id, version, **options)
    data = manifest(id, version)
    code = "SUHub.register_command(id: 'fixture_command', title: 'Fixture') { SUHub.instance_variable_set(:@contract_executed, '#{version}') }"
    zip(path, { "#{id}/manifest.json" => JSON.generate(data), "#{id}/run.rb" => code }, **options)
  end

  def reject(message)
    begin
      yield
    rescue StandardError
      return
    end
    raise message
  end
end

class UI::HtmlDialog
  STYLE_UTILITY = 1 unless const_defined?(:STYLE_UTILITY)
  STYLE_DIALOG = 2 unless const_defined?(:STYLE_DIALOG)
  attr_reader :callbacks, :scripts
  def initialize(**_options); @callbacks = {}; @scripts = []; @visible = false; end
  def add_action_callback(name, &block); @callbacks[name] = block; end
  def execute_script(script); @scripts << script; end
  def set_file(_path); end
  def set_on_closed(&block); @on_closed = block; end
  def show; @visible = true; end
  def visible?; @visible; end
  def bring_to_front; end
  def center; end
  def close; @visible = false; @on_closed&.call; end
end
module UI
  def self.openURL(_url); true; end
end

old_settings = ENV['SUHUB_SETTINGS_DIR']
old_plugins_dir = SUHub::PLUGINS_DIR
old_plugins = SUHub.plugins
old_commands = SUHub.commands
old_panel = SUHub.panel
old_palette = SUHub.palette
FileUtils.mkdir_p(File.join(__dir__, 'tmp'))
Dir.mktmpdir('suhub-contract-', File.join(__dir__, 'tmp')) do |temporary|
  begin
    ENV['SUHUB_SETTINGS_DIR'] = File.join(temporary, 'settings')
    plugin_dir = File.join(temporary, 'plugins')
    FileUtils.mkdir_p(plugin_dir)
    SUHub.send(:remove_const, :PLUGINS_DIR)
    SUHub.const_set(:PLUGINS_DIR, plugin_dir)
    SUHub.instance_variable_set(:@plugins, {})
    SUHub.instance_variable_set(:@commands, {})
    SUHub.instance_variable_set(:@panel, nil)
    SUHub.instance_variable_set(:@palette, nil)
    catalog_dir = File.join(temporary, '中文 source')
    FileUtils.mkdir_p(catalog_dir)
    package_path = File.join(catalog_dir, 'fixture.zip')
    catalog_path = File.join(catalog_dir, 'catalog.json')
    BackendContract.package(package_path, 'fixture', '1.0.0', descriptor: true)
    entry = { 'id' => 'fixture', 'name' => 'Fixture', 'version' => '1.0.0', 'url' => 'fixture.zip',
              'sha256' => Digest::SHA256.file(package_path).hexdigest }
    File.write(catalog_path, JSON.generate('plugins' => [entry]), encoding: 'UTF-8')
    file_uri = 'file:///' + URI::DEFAULT_PARSER.escape(catalog_path.tr('\\', '/'), /[^\x21-\x7E]/)
    BackendContract.assert(SUHub::Market.fetch_catalog(file_uri)['plugins'].size == 1, 'file URI with spaces/Chinese failed')
    SUHub::Settings.save('sources' => [catalog_path])
    BackendContract.assert(SUHub::Market.catalogs[1].empty?, 'local relative catalog failed')
    result = SUHub::Market.install_plugin('fixture')
    BackendContract.assert(result[:ok], "real ZIP install failed: #{result.inspect}")
    BackendContract.assert(SUHub.plugins.key?('fixture'), 'install did not refresh registry')
    BackendContract.assert(SUHub.run_command('fixture_command'), 'installed command did not lazy load')
    BackendContract.assert(SUHub.instance_variable_get(:@contract_executed) == '1.0.0', 'wrong implementation executed')
    SUHub::Settings.save('enabled' => { 'fixture' => false })
    BackendContract.assert(!SUHub.run_command('fixture_command'), 'disabled command executed')
    SUHub::Settings.save('enabled' => { 'fixture' => true })
    result = SUHub.save_settings('shortcuts' => [{ 'id' => 'fixture-shortcut', 'title' => 'Test', 'type' => 'command', 'target' => 'fixture_command' }])
    BackendContract.assert(result[:ok], 'shortcut save failed')
    BackendContract.assert(SUHub.execute_shortcut('fixture-shortcut')[:ok], 'shortcut execution failed')
    SUHub.save_settings('favorites' => ['fixture_command'])
    BackendContract.assert(SUHub::Settings.current['shortcuts'].size == 1, 'patch settings lost shortcuts')
    BackendContract.assert(!SUHub.save_settings('shortcuts' => [{ 'id' => 'evil', 'title' => 'Bad', 'type' => 'url', 'target' => 'javascript:alert(1)' }])[:ok], 'unsafe shortcut accepted')
    BackendContract.assert(!SUHub.open_url('file:///C:/Windows/notepad.exe')[:ok], 'unsafe open_url accepted')
    BackendContract.assert(!SUHub::Market.install_plugin('../escape')[:ok], 'unsafe plugin ID accepted')

    # Failed checksum leaves the old plugin and command untouched.
    entry['version'] = '1.1.0'
    entry['sha256'] = '0' * 64
    File.write(catalog_path, JSON.generate('plugins' => [entry]))
    BackendContract.assert(!SUHub::Market.install_plugin('fixture')[:ok], 'checksum mismatch accepted')
    BackendContract.assert(SUHub.plugins['fixture'][:manifest]['version'] == '1.0.0', 'checksum failure modified plugin')

    # A matching hash cannot hide an ID mismatch.
    BackendContract.package(package_path, 'different', '1.1.0')
    entry['sha256'] = Digest::SHA256.file(package_path).hexdigest
    File.write(catalog_path, JSON.generate('plugins' => [entry]))
    BackendContract.assert(!SUHub::Market.install_plugin('fixture')[:ok], 'manifest mismatch accepted')

    # Update while loaded records pending restart and prevents executing stale code.
    BackendContract.package(package_path, 'fixture', '1.1.0')
    entry['sha256'] = Digest::SHA256.file(package_path).hexdigest
    File.write(catalog_path, JSON.generate('plugins' => [entry]))
    result = SUHub::Market.install_plugin('fixture')
    BackendContract.assert(result[:ok] && result[:restartRequired], 'loaded update did not require restart')
    BackendContract.assert(!SUHub.run_command('fixture_command'), 'updated plugin executed stale code')
    BackendContract.assert(!Dir.glob(File.join(plugin_dir, '_backup', '*')).empty?, 'update lost backup')

    # Force a failure after replacement: commit_install must restore the prior folder.
    source = File.join(temporary, 'rollback-source')
    FileUtils.mkdir_p(source)
    File.write(File.join(source, 'manifest.json'), JSON.generate(BackendContract.manifest('fixture', '1.2.0')))
    File.write(File.join(source, 'run.rb'), '# replacement')
    original_scan = SUHub.method(:scan_plugins)
    scans = 0
    SUHub.define_singleton_method(:scan_plugins) do
      scans += 1
      raise 'simulated post-copy registration failure' if scans == 1
      original_scan.call
    end
    BackendContract.reject('commit rollback did not report failure') { SUHub::Market.commit_install('fixture', source) }
    SUHub.define_singleton_method(:scan_plugins, original_scan)
    disk_manifest = JSON.parse(File.read(File.join(plugin_dir, 'fixture', 'manifest.json')))
    BackendContract.assert(disk_manifest['version'] == '1.1.0', 'transaction did not restore previous version')

    # ZIP traversal, duplicate paths, absolute paths and CRC corruption fail explicitly.
    ['../escape.rb', '/absolute.rb', 'C:/escape.rb', 'bad./file.rb', 'CON.rb'].each do |name|
      BackendContract.zip(package_path, { name => 'bad' })
      BackendContract.reject("unsafe ZIP accepted: #{name}") { SUHub::ZipX.extract(package_path, File.join(temporary, 'unsafe')) }
    end
    BackendContract.zip(package_path, { 'a.rb' => 'bad' }, corrupt_crc: true)
    BackendContract.reject('CRC corruption accepted') { SUHub::ZipX.extract(package_path, File.join(temporary, 'corrupt')) }
    BackendContract.assert(SUHub::Market.compare_versions('1.0.0', '1.0.0-rc.1') > 0, 'prerelease ordering failed')
    BackendContract.assert(SUHub::Market.compare_versions('2022-02-24', '2020-03-10') > 0, 'dated version ordering failed')

    # The JS bridge returns the exact request ID and catches invalid inputs.
    dialog = UI::HtmlDialog.new
    SUHub.bind_callbacks(dialog)
    dialog.callbacks['get_settings'].call(nil, 'request-settings')
    BackendContract.assert(dialog.scripts.last.include?('"request-settings"'), 'settings request ID lost')
    dialog.callbacks['open_url'].call(nil, 'javascript:bad', 'request-open')
    BackendContract.assert(dialog.scripts.last.include?('"ok":false') && dialog.scripts.last.include?('"request-open"'), 'bridge unsafe URL was not reported')
    dialog.callbacks['run_command'].call(nil, 'missing', 'request-command')
    BackendContract.assert(dialog.scripts.last.include?('"ok":false') && dialog.scripts.last.include?('"request-command"'), 'command error did not preserve ID')
    SUHub.open_panel(JSON.generate('tab' => 'market', 'query' => 'test'))
    revision = SUHub.state_payload[:panelContext]['revision']
    SUHub.open_panel(JSON.generate('tab' => 'market', 'query' => 'test'))
    BackendContract.assert(SUHub.state_payload[:panelContext]['revision'] > revision, 'panel context revision did not advance')
    data = BackendContract.manifest('fixture', '1.0.0').merge('dependencies' => [{ 'require' => 'MissingLib_Contract/core.rb', 'name' => 'MissingLib' }])
    BackendContract.assert(SUHub::Market.compatibility_errors(data).any? { |message| message.include?('MissingLib') }, 'missing native dependency not detected')
  ensure
    SUHub.define_singleton_method(:scan_plugins, original_scan) if original_scan
    ENV['SUHUB_SETTINGS_DIR'] = old_settings
    SUHub.send(:remove_const, :PLUGINS_DIR)
    SUHub.const_set(:PLUGINS_DIR, old_plugins_dir)
    SUHub.instance_variable_set(:@plugins, old_plugins)
    SUHub.instance_variable_set(:@commands, old_commands)
    SUHub.instance_variable_set(:@panel, old_panel)
    SUHub.instance_variable_set(:@palette, old_palette)
  end
end
puts 'BACKEND CONTRACT TESTS PASSED'
