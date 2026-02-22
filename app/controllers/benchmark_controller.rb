class BenchmarkController < ApplicationController
  def compute
    start_time = Time.now

    # A heavy mathematical workload
    sum = 0
    10_000.times do
      1000.times do |i|
        sum += (i * 2) - 1
      end
    end

    # Explicitly check if ZJIT is enabled in the current Ruby process
    zjit_enabled = defined?(RubyVM::ZJIT) && RubyVM::ZJIT.enabled?

    end_time = Time.now
    duration_ms = ((end_time - start_time) * 1000).round(2)

    render json: {
      zjit_enabled: zjit_enabled,
      ruby_version: RUBY_VERSION,
      result: sum,
      time_taken_ms: duration_ms,
      message: zjit_enabled ? "ZJIT completely compiled and optimized this request!" : "Standard Ruby interpreter executed this request."
    }
  end
end
