# SU 中枢 · 设置持久化（%APPDATA%/SUZhongShu/settings.json）
require 'json'
require 'fileutils'
require 'tempfile'
require 'uri'
require 'digest'
require 'time'

module SUHub
  module Settings
    SCHEMA_VERSION = 1 unless const_defined?(:SCHEMA_VERSION, false)
    class StorageError < StandardError; end
    module_function

    def dir
      base = ENV['SUHUB_SETTINGS_DIR']
      base = File.join(ENV['APPDATA'] || File.expand_path('~'), 'SUZhongShu') if base.to_s.empty?
      FileUtils.mkdir_p(base)
      base
    end

    def path
      File.join(dir, 'settings.json')
    end

    def context
      @contexts ||= {}
      @contexts[path] ||= { diagnostics: [], read_only: false, last_good: nil }
    end

    def copy(value)
      JSON.parse(JSON.generate(value))
    end

    def add_diagnostic(code, message, severity: 'error', **details)
      item = { code: code, message: message, severity: severity, path: path }.merge(details)
      context[:diagnostics] << item unless context[:diagnostics].any? { |old| old[:code] == code && old[:message] == message }
      item
    end

    def diagnostics
      current
      copy(context[:diagnostics]).map { |item| item.transform_keys(&:to_sym) }
    end

    def storage_status
      data = current
      { readOnly: context[:read_only], schemaVersion: data['schemaVersion'],
        revision: data['revision'], path: path }
    end

    def backup_bytes(bytes, reason)
      backup_dir = File.join(dir, 'backups')
      FileUtils.mkdir_p(backup_dir)
      name = "settings-#{reason}-#{Digest::SHA256.hexdigest(bytes)[0, 20]}.json"
      destination = File.join(backup_dir, name)
      unless File.exist?(destination)
        File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.binmode
          file.write(bytes)
          file.flush
          file.fsync
        end
      end
      raise StorageError, '设置备份校验失败' unless File.binread(destination) == bytes
      destination
    end

    def atomic_write(destination, bytes)
      temporary = Tempfile.new(['settings-', '.tmp'], File.dirname(destination))
      begin
        temporary.binmode
        temporary.write(bytes)
        temporary.flush
        temporary.fsync
        temporary.close
        File.rename(temporary.path, destination)
      ensure
        temporary.close!
      end
    end

    def write_last_good(data)
      atomic_write(File.join(dir, 'settings.last-good.json'), JSON.pretty_generate(data))
    rescue SystemCallError, IOError => error
      add_diagnostic('last_good_write_failed', "有效设置已保存，但恢复副本未更新：#{error.message}", severity: 'warning')
    end

    def parse_document(bytes)
      text = bytes.dup.force_encoding('UTF-8')
      raise StorageError, '设置文件不是有效 UTF-8 编码' unless text.valid_encoding?
      data = JSON.parse(text.sub(/\A\uFEFF/, ''))
      raise StorageError, '设置文件根节点必须是 JSON 对象' unless data.is_a?(Hash)
      version = data.fetch('schemaVersion', 0)
      raise StorageError, '设置 schemaVersion 格式无效' unless version.is_a?(Integer) && version >= 0
      raise StorageError, "设置来自更新版本（schemaVersion=#{version}），当前仅支持 #{SCHEMA_VERSION}" if version > SCHEMA_VERSION
      if data.key?('revision')
        raise StorageError, '设置 revision 格式无效' unless data['revision'].is_a?(Integer) && data['revision'] >= 0
      end
      data
    end

    def fallback
      return copy(context[:last_good]) if context[:last_good]
      good_path = File.join(dir, 'settings.last-good.json')
      if File.file?(good_path)
        begin
          data = parse_document(File.binread(good_path))
          return normalize(data) if data['schemaVersion'] == SCHEMA_VERSION
        rescue JSON::ParserError, EncodingError, StorageError, SystemCallError, IOError
          # Keep both files untouched; the primary error stays visible.
        end
      end
      defaults
    end

    def migration(data, bytes)
      backup = backup_bytes(bytes, 'schema-0')
      next_data = normalize(data).merge('schemaVersion' => SCHEMA_VERSION,
        'revision' => data.fetch('revision', 0) + 1)
      journal_path = File.join(dir, 'settings.migration.json')
      journal = { fromSchema: 0, toSchema: SCHEMA_VERSION, phase: 'prepared', backup: backup,
        sourceSha256: Digest::SHA256.hexdigest(bytes), targetRevision: next_data['revision'], at: Time.now.utc.iso8601 }
      atomic_write(journal_path, JSON.pretty_generate(journal))
      atomic_write(path, JSON.pretty_generate(next_data))
      context[:last_good] = copy(next_data)
      write_last_good(next_data)
      begin
        atomic_write(journal_path, JSON.pretty_generate(journal.merge(phase: 'completed')))
      rescue SystemCallError, IOError => error
        add_diagnostic('migration_journal_write_failed', "设置迁移已提交，迁移日志尚未完成：#{error.message}", severity: 'warning', backup: backup)
      end
      next_data
    end

    def load
      unless File.file?(path)
        context[:read_only] = false
        context[:diagnostics] = []
        context[:last_good] = defaults
        return defaults
      end
      bytes = File.binread(path)
      fingerprint = Digest::SHA256.hexdigest(bytes)
      if context[:fingerprint] == fingerprint && context[:data]
        return copy(context[:data])
      end
      context[:read_only] = false
      context[:diagnostics] = []
      data = parse_document(bytes)
      if data.fetch('schemaVersion', 0) == 0
        context[:last_good] = normalize(data)
        data = migration(data, bytes)
        bytes = File.binread(path)
      else
        data = normalize(data)
      end
      context[:last_good] = copy(data)
      context[:data] = copy(data)
      context[:fingerprint] = Digest::SHA256.hexdigest(bytes)
      copy(data)
    rescue JSON::ParserError, EncodingError, StorageError, SystemCallError, IOError => error
      context[:read_only] = true
      backup = nil
      begin
        backup = backup_bytes(bytes, 'unreadable') if bytes
      rescue SystemCallError, IOError, StorageError => backup_error
        add_diagnostic('invalid_settings_backup_failed', "无法备份异常设置，原文件保持不变：#{backup_error.message}")
      end
      add_diagnostic('settings_read_only', "设置文件无法安全读取，已进入只读模式；原文件保留，请恢复有效备份后重试。#{error.message}", backup: backup)
      data = fallback
      context[:data] = copy(data)
      context[:fingerprint] = fingerprint if fingerprint
      copy(data)
    end

    # Accept HTTP(S), local absolute paths and local file URIs.
    def escape_uri(value)
      URI::DEFAULT_PARSER.escape(value, /[^A-Za-z0-9\-._~:\/?#\[\]@!$&'()*+,;=%]/)
    end

    def normalize_source(value)
      source = value.to_s.strip
      raise ArgumentError, '插件源不能为空' if source.empty?
      raise ArgumentError, '请替换示例账号或占位地址' if source.match?(/<[^>]+>|%3[cC]|你的账号|\/example\//)
      return File.expand_path(source) if source.match?(/\A[A-Za-z]:[\\\/]/) || source.start_with?('/')
      uri = URI.parse(escape_uri(source))
      if %w[http https].include?(uri.scheme)
        raise ArgumentError, '插件源地址缺少域名' if uri.host.to_s.empty?
        raise ArgumentError, '插件源地址不能包含密码或片段' if uri.userinfo || uri.fragment
      elsif uri.scheme == 'file'
        raise ArgumentError, '仅支持本机 file 地址' unless [nil, '', 'localhost'].include?(uri.host)
        raise ArgumentError, 'file 地址不能包含查询或片段' if uri.query || uri.fragment
        raise ArgumentError, 'file 地址须使用绝对路径（file:///盘符:/目录/catalog.json）' unless uri.path && uri.path.start_with?('/')
      else
        raise ArgumentError, '插件源须为 HTTP(S)、file:// 或本机绝对路径'
      end
      uri.to_s
    rescue URI::InvalidURIError
      raise ArgumentError, '插件源地址格式无效'
    end

    def defaults
      { 'schemaVersion' => SCHEMA_VERSION, 'revision' => 0,
        'sources' => [SUHub::DEFAULT_CATALOG_URL], 'shortcuts' => [], 'favorites' => [], 'enabled' => {} }
    end

    def normalize(data)
      list = Array(data['sources']).filter_map do |source|
        normalize_source(source)
      rescue ArgumentError
        nil # Migrate the old default GitHub placeholder automatically.
      end.uniq
      copy(data).merge(
        'schemaVersion' => SCHEMA_VERSION,
        'revision' => data.fetch('revision', 0),
        'sources' => list.empty? ? defaults['sources'] : list,
        'shortcuts' => Array(data['shortcuts']).select { |item| item.is_a?(Hash) },
        'favorites' => Array(data['favorites']).map(&:to_s).uniq,
        'enabled' => data['enabled'].is_a?(Hash) ? data['enabled'] : {}
      )
    end

    def current
      load
    end

    # Explicit retry after an operator restores a file or fixes write access.
    def reload!
      context.delete(:fingerprint)
      context.delete(:data)
      current
    end

    def validate(hash)
      raise ArgumentError, '设置必须是 JSON 对象' unless hash.is_a?(Hash)
      result = current
      raise StorageError, '设置处于只读保护中，请先恢复有效设置或修复原文件' if context[:read_only]
      hash.each do |key, value|
        next if %w[schemaVersion revision sources shortcuts favorites enabled].include?(key)
        result[key] = copy(value)
      end
      if hash.key?('sources')
        raise ArgumentError, 'sources 必须是数组' unless hash['sources'].is_a?(Array)
        raise ArgumentError, '插件源最多 30 个' if hash['sources'].length > 30
        result['sources'] = hash['sources'].map { |value| normalize_source(value) }.uniq
        result['sources'] = defaults['sources'] if result['sources'].empty?
      end
      if hash.key?('favorites')
        raise ArgumentError, 'favorites 必须是数组' unless hash['favorites'].is_a?(Array)
        result['favorites'] = hash['favorites'].map(&:to_s).uniq.take(500)
      end
      if hash.key?('enabled')
        raise ArgumentError, 'enabled 必须是对象' unless hash['enabled'].is_a?(Hash)
        hash['enabled'].each do |id, enabled|
          raise ArgumentError, '插件启用状态格式无效' unless id.match?(/\A[a-z0-9][a-z0-9-]*\z/) && [true, false].include?(enabled)
        end
        result['enabled'] = result['enabled'].merge(hash['enabled'])
      end
      if hash.key?('shortcuts')
        raise ArgumentError, 'shortcuts 必须是数组' unless hash['shortcuts'].is_a?(Array)
        raise ArgumentError, '快捷入口最多 100 个' if hash['shortcuts'].size > 100
        seen = {}
        result['shortcuts'] = hash['shortcuts'].map do |item|
          raise ArgumentError, '快捷入口格式无效' unless item.is_a?(Hash)
          id, title, type, target = %w[id title type target].map { |key| item[key].to_s.strip }
          raise ArgumentError, '快捷入口 ID 仅支持字母、数字、下划线及连字符' unless id.match?(/\A[a-zA-Z0-9_-]{1,80}\z/)
          raise ArgumentError, "快捷入口 ID 重复：#{id}" if seen[id]
          seen[id] = true
          raise ArgumentError, '快捷入口名称须为 1–80 个字符' unless (1..80).cover?(title.length)
          raise ArgumentError, '快捷入口类型须为 command 或 url' unless %w[command url].include?(type)
          raise ArgumentError, '快捷入口目标不能为空' if target.empty?
          if type == 'url'
            target = normalize_source(target)
            raise ArgumentError, '网址入口只支持 HTTP(S)' unless target.match?(/\Ahttps?:\/\//)
          end
          copy(item).merge('id' => id, 'title' => title, 'type' => type, 'target' => target)
        end
      end
      result
    end

    def save(hash)
      result = validate(hash)
      result['schemaVersion'] = SCHEMA_VERSION
      result['revision'] = result.fetch('revision', 0) + 1
      atomic_write(path, JSON.pretty_generate(result))
      context[:read_only] = false
      context[:diagnostics] = []
      context[:last_good] = copy(result)
      context[:data] = copy(result)
      context[:fingerprint] = Digest::SHA256.file(path).hexdigest
      write_last_good(result)
      copy(result)
    rescue SystemCallError, IOError => error
      add_diagnostic('settings_write_failed', "设置保存失败，上一版本保持有效：#{error.message}")
      raise StorageError, "设置保存失败，上一版本保持有效：#{error.message}"
    end

    def sources
      current['sources']
    end

    def add_source(url)
      save('sources' => sources + [normalize_source(url)])
    end
  end
end
