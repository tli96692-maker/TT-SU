# Command outcomes are explicit; a tool being activated is not a model change.
module SUHub
  module Result
    STATUSES = %w[completed started cancelled failed unavailable].freeze
    DEFAULT_MESSAGES = {
      'completed' => '操作已完成', 'started' => '工具已启动，请继续操作',
      'cancelled' => '已取消', 'failed' => '操作失败', 'unavailable' => '当前不可用'
    }.freeze
    module_function

    def build(status, message: nil, code: nil, changed: nil, data: nil)
      status = status.to_s
      raise ArgumentError, "未知命令状态：#{status}" unless STATUSES.include?(status)
      raise ArgumentError, 'changed 必须为 true、false 或 nil' unless [true, false, nil].include?(changed)
      { status: status, ok: %w[completed started].include?(status),
        code: (code || "command_#{status}").to_s,
        message: (message || DEFAULT_MESSAGES.fetch(status)).to_s,
        changed: changed, data: data }
    end

    STATUSES.each do |status|
      define_singleton_method(status) { |**options| build(status, **options) }
    end

    def from_error(error, message: nil)
      build(error.is_a?(ArgumentError) ? :unavailable : :failed,
        code: error.is_a?(ArgumentError) ? 'invalid_input' : 'execution_error',
        message: message || error.message, data: { errorType: error.class.name })
    end

    def normalize(value, command_id:, invocation_id:, request_id: nil)
      result = if value.is_a?(Hash) && (value.key?(:status) || value.key?('status'))
        item = value.transform_keys(&:to_sym)
        build(item[:status], message: item[:message], code: item[:code], changed: item[:changed], data: item[:data])
      elsif value.is_a?(Hash) && (value.key?(:ok) || value.key?('ok'))
        item = value.transform_keys(&:to_sym)
        build(item[:ok] == true ? :completed : :failed,
          message: item[:message], code: item[:code] || 'legacy_result', changed: item[:changed], data: item[:data])
      elsif value == true
        completed(code: 'legacy_completed')
      elsif value == false
        failed(code: 'command_returned_false', message: '工具未完成操作')
      else
        started(code: 'legacy_result_unconfirmed',
          message: '已调用工具入口，结果尚未确认；请在工具窗口中继续操作')
      end
      result.merge(commandId: command_id.to_s, invocationId: invocation_id,
        requestId: request_id)
    end
  end
end
