# SU 中枢 · 多源市场：本地/HTTPS catalog、校验、事务安装及自动回滚。
require 'json'
require 'net/http'
require 'uri'
require 'digest'
require 'fileutils'
require 'tmpdir'
require 'tempfile'
require 'securerandom'
require_relative 'zipx'

module SUHub
  module Market
    module_function
    TIMEOUT = 20
    MAX_CATALOG = 8 * 1024 * 1024
    ID_PATTERN = /\A[a-z0-9][a-z0-9-]{0,79}\z/
    VERSION_PATTERN = /\A\d+(?:[.\-]\d+)*(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?\z/

    def local_path(location)
      value = location.to_s
      return File.expand_path(value) if value.match?(/\A[A-Za-z]:[\\\/]/) || value.start_with?('/')
      return nil unless value.start_with?('file:')
      uri = URI.parse(Settings.escape_uri(value))
      raise '仅支持本机 file 地址' unless [nil, '', 'localhost'].include?(uri.host)
      path = URI::DEFAULT_PARSER.unescape(uri.path).force_encoding('UTF-8')
      path = path.sub(%r{\A/([A-Za-z]:/)}, '\\1') if File::ALT_SEPARATOR
      File.expand_path(path)
    end

    def resolve_location(location, source = nil)
      value = location.to_s
      return Settings.normalize_source(value) if local_path(value) || value.match?(/\Ahttps?:/)
      raise '下载地址缺少 catalog 基准位置' unless source
      if (base = local_path(source))
        File.expand_path(URI::DEFAULT_PARSER.unescape(value), File.dirname(base))
      else
        Settings.normalize_source(URI.join(source, Settings.escape_uri(value)).to_s)
      end
    end

    # The block streams each response chunk; redirects apply to both catalogs and ZIPs.
    def transfer(location, limit:, &write)
      if (path = local_path(location))
        raise "本地文件不存在：#{path}" unless File.file?(path)
        raise '文件超过允许大小' if File.size(path) > limit
        File.open(path, 'rb') do |file|
          while (chunk = file.read(64 * 1024))
            write.call(chunk)
          end
        end
        return
      end
      uri = URI.parse(Settings.normalize_source(location))
      raise '下载地址仅支持 HTTP(S) 或本地文件' unless %w[http https].include?(uri.scheme)
      http_transfer(uri, 0, limit, &write)
    end

    def http_transfer(uri, hops, limit, &write)
      raise '重定向过多' if hops > 5
      raise '重定向协议无效' unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = TIMEOUT
      http.read_timeout = 120
      request = Net::HTTP::Get.new(uri.request_uri)
      request['User-Agent'] = 'SUZhongShu/0.2'
      request['Accept-Encoding'] = 'identity'
      redirect = nil
      http.start do |connection|
        connection.request(request) do |response|
          if response.is_a?(Net::HTTPRedirection)
            raise '重定向缺少地址' unless response['location']
            redirect = URI.join(uri.to_s, response['location'])
            raise '拒绝 HTTPS 降级重定向' if uri.scheme == 'https' && redirect.scheme != 'https'
          else
            raise "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
            declared = response['content-length']
            raise '下载超过允许大小' if declared && declared.to_i > limit
            received = 0
            response.read_body do |chunk|
              received += chunk.bytesize
              raise '下载超过允许大小' if received > limit
              write.call(chunk)
            end
            raise '下载未完成' if declared && received != declared.to_i
          end
        end
      end
      http_transfer(redirect, hops + 1, limit, &write) if redirect
    end

    def fetch_catalog(source)
      body = ''.b
      transfer(source, limit: MAX_CATALOG) { |chunk| body << chunk }
      catalog = JSON.parse(body.force_encoding('UTF-8').sub(/\A\uFEFF/, ''))
      raise 'catalog 必须包含 plugins 数组' unless catalog.is_a?(Hash) && catalog['plugins'].is_a?(Array)
      catalog
    end

    def validate_catalog_entry(entry, source)
      raise 'catalog 条目必须是对象' unless entry.is_a?(Hash)
      raise '插件 ID 无效' unless entry['id'].is_a?(String) && entry['id'].match?(ID_PATTERN)
      %w[name version].each { |field| raise "#{entry['id']} 缺少 #{field}" if entry[field].to_s.strip.empty? }
      raise "#{entry['id']} 版本号无效" unless entry['official'] || entry['version'].to_s.match?(VERSION_PATTERN)
      result = entry.dup
      if entry['official']
        homepage = Settings.normalize_source(entry['homepage'])
        raise '官方主页须为 HTTP(S)' unless homepage.match?(/\Ahttps?:\/\//)
      else
        raise "#{entry['id']} 缺少有效 SHA256" unless entry['sha256'].to_s.match?(/\A[0-9a-f]{64}\z/i)
        raise "#{entry['id']} 缺少下载地址" if entry['url'].to_s.empty?
        result['url'] = resolve_location(entry['url'], source)
      end
      result
    end

    def catalogs
      merged = {}
      errors = []
      Settings.sources.each do |source|
        begin
          fetch_catalog(source)['plugins'].each do |entry|
            begin
              item = validate_catalog_entry(entry, source)
              merged[item['id']] = item
            rescue StandardError => error
              errors << "#{source}: #{error.message}"
            end
          end
        rescue StandardError => error
          errors << "#{source}: #{error.message}"
        end
      end
      [merged, errors]
    end

    def market_payload
      merged, errors = catalogs
      list = merged.map do |id, entry|
        local = SUHub.plugins[id]
        version = local && local[:manifest]['version']
        {
          id: id, name: entry['name'], version: entry['version'],
          category: entry['category'].to_s, description: entry['description'],
          license: entry['license'], author: entry['author'], keywords: Array(entry['keywords']),
          homepage: entry['homepage'], official: !!entry['official'], changelog: entry['changelog'],
          installed: !local.nil?, installedVersion: version,
          updateAvailable: !!(version && compare_versions(entry['version'], version).positive?),
          restartRequired: !!(local && local[:pending_restart])
        }
      end
      { count: list.size, plugins: list.sort_by { |item| item[:name].to_s }, errors: errors, sources: Settings.sources }
    end

    def version_parts(value)
      value = value.to_s.split('+', 2).first
      return [value.split('-').map(&:to_i), nil] if value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      core, prerelease = value.split('-', 2)
      [core.split('.').map(&:to_i), prerelease]
    end

    def compare_versions(a, b)
      left, pre_a = version_parts(a)
      right, pre_b = version_parts(b)
      [left.length, right.length].max.times do |index|
        comparison = (left[index] || 0) <=> (right[index] || 0)
        return comparison unless comparison.zero?
      end
      return 0 if pre_a == pre_b
      return 1 unless pre_a
      return -1 unless pre_b
      aa, bb = pre_a.split('.'), pre_b.split('.')
      [aa.length, bb.length].max.times do |index|
        return -1 unless aa[index]
        return 1 unless bb[index]
        x, y = aa[index], bb[index]
        comparison = if x.match?(/\A\d+\z/) && y.match?(/\A\d+\z/)
                       x.to_i <=> y.to_i
                     elsif x.match?(/\A\d+\z/)
                       -1
                     elsif y.match?(/\A\d+\z/)
                       1
                     else
                       x <=> y
                     end
        return comparison unless comparison.zero?
      end
      0
    end

    def validate_manifest(manifest, directory, expected_id: nil, expected_version: nil)
      raise 'manifest 必须是对象' unless manifest.is_a?(Hash)
      id = manifest['id']
      raise 'manifest.id 无效' unless id.is_a?(String) && id.match?(ID_PATTERN)
      raise 'manifest.id 与目标插件不匹配' if expected_id && expected_id != id
      %w[name version category entry].each { |key| raise "manifest 缺少 #{key}" if manifest[key].to_s.strip.empty? }
      raise 'manifest.version 无效' unless manifest['version'].match?(VERSION_PATTERN)
      raise 'manifest.version 与 catalog 不匹配' if expected_version && manifest['version'] != expected_version
      entry = ZipX.safe_join(directory, manifest['entry'])
      raise 'manifest.entry 必须指向插件目录内的 Ruby 文件' unless entry && entry.match?(/\.(?:rb|rbe|rbs)\z/i) && File.file?(entry)
      ZipX.ensure_no_symlinks(directory, entry)
      if manifest['command']
        raise 'manifest.command.id 无效' unless manifest['command'].is_a?(Hash) && manifest['command']['id'].to_s.match?(/\A[a-zA-Z0-9_-]{1,100}\z/)
      end
      dependencies = manifest.fetch('dependencies', [])
      raise 'manifest.dependencies 格式无效' unless dependencies.is_a?(Array) && dependencies.all? do |item|
        if item.is_a?(String)
          item.match?(ID_PATTERN) && item != id
        elsif item.is_a?(Hash)
          target = item['require']
          target.is_a?(String) && target.match?(/\A[a-zA-Z0-9_\/-]+(?:\.rb)?\z/) && !target.split('/').include?('..')
        else
          false
        end
      end
      manifest
    end

    def compatibility_errors(manifest)
      errors = []
      if defined?(Sketchup) && Sketchup.respond_to?(:version)
        major = Sketchup.version.to_i
        year = major < 2000 ? major + 2000 : major
        required = manifest.fetch('min_su', '2024').to_i
        required += 2000 if required.positive? && required < 2000
        errors << "需要 SketchUp #{required} 或更高版本" if required > year
      end
      Array(manifest['dependencies']).each do |id|
        if id.is_a?(Hash)
          target = id['require']
          available = $LOADED_FEATURES.any? { |feature| feature.tr('\\', '/').end_with?(target) }
          candidates = [target, target.sub(/\.rb\z/, '') + '.rb', target.sub(/\.rb\z/, '') + '.rbe', target.sub(/\.rb\z/, '') + '.rbs']
          available ||= $LOAD_PATH.any? { |base| candidates.any? { |candidate| File.file?(File.join(base, candidate)) } }
          available ||= defined?(Sketchup) && Sketchup.respond_to?(:find_support_file) && !!Sketchup.find_support_file(target, 'Plugins')
          errors << "缺少依赖 #{id['name'] || target}，请先通过扩展程序管理器安装后重启 SketchUp#{id['homepage'] ? '：' + id['homepage'] : ''}" unless available
        elsif !SUHub.plugins.key?(id)
          errors << "请先安装依赖插件 #{id}"
        elsif Settings.current['enabled'][id] == false
          errors << "请先启用依赖插件 #{id}"
        end
      end
      errors
    end

    def install_plugin(id, force: false)
      id = id.to_s
      raise '插件 ID 无效' unless id.match?(ID_PATTERN)
      merged, errors = catalogs
      entry = merged[id]
      return { ok: false, message: "市场中没有找到该插件#{errors.empty? ? '' : '；请检查插件源'}" } unless entry
      return { ok: false, message: '请前往官方页面获取该插件' } if entry['official']
      local = SUHub.plugins[id]
      if local && !force && compare_versions(entry['version'], local[:manifest]['version']) <= 0
        return { ok: false, message: '已安装当前版本或更高版本', id: id }
      end
      cache = File.join(Settings.dir, 'cache')
      FileUtils.mkdir_p(cache)
      Dir.mktmpdir('install-', cache) do |temporary|
        zip = File.join(temporary, 'download.zip')
        download(entry['url'], zip)
        actual = Digest::SHA256.file(zip).hexdigest
        raise 'SHA256 校验失败，已保留现有插件' unless actual.casecmp?(entry['sha256'])
        extract_dir = File.join(temporary, 'extracted')
        ZipX.extract(zip, extract_dir)
        candidates = Dir.glob(['manifest.json', '*/manifest.json'], base: extract_dir).filter_map do |relative|
          path = File.join(extract_dir, relative)
          manifest = JSON.parse(File.read(path, encoding: 'UTF-8').sub(/\A\uFEFF/, ''))
          [File.dirname(path), manifest] if manifest.is_a?(Hash) && manifest['id'] == id
        end
        raise '安装包必须包含唯一匹配的 manifest.json' unless candidates.length == 1
        source, manifest = candidates.first
        validate_manifest(manifest, source, expected_id: id, expected_version: entry['version'])
        problems = compatibility_errors(manifest)
        raise problems.join('；') unless problems.empty?
        commit_install(id, source)
      end
      plugin = SUHub.plugins[id]
      restart = !!plugin[:pending_restart]
      { ok: true, id: id, restartRequired: restart, message: "已安装 #{entry['name']} #{entry['version']}#{restart ? '；请重启 SketchUp 后使用新版' : '，可立即使用'}" }
    rescue StandardError => error
      SUHub.log("install #{id}: #{error.class}: #{error.message}") if SUHub.respond_to?(:log)
      { ok: false, id: id, message: "安装失败：#{error.message}" }
    end

    def commit_install(id, source)
      FileUtils.mkdir_p(SUHub::PLUGINS_DIR)
      stage = Dir.mktmpdir(".install-#{id}-", SUHub::PLUGINS_DIR)
      destination = File.join(SUHub::PLUGINS_DIR, id)
      backup = nil
      moved = false
      begin
        FileUtils.cp_r(File.join(source, '.'), stage)
        backup = backup_existing(destination)
        File.rename(stage, destination)
        moved = true
        SUHub.scan_plugins
        raise '安装后插件未能注册' unless SUHub.plugins.key?(id)
      rescue StandardError
        FileUtils.rm_rf(destination) if moved
        File.rename(backup, destination) if backup && File.directory?(backup)
        SUHub.scan_plugins
        raise
      ensure
        FileUtils.rm_rf(stage) if File.directory?(stage)
      end
    end

    def update_plugin(id)
      install_plugin(id)
    end

    def backup_existing(destination)
      return unless File.directory?(destination)
      path = File.join(SUHub::PLUGINS_DIR, '_backup', "#{File.basename(destination)}-#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(4)}")
      FileUtils.mkdir_p(File.dirname(path))
      File.rename(destination, path)
      path
    end

    def download(location, target = nil)
      unless target
        temporary = Tempfile.new(['suzhongshu-download-', '.zip'])
        target = temporary.path
        temporary.close
      end
      File.open(target, 'wb') { |file| transfer(location, limit: ZipX::MAX_ARCHIVE) { |chunk| file.write(chunk) } }
      target
    rescue StandardError
      FileUtils.rm_f(target) if target
      raise
    end
  end
end
