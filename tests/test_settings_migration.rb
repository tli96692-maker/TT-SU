# Persistence behavior only; never reads the user's real settings directory.
require 'json'
require 'tmpdir'
require 'fileutils'
require 'digest'
module SUHub
  DEFAULT_CATALOG_URL = File.expand_path('../fixtures/catalog.json', __dir__) unless const_defined?(:DEFAULT_CATALOG_URL, false)
end
require_relative '../src/hub/settings'

module SettingsMigrationTest
  module_function
  def assert(condition, message)
    raise message unless condition
  end

  def readonly?(settings)
    settings.storage_status[:readOnly] && settings.diagnostics.any? { |item| item[:code] == 'settings_read_only' }
  end

  def rejected
    begin
      yield
    rescue SUHub::Settings::StorageError
      return true
    end
    raise 'Unsafe settings save was not rejected'
  end

  def fail_primary_rename(target)
    original = File.method(:rename)
    File.define_singleton_method(:rename) do |source, destination|
      raise Errno::ENOSPC, destination if File.expand_path(destination) == File.expand_path(target)
      original.call(source, destination)
    end
    yield
  ensure
    File.define_singleton_method(:rename, original) if original
  end
end

settings = SUHub::Settings
previous = ENV['SUHUB_SETTINGS_DIR']
FileUtils.mkdir_p(File.join(__dir__, 'tmp'))
Dir.mktmpdir('settings-migration-', File.join(__dir__, 'tmp')) do |temporary|
  begin
    ENV['SUHUB_SETTINGS_DIR'] = File.join(temporary, '中文 设置')
    SettingsMigrationTest.assert(settings.current['schemaVersion'] == 1, 'Fresh defaults lack schema')
    SettingsMigrationTest.assert(!File.exist?(settings.path), 'A read unexpectedly persisted defaults')
    original_data = {
      'sources' => [File.join(temporary, '离线 市场.json')],
      'favorites' => ['scale_selection', 'round_corner'],
      'enabled' => { 'cleanup' => false },
      'shortcuts' => [{ 'id' => 'scale', 'title' => '局部缩放', 'type' => 'command',
        'target' => 'scale_selection', 'icon' => 'custom-icon', 'extension' => { 'color' => 'blue' } }],
      'futurePreference' => { 'nested' => [1, '中文', true] }
    }
    original_bytes = "\uFEFF" + JSON.pretty_generate(original_data)
    File.binwrite(settings.path, original_bytes)
    migrated = settings.current
    SettingsMigrationTest.assert(migrated['schemaVersion'] == 1 && migrated['revision'] == 1, 'Legacy document did not migrate once')
    original_data.each do |key, value|
      SettingsMigrationTest.assert(migrated[key] == value, "Migration lost #{key}")
    end
    backup_paths = Dir.glob(File.join(settings.dir, 'backups/settings-schema-0-*.json'))
    SettingsMigrationTest.assert(backup_paths.size == 1 && File.binread(backup_paths.first) == original_bytes.b, 'Original bytes were not backed up exactly')
    journal = JSON.parse(File.read(File.join(settings.dir, 'settings.migration.json'), encoding: 'UTF-8'))
    SettingsMigrationTest.assert(journal['phase'] == 'completed' && journal['sourceSha256'] == Digest::SHA256.hexdigest(original_bytes), 'Migration journal incomplete')
    stable_hash = Digest::SHA256.file(settings.path).hexdigest
    3.times { SettingsMigrationTest.assert(settings.current['revision'] == 1, 'Repeated read changed revision') }
    SettingsMigrationTest.assert(Digest::SHA256.file(settings.path).hexdigest == stable_hash, 'Idempotent migration rewrote document')
    saved = settings.save('favorites' => ['paint_through'], 'schemaVersion' => 999, 'revision' => 500)
    SettingsMigrationTest.assert(saved['revision'] == 2 && saved['schemaVersion'] == 1, 'Client-controlled schema/revision accepted')
    SettingsMigrationTest.assert(saved['enabled'] == original_data['enabled'] && saved['shortcuts'] == original_data['shortcuts'], 'Patch save lost unrelated preferences')
    settings.save('shortcuts' => saved['shortcuts'])
    SettingsMigrationTest.assert(settings.current['shortcuts'] == original_data['shortcuts'], 'Shortcut extensions were discarded')
    last_valid = settings.current
    valid_bytes = File.binread(settings.path)
    corrupt_bytes = '{"favorites": ['
    File.binwrite(settings.path, corrupt_bytes)
    SettingsMigrationTest.assert(settings.current == last_valid && SettingsMigrationTest.readonly?(settings), 'Corruption silently reset preferences')
    SettingsMigrationTest.rejected { settings.save('favorites' => []) }
    SettingsMigrationTest.assert(File.binread(settings.path) == corrupt_bytes, 'Save overwrote corrupt original')
    diagnostic = settings.diagnostics.find { |item| item[:code] == 'settings_read_only' }
    SettingsMigrationTest.assert(diagnostic[:backup] && File.binread(diagnostic[:backup]) == corrupt_bytes, 'Corrupt bytes not preserved')
    # Simulate a new process: recovery must not rely only on Ruby module state.
    settings.instance_variable_set(:@contexts, {})
    SettingsMigrationTest.assert(settings.current == last_valid, 'Restart lost last-known-good recovery data')
    File.binwrite(settings.path, valid_bytes)
    SettingsMigrationTest.assert(settings.current == last_valid && !settings.storage_status[:readOnly], 'External valid restore did not unlock settings')

    before_failure = File.binread(settings.path)
    before_revision = settings.current['revision']
    SettingsMigrationTest.fail_primary_rename(settings.path) do
      SettingsMigrationTest.rejected { settings.save('favorites' => ['must-not-commit']) }
    end
    SettingsMigrationTest.assert(File.binread(settings.path) == before_failure, 'Failed write damaged old document')
    SettingsMigrationTest.assert(settings.current['revision'] == before_revision && settings.current['favorites'] == last_valid['favorites'], 'Failed write advanced state')
    SettingsMigrationTest.assert(settings.diagnostics.any? { |item| item[:code] == 'settings_write_failed' }, 'Write failure lacks diagnostic')
    SettingsMigrationTest.assert(Dir.glob(File.join(settings.dir, '*.tmp')).empty?, 'Failed transaction leaked temporary files')
    settings.save('favorites' => ['retry-ok'])
    SettingsMigrationTest.assert(settings.current['revision'] == before_revision + 1, 'Retry did not commit exactly once')

    ENV['SUHUB_SETTINGS_DIR'] = File.join(temporary, 'invalid-first-start')
    FileUtils.mkdir_p(settings.dir)
    File.binwrite(settings.path, '[]')
    SettingsMigrationTest.assert(SettingsMigrationTest.readonly?(settings), 'Non-object document accepted')
    SettingsMigrationTest.rejected { settings.save('enabled' => {}) }
    SettingsMigrationTest.assert(File.binread(settings.path) == '[]', 'Non-object original changed')

    ENV['SUHUB_SETTINGS_DIR'] = File.join(temporary, 'future-schema')
    FileUtils.mkdir_p(settings.dir)
    future = JSON.generate('schemaVersion' => 2, 'revision' => 9, 'future' => 'preserve-me')
    File.binwrite(settings.path, future)
    SettingsMigrationTest.assert(SettingsMigrationTest.readonly?(settings), 'Future schema was downgraded silently')
    SettingsMigrationTest.rejected { settings.save('favorites' => ['unsafe']) }
    SettingsMigrationTest.assert(File.binread(settings.path) == future, 'Future-schema document changed')

    ENV['SUHUB_SETTINGS_DIR'] = File.join(temporary, 'migration-write-failure')
    FileUtils.mkdir_p(settings.dir)
    legacy = JSON.generate(original_data)
    File.binwrite(settings.path, legacy)
    SettingsMigrationTest.fail_primary_rename(settings.path) do
      SettingsMigrationTest.assert(settings.current['favorites'] == original_data['favorites'], 'Failed migration lost legacy values')
      SettingsMigrationTest.assert(SettingsMigrationTest.readonly?(settings), 'Failed migration was not protected')
    end
    SettingsMigrationTest.assert(File.binread(settings.path) == legacy.b, 'Failed migration damaged original')
    SettingsMigrationTest.assert(Dir.glob(File.join(settings.dir, 'backups/settings-schema-0-*.json')).size == 1, 'Failed migration lacks original backup')
    retried_migration = settings.reload!
    SettingsMigrationTest.assert(retried_migration['revision'] == 1 && !settings.storage_status[:readOnly], 'Explicit retry did not recover failed migration')
    SettingsMigrationTest.assert(Dir.glob(File.join(settings.dir, 'backups/settings-schema-0-*.json')).size == 1, 'Retry duplicated original backup')

    ENV['SUHUB_SETTINGS_DIR'] = File.join(temporary, 'invalid-encoding')
    FileUtils.mkdir_p(settings.dir)
    bytes = "\xFF\xFE{\"favorites\":[]}".b
    File.binwrite(settings.path, bytes)
    SettingsMigrationTest.assert(SettingsMigrationTest.readonly?(settings), 'Invalid UTF-8 was not protected')
    SettingsMigrationTest.assert(File.binread(settings.path) == bytes, 'Invalid UTF-8 original changed')
  ensure
    ENV['SUHUB_SETTINGS_DIR'] = previous
  end
end
puts 'SETTINGS MIGRATION, RECOVERY AND WRITE-FAILURE TESTS PASSED'
