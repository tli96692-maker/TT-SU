# Network work is isolated from SketchUp's main thread. This only discovers
# releases; it does not download packages, install files, or modify models.
require 'thread'

module SUHub
  module UpdateBridge
    module_function
    CACHE_SECONDS = 600
    ERROR_CACHE_SECONDS = 30
    DEADLINE_SECONDS = 35
    MAX_WAITERS = 32

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def environment
      version = defined?(Sketchup) && Sketchup.respond_to?(:version) ? Sketchup.version : nil
      platform = if defined?(Sketchup) && Sketchup.respond_to?(:platform)
                   Sketchup.platform == :platform_win ? 'windows' : 'macos'
                 else
                   RUBY_PLATFORM.match?(/mswin|mingw/) ? 'windows' : 'unknown'
                 end
      { sketchup_version: version, platform: platform }
    end

    def deliver(dialog, request_id, result)
      SUHub.push(dialog, '__onHostUpdate', result, request_id)
    rescue StandardError
      # A closed HtmlDialog must not break other listeners or the cached result.
      nil
    end

    def request(dialog, request_id)
      config = Updates.configuration
      unless config[:status] == 'ready'
        deliver(dialog, request_id, config)
        return
      end
      env = environment # Capture every SketchUp API value on the UI thread.
      key = [config[:repository], config[:channel], SUHub::VERSION, env]
      if @cache && @cache[:key] == key && now < @cache[:expires]
        deliver(dialog, request_id, @cache[:result])
        return
      end
      @waiters ||= []
      if @waiters.length >= MAX_WAITERS
        deliver(dialog, request_id, {ok: false, status: 'busy', currentVersion: SUHub::VERSION,
                                    message: '更新检查正在进行，请稍后重试。'})
        return
      end
      @waiters << [dialog, request_id]
      return if @worker

      @key, @started, @queue = key, now, Queue.new
      queue = @queue
      @worker = Thread.new do
        begin
          queue << Updates.check(**env)
        rescue StandardError => error
          queue << {ok: false, status: 'offline', currentVersion: SUHub::VERSION,
                    message: "更新检查失败：#{error.message}"}
        end
      end
      @worker.report_on_exception = false
      @timer = UI.start_timer(0.1, true) { poll }
      nil
    rescue StandardError => error
      result = {ok: false, status: 'offline', currentVersion: SUHub::VERSION,
                message: "无法开始更新检查：#{error.message}"}
      if @worker
        @worker.kill
        complete(result)
      else
        deliver(dialog, request_id, result)
      end
      nil
    end

    def poll
      return unless @worker
      if !@queue.empty?
        complete(@queue.pop)
      elsif now - @started > DEADLINE_SECONDS
        @worker.kill
        complete({ok: false, status: 'offline', currentVersion: SUHub::VERSION,
                  message: '更新检查超时。已安装功能可以继续使用，请稍后重试。'})
      end
    end

    def complete(result)
      UI.stop_timer(@timer) if @timer
      @timer, @worker = nil, nil
      duration = result[:ok] ? CACHE_SECONDS : ERROR_CACHE_SECONDS
      @cache = {key: @key, result: result, expires: now + duration}
      waiters, @waiters = @waiters || [], []
      waiters.each { |dialog, request_id| deliver(dialog, request_id, result) }
      nil
    end
  end
end
