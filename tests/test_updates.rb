# Pure update-discovery tests: no network, no SketchUp, no filesystem mutations.
require 'json'
module SUHub
  VERSION = '0.2.2'
end
require_relative '../src/hub/updates'

module UpdateTests
  REPOSITORY = 'example-owner/su-hub'.freeze
  CONFIG = { 'schemaVersion' => 1, 'repository' => REPOSITORY, 'channel' => 'preview',
             'assetName' => 'su_zhongshu-core.rbz' }.freeze
  API = "https://api.github.com/repos/#{REPOSITORY}/releases?per_page=30".freeze
  module_function

  def assert(name, value)
    raise "FAIL: #{name}" unless value
    @assertions = (@assertions || 0) + 1
  end

  def response(value, status: 200, headers: {})
    { status: status, headers: headers, body: JSON.generate(value) }
  end

  def pair(version = '0.2.3', preview: false)
    tag = "v#{version}"
    encoded = URI.encode_www_form_component(tag).gsub('+', '%20')
    assets = [SUHub::Updates::CORE_ASSET, SUHub::Updates::MANIFEST_ASSET].map do |name|
      { 'name' => name, 'state' => 'uploaded', 'size' => name.end_with?('.rbz') ? 2048 : 512,
        'browser_download_url' => "https://github.com/#{REPOSITORY}/releases/download/#{encoded}/#{name}" }
    end
    release = {
      'tag_name' => tag, 'draft' => false, 'prerelease' => preview,
      'html_url' => "https://github.com/#{REPOSITORY}/releases/tag/#{encoded}", 'assets' => assets,
      'published_at' => '2026-10-23T00:00:00Z', 'body' => "Updated tools\nInstall and restart SketchUp."
    }
    manifest = {
      'schemaVersion' => 1, 'repository' => REPOSITORY, 'version' => version,
      'channel' => preview || version.include?('-') ? 'preview' : 'stable',
      'assetName' => 'su_zhongshu-core.rbz', 'sha256' => 'a' * 64, 'bytes' => 2048,
      'compatibility' => { 'platforms' => ['windows'], 'minSketchUp' => 2024, 'maxSketchUp' => 2024 }
    }
    [release, manifest]
  end

  def routes_for(*pairs)
    routes = { API => response(pairs.map(&:first)) }
    pairs.each { |release, manifest| routes[release['assets'].last['browser_download_url']] = response(manifest) }
    routes
  end

  def check(routes, **options)
    calls = []
    transport = lambda do |url, max_bytes:|
      calls << [url, max_bytes]
      value = routes.fetch(url) { raise "Unexpected network target: #{url}" }
      raise value if value.is_a?(Exception)
      value
    end
    result = SUHub::Updates.check(**{ config: CONFIG, transport: transport, sketchup_version: '24.0.484', platform: 'windows' }.merge(options))
    # Every returned value must pass the actual JSON bridge encoding.
    JSON.generate(result)
    [result, calls]
  end

  def expect_status(name, status, routes, **options)
    result, calls = check(routes, **options)
    assert("#{name}: expected #{status}, got #{result[:status]} (#{result[:message]})", result[:status] == status)
    assert("#{name}: failures have no download", result[:downloadUrl].nil?) if result[:ok] == false
    [result, calls]
  end

  def run
    result, calls = expect_status('unconfigured avoids all network', 'unconfigured', {}, config: CONFIG.merge('repository' => ''))
    assert('no network for missing repository', calls.empty?)
    assert('all documented keys exist when unconfigured', %i[ok status currentVersion repository channel version message releaseUrl downloadUrl sha256 publishedAt notes compatible].all? { |key| result.key?(key) })
    ['../repo', 'owner/repo/extra', 'https://github.com/o/r', 'owner/r?x=1', 'owner/..', 'owner/r%2fsecret', "owner/repo\n"].each do |repo|
      _, calls = expect_status("invalid repository #{repo.inspect}", 'invalid_configuration', {}, config: CONFIG.merge('repository' => repo))
      assert('invalid repository never requests', calls.empty?)
    end
    expect_status('unknown channel', 'invalid_configuration', {}, config: CONFIG.merge('channel' => 'nightly'))
    expect_status('wrong schema', 'invalid_configuration', {}, config: CONFIG.merge('schemaVersion' => 2))
    expect_status('wrong core asset', 'invalid_configuration', {}, config: CONFIG.merge('assetName' => 'unknown.rbz'))

    release, manifest = pair
    result, calls = expect_status('valid available release', 'available', routes_for([release, manifest]))
    assert('only API and manifest fetched, never downloads RBZ', calls.map(&:first) == [API, release['assets'].last['browser_download_url']])
    assert('API and manifest size limits passed', calls.map(&:last) == [SUHub::Updates::API_LIMIT, SUHub::Updates::MANIFEST_LIMIT])
    assert('verified metadata returned', result[:compatible] && result[:sha256] == 'a' * 64 && result[:bytes] == 2048 && result[:version] == '0.2.3')
    assert('metadata not called a verified download', !result[:message].include?('已校验'))
    expect_status('equal version', 'up_to_date', routes_for(pair('0.2.2')))
    expect_status('installed ahead', 'up_to_date', routes_for(pair('0.2.1')))
    expect_status('empty list not latest', 'no_release', { API => response([]) })
    draft = pair
    draft[0]['draft'] = true
    expect_status('draft excluded', 'no_release', routes_for(draft))
    invalid_flags = pair
    invalid_flags[0]['draft'] = 'false'
    expect_status('malformed release flags rejected', 'invalid_response', routes_for(invalid_flags))
    bad_version = pair
    bad_version[0]['tag_name'] = 'nightly'
    expect_status('unrecognised tag not latest', 'no_release', routes_for(bad_version))

    preview, stable = pair('0.3.0-beta.2', preview: true), pair('0.2.10')
    routes = routes_for(preview, stable, pair('0.2.9'))
    result, = expect_status('preview selects semantic highest', 'available', routes)
    assert('preview selected', result[:version] == '0.3.0-beta.2')
    result, = expect_status('stable excludes prerelease', 'available', routes, config: CONFIG.merge('channel' => 'stable'))
    assert('stable numeric patch comparison', result[:version] == '0.2.10')
    expect_status('stable has only preview', 'no_release', routes_for(preview), config: CONFIG.merge('channel' => 'stable'))
    flag_preview = pair('0.3.0', preview: true)
    expect_status('stable excludes prerelease flag on normal version', 'no_release', routes_for(flag_preview), config: CONFIG.merge('channel' => 'stable'))
    result, = expect_status('numeric prerelease identifiers', 'available', routes_for(pair('1.0.0-beta.2', preview: true), pair('1.0.0-beta.11', preview: true)))
    assert('beta.11 follows beta.2', result[:version] == '1.0.0-beta.11')
    versions = %w[1.0.0-alpha 1.0.0-alpha.1 1.0.0-alpha.beta 1.0.0-beta 1.0.0-beta.2 1.0.0-beta.11 1.0.0-rc.1 1.0.0]
    versions.each_cons(2) { |a, b| assert("SemVer precedence #{a} < #{b}", SUHub::Updates.compare_versions(SUHub::Updates.parse_version(a), SUHub::Updates.parse_version(b)) == -1) }
    assert('build metadata does not change version precedence', SUHub::Updates.compare_versions(SUHub::Updates.parse_version('1.0.0+build.1'), SUHub::Updates.parse_version('1.0.0+build.9')).zero?)
    %w[01.0.0 1.01.0 1.0.01 1.0.0-beta.01 1.0 1.0.0-].each { |value| assert("invalid SemVer #{value}", SUHub::Updates.parse_version(value).nil?) }

    expect_status('unsupported SU version', 'incompatible', routes_for(pair), sketchup_version: '25.0.0')
    result, = expect_status('unsupported OS', 'incompatible', routes_for(pair), platform: 'macos')
    assert('incompatible release is visible without download', !result[:compatible] && result[:downloadUrl].nil? && result[:releaseUrl])
    expect_status('unknown SU version not guessed', 'compatibility_unknown', routes_for(pair), sketchup_version: nil)
    expect_status('malformed SU version not guessed', 'compatibility_unknown', routes_for(pair), sketchup_version: 'unknown')
    expect_status('full SU year supported', 'available', routes_for(pair), sketchup_version: '2024')

    {
      'wrong repository' => ['repository', 'attacker/repo'], 'wrong version' => ['version', '99.0.0'],
      'wrong schema' => ['schemaVersion', 2], 'wrong channel' => ['channel', 'preview'],
      'wrong name' => ['assetName', 'evil.rbz'], 'bad sha' => ['sha256', 'a' * 63],
      'wrong bytes' => ['bytes', 99], 'string bytes' => ['bytes', '2048'],
      'missing compatibility' => ['compatibility', nil],
      'reversed compatibility' => ['compatibility', { 'platforms' => ['windows'], 'minSketchUp' => 2025, 'maxSketchUp' => 2024 }],
      'bad OS' => ['compatibility', { 'platforms' => ['linux'], 'minSketchUp' => 2024, 'maxSketchUp' => 2024 }]
    }.each do |name, (key, value)|
      entry = pair
      entry[1][key] = value
      expect_status("manifest #{name}", 'invalid_response', routes_for(entry))
    end

    %w[https://evil.example/core.rbz http://github.com/example-owner/su-hub/releases/download/v0.2.3/su_zhongshu-core.rbz https://github.com/attacker/repo/releases/download/v0.2.3/su_zhongshu-core.rbz].each do |url|
      entry = pair
      entry[0]['assets'].first['browser_download_url'] = url
      _, calls = expect_status('malicious asset URL', 'invalid_response', routes_for(entry))
      assert('invalid URL rejected before asset request', calls.size == 1)
    end
    entry = pair
    entry[0]['html_url'] = 'https://github.com/attacker/repo/releases/tag/v0.2.3'
    expect_status('wrong release repository', 'invalid_response', routes_for(entry))
    entry = pair
    entry[0]['assets'].first['state'] = 'new'
    expect_status('incomplete upload', 'invalid_response', routes_for(entry))
    entry = pair
    entry[0]['assets'].first['size'] = 0
    expect_status('empty asset', 'invalid_response', routes_for(entry))
    entry = pair
    entry[0]['assets'].shift
    expect_status('missing core package', 'invalid_response', routes_for(entry))
    entry = pair
    entry[0]['assets'].pop
    expect_status('missing manifest', 'invalid_response', { API => response([entry[0]]) })
    entry = pair
    entry[0]['assets'] << entry[0]['assets'].first.dup
    expect_status('duplicate package', 'invalid_response', routes_for(entry))
    entry = pair
    entry[0]['published_at'] = 'yesterday'
    expect_status('invalid published time', 'invalid_response', routes_for(entry))

    api_errors = {
      'offline' => SocketError.new('offline'),
      'rate_limited' => response({}, status: 429),
      'source_unavailable' => response({}, status: 404),
      'invalid_response' => { status: 200, headers: {}, body: '<html>not JSON</html>' }
    }
    api_errors.each { |status, value| expect_status("API #{status}", status, { API => value }) }
    expect_status('403 rate limit', 'rate_limited', { API => response({}, status: 403, headers: { 'X-RateLimit-Remaining' => '0' }) })
    expect_status('403 without rate evidence', 'offline', { API => response({}, status: 403) })
    expect_status('503 service failure', 'offline', { API => response({}, status: 503) })
    expect_status('API object instead of list', 'invalid_response', { API => response({ 'message' => 'not a list' }) })
    expect_status('malformed response headers rejected', 'invalid_response', { API => { status: 200, headers: nil, body: '[]' } })
    expect_status('API oversized', 'invalid_response', { API => { status: 200, body: ' ' * (SUHub::Updates::API_LIMIT + 1) } })
    expect_status('API foreign redirect forbidden', 'invalid_response', { API => response({}, status: 302, headers: { 'location' => 'https://evil.example/' }) })
    expect_status('API repository redirect requires reconfiguration', 'invalid_response', { API => response({}, status: 301, headers: { 'location' => API.sub('example-owner', 'other-owner') }) })

    entry = pair
    manifest_url = entry[0]['assets'].last['browser_download_url']
    redirects = ['http://release-assets.githubusercontent.com/a', 'https://user:pass@release-assets.githubusercontent.com/a',
                 'https://release-assets.githubusercontent.com:444/a', 'https://release-assets.githubusercontent.com.evil.example/a',
                 'https://127.0.0.1/private', 'https://github.com/attacker/repo/releases/download/v0.2.3/release-manifest.json']
    redirects.each do |url|
      routes = routes_for(entry)
      routes[manifest_url] = response({}, status: 302, headers: { 'location' => url })
      _, calls = expect_status('unsafe redirect rejected', 'invalid_response', routes)
      assert('unsafe destination never requested', calls.size == 2)
    end
    routes = routes_for(entry)
    cdn = 'https://release-assets.githubusercontent.com/github-production-release-asset/fixture?token=public-signed-link'
    routes[manifest_url] = response({}, status: 302, headers: { 'location' => cdn })
    routes[cdn] = response(entry[1])
    result, calls = expect_status('legitimate GitHub CDN redirect', 'available', routes)
    assert('CDN signed URL not exposed to UI', !JSON.generate(result).include?('public-signed-link'))
    assert('CDN fetched with manifest size limit', calls.last == [cdn, SUHub::Updates::MANIFEST_LIMIT])
    routes[cdn] = response({}, status: 302, headers: { 'location' => cdn })
    expect_status('redirect loop bounded', 'invalid_response', routes)
    routes = routes_for(entry)
    routes[manifest_url] = { status: 200, body: ' ' * (SUHub::Updates::MANIFEST_LIMIT + 1) }
    expect_status('manifest oversized', 'invalid_response', routes)
    routes[manifest_url] = response({}, status: 404)
    expect_status('missing remote manifest not latest', 'source_unavailable', routes)

    entry = pair
    entry[0]['body'] = "<script>alert(1)</script>\u0000" + ('a' * 15_000)
    result, = expect_status('notes treated as bounded literal text', 'available', routes_for(entry))
    assert('notes retain literal markup without executing', result[:notes].start_with?('<script>alert(1)</script>'))
    assert('notes bounded and control bytes removed', result[:notes].length == 10_000 && !result[:notes].include?("\u0000"))
    entry[0]['body'] = { 'unexpected' => 'object' }
    expect_status('malformed release notes rejected', 'invalid_response', routes_for(entry))
    puts "UPDATE DISCOVERY TESTS PASSED (#{@assertions} assertions; offline fixtures only)"
  end
end

UpdateTests.run
