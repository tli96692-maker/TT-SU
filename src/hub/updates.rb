# Read-only public GitHub release discovery. No SketchUp, Settings or UI calls:
# the host may run check on a worker and deliver its result on the UI thread.
require 'json'
require 'net/http'
require 'uri'
require 'openssl'
require 'time'

module SUHub
  module Updates
    MANIFEST_ASSET = 'release-manifest.json'.freeze
    CORE_ASSET = 'su_zhongshu-core.rbz'.freeze
    API_LIMIT = 2 * 1024 * 1024
    MANIFEST_LIMIT = 64 * 1024
    REDIRECT_CODES = [301, 302, 303, 307, 308].freeze
    CDN_HOSTS = %w[release-assets.githubusercontent.com objects.githubusercontent.com].freeze
    SEMVER = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?\z/
    class InvalidResponse < StandardError; end
    class RequestFailure < StandardError
      attr_reader :status
      def initialize(status, message)
        @status = status
        super(message)
      end
    end

    module_function

    # Optional config and transport arguments support deterministic offline tests.
    # transport.call(url, max_bytes:) returns {status:, headers:, body:}; it must
    # not follow redirects. Redirect validation remains in this module.
    def configuration(config: nil)
      data = config
      if data.nil?
        path = File.expand_path('../release.json', __dir__)
        data = File.file?(path) ? JSON.parse(File.read(path, encoding: 'UTF-8').sub(/\A\uFEFF/, '')) : {
          'schemaVersion' => 1, 'repository' => '', 'channel' => 'preview', 'assetName' => CORE_ASSET
        }
      end
      return config_error('发行配置必须是 JSON 对象。') unless data.is_a?(Hash)
      data = data.transform_keys(&:to_s)
      repository = data['repository']
      channel = data['channel']
      return config_error('发行配置版本或安装包名称不受支持。') unless data['schemaVersion'] == 1 && data['assetName'] == CORE_ASSET
      return config_error('发行渠道必须是 preview 或 stable。') unless %w[preview stable].include?(channel)
      return config_error('GitHub 仓库名称无效，应为 owner/repo。') unless repository.is_a?(String) && (repository.empty? || valid_repository?(repository))
      configured = !repository.empty?
      {
        ok: true, status: configured ? 'ready' : 'unconfigured', configured: configured,
        currentVersion: current_version, repository: repository, channel: channel, assetName: CORE_ASSET,
        message: configured ? '已配置公开 GitHub 发行源，点击检查更新。' : '尚未配置发行仓库；当前可继续使用已安装功能。'
      }
    rescue JSON::ParserError, EncodingError, SystemCallError, IOError
      config_error('发行配置无法读取或不是有效 JSON。')
    end

    def check(sketchup_version: nil, platform: nil, transport: nil, config: nil)
      settings = configuration(config: config)
      base = {
        ok: settings[:ok], status: settings[:status], currentVersion: settings[:currentVersion],
        repository: settings[:repository], channel: settings[:channel], version: nil,
        message: settings[:message], releaseUrl: nil, downloadUrl: nil, sha256: nil,
        publishedAt: nil, notes: '', compatible: nil
      }
      return base unless settings[:configured]
      current = parse_version(current_version)
      raise InvalidResponse, '当前宿主版本不是受支持的语义版本。' unless current
      repository = settings[:repository]
      api_url = "https://api.github.com/repos/#{repository}/releases?per_page=30"
      releases = fetch_json(api_url, max_bytes: API_LIMIT, transport: transport, asset: false)
      raise InvalidResponse, 'GitHub 返回的发行列表格式无效。' unless releases.is_a?(Array)
      candidates = releases.filter_map do |release|
        raise InvalidResponse, 'GitHub 发行记录格式无效。' unless release.is_a?(Hash)
        unless [true, false].include?(release['draft']) && [true, false].include?(release['prerelease'])
          raise InvalidResponse, 'GitHub 发行记录缺少公开状态或渠道标记。'
        end
        next if release['draft'] == true
        version = parse_version(release['tag_name'].to_s.sub(/\Av/, ''))
        next unless version
        next if settings[:channel] == 'stable' && (release['prerelease'] == true || version[:pre])
        [version, release]
      end
      return base.merge(ok: true, status: 'no_release', message: '此渠道未找到可识别的公开版本；尚不能判断是否需要更新。') if candidates.empty?
      version, release = candidates.max { |a, b| compare_versions(a[0], b[0]) }
      selected = validate_release(release, repository, version, transport)
      compatibility = compatible?(selected[:compatibility], sketchup_version, platform)
      payload = base.merge(selected.reject { |key, _| key == :compatibility }, compatible: compatibility)
      if compare_versions(version, current) <= 0
        return payload.merge(ok: true, status: 'up_to_date', message: '本次查询未发现比当前版本更新的有效发行版。')
      end
      if compatibility == false
        return payload.merge(ok: true, status: 'incompatible', downloadUrl: nil,
                             message: '发现新版本，但它不支持当前 SketchUp 版本或操作系统。')
      end
      if compatibility.nil?
        return payload.merge(ok: true, status: 'compatibility_unknown', downloadUrl: nil,
                             message: '发现新版本，但缺少环境信息，尚不能确认兼容性。')
      end
      payload.merge(ok: true, status: 'available', message: '发现兼容的新版本。请下载后通过 SketchUp 扩展程序管理器安装并重启。')
    rescue RequestFailure => error
      (base || {}).merge(ok: false, status: error.status, message: error.message)
    rescue InvalidResponse => error
      (base || {}).merge(ok: false, status: 'invalid_response', message: error.message)
    rescue JSON::ParserError, EncodingError, TypeError, ArgumentError
      (base || {}).merge(ok: false, status: 'invalid_response', message: '发行元数据无效，未提供更新下载链接。')
    rescue SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
      (base || {}).merge(ok: false, status: 'offline', message: '暂时无法连接 GitHub；请检查网络后重试。已安装功能仍可使用。')
    end

    def config_error(message)
      { ok: false, status: 'invalid_configuration', configured: false, currentVersion: current_version,
        repository: '', channel: '', assetName: CORE_ASSET, message: message }
    end

    def current_version
      SUHub.const_defined?(:VERSION, false) ? SUHub::VERSION.to_s : ''
    end

    def valid_repository?(repository)
      return false unless repository.match?(%r{\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9_.-]{1,100}\z})
      owner, name = repository.split('/')
      !owner.end_with?('-') && !%w[. ..].include?(name)
    end

    def parse_version(value)
      match = SEMVER.match(value)
      return nil unless match
      pre = match[4]&.split('.')
      return nil if pre && pre.any? { |part| part.match?(/\A\d+\z/) && part.size > 1 && part.start_with?('0') }
      { text: value, numbers: [match[1].to_i, match[2].to_i, match[3].to_i], pre: pre }
    end

    def compare_versions(left, right)
      comparison = left[:numbers] <=> right[:numbers]
      return comparison unless comparison.zero?
      a, b = left[:pre], right[:pre]
      return 0 if a.nil? && b.nil?
      return 1 if a.nil?
      return -1 if b.nil?
      [a.size, b.size].min.times do |index|
        x, y = a[index], b[index]
        numeric_x, numeric_y = x.match?(/\A\d+\z/), y.match?(/\A\d+\z/)
        comparison = if numeric_x && numeric_y
                       x.to_i <=> y.to_i
                     elsif numeric_x != numeric_y
                       numeric_x ? -1 : 1
                     else
                       x <=> y
                     end
        return comparison unless comparison.zero?
      end
      a.size <=> b.size
    end

    def validate_release(release, repository, version, transport)
      tag = release['tag_name']
      encoded_tag = URI.encode_www_form_component(tag).gsub('+', '%20')
      release_url = "https://github.com/#{repository}/releases/tag/#{encoded_tag}"
      raise InvalidResponse, '发行页面不属于配置的仓库。' unless release['html_url'] == release_url
      assets = release['assets']
      raise InvalidResponse, '发行版缺少资产列表。' unless assets.is_a?(Array) && assets.all? { |item| item.is_a?(Hash) }
      found = {}
      [CORE_ASSET, MANIFEST_ASSET].each do |name|
        matches = assets.select { |item| item['name'] == name }
        raise InvalidResponse, "发行版缺少或重复 #{name}。" unless matches.size == 1
        expected_url = "https://github.com/#{repository}/releases/download/#{encoded_tag}/#{name}"
        item = matches.first
        raise InvalidResponse, '发行资产链接不属于同一个仓库和版本。' unless item['browser_download_url'] == expected_url
        raise InvalidResponse, '发行资产仍未上传完成。' unless item['state'] == 'uploaded'
        raise InvalidResponse, '发行资产大小无效。' unless item['size'].is_a?(Integer) && item['size'].positive?
        found[name] = item
      end
      raise InvalidResponse, '发行清单超过大小限制。' if found[MANIFEST_ASSET]['size'] > MANIFEST_LIMIT
      manifest = fetch_json(found[MANIFEST_ASSET]['browser_download_url'], max_bytes: MANIFEST_LIMIT, transport: transport, asset: true)
      raise InvalidResponse, '发行清单格式无效。' unless manifest.is_a?(Hash)
      expected_channel = release['prerelease'] == true || version[:pre] ? 'preview' : 'stable'
      unless manifest['schemaVersion'] == 1 && manifest['version'] == version[:text] &&
             manifest['repository'] == repository && manifest['channel'] == expected_channel && manifest['assetName'] == CORE_ASSET
        raise InvalidResponse, '发行清单与仓库、版本、渠道或安装包不一致。'
      end
      unless manifest['sha256'].is_a?(String) && manifest['sha256'].match?(/\A[0-9a-fA-F]{64}\z/) &&
             manifest['bytes'].is_a?(Integer) && manifest['bytes'].positive? && manifest['bytes'] == found[CORE_ASSET]['size']
        raise InvalidResponse, '安装包校验值或文件大小无效。'
      end
      compatibility = manifest['compatibility']
      unless compatibility.is_a?(Hash) && compatibility['platforms'].is_a?(Array) && !compatibility['platforms'].empty? &&
             compatibility['platforms'].all? { |value| %w[windows macos].include?(value) } &&
             compatibility['minSketchUp'].is_a?(Integer) && compatibility['maxSketchUp'].is_a?(Integer) &&
             compatibility['minSketchUp'] >= 2017 && compatibility['minSketchUp'] <= compatibility['maxSketchUp']
        raise InvalidResponse, '发行兼容性声明缺失或无效。'
      end
      published_at = release['published_at']
      raise InvalidResponse, '发行时间无效。' unless published_at.is_a?(String)
      Time.iso8601(published_at)
      raise InvalidResponse, '发行说明格式无效。' unless release['body'].nil? || release['body'].is_a?(String)
      {
        version: version[:text], releaseUrl: release_url, downloadUrl: found[CORE_ASSET]['browser_download_url'],
        sha256: manifest['sha256'].downcase, publishedAt: published_at, notes: plain_text(release['body']),
        compatible: nil, compatibility: compatibility, bytes: manifest['bytes']
      }
    end

    def compatible?(compatibility, sketchup_version, platform)
      platform ||= RUBY_PLATFORM.match?(/mswin|mingw|cygwin/) ? 'windows' : (RUBY_PLATFORM.include?('darwin') ? 'macos' : nil)
      return nil if platform.to_s.empty? || sketchup_version.to_s.empty?
      return nil unless sketchup_version.to_s.match?(/\A\d{2,4}(?:\.\d+)*\z/)
      major = sketchup_version.to_s.split('.').first.to_i
      major += 2000 if major < 100
      compatibility['platforms'].include?(platform.to_s.downcase) &&
        major.between?(compatibility['minSketchUp'], compatibility['maxSketchUp'])
    end

    # Plain text only; callers must use textContent, never an HTML/Markdown renderer.
    def plain_text(value)
      value.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
           .gsub(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/, '')[0, 10_000]
    end

    def safe_uri(url)
      uri = URI.parse(url)
      unless uri.is_a?(URI::HTTPS) && uri.host && uri.port == 443 && !uri.userinfo && !uri.fragment
        raise InvalidResponse, '更新链接必须是有效的 HTTPS 地址。'
      end
      uri
    rescue URI::InvalidURIError
      raise InvalidResponse, '更新链接格式无效。'
    end

    def fetch_json(url, max_bytes:, transport:, asset:)
      original = safe_uri(url)
      current = original
      4.times do |index|
        unless current == original || (asset && CDN_HOSTS.include?(current.host))
          raise InvalidResponse, '更新请求跳转到了不受支持的地址。'
        end
        response = transport ? transport.call(current.to_s, max_bytes: max_bytes) : http_get(current, max_bytes)
        raise InvalidResponse, '更新服务器响应格式无效。' unless response.is_a?(Hash)
        status = response[:status]
        raw_headers = response.fetch(:headers, {})
        raise InvalidResponse, '更新服务器响应头格式无效。' unless raw_headers.is_a?(Hash)
        headers = raw_headers.transform_keys { |key| key.to_s.downcase }
        if REDIRECT_CODES.include?(status)
          raise InvalidResponse, '更新请求重定向次数过多。' if index == 3
          current = safe_uri(URI.join(current.to_s, headers.fetch('location', '')).to_s)
          next
        end
        if status == 429 || (status == 403 && (headers['x-ratelimit-remaining'].to_s == '0' || headers.key?('retry-after')))
          raise RequestFailure.new('rate_limited', 'GitHub 暂时限制了更新检查频率，请稍后重试。')
        end
        if status == 404
          raise RequestFailure.new('source_unavailable', '发行仓库或附件不可访问；请确认仓库公开且发行资产已上传。')
        end
        unless status == 200
          raise RequestFailure.new('offline', 'GitHub 暂时无法提供发行信息，请稍后重试。')
        end
        body = response[:body]
        raise InvalidResponse, '更新响应超过大小限制或格式无效。' unless body.is_a?(String) && body.bytesize <= max_bytes
        return JSON.parse(body.force_encoding('UTF-8'))
      end
      raise InvalidResponse, '更新请求无法完成。'
    end

    def http_get(uri, max_bytes)
      # No authorization headers or tokens are read from the machine.
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 5
      http.read_timeout = 8
      http.write_timeout = 8
      http.max_retries = 0
      request = Net::HTTP::Get.new(uri.request_uri)
      request['User-Agent'] = "SU-ZhongShu/#{current_version}"
      request['Accept'] = uri.host == 'api.github.com' ? 'application/vnd.github+json' : 'application/json'
      request['X-GitHub-Api-Version'] = '2022-11-28' if uri.host == 'api.github.com'
      body = +''
      status = nil
      headers = {}
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      http.request(request) do |response|
        status = response.code.to_i
        headers = response.to_hash.transform_values(&:first)
        if headers['content-length'].to_i > max_bytes
          raise InvalidResponse, '更新响应超过大小限制。'
        end
        response.read_body do |chunk|
          raise Timeout::Error, 'update request exceeded time limit' if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > 20
          body << chunk
          raise InvalidResponse, '更新响应超过大小限制。' if body.bytesize > max_bytes
        end
      end
      { status: status, headers: headers, body: body }
    end
  end
end
