# Each test file gets its own Ruby process and settings directory.
require 'rbconfig'
require 'tmpdir'
require 'fileutils'

temporary_root = File.join(__dir__, 'tmp')
FileUtils.mkdir_p(temporary_root)
results = {}
Dir.glob('test_*.rb', base: __dir__).sort.each do |name|
  file = File.join(__dir__, name)
  Dir.mktmpdir('test-settings-', temporary_root) do |settings_dir|
    ok = system({ 'SUHUB_SETTINGS_DIR' => settings_dir }, RbConfig.ruby, '--disable-gems', file)
    results[name] = ok ? 'PASSED' : "FAILED (exit #{$?.exitstatus || 'signal'})"
  end
end
puts '=' * 60
results.each { |name, status| puts "#{status == 'PASSED' ? '✔' : '✘'} #{name} — #{status}" }
puts '=' * 60
exit(results.values.all? { |status| status == 'PASSED' } ? 0 : 1)
